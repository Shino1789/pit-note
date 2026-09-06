# 休止手順（コスト削減のための一時停止）

Pitviaのβ版を一定期間使わない場合に、AWS課金が発生するリソースを削除し、コストを抑えるための手順。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。

---

# 結論

- `infra/terraform/aws`を`terraform destroy`することで、VPC・NAT Gateway・RDS・S3・ECR・ECS・ALB等のTerraform管理対象リソースを削除する。
- IAM Role・ACM証明書・Route53 Hosted Zone・GitHub OIDC Provider・AWS Budgetsは削除されない（Terraform管理外のため）。
- Vercel ProjectはTerraformで削除せず、アクセス防止のためCLIで手動Pauseする。
- Terraform State用S3バケット（`bootstrap`で作成）は絶対に`destroy`しない。

---

# 手順

## 1. 事前確認

```bash
cd infra/terraform/aws
terraform plan -destroy
```

意図した通り、削除対象がRDS/S3/ECR/ECS/ALB/NAT Gateway/VPC関連リソースのみであり、IAM/ACM/Route53等が含まれていないことを確認する。

## 2. AWSリソースの削除

```bash
terraform destroy
```

実行前に、確認プロンプトで削除対象リソース数・種類を必ず目視確認すること。

## 3. Vercel Projectの一時非公開化

Vercel Terraform Providerは Project の Pause/Resume に対応していないため、CLIで手動実行する。

```bash
vercel project pause pitvia
```

これはコスト削減ではなく（Hobbyプランは無料のため）、誤操作でのアクセス・デプロイを防止する目的。

## 4. 削除後の確認

- AWS Budgetsのアラートが正常な範囲に収まっていることを確認する。
- Route53の`api.pitviaapp.com`Aliasレコードは残ったままになる（ALB削除により参照先が無効化されるが、レコード自体は削除されない）。次回再構築時、`docs/operations/recovery.md`の手順でAliasを更新する。

---

# 注意事項

- `infra/terraform/bootstrap`（State用S3バケット）は今回のスコープでは`destroy`しない。
- Vercel Project自体（`infra/terraform/vercel`）は`destroy`しない（Pauseのみ）。
- JWTシークレット（Secrets Manager）はAWSリソース削除に含まれる。再構築後、値の再投入が必要になる（`docs/operations/recovery.md`参照。再投入によりリフレッシュトークンは無効化される）。
