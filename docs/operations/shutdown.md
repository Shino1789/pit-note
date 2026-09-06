# 休止手順（コスト削減のための一時停止）

Pitviaのβ版を一定期間使わない場合に、AWS課金が発生するリソースを削除し、コストを抑えるための手順。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。自動化スクリプトは`scripts/prod/shutdown.sh`（対で`scripts/prod/recover.sh` / `scripts/prod/status.sh`）。

---

# 結論

- `infra/terraform/aws`を`terraform destroy`することで、VPC・NAT Gateway・RDS・S3・ECR・ECS・ALB等のTerraform管理対象リソースを削除する。
- IAM Role・ACM証明書・Route53 Hosted Zone・GitHub OIDC Provider・AWS Budgetsは削除されない（Terraform管理外のため）。
- Vercel ProjectはTerraformで削除せず、アクセス防止のためCLIで手動（またはスクリプト経由で）Pauseする。
- Terraform State用S3バケット（`bootstrap`で作成）は絶対に`destroy`しない。

---

# 何が消えるか

| リソース | 消えるもの | 復旧可否 |
| --- | --- | --- |
| RDS（`pitvia-db`） | **βデータ全て**（`skip_final_snapshot=true`のためスナップショットも残らない） | ❌ 復旧不可（新規空DBとして再作成のみ） |
| S3（`pitvia-prod-storage`） | 整備写真等のアップロード済みファイル全て（`force_destroy=true`） | ❌ 復旧不可 |
| ECR（`pitvia-api`） | 保存済みDocker imageすべて | ✅ CD再実行で再生成可能 |
| ECS Cluster/Service/Task Definition | 稼働中のコンテナ・Task Definition revision履歴 | ✅ Terraform apply + CDで再構築可能 |
| Secrets Manager（JWT） | JWT署名鍵の値（`recovery_window_in_days=0`のため即時削除） | ✅ 再生成可能（既存リフレッシュトークン/セッションは無効化） |
| VPC / Subnet / SG / NAT Gateway / ALB | ネットワーク構成一式（ALBは再作成でDNS名が変わる） | ✅ Terraform applyで再構築可能 |

## 1. 事前確認

```bash
cd infra/terraform/aws
terraform plan -destroy
```

意図した通り、削除対象がRDS/S3/ECR/ECS/ALB/NAT Gateway/VPC関連リソースのみであり、IAM/ACM/Route53等が含まれていないことを確認する。

## 2. AWSリソースの削除

自動化スクリプトを使う場合（推奨。安全確認・destroy対象表示・Vercel pauseを一貫して行う）:

```bash
./scripts/prod/shutdown.sh          # 通常実行（二段階の明示的確認あり）
./scripts/prod/shutdown.sh --dry-run  # destroy対象の確認のみ（実行しない）
```

**Vercel pauseはfail-closed設計**: pauseに失敗した場合、`shutdown.sh`はAWSのdestroyを一切実行せず終了する（Frontendが公開されたままBackendだけdestroyされる中途半端な状態を避けるため）。

手動で行う場合:

```bash
terraform destroy
```

実行前に、確認プロンプトで削除対象リソース数・種類を必ず目視確認すること。

## 3. Vercel Projectの一時非公開化

Vercel Terraform Providerは Project の Pause/Resume に対応していないため、CLIで手動実行する（`prod/shutdown.sh`使用時はAWS destroy前に自動実行される）。

```bash
vercel project pause pitvia
```

これはコスト削減ではなく（Hobbyプランは無料のため）、誤操作でのアクセス・デプロイを防止する目的。

## 4. 削除後の確認

```bash
./scripts/prod/status.sh
```

- AWS Budgetsのアラートが正常な範囲に収まっていることを確認する。
- Route53の`api.pitviaapp.com`Aliasレコードは残ったままになる（ALB削除により参照先が無効化されるが、レコード自体は削除されない）。次回再構築時、`docs/operations/recovery.md`の手順でAliasを更新する。

---

# 注意事項

- `infra/terraform/bootstrap`（State用S3バケット）は今回のスコープでは`destroy`しない。
- Vercel Project自体（`infra/terraform/vercel`）は`destroy`しない（Pauseのみ）。
- JWTシークレット（Secrets Manager）はAWSリソース削除に含まれる。再構築後、値の再投入が必要になる（`docs/operations/recovery.md`参照。再投入によりリフレッシュトークンは無効化される）。
