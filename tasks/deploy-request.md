# Deploy request
app: letflow-queue
ref: master (ba9f1e0)
env: test
ready: false
notes: >
  Initial deploy. Small Elixir/Phoenix + SQLite service, 4 endpoints
  (register_task, get_next_task, set_lock, release_lock) for multi-host
  Letflow agent coordination. 46/46 tests passing locally, including
  concurrent-claim race tests; Docker release build verified locally.
  Requires ai-dala-infra's T-0107 (setup) to run first, then this
  deploy request is what T-0108 (deploy-app workflow) reads to pick
  the git ref. See README.md for the full endpoint contract and
  deploy/ for Dockerfile, docker-compose.{test,prod}.yml, and nginx
  vhost snippets. Host port 127.0.0.1:3112 (test), assumed free per
  ai-dala-infra/landscape/services.md as of 2026-08-15 — re-verify
  before deploying.
