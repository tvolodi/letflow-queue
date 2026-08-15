#!/usr/bin/env bash
# Redeploy letflow-queue to the test environment on hetzner-prod.
# Run as root (or the CD deploy account) on the host:
#   bash /opt/apps/letflow-queue-test/deploy/redeploy-test.sh
#
# Invoked two ways:
#   1. Manually, per ai-dala-infra's deploy-app workflow (see T-0108's precedent).
#   2. Automatically, by .github/workflows/cd.yml over a restricted SSH deploy key
#      (see ai-dala-infra's T-0111) after CI passes on a push to master. The
#      command= restriction on that key invokes this exact script — nothing else.
set -euo pipefail

APP_DIR=/opt/apps/letflow-queue-test
COMPOSE="docker compose --project-directory $APP_DIR -f $APP_DIR/deploy/docker-compose.test.yml"
DATE=$(date +%Y%m%d)

echo "=== letflow-queue test redeploy: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# 1. Pull latest code (public repo — no credential injection needed)
cd "$APP_DIR"
git pull
CURRENT_REF=$(git rev-parse --short HEAD)
echo "Git ref: $CURRENT_REF"

# 2. Tag rollback image (best-effort — ignore if it doesn't exist yet, e.g. first run)
docker tag letflow-queue-test:latest "letflow-queue-test:rollback-${DATE}" 2>/dev/null || true

# 3. Build image
echo "--- Building image ---"
docker build -f deploy/Dockerfile -t letflow-queue-test:latest .

# 4. Restart container (Ecto migrations run automatically on boot via
#    Ecto.Migrator in the supervision tree — see lib/letflow_queue/application.ex)
echo "--- Restarting container ---"
$COMPOSE up -d --force-recreate

# 5. Health check (retry for up to 30 s)
echo "--- Health check ---"
for i in $(seq 1 10); do
  STATUS=$(curl -sf http://127.0.0.1:3112/health | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [[ "$STATUS" == "ok" ]]; then
    echo "Health check passed (attempt $i)"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "ERROR: health check did not pass after 10 attempts" >&2
    exit 1
  fi
  echo "Waiting... ($i/10)"
  sleep 3
done

echo "=== Done. Deployed ref: $CURRENT_REF ==="
