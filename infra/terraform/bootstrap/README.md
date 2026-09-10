# Terraform Bootstrap

`infra/terraform/aws` と `infra/terraform/vercel` が使用する、Terraform state保管用S3 bucketをここで作成します。

## なぜ分離しているか

state保管用のS3 bucket自体をTerraformで管理し、かつそのTerraformのstateを同じbucketに置くと循環参照になります（bucketを消すとstateも消え、stateがないとbucketを消したことを検知できない）。そのため、このbootstrapディレクトリだけは**local state**のまま運用し、`infra/terraform/aws` / `infra/terraform/vercel` とは完全に独立させています。

## 初回セットアップ手順

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan
terraform apply
```

作成されるのは以下のみです。

- S3 bucket（`pitvia-terraform-state`）: versioning有効・SSE-S3暗号化・Public Access Block有効

## 注意事項

- このディレクトリの `terraform.tfstate` は **Gitにコミットしない**（リポジトリの `.gitignore` で除外済み）
- 一度作成したら、通常はこのディレクトリで再度 `apply` する必要はない
- このbucketを誤って `terraform destroy` すると、`infra/terraform/aws` / `infra/terraform/vercel` のstateが保管先を失うため、destroyは絶対に実行しない
