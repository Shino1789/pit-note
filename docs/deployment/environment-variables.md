# Environment Variables (β版本番環境)

Pitvia のβ版デプロイに向けた、環境変数・Secretsの管理方針をまとめたドキュメント。

対象は AWS（ECS/Fargate + RDS + S3）と Vercel。**2026-08-31時点でAWS CLIの読み取り専用コマンドにより実機と再突合済み**（ECS Task Definition `pitvia-api:2`、ECS Service `pitvia-api-service`、RDS `pitvia-db`、S3 `pitvia-prod-storage`、Secrets Manager、ALB `pitvia-alb`、Route 53 Hosted Zone、ACM証明書）。値は当時実際に構築された内容を反映した記録である。

> **Terraform化（Issue #30）以降の注記**: 本ドキュメントは手動構築時点（2026-08-31）のスナップショットであり、ECS Task Definitionの`environment`/`secrets`定義自体は現在`infra/terraform/aws/ecs.tf`でTerraform管理されている。ALBのDNS名・RDSエンドポイント・Secrets ManagerのARN等、AWSが払い出すランダムな識別子を含む値は、`terraform destroy` → `terraform apply`（`scripts/prod/shutdown.sh` / `recover.sh`）のたびに変わりうる。そのため本ドキュメントでは、変わりうる値は固定値ではなく`terraform output`等の確認方法を記載する方針に変更している（詳細は`docs/infrastructure/terraform.md`参照）。変数の一覧・機密区分・管理先といった「値そのものではない」情報は引き続き有効である。

ECS Serviceは`pitvia-api:2`で`runningCount: 1 / desiredCount: 1`・`rolloutState: COMPLETED`（定常状態）を確認済み（2026-08-31時点）。`api.pitviaapp.com`のRoute 53 AレコードはALB（`aws_lb.main`、`ip_address_type=ipv4`のためdualstackプレフィックス無し）へのAliasとして設定されている。ALB再作成でDNS名が変わった場合は`scripts/prod/recover.sh`が自動でUPSERT・再アタッチする（`docs/operations/recovery.md`参照）ため、本ドキュメントでは特定時点のALB DNS名は記載しない。ACM証明書（`api.pitviaapp.com`）はALBのHTTPS:443リスナーに`InUse: true`でアタッチ済み（Terraformは`data "aws_acm_certificate"`で参照のみ）。

---

# 結論

- **`.env.prod`（実際の値を含むファイル）はリポジトリに作成しない。**
  ECS は Secrets Manager から Task Definition 経由で機密値を注入し、非機密値は Task Definition の `environment` に直接設定する運用のため、
  本番の実値をファイルとして永続化する必要がない（むしろGit管理下に秘密情報を置くリスクを増やすだけになる）。
  これは既存の `.gitignore`（`.env*` を除外し `.env.example` のみ許可）の方針とも一貫する。
- **非機密値の管理先は「SSM Parameter Store」ではなく「ECS Task Definition の `environment`」を正式採用した。** 経緯は後述（[管理先ごとの整理](#管理先ごとの整理)）。
- 独自ドメインは `pitviaapp.com`（Frontend）／`api.pitviaapp.com`（Backend）を採用している。当初 `pitvia.com` を予定していたが、お名前.comでプレミアムドメイン扱いとなり545,512円（税込）が提示されたため取得を断念した経緯がある（詳細はデプロイ道場§9参照）。

---

# バックエンド（apps/api）環境変数一覧

`application.yaml` / `application-dev.yaml` / `application-prod.yaml`（2026-08-30時点の内容で再確認済み）から実際に参照されている環境変数。

| 変数                      | 機密性                       | ローカル開発（.env.dev）       | β版本番（実機の実際の値）                                                                           | 管理先（実機で確認済み）                                                          |
| ------------------------- | ---------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `SPRING_PROFILES_ACTIVE`  | 非機密                       | `dev`                          | `prod`                                                                                              | ECS Task Definition `environment`                                                 |
| `SERVER_PORT`             | 非機密                       | `8080`                         | `8080`                                                                                              | ECS Task Definition `environment`                                                 |
| `FRONTEND_URL`            | 非機密（環境依存）           | `http://localhost:3000`        | `https://pitviaapp.com`                                                                             | ECS Task Definition `environment`                                                 |
| `JWT_SECRET_KEY`          | **機密**                     | 開発用サンプル値               | 本番専用に新規生成した値                                                                            | **Secrets Manager**（`pitvia/prod/jwt-secret-key`）                               |
| `JWT_EXPIRES`             | 非機密                       | `15m`                          | `15m`                                                                                               | ECS Task Definition `environment`                                                 |
| `JWT_REFRESH_EXPIRES`     | 非機密                       | `7d`                           | `7d`                                                                                                | ECS Task Definition `environment`                                                 |
| `COOKIE_DOMAIN`           | 非機密（環境依存）           | 未設定（空）                   | `.pitviaapp.com`                                                                                    | ECS Task Definition `environment`                                                 |
| `DB_HOST`                 | 非機密（内部エンドポイント） | `db`（コンテナ名）             | RDSエンドポイント（`destroy`→`apply`のたびに変わる。`terraform -chdir=infra/terraform/aws output -raw rds_endpoint`で確認）        | ECS Task Definition `environment`（値は`aws_db_instance.main.address`から自動反映）                                                 |
| `DB_PORT`                 | 非機密                       | `5432`                         | `5432`                                                                                              | ECS Task Definition `environment`                                                 |
| `DB_NAME`                 | 非機密                       | `pitvia`                       | `pitvia`                                                                                            | ECS Task Definition `environment`                                                 |
| `DB_USERNAME`             | 非機密                       | `pitvia`                       | `pitvia`                                                                                            | ECS Task Definition `environment`                                                 |
| `DB_PASSWORD`             | **機密**                     | `pitvia`                       | RDSの「マスター認証情報の自動管理」機能で自動生成                                                   | **Secrets Manager**（RDSが自動作成する`rds!db-...`Secret。RDS作成時に有効化済み） |
| `STORAGE_PROVIDER`        | 非機密                       | `minio`                        | `s3`                                                                                                | ECS Task Definition `environment`                                                 |
| `STORAGE_ENDPOINT`        | 非機密（dev専用）            | `http://minio:9000`            | **未設定**（S3利用時は空。`S3ClientConfig`はS3の場合エンドポイント上書きを行わない）                | ―                                                                                 |
| `STORAGE_PUBLIC_BASE_URL` | 非機密                       | `http://localhost:9000/pitvia` | `https://pitvia-prod-storage.s3.ap-northeast-1.amazonaws.com`                                       | ECS Task Definition `environment`                                                 |
| `STORAGE_ACCESS_KEY`      | 機密（dev専用）              | `minioadmin`                   | **未設定**（本番はECS Task RoleによるIAM Role運用のため不要。`S3ClientConfig`のS3分岐は参照しない） | ―                                                                                 |
| `STORAGE_SECRET_KEY`      | 機密（dev専用）              | `minioadmin`                   | **未設定**（同上）                                                                                  | ―                                                                                 |
| `STORAGE_BUCKET`          | 非機密                       | `pitvia`                       | `pitvia-prod-storage`                                                                               | ECS Task Definition `environment`                                                 |
| `STORAGE_REGION`          | 非機密                       | `us-east-1`                    | `ap-northeast-1`                                                                                    | ECS Task Definition `environment`                                                 |
| `DEBUG`                   | 非機密                       | `false`                        | 未使用（コード上での参照箇所なし。`.env.example`のみに存在する項目のため、そのままでも実害はない）  | ―                                                                                 |

上記のうち`COOKIE_DOMAIN`を除く、機密性「非機密」の12変数・機密性「機密」の2変数、計14変数は `aws ecs describe-task-definition --task-definition pitvia-api` で実際に取得し、1件ずつ突合済み（値の一致を確認、Secretは`valueFrom`のARN一致のみ確認し値は取得していない。2026-08-31時点）。`COOKIE_DOMAIN`は当時はコード実装のみでECS Task Definitionへの反映は未実施だったが、現在は`infra/terraform/aws/ecs.tf`の`environment`にTerraform管理で反映済み（詳細は下記「refresh_token CookieのDomain属性について」を参照）。

**注意（重要・refresh_token CookieのDomain属性について）**: `pitviaapp.com`（Frontend/Vercel）と`api.pitviaapp.com`（Backend/ALB）という別ホスト構成のため、Backendが発行する`refresh_token` CookieにDomain属性（`.pitviaapp.com`）を明示しないと、ブラウザはこのCookieを`api.pitviaapp.com`専用のhost-only Cookieとして扱う。その結果、`pitviaapp.com`（Next.js Middleware）側からはこのCookieを一切参照できず、ログインAPI成功後も未ログイン判定でログイン画面へ差し戻されてしまう不具合が実機で確認された。
対応として、`app.security.cookie.domain`（環境変数`COOKIE_DOMAIN`）を新設し、値が設定されている場合のみ`RefreshTokenCookieFactory`がCookieにDomain属性を付与する実装に変更した（未設定時は従来通りhost-only Cookieとして発行され、ローカル開発環境の挙動に影響しない）。**現在は`infra/terraform/aws/ecs.tf`のTask Definition `environment`に`COOKIE_DOMAIN=.pitviaapp.com`として反映済み。**

**S3移行のポイント**: `STORAGE_PROVIDER=s3` に切り替えると、`S3ClientConfig`（`storage/config/S3ClientConfig.java`）は
`DefaultCredentialsProvider` を使うため、`STORAGE_ACCESS_KEY` / `STORAGE_SECRET_KEY` は本番では発行不要。
ECS Task Role（`pitvia-ecs-task-role`）に対象S3バケット（`pitvia-prod-storage`）への最小権限（`GetObject` / `PutObject` / `DeleteObject`）を付与するだけで済む。実機のTask Roleインラインポリシー（`pitvia-s3-access-policy`）でこの3操作・対象バケット限定であることを確認済み。

---

# フロントエンド（apps/web）環境変数一覧

| 変数                  | 機密性                                    | ローカル開発                   | β版本番                                                                | 管理先                                  |
| --------------------- | ----------------------------------------- | ------------------------------ | ---------------------------------------------------------------------- | --------------------------------------- |
| `NEXT_PUBLIC_API_URL` | 非機密（※クライアントに露出する前提の値） | `http://localhost:8080/api/v1` | `https://api.pitviaapp.com/api/v1` | Vercel Project の Environment Variables |

> **注記（Terraform化後）**: Vercel Projectおよびこの環境変数は、現在`infra/terraform/vercel`の`vercel_project_environment_variable`リソースでTerraform管理されている（`vercel_project`本体の`environment`属性は、既存変数の更新時に`ENV_CONFLICT`で失敗するVercel Providerの既知の制約があるため使用しない。詳細は`docs/infrastructure/terraform.md`参照）。`https://api.pitviaapp.com`はALB経由で到達可能なAPIドメインとして稼働中。

`NEXT_PUBLIC_*` プレフィックスの変数はビルド時にクライアントバンドルへ埋め込まれるため、
そもそも「クライアントに見えて構わない値」しか置いてはならない。現状この1変数のみで、機密情報は含まれていない。

---

# 管理先ごとの整理

## AWS Secrets Manager に保存するもの（実機確認済み）

- `JWT_SECRET_KEY` → `pitvia/prod/jwt-secret-key`（Secrets Manager。メタデータのみ`infra/terraform/aws/secrets.tf`でTerraform管理し、値は`aws_secretsmanager_secret_version`として作成しない。Task Execution Roleの`GetSecretValue`をこのARNのみに限定したインラインポリシーで参照）
- `DB_PASSWORD` → RDSが自動作成するSecret（ARNは`rds!db-...`形式でRDS再作成のたびに変わる。`aws_db_instance.main`の`manage_master_user_password=true`により作成・管理される）

いずれもECS Task Definitionの`secrets`（`valueFrom`）経由で注入されており、`environment`（平文）側にはこの2つのキーが含まれていないことを実機で確認済み。値そのものはTerraform state・コードのいずれにも書き込まれない。`JWT_SECRET_KEY`の値は`terraform apply`後に空（未設定）となるため、`scripts/prod/recover.sh`が未設定時のみ自動生成・投入する（`docs/operations/recovery.md`参照）。

**注意（重要・revision 1→2で修正した落とし穴）**: 上記2つのSecretは、どちらもSecrets Manager側でキー/値ペア形式（JSON、例: `{"JWT_SECRET_KEY":"..."}` / `{"username":"...","password":"..."}`）で保存されている。そのため、Task Definitionの`secrets[].valueFrom`にARNだけを指定すると、JSON文字列全体がそのまま環境変数の値として渡ってしまい、アプリ側のBase64デコード等が失敗してタスクが起動できない不具合が発生した（`pitvia-api:1`で発生・実機調査済み）。
正しくは、ARNの末尾にJSONキー修飾子（`:キー名::`）を付ける必要がある。現在の`pitvia-api:2`ではこれが反映済みであることを実機で確認済み。
