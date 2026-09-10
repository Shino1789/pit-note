#!/bin/bash

# ==================================================
# Docker開発環境 停止スクリプト
# ==================================================

docker compose \
-f docker-compose.dev.yml \
--env-file .env.dev down
