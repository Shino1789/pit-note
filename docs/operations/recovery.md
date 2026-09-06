# Pitvia β Recovery Runbook

`docs/operations/shutdown.md`でAWSリソースを削除した状態、またはAWSリソースが意図せず削除された状態から、Pitviaβ版を復旧するための手順書。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。自動化スクリプトは`scripts/prod/recover.sh`（対で`scripts/prod/shutdown.sh` / `scripts/prod/status.sh`）。

---

# 結論

- 復旧は`./scripts/prod/recover.sh`で一貫実行できる（各ステップに確認・失敗時の停止処理あり）。
- **Terraform applyだけでは復旧は完了しない。** ECR image再push（GitHub Actions CD）、JWT Secret再投入、（ALB再作成時のみ）Route53 Alias手動更新、Vercel resumeが別途必要。
- JWT Secret再投入・Route53 Alias更新・IAM/ACM/Route53 Hosted Zoneの状態確認は、Terraform管理外のため自動化スクリプトも一部で「手動対応が必要」として明示的に停止する設計にしている。
- 復旧完了の最終確認は「`terraform plan`がNo changesであること」＋「API/Frontendへの実際の疎通確認」の両方で行う。

---

# 1. 前提

- `infra/terraform/aws`が本番S3 backend（`pitvia-terraform-state`）に接続されていること。
- AWSアカウント（`956118719101`）・リージョン（`ap-northeast-1`）で作業していること。
- 以下のCLIが利用可能でログイン済みであること: `aws` / `terraform` / `gh`（`gh auth status`） / `vercel`（`vercel whoami`）。
- IAM Role・GitHub OIDC Provider・ACM証明書・Route53 Hosted Zone・AWS Budgetsは削除されていない前提（これらはTerraform管理外のため、`prod/shutdown.sh`でも削除されない）。

---

# 2. Terraform apply

```bash
./scripts/prod/recover.sh
```

内部では`infra/terraform/aws`で`terraform plan`→内容確認→`terraform apply`を実行する。

初回applyでは、ECS Task Definitionのimageは`<ECRリポジトリURL>:latest`という雛形イメージを参照する（実際にはまだECRにイメージが存在しないため、この時点でのECS Serviceのタスク起動は失敗する。次の3.でCDが正しいイメージを反映するまでの一時的な状態であり、想定内）。

手動で行う場合:

```bash
cd infra/terraform/aws
terraform plan
terraform apply
```

---

# 3. ECR / GitHub Actions CD

ECRリポジトリを削除・再作成しているため、既存イメージは失われている。`push`トリガー（`apps/api/**`等の変更）を待たず、`workflow_dispatch`で手動実行してECRへのイメージpushとECS Serviceへのデプロイを行う。

```bash
gh workflow run deploy.yml --ref main
```

**本番デプロイのため、`develop`ではなく必ず`main`を対象にすること。** `deploy.yml`の`workflow_dispatch`はinput無しで安全に実行できる仕様であることを確認済み（実機で複数回実行・成功を確認済み）。

`prod/recover.sh`は上記を自動実行し、`gh run view`でrunの完了・成功（`conclusion: success`）まで監視する。手動実行の場合は`gh run watch`等でCircuit Breakerによるロールバックが発生していないこと、ALBのヘルスチェックが`healthy`になることを確認する。

---

# 4. RDS / Flyway確認

RDSは新規作成のため、スキーマが存在しない空のデータベースになる。ECS Serviceが起動しSpring Bootアプリケーションが接続すると、`db/migration`配下のFlywayマイグレーションが自動適用される（Spring Boot標準のFlyway自動実行機能によるもので、追加の手動操作は不要）。

CloudWatch Logs（`/ecs/pitvia-api`）でマイグレーション成功のログ（`Successfully applied N migrations`等）を確認する。

> **要検証**: この自動適用は設計・実装上の想定であり、実際のdestroy→recovery実地検証ではまだ確認できていない（今回はコード整備のみ）。次回の実地検証で必ずログを確認すること。

---

# 5. JWT Secret再投入

`terraform apply`で作成された`aws_secretsmanager_secret.jwt`（`pitvia/prod/jwt-secret-key`）は、メタデータのみでSecret値を持たない。`prod/recover.sh`は、値が未設定の場合のみ自動生成・投入する（`openssl rand -base64 64`を生成し、画面・ログには一切出力せず、`--secret-string file://...`経由で投入後に即座にファイルを削除する）。

手動で行う場合:

```bash
aws secretsmanager put-secret-value \
  --secret-id pitvia/prod/jwt-secret-key \
  --secret-string '{"JWT_SECRET_KEY":"<新しいランダム値>"}'
```

- ECS Task Definitionの`secrets`は`${ARN}:JWT_SECRET_KEY::`という形式でこのJSONキーを参照しているため、`--secret-string`は**必ずJSONオブジェクト形式**で投入すること。文字列そのものを渡すとキー参照が失敗しタスクが起動できない（過去に同種の事故がRDS Secretで発生済み。`docs/deployment/environment-variables.md`参照）。
- **注意**: JWTシークレットの値を変更すると、既存のリフレッシュトークン（HttpOnly Cookieに保存済みのもの）はすべて検証に失敗し、無効化される。β版ではこれを許容する（全ユーザーが再ログインになる）。
- このステップは`prod/recover.sh`では**2.のterraform apply直後・3.のCD実行より前**に前倒ししている。ECSが実際に起動を試みる（＝JWT_SECRET_KEYを参照する）のは3.でCDがデプロイした後のため、先に値を用意しておくことで、初回起動時にSecret未設定のまま失敗する事態を避けられる。

---

# 6. ALB DNS変更

ALBを再作成すると、ALBのDNS Name（`dualstack.pitvia-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com`）が変わる。新しいDNS名は以下で取得できる。

```bash
terraform -chdir=infra/terraform/aws output -raw alb_dns_name
terraform -chdir=infra/terraform/aws output -raw alb_zone_id
```

`prod/recover.sh`はこの値を使い、ALBのDNS名に直接アクセスして（カスタムドメインを経由せず）ECS/ALBの疎通自体が正常かを先に確認する。

---

# 7. Route53 Alias確認

`api.pitviaapp.com`のRoute53 AliasレコードはTerraform管理外のため、ALBのDNS名が変わった場合は手動で向き先を更新する必要がある。

`prod/recover.sh`は現在のRoute53レコードと6.で取得したALBのDNS名を自動比較し、

- 一致していれば「更新不要」として次に進む
- 異なっていれば、実行すべき`aws route53 change-resource-record-sets`コマンドを画面に表示した上で**処理を停止する**（自動更新はしない。DNSの誤設定は影響範囲が大きいため）

停止した場合は、表示されたコマンドを実行してから`./scripts/prod/recover.sh`を再実行する。

---

# 8. Vercel resume

```bash
vercel project resume pitvia
```

Vercel ProjectとProject設定（`infra/terraform/vercel`）自体は`shutdown.md`の手順で削除していないため、`terraform apply`は不要（設定に変更がある場合のみ`terraform plan`で差分を確認の上apply）。

`prod/recover.sh`は上記CLIを自動実行する。失敗してもAWS側の復旧は完了しているため処理は止めず、警告を表示して手動対応を促す。

---

# 9. API health check

```bash
curl https://api.pitviaapp.com/api/v1/health
```

`prod/recover.sh`は7.のRoute53確認が完了した後にこれを自動実行し、HTTP 200を確認する（ALBのTarget Groupヘルスチェックと同一パス）。

---

# 10. Frontend health check

```bash
curl -I https://pitviaapp.com
```

未ログイン状態では`/login`への307リダイレクトが正常応答（Next.js Middlewareによる仕様通りの挙動）。

---

# 11. terraform plan = No changes

```bash
cd infra/terraform/aws
terraform plan
```

**`No changes. Your infrastructure matches the configuration.`** となることを確認する。`prod/recover.sh`は最終ステップとしてこれを自動実行する。

---

# 12. 復旧完了判定

以下をすべて満たした場合に復旧完了と判定する。

- [ ] `terraform apply`が成功し、destroy/replaceが発生していない
- [ ] GitHub Actions `deploy.yml`が成功（`conclusion: success`）
- [ ] ECS Serviceの`runningCount`が`desiredCount`と一致し、Circuit Breakerによるロールバックが発生していない
- [ ] ALB Target Groupが`healthy`
- [ ] Route53 Aliasが現在のALBを指している（ALB再作成時は手動更新済み）
- [ ] JWT Secretに値が投入されている
- [ ] `https://api.pitviaapp.com/api/v1/health`が200
- [ ] `https://pitviaapp.com`が正常応答（307/200等、ログイン画面への到達含む）
- [ ] Vercel Projectがresume済み（pause状態でない）
- [ ] `terraform plan`が`infra/terraform/aws` / `infra/terraform/vercel`ともにNo changes

`./scripts/prod/status.sh`で上記の大半を一括確認できる。
