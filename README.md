# CountryWars_RP

建国鯖のリソースパック。

## 本番への反映

- `main` に push すると、GitHub Actions が本番サーバーに入れる（`.github/workflows/deploy.yml`）。
- プレイヤーに届くのは、次のサーバーの再起動（4時・12時・18時）から。
- **manifest.json の版（`header.version`）は上げなくてよい。** 中身が変わっていれば、入れるときに自動で上げる（今まで使った一番大きい版の3つ目を +1）。手で上げた版が今までのどの版よりも大きければ、その版を使う。
- 中身が前と同じなら、何も入れ替えない（版も上げない）。
- そのため、リポジトリの manifest.json の版と本番の版は一致しない。本番の版は Actions のログの「版 X.Y.Z を入れました」で分かる。
- `README.md` と `.github` はパックに入れない。

仕組みの詳細は `.github/scripts/install_rp.sh` の先頭に書いてある。
