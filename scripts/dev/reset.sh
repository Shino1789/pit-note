#!/bin/bash

# ==================================================
# Docker開発環境 リセットスクリプト
#
# - コンテナ停止
# - ネットワーク削除
# - Volume削除
#
# Volumeも削除されるため、
# PostgreSQLデータやnode_modulesも初期化される。
#
# Docker環境が壊れた時の完全初期化用。
# ==================================================

docker compose \
-f docker-compose.dev.yml \
--env-file .env.dev down -v
