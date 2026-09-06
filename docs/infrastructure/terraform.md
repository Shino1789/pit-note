# Terraform構成（Issue #30）

Pitviaのβ版本番環境（AWS / Vercel）をTerraformで再構築可能にするための構成ドキュメント。

対象は「β版で発生する長期休止（AWS課金停止）→ 再構築」のサイクルを安全に回すことであり、日々のアプリケーションデプロイ（Backend/Frontend）はこれまで通りGitHub Actions CD（`.github/workflows/deploy.yml`）とVercelの自動デプロイが担う。

---

# 結論

- Terraformは3つの独立した構成に分割している：`infra/terraform/bootstrap`（State用S3バケット）、`infra/terraform/aws`（AWSインフラ本体）、`infra/terraform/vercel`（Vercel Project設定）。
- ECS Task Definition／Serviceの「実際に稼働しているコンテナイメージ」はGitHub Actions CDが管理し、Terraformは`lifecycle.ignore_changes`でそこに干渉しない。
- IAM Role・GitHub OIDC Provider・ACM証明書・Route53 Hosted Zone・AWS Budgetsは、今回Terraformで作成・変更・削除しない（`data`ソースで参照するのみ）。
- Secret値（JWTシークレットの値、RDSマスターパスワードの値）はTerraformコード・tfvars・tfstateのいずれにも書き込まない。

---

# ディレクトリ構成

```
infra/terraform/
├── bootstrap/        # Terraform State用S3バケットの作成（Local State管理）
│   ├── main.tf
│   └── README.md
├── aws/               # AWSインフラ本体（S3 Backend管理）
│   ├── main.tf                # terraform/backend/provider設定
│   ├── variables.tf
│   ├── data.tf                # 既存IAM Role / ACM証明書の参照（data source）
│   ├── network.tf             # VPC / Subnet / IGW / RouteTable / NAT Gateway
│   ├── security-groups.tf
│   ├── rds.tf
│   ├── s3.tf
│   ├── ecr.tf
│   ├── ecs.tf                 # Cluster / TaskDefinition / Service
│   ├── alb.tf
│   ├── cloudwatch.tf
│   ├── secrets.tf              # Secrets Managerのメタデータのみ
│   └── outputs.tf
└── vercel/            # Vercel Project設定（S3 Backend管理）
    ├── main.tf
    ├── variables.tf
    ├── project.tf
    └── outputs.tf
```

`bootstrap`だけをLocal State管理にしているのは、State保存先自体のS3バケットをTerraformで作ろうとすると「バケットを作るためのState保存先がまだ存在しない」という循環依存が発生するため。`bootstrap`は初回のみ実行し、以降触らない想定（詳細は`bootstrap/README.md`）。

`aws`と`vercel`を分けているのは、AWSリソースの休止/再構築サイクルと、Vercel Project設定の変更サイクルが独立しているため（Vercel Projectそのものは今回のサイクルでは削除しない）。

---

# Terraform管理の対象・非対象

## 管理する（作成・変更・削除の対象）

| リソース | 備考 |
| --- | --- |
| VPC / Subnet(4) / IGW / RouteTable / Route / RouteTableAssociation | NAT Gatewayが自動生成する特殊なRouteTable/Associationは対象外（後述） |
| EIP（NAT Gateway用） / NAT Gateway（Regional） | |
| Security Group（ALB / ECS / RDS） | |
| RDS（`pitvia-db`） | `manage_master_user_password=true`。パスワード自体は非管理 |
| S3（`pitvia-prod-storage`） + バケットポリシー + Public Access Block | |
| ECR（`pitvia-api`） + ライフサイクルポリシー | |
| ECS Cluster / Task Definition / Service | Task Definitionの`container_definitions`とServiceの`task_definition`は`ignore_changes`対象（後述） |
| ALB / Listener(2) / Target Group | |
| CloudWatch Logs（`/ecs/pitvia-api`） | |
| Secrets Manager（`pitvia/prod/jwt-secret-key`のメタデータのみ） | 値（`aws_secretsmanager_secret_version`）は作成しない |
| Vercel Project設定（root_directory / framework / build command / node_version / ignore_command / 環境変数 / ドメイン） | Project自体の削除は今回のサイクル対象外 |

## 管理しない（`data`ソース参照のみ、または完全に対象外）

| リソース | 理由 |
| --- | --- |
| IAM Role（`pitvia-ecs-execution-role` / `pitvia-ecs-task-role` / `pitvia-github-actions-deploy-role`） | 権限管理はTerraform化のスコープ外。誤操作でCDや実行権限を壊すリスクを避けるため |
| GitHub OIDC Provider | 同上 |
| ACM証明書（`api.pitviaapp.com`） | 証明書の再発行・検証待ちが発生すると復旧時間が読めなくなるため |
| Route53 Hosted Zone / レコード | ALB再作成時にDNS Nameが変わるため、Aliasレコードの更新は手動（`docs/operations/recovery.md`参照） |
| AWS Budgets | コスト監視設定であり、インフラ再構築サイクルと無関係 |
| Vercel Project Pause/Resume | Vercel Terraform Providerが非対応（全49リソースのドキュメント・プロバイダソースを確認済み）。手動CLI操作で対応（`docs/operations/shutdown.md`） |

---

# NAT Gatewayと「特殊なRoute Table」について

Regional NAT Gateway（`availability_mode = "regional"`）を作成すると、AWSは`NatGateway.routeTableId`として、ユーザーが作成していない専用のRoute Tableと、そのGateway Route Table Association（`GatewayId`にNAT Gateway IDを指定した特殊な関連付け）を自動生成する。

これは実機の隔離VPCでの2回の検証（apply→確認→destroy→再apply→再確認→destroy）で、以下を確認済み：

- `aws_nat_gateway`リソースは`vpc_id`を指定し、`subnet_id`は指定しない（Regional NAT Gatewayでは`subnet_id`は逆にエラーになる）。
- `allocation_id`もあえて指定しない。実機のNAT Gateway（`nat-144eb2792674ecc3b`）が保持するEIPを確認したところ、2つとも`ServiceManaged: rnat`（AWSがRegional NAT Gateway用に完全自動管理するEIP）であり、ユーザー/Terraformが所有するEIPは存在しなかったため、EIPの確保・複数AZ展開をAWSに完全に委ねる構成とした。
- この特殊なRoute Table/Associationは`aws_route_table_association`（`gateway_id`にNAT Gateway IDを指定）では作成できない（AWS API側で`InvalidParameterValue`）。
- Terraformコードに含めなくても、destroy→再applyのたびにAWSが自動的に再生成し、Private Subnetからのインターネット疎通（EC2+SSM+curlで実証）は正常に機能する。

そのため、`network.tf`ではこの特殊なRoute Table/Associationを一切コード化していない。

---

# Import一覧（既存AWSリソース → Terraform管理への移行）

既存の本番AWSリソースをTerraform管理下に移行するための`terraform import`対応表。実行は`infra/terraform/aws`ディレクトリで行う（`terraform import <Terraformリソースアドレス> <import ID>`）。

| Terraformリソースアドレス | 実リソース | import ID |
| --- | --- | --- |
| `aws_vpc.main` | VPC | `vpc-078ebc2588997946c` |
| `aws_subnet.public_1a` | Subnet（public1, 1a） | `subnet-06a3895900cd7809c` |
| `aws_subnet.public_1c` | Subnet（public2, 1c） | `subnet-0221a18556d3d2270` |
| `aws_subnet.private_1a` | Subnet（private1, 1a） | `subnet-0b0ce0640b286e7ca` |
| `aws_subnet.private_1c` | Subnet（private2, 1c） | `subnet-0e76ca11e1ee29c62` |
| `aws_internet_gateway.main` | IGW | `igw-07c8336c6003f3de6` |
| `aws_route_table.public` | Route Table（public） | `rtb-0da712144557cdb39` |
| `aws_route.public_igw` | Route（public→IGW） | `rtb-0da712144557cdb39_0.0.0.0/0` |
| `aws_route_table_association.public_1a` | Association | `subnet-06a3895900cd7809c/rtb-0da712144557cdb39` |
| `aws_route_table_association.public_1c` | Association | `subnet-0221a18556d3d2270/rtb-0da712144557cdb39` |
| `aws_route_table.private_1a` | Route Table（private, 1a） | `rtb-02c9816a06040da46` |
| `aws_route.private_1a_nat` | Route（private1a→NAT） | `rtb-02c9816a06040da46_0.0.0.0/0` |
| `aws_route_table_association.private_1a` | Association | `subnet-0b0ce0640b286e7ca/rtb-02c9816a06040da46` |
| `aws_route_table.private_1c` | Route Table（private, 1c） | `rtb-0a64c8f57192d562c` |
| `aws_route.private_1c_nat` | Route（private1c→NAT） | `rtb-0a64c8f57192d562c_0.0.0.0/0` |
| `aws_route_table_association.private_1c` | Association | `subnet-0e76ca11e1ee29c62/rtb-0a64c8f57192d562c` |
| `aws_nat_gateway.main` | NAT Gateway（Regional） | `nat-144eb2792674ecc3b` |
| `aws_security_group.alb` | Security Group | `sg-05ed0049efce2368d` |
| `aws_security_group.ecs` | Security Group | `sg-06c275eaf76c9ea25` |
| `aws_security_group.rds` | Security Group | `sg-096e7c41e8b2ab935` |
| `aws_db_subnet_group.main` | DB Subnet Group | `pitvia-db-subnet-group` |
| `aws_db_instance.main` | RDS | `pitvia-db` |
| `aws_s3_bucket.storage` | S3 Bucket | `pitvia-prod-storage` |
| `aws_s3_bucket_versioning.storage` | S3 Versioning設定 | `pitvia-prod-storage` |
| `aws_s3_bucket_server_side_encryption_configuration.storage` | S3 暗号化設定 | `pitvia-prod-storage` |
| `aws_s3_bucket_public_access_block.storage` | S3 Public Access Block | `pitvia-prod-storage` |
| `aws_s3_bucket_policy.storage` | S3 Bucket Policy | `pitvia-prod-storage` |
| `aws_ecr_repository.api` | ECR | `pitvia-api` |
| `aws_ecr_lifecycle_policy.api` | ECR ライフサイクルポリシー | `pitvia-api` |
| `aws_cloudwatch_log_group.api` | CloudWatch Log Group | `/ecs/pitvia-api` |
| `aws_secretsmanager_secret.jwt` | Secrets Manager（JWT） | `arn:aws:secretsmanager:ap-northeast-1:956118719101:secret:pitvia/prod/jwt-secret-key-jGESR2` |
| `aws_ecs_cluster.main` | ECS Cluster | `pitvia-cluster` |
| `aws_ecs_task_definition.api` | ECS Task Definition | `arn:aws:ecs:ap-northeast-1:956118719101:task-definition/pitvia-api:8`（import時点の最新revision。`family:revision`形式ではARNの検証エラーになるため、必ずフルARNを指定する） |
| `aws_ecs_service.api` | ECS Service | `pitvia-cluster/pitvia-api-service` |
| `aws_lb.main` | ALB | `arn:aws:elasticloadbalancing:ap-northeast-1:956118719101:loadbalancer/app/pitvia-alb/2169765d4ab3d04e` |
| `aws_lb_target_group.api` | Target Group | `arn:aws:elasticloadbalancing:ap-northeast-1:956118719101:targetgroup/pitvia-api-tg/c4e2de922dac5934` |
| `aws_lb_listener.http` | ALB Listener（80） | `arn:aws:elasticloadbalancing:ap-northeast-1:956118719101:listener/app/pitvia-alb/2169765d4ab3d04e/00365324984c0240` |
| `aws_lb_listener.https` | ALB Listener（443） | `arn:aws:elasticloadbalancing:ap-northeast-1:956118719101:listener/app/pitvia-alb/2169765d4ab3d04e/bf8d0d0e633e02b5` |

**依存関係・実行順序**: 上記の記載順が依存関係順になっている（VPC → Subnet/IGW → RouteTable → Route/Association → NAT Gateway → SecurityGroup → RDS/S3/ECR/CloudWatch/Secrets → ECS → ALB）。ただし`terraform import`はTerraformリソースグラフとは独立してAWS側から1件ずつ状態を読み込むだけの操作のため、実際には依存順を厳密に守らなくても実行できる（destroy/applyのような実際のリソース操作順序が問題になる操作ではない）。

**あえてimportしないリソース**:
- NAT Gateway用EIP（`eipalloc-0b22607b1436c048d` / `eipalloc-037d3e585c8d2876a`）: 前述の通り両方とも`ServiceManaged: rnat`のAWS完全管理EIPであり、`aws_eip`としてTerraform管理する対象ではない。
- NAT Gateway専用の特殊Route Table（`rtb-0cb203cad2bf15bda`）とそのGateway Route Table Association: AWSが自動生成・管理するものであり、Terraformで作成不可（`AssociateRouteTable`がNAT Gateway IDを`gateway-id`として受け付けない）。
- VPCのデフォルトMain Route Table（`rtb-06b8703c84102b2e4`）: VPC作成時にAWSが暗黙に生成するものであり、別途`aws_route_table`として管理しない（`aws_main_route_table_association`等での明示的な管理も今回は行わない）。
- RDSマスターパスワード用Secrets Manager Secret（`rds!db-d8a9a94c-...`）: `aws_db_instance.main`の`manage_master_user_password`機能に内包されるため、別リソースとしてimportしない。

---

# ECS Task Definition / Service と GitHub Actions CDの責務分離

## 設計

- **Terraformが管理**: Cluster本体、Task Definitionの雛形（cpu/memory/role/environment/secrets/portMappings/logConfiguration）、Serviceのネットワーク設定・ALB連携・Circuit Breaker設定。
- **GitHub Actions CD（deploy.yml）が管理**: 実際に稼働するcontainer image、およびそれを反映した新しいTask Definition revision。

`aws_ecs_task_definition.api`に`lifecycle { ignore_changes = [container_definitions] }`、`aws_ecs_service.api`に`lifecycle { ignore_changes = [task_definition] }`を設定することで、`terraform apply`がCDの最新revisionを巻き戻さないようにしている。

## deploy.ymlとの整合性検証

`deploy.yml`は以下の順で動作する（実装済みコードを確認済み）：

1. `aws ecs describe-services`でServiceが現在参照しているTask Definition ARN（**family-latestではなく実際に稼働中のrevision**）を取得する。
2. そのTask Definitionの内容を取得し、`image`フィールドのみを新しいECRイメージタグに書き換えて`register-task-definition`で新しいrevisionを登録する。
3. `update-service`で新しいrevisionをServiceに反映し、安定化を待ってCircuit Breakerのロールバック有無を確認する。

この設計により、以下の4シナリオで問題が発生しないことを確認済み：

| シナリオ | 結果 |
| --- | --- |
| 通常運用（Terraform適用済み、CD未実行） | Task Definitionは`terraform apply`時点のrevisionのまま。競合なし |
| `terraform apply`後に初めてCDを実行 | CDはServiceの現在のrevision（Terraformが作成したもの）を起点に新しいrevisionを作成。競合なし |
| CD実行後に再度`terraform apply` | `ignore_changes`によりTask Definition/Serviceのrevisionはstateの差分として無視され、CDが作成した最新revisionを巻き戻さない |
| destroy→apply→CD再実行（完全復旧） | Terraformが雛形revision（1件目）を作成 → CDがそのrevisionを起点に新しいrevisionを作成。通常運用と同じ流れで復旧できる |

## インフラ的な変更が必要な場合

環境変数の追加やIAM Roleの変更など、Task Definitionの雛形自体を変更したい場合は、一時的に`ignore_changes`を外して`terraform apply`し、変更が反映されたことを確認した後、`ignore_changes`を戻す運用とする（CDの最新revisionを上書きしてしまわないよう、apply前にCDが動いていないタイミングで行うこと）。

---

# Terraform State管理

- Stateは`bootstrap`で作成したS3バケット（`pitvia-terraform-state`）に保存する。
- ロックはDynamoDBを使わず、S3ネイティブロック（`use_lockfile = true`）を使用する（DynamoDBロックはTerraform公式ドキュメントで非推奨化されているため）。
- `.gitignore`により、`*.tfstate`・`*.tfvars`・`.terraform/`はGit管理から除外している（`.terraform.lock.hcl`はProviderバージョン再現性のためGit管理する）。

---

# Secrets Managerの扱い

- `aws_secretsmanager_secret.jwt`（メタデータのみ）をTerraform管理し、`aws_secretsmanager_secret_version`は作成しない。
- RDSのマスターパスワード用Secretは`aws_db_instance.main.manage_master_user_password = true`によりRDSが自動管理するため、別リソースとしては扱わない。ECS Task Definitionからは`aws_db_instance.main.master_user_secret[0].secret_arn`を参照する。
- JWTシークレットの値そのものは、再構築時に手動で再投入する（`docs/operations/recovery.md`参照）。値を再生成するとリフレッシュトークンが無効化されるが、β版では許容する。

---

# import検証で確認済みの事項

ローカルState（実際のS3 backend/実AWSへの`apply`は一切行わない、使い捨てのローカルディレクトリ）に全リソースを`terraform import`し、`terraform plan`で差分を確認した（詳細は本ドキュメント「Import一覧」参照）。

- `master_user_secret_kms_key_id`（RDS）: 実機のKMS Keyは`alias/aws/secretsmanager`（Secrets Managerのデフォルトキー）であることを確認済み。Terraformコードでは意図的に未設定（デフォルト動作に委ねる）とし、これによる差分は発生しないことを確認した。
- `retention_in_days`（CloudWatch Logs）: 実機は無期限保持（未設定）。Terraformコードも意図的に未設定とし、差分は発生しないことを確認した。
- 初回の`terraform plan`では、以下の**意図しない差分**が検出され、コード修正により解消した（`terraform apply`は未実行）。
  - `aws_ecs_task_definition.api`が`must be replaced`と判定された。原因は実機のTask Definitionが保持する`runtime_platform`（`cpu_architecture=X86_64`, `operating_system_family=LINUX`）をコードで未指定だったこと。`runtime_platform`はforce-new属性であり、指定漏れがTask Definitionの意図しない置き換え（＝CDがデプロイした実イメージの巻き戻りリスク）に直結することを実機検証で確認した。**`ignore_changes`は他の属性が原因の強制置き換えを防げない**ことが分かったため、Task Definitionの雛形はcontainer_definitions以外の属性（cpu/memory/role/runtime_platform等）も実機と完全一致させることが重要、という設計上の教訓として記録する。
  - `aws_ecs_cluster.main`の`configuration.execute_command_configuration.logging`（実機は`DEFAULT`）が未指定だったため、コードに追加。
  - `aws_db_subnet_group.main`の`description`（実機は`"Pitvia DB subnet group"`）が未指定で、既定値`"Managed by Terraform"`に上書きされる差分があったため、実機の値をコードに明示。
  - `aws_secretsmanager_secret.jwt`の`description`（実機は`"Pitvia production JWT signing secret"`）が未指定だったため、実機の値をコードに明示。
  - `aws_lb_listener.https`の`default_action`を`target_group_arn`ショートハンドで記述していたが、実機のListenerは明示的な`forward`ブロック（`target_group{arn,weight}` + `stickiness{enabled,duration}`）を保持していたため、同じ構造に修正。
- 上記修正後の再`terraform plan`では、**destroy 0件・replace 0件**を確認済み。残る26件の差分はすべて「`Name`タグの新規付与」「`default_tags`による`Project`/`ManagedBy`タグの正規化（大文字小文字差異の統一含む）」「Terraformのみが持つメタ属性（`skip_destroy`、`revoke_rules_on_delete`等）のデフォルト値追加」であり、実リソースの機能・可用性に影響しない安全な変更であることを確認した。

# 本番backend移行の結果（STEP6〜8で実施済み）

- `infra/terraform/bootstrap`を本番AWSに`apply`し、State用S3バケット（`pitvia-terraform-state`）を作成済み（作成されたのはこのバケット関連4リソースのみ。既存Pitviaリソースへの変更なし）。
- `infra/terraform/aws`を本番S3 backend（`key = "aws/terraform.tfstate"`）へ`terraform init`で切り替え、37リソース全件を本番backend上のStateへ`terraform import`済み。
- 本番backend上での`terraform plan`結果は、使い捨てローカルStateでの検証結果と**完全に一致**（`0 to add, 26 to change, 0 to destroy`）。destroy/replaceは0件。
- `terraform state show`でSecrets Manager（JWT）・RDS（`master_user_secret`）を確認し、いずれもARN/メタデータのみでSecret値そのものは含まれていないことを確認済み。
- `infra/terraform/aws`・`vercel`への`terraform apply`はまだ実行していない。

# Vercel検証の結果（STEP10で実施済み）

- `infra/terraform/vercel`は使い捨てのローカルStateで`vercel_project.web`（Project本体）と`vercel_project_domain.production`（`pitviaapp.com`）をimportし、`terraform plan`を実施した。
- 結果は`0 to add, 1 to change, 0 to destroy`。Project自体のreplace/削除にはつながらない。
- `vercel_project_domain.production`（ドメイン）は差分なし（完全一致）。
- `vercel_project.web`の1件の変更内容:
  - `environment`（`NEXT_PUBLIC_API_URL`）が`+`（新規追加）として表示された。これはSetかつSensitive属性のため、import時にAPIから値を読み取れず、plan上は「未追跡→追加」という扱いになる既知の制約。値自体は`docs/deployment/environment-variables.md`記載の確定値（`https://api.pitviaapp.com/api/v1`）を使用しているため、実質的な値の変更ではないと考えられるが、**未applyのため実値の完全一致は最終未確認**。
  - `build_machine_type`、`resource_config`（`fluid`/`function_default_regions`等）が`(known after apply)`表示になった。これはOptional+Computed属性をTerraformコードで明示していないことに起因し、`environment`の初回反映と同時にProject全体がAPI経由で再計算されるための表示と考えられる。実際に値がリセットされるか（例: `build_machine_type=basic`が既定値に戻る等）は**未applyのため未確認**。

# 正式apply結果（実施済み）

- `build_machine_type = "basic"` / `resource_config = { fluid = true, function_default_regions = ["iad1"] }` を実機の値通りにコードへ明示し、`(known after apply)`の不確実性を解消した。
- **実際に`terraform apply`したところ、`vercel_project.web`内の`environment`属性でエラーが発生した**（`ENV_CONFLICT`: 既存の`NEXT_PUBLIC_API_URL`と同名の変数を新規作成しようとして失敗）。これは事前のplanでは検出できなかった、Vercel Providerの既知の制約（Set型かつSensitive値を持つ属性は、import時にAPIから値を読み取れず、apply時に「新規作成」として扱われてしまう）による実際の失敗。**Projectやドメインの削除・変更は一切発生せず、安全に失敗した**。
- 対策として、`environment`属性を`vercel_project`から削除し、専用リソース`vercel_project_environment_variable`で個別管理する設計に変更した。既存の環境変数を`PROJECT_ID/ENV_VAR_ID`形式でimportし直したところ、差分ゼロで一致することを確認し、`apply`にも成功した。
- 最終的に`infra/terraform/aws`・`infra/terraform/vercel`とも、apply後の`terraform plan`が`No changes. Your infrastructure matches the configuration.`となることを確認済み。

# 残存リスク・未確認事項

- Vercel Projectの一部設定（`auto_assign_custom_domains`、SSO Protectionなど）は今回のスコープ外としてTerraformコードに含めていない。
- 環境変数を追加する場合は、必ず`vercel_project`の`environment`属性ではなく`vercel_project_environment_variable`リソースを使用すること（上記の理由により、前者は既存変数の更新で失敗する）。

---

# shutdown/recovery設計判断（自動化可能 / 手動作業 / 要検証）

「destroy→apply→recoveryで本当にβ環境を復旧できるか」を検討する上での個別論点。`scripts/prod/shutdown.sh` / `scripts/prod/recover.sh` / `scripts/prod/status.sh`と`docs/operations/shutdown.md` / `recovery.md`に対応する。

| 論点 | 分類 | 内容 |
| --- | --- | --- |
| A. terraform apply直後にECSがECR image不存在で失敗する可能性 | **自動化可能** | 初回applyのTask Definitionは`<ECRリポジトリURL>:latest`という雛形を参照するが、ECRは空のため必ず起動に失敗する。これは想定内で、`prod/recover.sh`もこの状態を前提に、ECSの安定化を待たずに直後のGitHub Actions CDへ進む設計にしている。CDが正しいimageで新revisionを登録した時点で正常化する。 |
| B. RDS再作成後にFlywayで初期migrationが自動実行されるか | **自動化可能（要検証）** | Spring Boot標準のFlyway自動実行（`spring.flyway.enabled`既定値）により、アプリ起動時に空のDBへ`db/migration`が自動適用される設計。ただし実際のdestroy→recoveryサイクルでの実地確認はまだ行っていないため、次回実施時にCloudWatch Logsでの確認が必須。 |
| C. ALB再作成後にRoute53 Aliasをどう更新するか | **手動作業** | Route53 Hosted Zoneは意図的にTerraform管理外。`prod/recover.sh`は現在のAliasと新ALBのDNS名を自動比較し、差分があれば実行すべき`aws route53 change-resource-record-sets`コマンドを画面表示した上で処理を停止する（DNS誤設定の影響が大きいため自動実行はしない）。 |
| D. ACM証明書を再利用できるか | **自動化可能** | `data "aws_acm_certificate" "api"`で既存の発行済み証明書を参照する設計のため、ALBが再作成されてもACM証明書自体は不変・自動的に再アタッチされる。手動作業は不要。 |
| E. JWT secret再作成後の再投入方法 | **自動化可能** | `prod/recover.sh`が`openssl rand`で新しい値を生成し、画面・ログに一切出力せず`put-secret-value`で投入する。既に値が設定済みの場合はスキップ（`--force-jwt-reset`で強制可）。リフレッシュトークン無効化は許容済みの仕様。 |
| F. Vercel pause/resumeをどこで実施するか | **自動化可能** | Terraform Provider非対応のため、`prod/shutdown.sh`/`prod/recover.sh`内でVercel CLI（`vercel project pause/resume`）を直接呼び出す。失敗してもAWS側の処理はブロックせず、警告を出して手動対応を促す。 |
| G. GitHub Actions CDをmainから安全にworkflow_dispatchできるか | **自動化可能** | `deploy.yml`の`workflow_dispatch`はinput無しで安全に実行できる仕様。`gh workflow run deploy.yml --ref main`を実機で複数回実行し成功を確認済み。`prod/recover.sh`はrun IDを特定し、完了・成功まで自動監視する。 |
| H. recovery完了後にterraform plan = No changesになるか | **要検証** | 現在の定常状態（destroyを経ていない状態）でのapply→CD実行→plan確認では`No changes`を確認済み。ただし実際のdestroy→apply一巡でも同じ結果になるかは、本ドキュメント整備時点ではまだ実地検証していない（`docs/operations/shutdown.md` / `recovery.md`の手順自体は整備済み）。 |
