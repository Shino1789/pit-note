#!/bin/bash

# ==================================================
# Docker開発環境 起動スクリプト
# ==================================================

docker compose \
  -f docker-compose.dev.yml \
  --env-file .env.dev up &

echo "⏳ Waiting for Next.js..."

until curl -s http://localhost:3000 > /dev/null; do
  sleep 3
done

echo "⏳ Waiting for Spring Boot..."

until curl -s http://localhost:8080/api/v1/health/db > /dev/null; do
  sleep 3
done

echo "🚀 Pitvia development environment is ready!"

open http://localhost:3000
