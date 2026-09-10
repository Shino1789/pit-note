# Pitvia β Recovery Runbook

`docs/operations/shutdown.md`でAWSリソースを削除した状態、またはAWSリソースが意図せず削除された状態から、Pitviaβ版を復旧するための手順書。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。自動化スクリプトは`scripts/prod/recover.sh`（対で`scripts/prod/shutdown.sh` / `scripts/prod/status.sh`）。

---

# 結論

- 復旧は`./scripts/prod/recover.sh`で一貫実行できる（各ステップに確認・失敗時の停止処理あり）。
- **Terraform applyだけでは復旧は完了しない。** ECR image再push（GitHub Actions CD）、JWT Secret再投入、（ALB再作成時のみ）Route53 Alias自動更新、Vercel resumeが別途必要。
- JWT Secret再投入・Route53 Alias更新・Vercel resumeは`recover.sh`が自動実行する。IAM/ACM/Route53 Hosted Zone自体はTerraform管理外のため変更しない（状態確認のみ）。
- 復旧完了の最終確認は「`terraform plan`がNo changesであること」＋「API/Frontendへの実際の疎通確認」の両方で行う。
- **実地検証（2026-09-08〜09実施、複数回）で判明した重要な注意点**: 初回はTerraform管理外のIAMインラインポリシー2件（Secrets ARN・ELB権限）とRDSの`db_name`未設定という3つの問題、2回目以降はmacOS標準bash（3.2）の既知の不具合とALB Target Healthの待機時間不足という2つの問題により、追加の修正が必要になった。いずれも恒久対応済みで、直近の実行では`terraform plan`が`No changes`になることまで確認している。詳細は`docs/infrastructure/terraform.md`の「実地復旧で発覚した問題と対応」「2回目以降の実地復旧で発覚した問題と対応」を参照。

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

> **実地検証済み（2026-09-08〜09）**: 自動適用自体は正常に動作することを確認した。ただし、実地検証で以下の重大な既知の落とし穴が判明したため必ず把握しておくこと。

## ⚠️ 既知の落とし穴: `pitvia`データベース自体が存在しない

`aws_db_instance.main`（`rds.tf`）は元々`db_name`が未設定だったため、RDSインスタンス再作成時にデフォルトの`postgres`データベースしか作られず、アプリケーションが接続しようとする`pitvia`データベース自体が存在しない状態になっていた（`FATAL: database "pitvia" does not exist`でコンテナがexit code 1でクラッシュし続ける）。

- **恒久対応（実機検証済み）**: `rds.tf`に`db_name = "pitvia"`を追加済み。その後の完全なdestroy→recovery（RDSインスタンスが新規作成されるケース）で、`db_name`込みでRDSが作成され、追加の手動対応なしに`pitvia`データベースへ接続できること、および`terraform plan`が`No changes`になることを確認済み。
- **もし今後の復旧でも`database "pitvia" does not exist`が再発した場合**（例: `db_name`を含まない過去のRDSインスタンスを使い回すケース等）、一時的なECS Fargate Task（`postgres`公式イメージ、RDSマスターSecretを`secrets`経由で注入、private subnet + ECS SG）で`CREATE DATABASE pitvia;`を実行することで復旧できる（実地検証で採用した方法。既存の`pitvia-ecs-execution-role`の権限で完結し、恒久的なAWSリソースは残らない）。
- 詳細は`docs/infrastructure/terraform.md`の「実地復旧で発覚した問題と対応」を参照。

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

ALBを再作成すると、ALBのDNS Name（`pitvia-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com`）が変わる。新しいDNS名は以下で取得できる。

> このALB（`aws_lb.main`）は`ip_address_type=ipv4`（dualstack非対応）で作成されているため、DNS名に`dualstack.`プレフィックスは付かない（実機の`aws elbv2 describe-load-balancers`で確認済み）。

```bash
terraform -chdir=infra/terraform/aws output -raw alb_dns_name
terraform -chdir=infra/terraform/aws output -raw alb_zone_id
```

`prod/recover.sh`はこの値を使い、ALBのDNS名に直接アクセスして（カスタムドメインを経由せず）ECS/ALBの疎通自体が正常かを先に確認する。

**ALB Target Healthの待機時間について**: ALB Target Group（`interval=30秒`・`healthy_threshold=5回連続`）が新規登録ターゲットを`healthy`と判定するまでの所要時間は、理論最短でも`(healthy_threshold-1)×interval=120秒`、実際にはアプリ起動時間（Spring Boot起動・DB接続確立・初回Flyway migration等）が上乗せされ150〜250秒超になりうる。そのため`prod/recover.sh`はALB Target Health確認だけ他のヘルスチェックより長い専用の待機予算（最大約300秒、`common.sh`の`ALB_TARGET_HEALTH_MAX_ATTEMPTS`/`ALB_TARGET_HEALTH_INTERVAL_SECONDS`）を使う。手動で確認する場合も、`healthy`になるまで数分程度かかることを前提に待つこと。

---

# 7. Route53 Alias確認・自動UPSERT

`api.pitviaapp.com`のRoute53 AliasレコードはTerraform管理外だが、`prod/recover.sh`が**このレコード1件だけ**を自動更新する（Route53 Hosted Zone自体や他のレコードには一切触れない）。

`prod/recover.sh`は現在のRoute53レコードと6.で取得したALBのDNS名を自動比較し、

- 一致していれば「更新不要」として次に進む（Route53 APIは呼ばない）
- レコードが存在しない、または異なっていれば、`jq -n`で安全に生成したchange-batch JSONを使って`aws route53 change-resource-record-sets`（UPSERT）を自動実行し、反映結果を再取得して新ALBを指していることを確認してから次に進む
- UPSERT自体が失敗した場合、または更新後の再確認で不一致が確認された場合は、その時点で`die`し、Vercel resume・Frontend health確認には進まない（fail-closed設計を維持）

手動更新が必要になるのは、Route53 Hosted Zone自体が見つからない等、UPSERTの前提条件（後述）が満たせない異常時のみ。

**UPSERT実行条件**: ALB DNS名・ALB Hosted Zone ID・Route53 Hosted Zone IDのいずれかが取得できない場合はUPSERTせず即座に`die`する。

---

# 8. Vercel resume

Vercel ProjectとProject設定（`infra/terraform/vercel`）自体は`shutdown.md`の手順で削除していないため、`terraform apply`は不要（設定に変更がある場合のみ`terraform plan`で差分を確認の上apply）。

`prod/recover.sh`は`common.sh`の`resume_vercel_project()`を自動実行する。これは`vercel project resume ... --non-interactive`ではなく、**Vercel REST API（`POST /v1/projects/{id}/unpause`）を直接呼び出す方式**。

> **なぜCLIを使わないか**: Vercel CLIの`project resume`は、実行時のstdinがTTYでない（＝スクリプトから実行している）場合、`--non-interactive`を付けても必ず対話確認エラーで失敗することをCLIバンドルのソースコードで確認済み（`canPrompt(client) = Boolean(client.stdin.isTTY) && !client.nonInteractive`）。`recover.sh`はGitHub Actions CD完了待ち等の自動ポーリングを挟む半自動スクリプトのため、途中に対話プロンプトが挟まると無期限にハングするリスクがある。REST API方式はこの制約を受けず、`get_vercel_paused_state()`（`shutdown.sh`が使う読み取り専用の状態確認）と同じ認証方式（`VERCEL_API_TOKEN`/`VERCEL_TOKEN`環境変数、無ければ`~/Library/Application Support/com.vercel.cli/auth.json`）・Project ID解決方式（`terraform -chdir=infra/terraform/vercel output -raw project_id`）を流用している。

失敗してもAWS側の復旧は完了しているため処理は止めず、警告を表示して手動対応（`vercel project resume pitvia`をご自身の対話ターミナルで実行）を促す。

> **実地検証での注意点**: `resume_vercel_project()`は`infra/terraform/vercel`が`terraform init`済みであることに依存する。実行環境でこのディレクトリが未初期化だと`Vercel Project IDを取得できませんでした`という警告で失敗する（AWS側は無関係に正常なまま）。事前に`terraform -chdir=infra/terraform/vercel init`しておくか、失敗した場合は`terraform init`後に手動で以下を実行して復旧できる。
>
> ```bash
> source scripts/prod/lib/common.sh
> resume_vercel_project
> ```

---

# 9. API health check

```bash
curl https://api.pitviaapp.com/api/v1/health
```

`prod/recover.sh`は7.のRoute53確認が完了した後にこれを自動実行し、HTTP 200を確認する（ALBのTarget Groupヘルスチェックと同一パス）。

**ローカルDNS解決失敗時のフォールバックについて**: `prod/recover.sh`のAPI/ALB/Frontend health確認は、`curl`がDNS解決失敗（`exit 6` = `CURLE_COULDNT_RESOLVE_HOST`）で失敗した場合に限り、Cloudflare Public DNS（`dig @1.1.1.1`）で再解決し`curl --resolve`で再試行する（`common.sh`の`http_code_with_dns_fallback()`）。これは実行環境（実行者のマシン・ネットワーク）のローカルDNSリゾルバが一時的に不調でも、AWS側のAPI/インフラ自体は正常なケースを誤って異常と判定しないための対策であり、実地の復旧作業で複数回発生することを確認している。DNS解決以外の失敗（接続不可・タイムアウト・5xx応答等）はフォールバックしない。なお、この対策はスクリプトの判定を守るものであり、復旧作業者自身のブラウザでも同様のDNS解決不調が起きている場合は別途ブラウザ側・ローカルネットワーク側の確認が必要になる（別ネットワークでの疎通確認、DNSサーバーの一時変更、ルーターの再起動等）。

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
- [ ] Route53 Aliasが現在のALBを指している（ALB再作成時は`recover.sh`が自動UPSERT済み）
- [ ] JWT Secretに値が投入されている
- [ ] `https://api.pitviaapp.com/api/v1/health`が200
- [ ] `https://pitviaapp.com`が正常応答（307/200等、ログイン画面への到達含む）
- [ ] Vercel Projectがresume済み（pause状態でない）
- [ ] `terraform plan`が`infra/terraform/aws` / `infra/terraform/vercel`ともにNo changes

`./scripts/prod/status.sh`で上記の大半を一括確認できる。
