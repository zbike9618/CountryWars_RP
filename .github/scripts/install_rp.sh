#!/usr/bin/env bash
# CountryWars_RP をサーバーに入れる。GitHub Actions が本番（VM100）に送って、root で実行する。
#
# プレイヤーの端末は、リソースパックを「uuid と版（manifest.json の header.version）」でキャッシュしている。
# 中身を変えても版が同じだと、前に落とした古いものが使われ続ける。そこで、中身が変わっていたら
# 版をこのスクリプトが自動で上げてから入れる。リポジトリの manifest.json の版は触らなくてよい。
#
#   新しい版 = リポジトリの版が、今まで使ったどの版よりも大きければ、その版
#              そうでなければ、今まで使った一番大きい版の3つ目を +1
#   今まで使った版 = 今入っている RP の manifest.json・world_resource_packs.json・minecraftpe/<uuid>_<版>.zip
#
# 中身が同じなら何も入れ替えない（版も上げない）。比べるときは manifest.json の header.version を除く。
# BDS はパックの版を起動時に読むので、プレイヤーに届くのは次の再起動から。
#
# 環境変数（どれも省略できる）:
#   ARCHIVE       Actions が送ってきた tar.gz（既定 /tmp/CountryWars_RP.tar.gz）
#   RELEASE_ID    コミットの sha（控えのフォルダ名に使う）
#   SERVER_DIR    BDS のフォルダ（既定 /home/minecraft/S3/server。staging の VM117 は /home/minecraft/server）
#   DISCORD_LANG  texts/ja_JP.lang のコピー先（Discord bot 用。既定は本番の discord_chat。空にするとコピーしない）
#   DRY_RUN=1     新しい版を決めて表示するだけで、何も書き換えない
set -Eeuo pipefail

ARCHIVE="${ARCHIVE:-/tmp/CountryWars_RP.tar.gz}"
RELEASE_ID="${RELEASE_ID:-manual}"
SERVER_DIR="${SERVER_DIR:-/home/minecraft/S3/server}"
DISCORD_LANG="${DISCORD_LANG-/home/minecraft/S3/discord_chat/ja_JP.lang}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/minecraft/.deploy/countrywars-rp}"
DRY_RUN="${DRY_RUN:-0}"
readonly EXPECTED_PACK_UUID="d23a70f8-df54-4aa5-9b7e-166e5d17e6d2"

case "$RELEASE_ID" in
  ''|*[!0-9A-Za-z._-]*)
    echo "Invalid release id: $RELEASE_ID" >&2
    exit 1
    ;;
esac

LEVEL_NAME="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" | tr -d '\r')"
test -n "$LEVEL_NAME"
readonly WORLD_DIR="$SERVER_DIR/worlds/$LEVEL_NAME"
readonly RP_PARENT="$WORLD_DIR/resource_packs"
readonly RP_DIR="$RP_PARENT/CountryWars_RP"
readonly WORLD_PACKS_FILE="$WORLD_DIR/world_resource_packs.json"
readonly ARCHIVE_DIR="$SERVER_DIR/minecraftpe"
readonly DEPLOY_ID="${RELEASE_ID}-$(date +%Y%m%d%H%M%S)"
readonly STAGE_DIR="$DEPLOY_ROOT/stage-$DEPLOY_ID"
readonly BACKUP_DIR="$DEPLOY_ROOT/backups/$DEPLOY_ID"

test -d "$RP_PARENT"
test -d "$ARCHIVE_DIR"
test -f "$WORLD_PACKS_FILE"
[ -z "$DISCORD_LANG" ] || test -f "$DISCORD_LANG"
jq empty "$WORLD_PACKS_FILE"
test "$(jq -er --arg id "$EXPECTED_PACK_UUID" '[.[] | select(.pack_id == $id)] | length' "$WORLD_PACKS_FILE")" = "1"

mkdir -p "$DEPLOY_ROOT"
STAGED_PACK_ARCHIVE=""
trap 'rm -rf "$STAGE_DIR"; [ -z "$STAGED_PACK_ARCHIVE" ] || rm -f "$STAGED_PACK_ARCHIVE"' EXIT
mkdir "$STAGE_DIR"

test -s "$ARCHIVE"
tar \
  --extract \
  --gzip \
  --file="$ARCHIVE" \
  --directory="$STAGE_DIR" \
  --no-same-owner \
  --no-same-permissions

test -f "$STAGE_DIR/manifest.json"
test -f "$STAGE_DIR/texts/ja_JP.lang"
jq empty "$STAGE_DIR/manifest.json"
test "$(jq -er '.header.uuid' "$STAGE_DIR/manifest.json")" = "$EXPECTED_PACK_UUID"

# 版は [整数, 整数, 整数]。jq は配列を前から順に数として比べるので、そのまま大小を比べられる
version_of() {
  jq -ec '
    .header.version
    | if type == "array" and length == 3 and all(.[]; type == "number" and floor == . and . >= 0)
      then .
      else error("header.version must contain three integers")
      end
  ' "$1"
}
REPO_VERSION="$(version_of "$STAGE_DIR/manifest.json")"

DEPLOYED_VERSION=null
if [ -f "$RP_DIR/manifest.json" ]; then
  DEPLOYED_VERSION="$(version_of "$RP_DIR/manifest.json")"
fi
WORLD_VERSION="$(jq -ec --arg id "$EXPECTED_PACK_UUID" 'first(.[] | select(.pack_id == $id) | .version)' "$WORLD_PACKS_FILE")"

known=("$DEPLOYED_VERSION" "$WORLD_VERSION")
for zip_path in "$ARCHIVE_DIR/${EXPECTED_PACK_UUID}_"*.zip; do
  [ -e "$zip_path" ] || continue
  zip_version="${zip_path##*_}"
  zip_version="${zip_version%.zip}"
  if [[ "$zip_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    known+=("[${zip_version//./,}]")
  fi
done
MAX_KNOWN="$(printf '%s\n' "${known[@]}" | jq -sc 'map(select(. != null)) | max')"

# 中身が変わったか（manifest.json は header.version を除いて比べる）
changed=1
if [ "$DEPLOYED_VERSION" != null ]; then
  other_diffs="$(diff -rq "$STAGE_DIR" "$RP_DIR" \
    | grep -vxF "Files $STAGE_DIR/manifest.json and $RP_DIR/manifest.json differ" || true)"
  if [ -z "$other_diffs" ] \
    && cmp -s <(jq -S 'del(.header.version)' "$STAGE_DIR/manifest.json") \
              <(jq -S 'del(.header.version)' "$RP_DIR/manifest.json"); then
    changed=0
  fi
fi
# 中身が同じでも、リポジトリの版が今の版より上なら、わざと上げたものとして配り直す
if [ "$changed" = 0 ] && jq -en --argjson repo "$REPO_VERSION" --argjson now "$DEPLOYED_VERSION" '$repo > $now' >/dev/null; then
  changed=1
fi

if [ "$changed" = 1 ]; then
  NEW_VERSION="$(jq -nc --argjson repo "$REPO_VERSION" --argjson max "$MAX_KNOWN" '
    if $max == null or $repo > $max then $repo else [$max[0], $max[1], $max[2] + 1] end')"
else
  NEW_VERSION="$DEPLOYED_VERSION"
fi
version_text() { jq -r 'if . == null then "なし" else join(".") end' <<<"$1"; }
NEW_VERSION_TEXT="$(version_text "$NEW_VERSION")"

echo "リポジトリの版: $(version_text "$REPO_VERSION")"
echo "入っている版: $(version_text "$DEPLOYED_VERSION")（world_resource_packs.json: $(version_text "$WORLD_VERSION")、今まで使った一番大きい版: $(version_text "$MAX_KNOWN")）"
if [ "$changed" = 1 ]; then
  echo "中身が変わったので、版 $NEW_VERSION_TEXT で入れます"
else
  echo "中身が変わっていないので、入れ替えません（版 $NEW_VERSION_TEXT のまま）"
fi
if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN=1 なので、ここで終わります"
  exit 0
fi

backup() {
  mkdir -p "$BACKUP_DIR"
  cp -a "$1" "$BACKUP_DIR/$2"
}

if [ "$changed" = 1 ]; then
  jq --argjson version "$NEW_VERSION" '.header.version = $version' "$STAGE_DIR/manifest.json" > "$STAGE_DIR/manifest.json.tmp"
  mv "$STAGE_DIR/manifest.json.tmp" "$STAGE_DIR/manifest.json"

  readonly PACK_ARCHIVE_NAME="${EXPECTED_PACK_UUID}_${NEW_VERSION_TEXT}.zip"
  readonly PACK_ARCHIVE="$ARCHIVE_DIR/$PACK_ARCHIVE_NAME"
  STAGED_PACK_ARCHIVE="$DEPLOY_ROOT/${PACK_ARCHIVE_NAME}.${DEPLOY_ID}.tmp"
  (
    cd "$STAGE_DIR"
    zip -qr "$STAGED_PACK_ARCHIVE" . -x '.git/*'
  )
  unzip -t "$STAGED_PACK_ARCHIVE" >/dev/null

  if [ -e "$RP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    mv "$RP_DIR" "$BACKUP_DIR/CountryWars_RP"
  fi
  mv "$STAGE_DIR" "$RP_DIR"

  if [ -e "$PACK_ARCHIVE" ]; then
    backup "$PACK_ARCHIVE" "$PACK_ARCHIVE_NAME"
  fi
  install -m 0644 "$STAGED_PACK_ARCHIVE" "$PACK_ARCHIVE.tmp.$DEPLOY_ID"
  mv "$PACK_ARCHIVE.tmp.$DEPLOY_ID" "$PACK_ARCHIVE"
fi

if [ "$WORLD_VERSION" != "$NEW_VERSION" ]; then
  backup "$WORLD_PACKS_FILE" world_resource_packs.json
  jq \
    --arg id "$EXPECTED_PACK_UUID" \
    --argjson version "$NEW_VERSION" \
    'map(if .pack_id == $id then .version = $version else . end)' \
    "$WORLD_PACKS_FILE" > "$WORLD_PACKS_FILE.tmp.$DEPLOY_ID"
  mv "$WORLD_PACKS_FILE.tmp.$DEPLOY_ID" "$WORLD_PACKS_FILE"
fi

if [ -n "$DISCORD_LANG" ] && ! cmp -s "$RP_DIR/texts/ja_JP.lang" "$DISCORD_LANG"; then
  backup "$DISCORD_LANG" discord_chat.ja_JP.lang
  install -m 0644 "$RP_DIR/texts/ja_JP.lang" "$DISCORD_LANG.tmp.$DEPLOY_ID"
  mv "$DISCORD_LANG.tmp.$DEPLOY_ID" "$DISCORD_LANG"
fi

rm -f "$ARCHIVE"
printf '%s\t%s\t%s -> %s\t%s\n' "$(date '+%F %T')" "$RELEASE_ID" \
  "$(version_text "$DEPLOYED_VERSION")" "$NEW_VERSION_TEXT" \
  "$([ "$changed" = 1 ] && echo changed || echo unchanged)" >> "$DEPLOY_ROOT/deploy.log"
if [ "$changed" = 1 ]; then
  echo "::notice title=CountryWars_RP::版 $NEW_VERSION_TEXT を入れました。プレイヤーに届くのは次のサーバーの再起動から"
else
  echo "::notice title=CountryWars_RP::中身が変わっていないので、入れ替えませんでした（版 $NEW_VERSION_TEXT のまま）"
fi
