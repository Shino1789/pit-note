# 再構築手順（休止からの復旧）

`docs/operations/shutdown.md`でAWSリソースを削除した状態から、Pitviaβ版を再構築するための手順。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。

---

# 結論

再構築は次の順序で行う。

1. `terraform apply`（`infra/terraform/aws`）でAWSインフラを再構築する
2. GitHub Actions `deploy.yml`を`workflow_dispatch`で手動実行し、ECRへのイメージpush・ECS Serviceへのデプロイを行う
3. JWTシークレットの値を手動で再投入する
4. Route53の`api.pitviaapp.com`Aliasレコードを、再作成後のALBに向けて手動更新する
5. RDS（新規作成された空DB）にFlywayマイグレーションが適用されていることを確認する
6. Vercel Projectを手動でResumeする

---

# 手順

## 1. AWSインフラの再構築

```bash
cd infra/terraform/aws
terraform plan
terraform apply
```

初回applyでは、ECS Task Definitionのimageは`<ECRリポジトリURL>:latest`という雛形イメージを参照する（実際にはまだECRにイメージが存在しないため、この時点でのECS Serviceのタスク起動は失敗する。次のステップでCDが正しいイメージを反映するまでの一時的な状態）。

## 2. GitHub Actions CDの手動実行

ECRリポジトリを削除・再作成しているため、既存イメージは失われている。`push`トリガー（`apps/api/**`等の変更）を待たず、`workflow_dispatch`で手動実行してECRへのイメージpushとECS Serviceへのデプロイを行う。

```bash
gh workflow run deploy.yml
```

実行後、`gh run watch`等でCircuit Breakerによるロールバックが発生していないこと、ALBのヘルスチェックが`healthy`になることを確認する。

## 3. JWTシークレットの再投入

`terraform apply`で作成された`aws_secretsmanager_secret.jwt`（`pitvia/prod/jwt-secret-key`）は、メタデータのみでSecret値を持たない。値を手動で投入する。

```bash
aws secretsmanager put-secret-value \
  --secret-id pitvia/prod/jwt-secret-key \
  --secret-string '{"JWT_SECRET_KEY":"<新しいランダム値>"}'
```

- ECS Task Definitionの`secrets`は`${ARN}:JWT_SECRET_KEY::`という形式でこのJSONキーを参照しているため、`--secret-string`は**必ずJSONオブジェクト形式**（`{"JWT_SECRET_KEY":"..."}`）で投入すること。文字列そのものを渡すとキー参照が失敗しタスクが起動できない（過去に同種の事故がRDS Secretで発生済み。`docs/deployment/environment-variables.md`参照）。
- 値の投入後、ECS Serviceのタスクを再起動（`aws ecs update-service --force-new-deployment`）して新しい値を反映させる。
- **注意**: JWTシークレットの値を変更すると、既存のリフレッシュトークン（HttpOnly Cookieに保存済みのもの）はすべて検証に失敗し、無効化される。β版ではこれを許容する（全ユーザーが再ログインになる）。

## 4. Route53 Aliasレコードの手動更新

ALBを再作成すると、ALBのDNS Name（`dualstack.pitvia-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com`）が変わる。`api.pitviaapp.com`のRoute53 AliasレコードはTerraform管理外のため、手動で向き先を更新する。

```bash
terraform output -raw alb_dns_name
terraform output -raw alb_zone_id
```

上記の値を使って、Route53コンソール（またはCLI）で`api.pitviaapp.com`のAレコード（Alias）の参照先を新しいALBに更新する。

## 5. RDS初期化（Flyway）の確認

RDSは新規作成のため、スキーマが存在しない空のデータベースになる。ECS Serviceが起動しSpring Bootアプリケーションが接続すると、`db/migration`配下のFlywayマイグレーションが自動適用される。CloudWatch Logs（`/ecs/pitvia-api`）でマイグレーション成功のログを確認する。

## 6. Vercel Projectの再開

```bash
vercel project resume pitvia
```

Vercel ProjectとProject設定（`infra/terraform/vercel`）自体は`shutdown.md`の手順で削除していないため、`terraform apply`は不要（設定に変更がある場合のみ`terraform plan`で差分を確認の上apply）。

---

# 復旧完了の確認

- `https://pitviaapp.com`にアクセスし、ログイン・整備記録の閲覧が正常に行えること
- `https://api.pitviaapp.com/api/v1/health`が200を返すこと（ALBのTarget Groupヘルスチェックと同一パス）
- ECS Serviceの`runningCount`が`desiredCount`と一致し、Circuit Breakerによるロールバックが発生していないこと
