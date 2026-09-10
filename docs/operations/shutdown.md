# 休止手順（コスト削減のための一時停止）

Pitviaのβ版を一定期間使わない場合に、AWS課金が発生するリソースを削除し、コストを抑えるための手順。

Terraformの前提・構成は`docs/infrastructure/terraform.md`を参照。自動化スクリプトは`scripts/prod/shutdown.sh`（対で`scripts/prod/recover.sh` / `scripts/prod/status.sh`）。

---

# 結論

- `infra/terraform/aws`を`terraform destroy`することで、VPC・NAT Gateway・RDS・S3・ECR・ECS・ALB等のTerraform管理対象リソースを削除する。
- IAM Role・ACM証明書・Route53 Hosted Zone・GitHub OIDC Provider・AWS Budgetsは削除されない（Terraform管理外のため）。
- Vercel ProjectはTerraformで削除せず、アクセス防止のためCLIで手動Pauseする。
- **Vercel pauseは必ずAWS destroyより前に、ユーザーが対話ターミナルで手動実行する。** `vercel project pause`はVercel側の仕様により非対話環境（スクリプト等）から実行できないことが実機確認済みのため（後述）、`shutdown.sh`はpauseを実行せず、pause済みであることを確認するのみ。
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
| CloudWatch Logs（`/ecs/pitvia-api`） | ECSタスクの標準出力ログ全履歴（過去のアプリケーションログ） | ❌ 復旧不可（Terraform apply後は空のロググループから再開） |

## 1. 事前確認

```bash
cd infra/terraform/aws
terraform plan -destroy
```

意図した通り、削除対象がRDS/S3/ECR/ECS/ALB/NAT Gateway/VPC関連リソースのみであり、IAM/ACM/Route53等が含まれていないことを確認する。

## 2. Vercel Projectの一時非公開化（必ずAWS destroyより前に、手動で実行）

Vercel Terraform Providerは Project の Pause/Resume に対応していません。加えて`vercel project pause`自体、**対話ターミナルからのみ実行可能**という仕様であることを実機で確認済みです（`--non-interactive`を付けても、確認用のプロジェクト名をstdinへpipeで流し込んでも、TTY判定の時点で内容を見ずに拒否される。Vercel側が誤自動化を防ぐため意図的にそう設計している）。そのため、**このステップだけは必ずユーザーご自身が対話ターミナルで実行してください**。

```bash
vercel project pause pitvia
```

実行するとプロジェクト名の入力を求められるので、`pitvia`と入力して確定します。これはコスト削減ではなく（Hobbyプランは無料のため）、誤操作でのアクセス・デプロイを防止する目的。

## 3. AWSリソースの削除

pauseが完了したら、自動化スクリプトを使う場合（推奨。安全確認・destroy対象表示・pause状態確認を一貫して行う）:

```bash
./scripts/prod/shutdown.sh          # 通常実行（二段階の明示的確認あり）
./scripts/prod/shutdown.sh --dry-run  # destroy対象の確認のみ（実行しない）
```

**Vercel pause確認はfail-closed設計**: `shutdown.sh`はVercel Projectがpause済みであることを確認するだけで、pauseそのものは実行しません。2.のpauseが完了していない（または状態を確認できない）場合、AWSのdestroyを一切実行せず終了します（Frontendが公開されたままBackendだけdestroyされる中途半端な状態を避けるため）。

手動で行う場合:

```bash
terraform destroy
```

実行前に、確認プロンプトで削除対象リソース数・種類を必ず目視確認すること。

## 4. 削除後の確認

```bash
./scripts/prod/status.sh
```

- AWS Budgetsのアラートが正常な範囲に収まっていることを確認する。
- Route53の`api.pitviaapp.com`Aliasレコードは残ったままになる（ALB削除により参照先が無効化されるが、レコード自体は削除されない）。次回再構築時、`recover.sh`が新しいALBへ自動UPSERTする（`docs/operations/recovery.md`参照）。

---

# 注意事項

- `infra/terraform/bootstrap`（State用S3バケット）は今回のスコープでは`destroy`しない。
- Vercel Project自体（`infra/terraform/vercel`）は`destroy`しない（Pauseのみ）。
- JWTシークレット（Secrets Manager）はAWSリソース削除に含まれる。再構築後、値の再投入が必要になる（`docs/operations/recovery.md`参照。再投入によりリフレッシュトークンは無効化される）。
