#!/usr/bin/env bash
# CountryWars_RP をサーバーに入れる。root で実行する。
#
#   install_rp.sh stage  … GitHub Actions が本番（VM100）に送って実行する。中身を確かめて「待ち」に置くだけで、
#                          配っている RP には触らない。何度 push されても、待ちは最後の1つだけ。
#   install_rp.sh apply  … BDS が止まっていて次に起動する直前に、本番の sh/run.sh が実行する。
#                          待ちがあれば、版を決めて入れ替える。
#
# BDS は RP の版を起動時に読み、動いている間はその版の名前のまま、ディスクにある今の中身を配る。
# 動いている間に中身を入れ替えると、前にその版を落とした人は古いまま、初めて落とす人は新しい中身になり、
# 人によって届いたり届かなかったりする（2026-10-31）。そのため、入れ替えは BDS の起動の直前にだけ行う。
#
# プレイヤーの端末は、リソースパックを「uuid と版（manifest.json の header.version）」でキャッシュしている。
# 中身を変えても版が同じだと、前に落とした古いものが使われ続ける。そこで、中身が変わっていたら
# 版をこのスクリプトが自動で上げてから入れる。リポジトリの manifest.json の版は触らなくてよい。
#
#   新しい版 = リポジトリの版が、今まで使ったどの版よりも大きければ、その版
#              そうでなければ、今まで使った一番大きい版の3つ目を +1
#   今まで使った版 = 今入っている RP の manifest.json・world_resource_packs.json・minecraftpe/<uuid>_<版>.zip・
#                    deploy.log に入れたと書いた版（BDS が自分で作った zip は再起動の後に残らないため）
#
# 版は apply のときに決める（待っている間に本番の RP が手で直されても、その時点の状態から決めるため）。
# 中身が同じなら何も入れ替えない（版も上げない）。比べるときは manifest.json の header.version を除く。
#
# 環境変数（どれも省略できる）:
#   ARCHIVE       stage: Actions が送ってきた tar.gz（既定 /tmp/CountryWars_RP.tar.gz）
#   RELEASE_ID    stage: コミットの sha（控えのフォルダ名と deploy.log に使う）
#   SERVER_DIR    BDS のフォルダ（既定 /home/minecraft/S3/server。staging の VM117 は /home/minecraft/server）
#   DISCORD_LANG  stage: texts/ja_JP.lang のコピー先（Discord bot 用。既定は本番の discord_chat。空にするとコピーしない）
#   DRY_RUN=1     stage: 待ちに置いたら入る版を表示するだけで、何も書き換えない
#   BDS_PROCESS   apply: 動いていたら入れ替えない BDS のプロセス名（既定 bedrock_server。試験用）
set -Eeuo pipefail

MODE="${1:-}"
case "$MODE" in
  stage|apply) ;;
  *)
    echo "使い方: install_rp.sh stage|apply" >&2
    exit 2
    ;;
esac

ARCHIVE="${ARCHIVE:-/tmp/CountryWars_RP.tar.gz}"
RELEASE_ID="${RELEASE_ID:-manual}"
SERVER_DIR="${SERVER_DIR:-/home/minecraft/S3/server}"
DISCORD_LANG="${DISCORD_LANG-/home/minecraft/S3/discord_chat/ja_JP.lang}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/minecraft/.deploy/countrywars-rp}"
DRY_RUN="${DRY_RUN:-0}"
BDS_PROCESS="${BDS_PROCESS:-bedrock_server}"
readonly EXPECTED_PACK_UUID="d23a70f8-df54-4aa5-9b7e-166e5d17e6d2"
readonly PENDING_DIR="$DEPLOY_ROOT/pending"
readonly LOG_FILE="$DEPLOY_ROOT/deploy.log"

# 普段の起動ではここで終わる（待ちが無ければ何も読まない）
if [ "$MODE" = apply ] && [ ! -d "$PENDING_DIR" ]; then
  exit 0
fi
if [ "$MODE" = apply ] && pgrep -x "$BDS_PROCESS" >/dev/null; then
  echo "$(date '+%F %T') BDS が動いているので、入れ替えません（待ちは次の起動で入れます）"
  exit 0
fi

LEVEL_NAME="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" | tr -d '\r')"
test -n "$LEVEL_NAME"
readonly WORLD_DIR="$SERVER_DIR/worlds/$LEVEL_NAME"
readonly RP_PARENT="$WORLD_DIR/resource_packs"
readonly RP_DIR="$RP_PARENT/CountryWars_RP"
readonly WORLD_PACKS_FILE="$WORLD_DIR/world_resource_packs.json"
readonly ARCHIVE_DIR="$SERVER_DIR/minecraftpe"

test -d "$RP_PARENT"
test -d "$ARCHIVE_DIR"
test -f "$WORLD_PACKS_FILE"
jq empty "$WORLD_PACKS_FILE"
test "$(jq -er --arg id "$EXPECTED_PACK_UUID" '[.[] | select(.pack_id == $id)] | length' "$WORLD_PACKS_FILE")" = "1"

mkdir -p "$DEPLOY_ROOT"

# stage と apply を同時に動かさない。apply は BDS の起動を待たせないよう、10秒で諦める
exec 8>"$DEPLOY_ROOT/lock"
if [ "$MODE" = apply ]; then
  if ! flock -w 10 8; then
    echo "$(date '+%F %T') stage が動いているので、入れ替えません（待ちは次の起動で入れます）"
    exit 0
  fi
  if [ ! -d "$PENDING_DIR" ]; then
    exit 0
  fi
  RELEASE_ID="$(cat "$PENDING_DIR/release" 2>/dev/null || echo unknown)"
else
  flock -w 120 8
fi

case "$RELEASE_ID" in
  ''|*[!0-9A-Za-z._-]*)
    echo "Invalid release id: $RELEASE_ID" >&2
    exit 1
    ;;
esac
# 同じ秒に2回動いても、控えや failed- のフォルダが重ならないよう、プロセス番号も付ける
readonly DEPLOY_ID="${RELEASE_ID}-$(date +%Y%m%d%H%M%S)-$$"
readonly STAGE_DIR="$DEPLOY_ROOT/stage-$DEPLOY_ID"
readonly BACKUP_DIR="$DEPLOY_ROOT/backups/$DEPLOY_ID"

STAGED_PACK_ARCHIVE=""
trap 'rm -rf "$STAGE_DIR" "$DEPLOY_ROOT/pending.new-$DEPLOY_ID"; [ -z "$STAGED_PACK_ARCHIVE" ] || rm -f "$STAGED_PACK_ARCHIVE"' EXIT

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
version_text() { jq -r 'if . == null then "なし" else join(".") end' <<<"$1"; }

# パックの中身を確かめる（stage では展開した直後、apply では待ちを写した直後）
check_pack() {
  test -f "$1/manifest.json"
  test -f "$1/texts/ja_JP.lang"
  jq empty "$1/manifest.json"
  test "$(jq -er '.header.uuid' "$1/manifest.json")" = "$EXPECTED_PACK_UUID"
  version_of "$1/manifest.json" >/dev/null
}

# $1 のパックを入れるとしたら、中身が変わるか（CHANGED）と、入れる版（NEW_VERSION）を決める
decide_version() {
  local src="$1" zip_path zip_version other_diffs
  REPO_VERSION="$(version_of "$src/manifest.json")"
  DEPLOYED_VERSION=null
  if [ -f "$RP_DIR/manifest.json" ]; then
    DEPLOYED_VERSION="$(version_of "$RP_DIR/manifest.json")"
  fi
  WORLD_VERSION="$(jq -ec --arg id "$EXPECTED_PACK_UUID" 'first(.[] | select(.pack_id == $id) | .version)' "$WORLD_PACKS_FILE")"

  local known=("$DEPLOYED_VERSION" "$WORLD_VERSION")
  for zip_path in "$ARCHIVE_DIR/${EXPECTED_PACK_UUID}_"*.zip; do
    [ -e "$zip_path" ] || continue
    zip_version="${zip_path##*_}"
    zip_version="${zip_version%.zip}"
    if [[ "$zip_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      known+=("[${zip_version//./,}]")
    fi
  done
  # deploy.log の「入れた」行（changed / applied）の版。staged の行の版は見込みなので数えない
  if [ -f "$LOG_FILE" ]; then
    while read -r zip_version; do
      known+=("[${zip_version//./,}]")
    done < <(awk -F'\t' '$4 == "changed" || $4 == "unchanged" || $4 == "applied" { print $3 }' "$LOG_FILE" \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi
  MAX_KNOWN="$(printf '%s\n' "${known[@]}" | jq -sc 'map(select(. != null)) | max')"

  # 中身が変わったか（manifest.json は header.version を除いて比べる）
  # diff の出力は英語で受け取る。本番は LANG=ja_JP.UTF-8 で、日本語の出力だと下の grep で manifest の行を外せず、
  # 版だけ違うときも「変わった」になっていた（2026-10-31）
  CHANGED=1
  if [ "$DEPLOYED_VERSION" != null ]; then
    other_diffs="$(LC_ALL=C diff -rq "$src" "$RP_DIR" \
      | grep -vxF "Files $src/manifest.json and $RP_DIR/manifest.json differ" || true)"
    if [ -z "$other_diffs" ] \
      && cmp -s <(jq -S 'del(.header.version)' "$src/manifest.json") \
                <(jq -S 'del(.header.version)' "$RP_DIR/manifest.json"); then
      CHANGED=0
    fi
  fi
  # 中身が同じでも、リポジトリの版が今の版より上なら、わざと上げたものとして配り直す
  if [ "$CHANGED" = 0 ] && jq -en --argjson repo "$REPO_VERSION" --argjson now "$DEPLOYED_VERSION" '$repo > $now' >/dev/null; then
    CHANGED=1
  fi

  if [ "$CHANGED" = 1 ]; then
    NEW_VERSION="$(jq -nc --argjson repo "$REPO_VERSION" --argjson max "$MAX_KNOWN" '
      if $max == null or $repo > $max then $repo else [$max[0], $max[1], $max[2] + 1] end')"
  else
    NEW_VERSION="$DEPLOYED_VERSION"
  fi
  NEW_VERSION_TEXT="$(version_text "$NEW_VERSION")"

  echo "リポジトリの版: $(version_text "$REPO_VERSION")"
  echo "入っている版: $(version_text "$DEPLOYED_VERSION")（world_resource_packs.json: $(version_text "$WORLD_VERSION")、今まで使った一番大きい版: $(version_text "$MAX_KNOWN")）"
}

log_line() { # <状態>  状態は staged / canceled / unchanged / applied / apply-failed
  printf '%s\t%s\t%s -> %s\t%s\n' "$(date '+%F %T')" "$RELEASE_ID" \
    "$(version_text "$DEPLOYED_VERSION")" "$NEW_VERSION_TEXT" "$1" >> "$LOG_FILE"
}

# ---------------------------------------------------------------- stage
if [ "$MODE" = stage ]; then
  [ -z "$DISCORD_LANG" ] || test -f "$DISCORD_LANG"
  test -s "$ARCHIVE"
  mkdir "$STAGE_DIR"
  tar \
    --extract \
    --gzip \
    --file="$ARCHIVE" \
    --directory="$STAGE_DIR" \
    --no-same-owner \
    --no-same-permissions
  check_pack "$STAGE_DIR"
  decide_version "$STAGE_DIR"

  if [ "$CHANGED" = 1 ]; then
    echo "中身が変わったので、待ちに置きます。次の起動で版 $NEW_VERSION_TEXT として入る見込みです"
  else
    echo "中身が今配っているものと同じなので、待ちには置きません（版 $NEW_VERSION_TEXT のまま）"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY_RUN=1 なので、ここで終わります"
    exit 0
  fi

  # Discord bot 用の翻訳。bot が読むのは bot の起動時だけなので、ここでコピーしてよい
  if [ -n "$DISCORD_LANG" ] && ! cmp -s "$STAGE_DIR/texts/ja_JP.lang" "$DISCORD_LANG"; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$DISCORD_LANG" "$BACKUP_DIR/discord_chat.ja_JP.lang"
    install -m 0644 "$STAGE_DIR/texts/ja_JP.lang" "$DISCORD_LANG.tmp.$DEPLOY_ID"
    mv "$DISCORD_LANG.tmp.$DEPLOY_ID" "$DISCORD_LANG"
  fi

  if [ "$CHANGED" = 1 ]; then
    # 待ちは丸ごと入れ替える（前の待ちは、まだ誰にも配っていないので捨ててよい）
    mkdir "$DEPLOY_ROOT/pending.new-$DEPLOY_ID"
    mv "$STAGE_DIR" "$DEPLOY_ROOT/pending.new-$DEPLOY_ID/pack"
    printf '%s\n' "$RELEASE_ID" > "$DEPLOY_ROOT/pending.new-$DEPLOY_ID/release"
    if [ -d "$PENDING_DIR" ]; then
      mv "$PENDING_DIR" "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
    fi
    mv "$DEPLOY_ROOT/pending.new-$DEPLOY_ID" "$PENDING_DIR"
    rm -rf "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
    log_line staged
    echo "::notice title=CountryWars_RP::版 $NEW_VERSION_TEXT を用意しました。入るのは次のサーバーの再起動（4時・12時・18時）から"
  else
    if [ -d "$PENDING_DIR" ]; then
      mv "$PENDING_DIR" "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
      rm -rf "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
      log_line canceled
      echo "前の待ちを取り消しました（今配っているものと同じ中身に戻ったため）"
    fi
    echo "::notice title=CountryWars_RP::中身が今配っているものと同じなので、入れ替えません（版 $NEW_VERSION_TEXT のまま）"
  fi

  # run.sh から呼ぶ apply 用に、このスクリプト自身を置く（動いている最中のものを書き換えないよう mv で差し替える）
  SELF="$(readlink -f "${BASH_SOURCE[0]}")"
  if [ "$SELF" != "$DEPLOY_ROOT/install_rp.sh" ]; then
    install -m 0755 "$SELF" "$DEPLOY_ROOT/install_rp.sh.tmp.$DEPLOY_ID"
    mv "$DEPLOY_ROOT/install_rp.sh.tmp.$DEPLOY_ID" "$DEPLOY_ROOT/install_rp.sh"
  fi
  rm -f "$ARCHIVE"
  exit 0
fi

# ---------------------------------------------------------------- apply
echo "$(date '+%F %T') 待ち（$RELEASE_ID）を入れます"
RP_MOVED=0
RP_INSTALLED=0
ZIP_INSTALLED=0
PACK_ARCHIVE=""
PACK_ARCHIVE_NAME=""

# 途中で失敗したら、入れ替える前に戻して、待ちを failed- に移す（毎回の起動で同じ失敗を繰り返さないため）
on_error() {
  local status=$?
  # set -E なので $( ) の中の失敗でも呼ばれる。戻すのは親でだけ行う（親でもこの関数がもう一度呼ばれる）
  if [ "$BASH_SUBSHELL" -gt 0 ]; then
    exit "$status"
  fi
  trap - ERR TERM
  set +e
  echo "$(date '+%F %T') 入れ替えに失敗しました（終了コード $status）。元に戻します"
  rm -f "$WORLD_PACKS_FILE.tmp.$DEPLOY_ID"
  if [ "$ZIP_INSTALLED" = 1 ]; then
    if [ -f "$BACKUP_DIR/$PACK_ARCHIVE_NAME" ]; then
      cp -a "$BACKUP_DIR/$PACK_ARCHIVE_NAME" "$PACK_ARCHIVE"
    else
      rm -f "$PACK_ARCHIVE"
    fi
  fi
  rm -f "$PACK_ARCHIVE.tmp.$DEPLOY_ID"
  if [ "$RP_INSTALLED" = 1 ]; then
    mv "$RP_DIR" "$BACKUP_DIR/CountryWars_RP.failed"
  fi
  if [ "$RP_MOVED" = 1 ]; then
    mv "$BACKUP_DIR/CountryWars_RP" "$RP_DIR"
  fi
  mv "$PENDING_DIR" "$DEPLOY_ROOT/failed-$DEPLOY_ID"
  NEW_VERSION_TEXT="${NEW_VERSION_TEXT:-?}"
  DEPLOYED_VERSION="${DEPLOYED_VERSION:-null}"
  log_line apply-failed
  echo "待ちは $DEPLOY_ROOT/failed-$DEPLOY_ID に移しました"
  exit 1
}
trap on_error ERR
# run.sh は timeout 30 で呼ぶ。打ち切られたときも元に戻す
trap on_error TERM

cp -a "$PENDING_DIR/pack" "$STAGE_DIR"
check_pack "$STAGE_DIR"
decide_version "$STAGE_DIR"

if [ "$CHANGED" = 0 ]; then
  echo "中身が今のものと同じなので、入れ替えません（版 $NEW_VERSION_TEXT のまま）"
  trap - ERR TERM
  mv "$PENDING_DIR" "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
  rm -rf "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
  log_line unchanged
  exit 0
fi
echo "版 $NEW_VERSION_TEXT で入れます"

jq --argjson version "$NEW_VERSION" '.header.version = $version' "$STAGE_DIR/manifest.json" > "$STAGE_DIR/manifest.json.tmp"
mv "$STAGE_DIR/manifest.json.tmp" "$STAGE_DIR/manifest.json"

PACK_ARCHIVE_NAME="${EXPECTED_PACK_UUID}_${NEW_VERSION_TEXT}.zip"
PACK_ARCHIVE="$ARCHIVE_DIR/$PACK_ARCHIVE_NAME"
STAGED_PACK_ARCHIVE="$DEPLOY_ROOT/${PACK_ARCHIVE_NAME}.${DEPLOY_ID}.tmp"
(
  cd "$STAGE_DIR"
  zip -qr "$STAGED_PACK_ARCHIVE" . -x '.git/*'
)
unzip -t "$STAGED_PACK_ARCHIVE" >/dev/null

mkdir -p "$BACKUP_DIR"
cp -a "$WORLD_PACKS_FILE" "$BACKUP_DIR/world_resource_packs.json"
if [ -e "$PACK_ARCHIVE" ]; then
  cp -a "$PACK_ARCHIVE" "$BACKUP_DIR/$PACK_ARCHIVE_NAME"
fi
if [ -e "$RP_DIR" ]; then
  mv "$RP_DIR" "$BACKUP_DIR/CountryWars_RP"
  RP_MOVED=1
fi
mv "$STAGE_DIR" "$RP_DIR"
RP_INSTALLED=1

install -m 0644 "$STAGED_PACK_ARCHIVE" "$PACK_ARCHIVE.tmp.$DEPLOY_ID"
ZIP_INSTALLED=1
mv "$PACK_ARCHIVE.tmp.$DEPLOY_ID" "$PACK_ARCHIVE"

if [ "$WORLD_VERSION" != "$NEW_VERSION" ]; then
  jq \
    --arg id "$EXPECTED_PACK_UUID" \
    --argjson version "$NEW_VERSION" \
    'map(if .pack_id == $id then .version = $version else . end)' \
    "$WORLD_PACKS_FILE" > "$WORLD_PACKS_FILE.tmp.$DEPLOY_ID"
  mv "$WORLD_PACKS_FILE.tmp.$DEPLOY_ID" "$WORLD_PACKS_FILE"
fi

trap - ERR TERM
mv "$PENDING_DIR" "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
rm -rf "$DEPLOY_ROOT/pending.old-$DEPLOY_ID"
log_line applied
echo "$(date '+%F %T') 版 $NEW_VERSION_TEXT を入れました"
