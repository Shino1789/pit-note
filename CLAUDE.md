# CLAUDE.md

このファイルは、このリポジトリで作業する際に Claude Code へプロジェクト固有の情報や開発ルールを伝えるためのガイドです。

---

# プロジェクト概要

Pitvia（走るクルマのための整備記録・ショップ連携アプリ）は、スポーツカー・旧車・カスタムカーのオーナー向けの整備記録・ショップ連携Webアプリです。

本プロジェクトは、フロントエンドとバックエンドを独立して開発・デプロイできるモノレポ構成となっています。

- `apps/web`
  - Next.js 16（App Router）
  - TypeScript
  - フロントエンド

- `apps/api`
  - Spring Boot 3（Java 21）
  - パッケージルート：`com.pitvia.api`
  - バックエンドAPI

設計資料は `docs/` 配下に配置されています。

- `docs/db/schema.dbml`
  - ER図（DBML）

- `docs/api/openapi.yaml`
  - OpenAPI仕様

- `docs/api/bruno/`
  - Bruno APIコレクション

- `docs/architecture/architecture.drawio`
  - システム構成図

- `docs/ui/figma-link.md`
  - Figma画面UIモック

---

# 開発環境

アプリケーション全体は Docker Compose により起動します。

構成は以下の通りです。

- Next.js
- Spring Boot
- PostgreSQL
- MinIO

ルートディレクトリには `package.json` は存在せず、各アプリケーションごとに管理されています。

## 開発用スクリプト

`scripts/dev/` 配下にあります。**ローカルDocker Compose環境専用**であり、本番β環境（後述）には使用しません。

```bash
./scripts/dev/up.sh
```

全コンテナを起動し、Web・APIのヘルスチェック完了後にブラウザを開きます。

```bash
./scripts/dev/down.sh
```

全コンテナを停止します。

```bash
./scripts/dev/logs.sh
```

全コンテナのログを表示します。

```bash
./scripts/dev/reset.sh
```

コンテナ・Volume を削除します。

以下のデータも削除されます。

- PostgreSQL
- node_modules
- MinIOデータ

---

Docker Compose は

```
docker-compose.dev.yml
```

を使用します。

環境変数は

```
.env.dev
```

を利用します。

必要に応じて

```
.env.example
```

をコピーして作成してください。

### 起動するサービス

- web
  - Next.js（ホットリロード）

- api
  - Spring Boot
  - `./gradlew bootRun`
  - ホットリロード対応

- db
  - PostgreSQL 17

- minio

- create-bucket
  - 初回起動時のみ実行
  - バケット作成
  - ポリシー設定
  - 整備写真保存用オブジェクトストレージ初期化

---

# 本番β環境（AWS / Vercel）

**本番β環境は実際に課金が発生する実インフラです。開発環境（上記）とは完全に別物として扱ってください。**

## 構成

- AWS region: `ap-northeast-1`
- Frontend: Vercel
- Backend: ECS/Fargate
- Database: RDS PostgreSQL
- Container image: ECR
- Load Balancer: ALB
- Object storage: S3

以下はTerraform管理外（Terraformで作成・変更・削除しない）:

- DNS: Route53 Hosted Zone
- Certificate: ACM
- IAM / GitHub OIDC
- AWS Budgets

## Terraform

- Terraform State: S3 backend `pitvia-terraform-state`
- AWS: `infra/terraform/aws`
- Vercel: `infra/terraform/vercel`
- State用S3バケット自体の作成: `infra/terraform/bootstrap`（Local State管理）

詳細は `docs/infrastructure/terraform.md` を参照。

## 運用スクリプト

`scripts/prod/` 配下にあります。開発用の `scripts/dev/` とは明確に別物です。

```bash
./scripts/prod/status.sh
```

本番β環境の状態確認（read-only）。

```bash
./scripts/prod/shutdown.sh
```

本番β環境をpause + AWS destroyする**破壊的操作**。二段階の明示的確認が必須。

```bash
./scripts/prod/recover.sh
```

Terraform apply + Secret再投入 + GitHub Actions CD + 疎通確認 + Vercel resumeによる復旧。

詳細は `scripts/README.md`、`docs/operations/shutdown.md`、`docs/operations/recovery.md` を参照。

## 重要な運用ルール

- 本番βAWSリソースを直接`aws` CLIで削除しない
- 本番βの破棄は原則 `./scripts/prod/shutdown.sh`、復旧は原則 `./scripts/prod/recover.sh`、状態確認は `./scripts/prod/status.sh` を使う
- `terraform destroy` を手動で直接実行する場合は、必ず事前にdestroy対象（`terraform plan -destroy`）を確認する
- Route53 Hosted Zone / IAM / GitHub OIDC / ACM / AWS BudgetsはTerraform管理外であり、destroyしてはいけない
- Vercel Project自体は削除しない。休止時はpause、復旧時はresumeする（Vercel Terraform Providerはpause/resumeを管理していない）
- JWT Secret・RDSマスターパスワード等のSecret実値を、コード・Terraform State・ログのいずれにも出力・保存しない
- RDS / S3 / ECR / ECS / ALB / NAT Gateway等は、β環境のshutdown/recovery検証でdestroy/recreate対象になり得る。destroyするとRDSデータ、S3画像、ECR image、JWT Secretの値などが失われるため、実行前に必ず内容を確認する
- **本番β環境のdestroy/recoveryは破壊的操作であるため、ユーザーの明示的な承認なしに実行しない**（本セクションの記載は、上記編集ポリシー・commit/push方針と同様に適用される）

---

# フロントエンド（apps/web）

## 起動

```bash
npm run dev
```

Next.js 開発サーバー起動

---

## ビルド

```bash
npm run build
```

---

## Lint

```bash
npm run lint
```

---

## テスト

```bash
npm test
```

Vitest実行

---

## Watchモード

```bash
npm run test:watch
```

---

## 単体テスト実行

```bash
npx vitest run src/features/auth/hooks/use-login.test.ts
```

テスト環境

- jsdom
- globals有効
- setupファイル：`vitest.setup.ts`
- `@/` は `src/` のエイリアス（`vitest.config.ts`）

---

# バックエンド（apps/api）

## 起動

```bash
./gradlew bootRun
```

`SPRING_PROFILES_ACTIVE=dev`

の場合は

```
application-dev.yml
```

を利用します。

---

## 全テスト実行

```bash
./gradlew test
```

JUnit5

---

## 単体テスト実行

```bash
./gradlew test --tests "com.pitvia.api.auth.controller.AuthControllerTest"
```

---

統合テストでは Testcontainers を使用しています。

利用ライブラリ

- spring-boot-testcontainers
- postgresql

Docker が起動している必要があります。

テスト設定

```
apps/api/src/test/resources/application-test.yml
```

---

CI

```
.github/workflows/test.yml
```

では

フロント

```
npm run lint
npm test
```

バックエンド

```
./gradlew test
```

を

- Pull Request
- main
- develop

への Push 時に実行します。

---

# バックエンド設計（apps/api）

パッケージは Feature 単位で構成されています。

```
com.pitvia.api
```

配下

- auth
- dashboard
- maintenance
- master
- shop
- token
- user
- vehicle
- health
- common
- config

各 Feature は必要に応じて

- controller
- service
- repository
- entity
- dto
- constant

のレイヤー構成を採用しています。

---

## 認証

Spring Security による JWT認証を採用しています。

特徴

- セッションレス認証
- CSRF無効
- SessionCreationPolicy.STATELESS

フィルター順

```
MdcLoggingFilter
↓

LoggingFilter
↓

JwtAuthenticationFilter
```

アクセストークン

- 有効期限15分
- レスポンスボディ返却

リフレッシュトークン

- 有効期限7日
- DB保存
- HttpOnly Cookie
- Cronで期限切れ削除

公開APIは

```
PublicEndpoints.java
```

で一元管理します。

ロール

```
UserRole

OWNER

SHOP
```

---

## APIパス

APIパスは

```
ApiPaths.java
```

で一元管理します。

Controllerで文字列を直接記述しないこと。

---

## レスポンス

レスポンス生成は

```
ResponseFactory
```

を使用します。

成功時

```
ApiResponse<T>
```

失敗時

```
ErrorResponse
```

例外処理は

```
GlobalExceptionHandler
```

に集約します。

新しい業務エラーは

```
BusinessException
```

と

```
ErrorCode
```

を使用してください。

---

## ダッシュボード

ロール別処理には Strategy パターンを採用しています。

DashboardService は

```
Map<UserRole, DashboardQuery>
```

で実装されています。

ロール判定で

```
if

switch
```

を使用しません。

同様のロール別機能では、この実装方式を踏襲してください。

---

## DBマイグレーション

Flyway を利用しています。

配置場所

```
src/main/resources/db/migration/  … 実スキーマ（本番にも適用）
src/main/resources/db/mock/       … development/test専用のモック・テストデータ
```

命名規則

```
V1__xxxx.sql
```

開発用データ

```
V1000__mock_data.sql
V1001__test_chart_scale.sql
```

実スキーマは

```
V1000未満
```

開発データは

```
V1000以上
```

としてください。

本番（production）にモック・テストデータを絶対に投入しないよう、`spring.flyway.locations` を
Spring Profileごとに出し分けています。

```
application.yaml       … classpath:db/migration（共通・本番デフォルト）
application-dev.yml    … classpath:db/migration,classpath:db/mock
application-test.yml   … classpath:db/migration,classpath:db/mock
```

`db/mock/` 配下に新しいファイルを追加する場合も、上記のバージョン番号規則（V1000以上）に従ってください。

---

## 設定

共通設定

```
application.yml
```

環境別

```
application-dev.yml
application-prod.yml
```

環境変数で管理

- DB
- JWT
- CORS
- Cookie
- Storage

詳細は

```
.env.example
```

を参照してください。

---

# フロントエンド設計（apps/web）

Feature Slice 構成を採用しています。

```
src/

app/

features/

shared/

lib/api/

providers/

stores/
```

## 認証

アクセストークン

- Zustandのみ保持
- 永続化しない

リフレッシュトークン

- HttpOnly Cookie

middleware.ts により

- 未ログイン
- ログイン済み

を判定します。

401発生時は Axios Interceptor が

- リフレッシュ
- リクエスト再送
- ログイン画面遷移

を制御します。

---

## データ取得

TanStack Query を使用します。

各 Feature の

```
queries/
```

で Query を管理します。

ログアウト時は

```
queryClient.clear()
```

を実行します。

---

## フォーム

以下を使用します。

- React Hook Form
- Zod
- @hookform/resolvers

---

## UI

使用ライブラリ

- Tailwind CSS v4
- Radix UI
- class-variance-authority
- tailwind-merge
- Recharts
- Sonner

---

## ルーティング

画面ルート

```
shared/constants/routes.ts
```

APIエンドポイント

```
lib/api/endpoints.ts
```

で一元管理します。

文字列を直接記述しないこと。

---

## テスト

テストコードは対象ファイルと同じディレクトリに配置します。

```
*.test.ts
*.test.tsx
```

テストライブラリ

- Vitest
- Testing Library

## Claudeへの指示

ユーザーとの会話(回答・説明・レビュー・エラーの解説等)は日本語で行ってください。

既存実装を必ず参考にしてください。

命名規則やコメントの付け方は既存コードに合わせてください。

必要以上にリファクタリングしないでください。

関係ないファイルは編集しないでください。

ビルド・テストを実行してください。

保守性や拡張性を意識し、ベストプラクティスで実装して下さい。

新しい設計やライブラリの導入を推奨する場合は、実装前に理由を説明してください。

## 編集ポリシー

- 必要最小限の変更に留める
- 関係ないファイルは変更しない
- リファクタリングを勝手に行わない
- 既存コードを優先して再利用する
- commit・push・merge、新規ブランチを作成・削除はユーザーの指示があるまで勝手に行わない
