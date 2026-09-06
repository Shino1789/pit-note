# scripts/

開発環境操作（`dev/`）と、本番β環境操作（`prod/`）を、ディレクトリレベルで明確に分離しています。**`dev/`と`prod/`を混同しないよう、実行前に必ずパスを確認してください。**

```
scripts/
├── dev/     … ローカルDocker Compose開発環境の操作（破壊的な操作でも影響範囲はローカルのみ）
└── prod/    … 本番β環境（AWS/Vercel）の操作（破壊的な操作が実際の本番環境に影響する）
```

---

## scripts/dev/

ローカルのDocker Compose開発環境を操作する。リポジトリルートから実行する。

| コマンド | 内容 |
| --- | --- |
| `./scripts/dev/up.sh` | 全コンテナを起動し、Web/APIのヘルスチェック完了後にブラウザを開く |
| `./scripts/dev/down.sh` | 全コンテナを停止する |
| `./scripts/dev/reset.sh` | コンテナ・ネットワーク・Volumeを削除する（PostgreSQL/node_modules/MinIOデータも初期化される） |
| `./scripts/dev/logs.sh` | 全コンテナのログをリアルタイム表示する |

---

## scripts/prod/

**本番β環境（AWS/Vercel）を直接操作する。`dev/`と違い、ここでの破壊的操作は実際の本番環境に影響します。**

| コマンド | 内容 |
| --- | --- |
| `./scripts/prod/status.sh` | 本番β環境の状態確認（**read-only**。AWS/Vercel/Terraformの状態を一覧表示するだけで、一切変更を加えない） |
| `./scripts/prod/shutdown.sh` | 本番β環境をpause + AWS destroyする**破壊的操作**。RDSデータ・S3画像・ECRイメージ・JWT Secret等が失われる |
| `./scripts/prod/recover.sh` | Terraform apply + Secret再投入 + GitHub Actions CD + 疎通確認 + Vercel resumeによる復旧 |
| `./scripts/prod/lib/common.sh` | 上記3スクリプトが共通で使うライブラリ（単体では実行しない） |

### ⚠️ `shutdown.sh`について

**`shutdown.sh`は本番β環境を実際に破棄するため、通常の開発用スクリプト（`dev/`配下）よりも厳重な確認が必要です。** 実行すると以下の二段階確認を経て、初めてAWSリソースのdestroyに進みます。

1. スクリプト開始直後: `DESTROY PITVIA BETA` という固定フレーズの完全一致入力（1文字でも違えば即終了）
2. `terraform plan -destroy`実行後: 実際のdestroy対象を提示したうえでの`[yes/no]`確認

どちらか一方でも拒否した場合、破壊的操作は一切行われません。事前に内容だけ確認したい場合は`./scripts/prod/shutdown.sh --dry-run`を使ってください（確認プロンプト自体が出ず、destroyもしません）。

詳しい手順は`docs/operations/shutdown.md` / `docs/operations/recovery.md`を参照してください。
