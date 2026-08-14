# letflow-queue

A small, self-contained coordination service for a multi-host AI-agent
development pipeline. It exists for one purpose: let multiple hosts,
each running Claude Code agents against the sibling
[Letflow](../letflow) project, claim work items ("tasks", representing
Letflow requirements) from a single shared queue without two hosts ever
grabbing the same one.

Stack: Elixir + Phoenix, HTTP via Bandit, persistence via Ecto +
`ecto_sqlite3` (a single SQLite file on disk — no Postgres, no other
services to run).

## Design

There are exactly **four** externally-callable operations. This is
deliberate: an AI agent driving this service can register a task, claim
the next eligible one, and lock/release — nothing else. There is no
generic CRUD, no way to list/edit/delete tasks outside that lock
protocol, and no way to bypass the atomic-claim semantics.

1. **register_task** — create a new task.
2. **get_next_task** — atomically claim the single next eligible task
   (lowest `impl_order`, `status = "open"`, unlocked, all dependencies
   `"done"`).
3. **set_lock** — explicit manual (re-)lock of a task you already know
   the id of (e.g. re-acquiring your own lock after a crash).
4. **release_lock** — release a lock, optionally transitioning status,
   with an admin/ORCH `force` override to unstick a task if a host died
   mid-work.

Every task row: `id` (= `impl_order`, autoincrement primary key),
`title`, `description`, `acceptance_criteria` (JSON list of strings),
`depends_on` (JSON list of other task ids), `stage` (free-form string,
purely informational — mirrors Letflow's S0–S8 stage tags with no
validation), `status` (`"open"` | `"done"` | `"blocked"`), `locked_by`,
`locked_at`, `inserted_at`/`updated_at`.

`impl_order` and `id` are always the same integer. The field is exposed
under both names in every JSON response so callers don't have to know
that "id" doubles as the queue's implementation order.

## Auth

Every endpoint except `GET /health` requires
`Authorization: Bearer <token>`, checked against the single shared
token in the `QUEUE_AUTH_TOKEN` environment variable (read at boot in
`config/runtime.exs`, never hardcoded). There is no token
generation/rotation endpoint — the token is provisioned out of band and
shared by every host/agent that talks to this service.

## Response envelope

Every endpoint returns `{"data": ..., "error": ...}` — exactly one of
the two is non-null. The one deviation is `GET /health`, which returns
the minimal `{"status":"ok"}` shape instead, since it's consumed by
generic infra tooling (Docker `HEALTHCHECK`, compose, uptime probes)
that expects that exact minimal body rather than the app's own
envelope.

## Endpoints

### `POST /tasks` — register_task

Request:

```bash
curl -X POST http://localhost:4000/tasks \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Implement REQ-042",
    "description": "Add the foo endpoint per docs/requirements.yaml",
    "acceptance_criteria": ["mix test passes", "REVIEWER sign-off recorded"],
    "depends_on": [12, 13],
    "stage": "S2"
  }'
```

`title`, `description`, `acceptance_criteria` (non-empty list of
strings) are required. `depends_on` (list of other task ids) and
`stage` are optional. Response (`201 Created`):

```json
{
  "data": {
    "id": 42,
    "impl_order": 42,
    "title": "Implement REQ-042",
    "description": "Add the foo endpoint per docs/requirements.yaml",
    "acceptance_criteria": ["mix test passes", "REVIEWER sign-off recorded"],
    "depends_on": [12, 13],
    "stage": "S2",
    "status": "open",
    "locked_by": null,
    "locked_at": null,
    "inserted_at": "2026-08-15T00:00:00Z",
    "updated_at": "2026-08-15T00:00:00Z"
  },
  "error": null
}
```

Missing required fields return `422` with `data: null` and a
human-readable `error` string.

### `GET /tasks/next?agent_id=<id>` — get_next_task

Atomically finds the lowest-`impl_order` task that is `status = "open"`,
unlocked, and whose every `depends_on` id is `status = "done"` in the
same statement that claims it (sets `locked_by`/`locked_at`) — so two
concurrent callers can never receive the same task.

```bash
curl "http://localhost:4000/tasks/next?agent_id=host-a" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
```

Success (`200`): the full claimed task record, same shape as above,
with `locked_by` set to `"host-a"`.

Nothing eligible (`404`):

```json
{ "data": null, "error": "no_eligible_task" }
```

### `POST /tasks/:id/lock` — set_lock

Explicit manual (re-)lock of a task you already know about (not
obtained via `get_next_task`) — e.g. reacquiring your own lock after a
crash, using the same `agent_id`.

```bash
curl -X POST http://localhost:4000/tasks/42/lock \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "host-a"}'
```

- Unlocked, or already locked by the same `agent_id` → `200`, lock
  set/refreshed (re-locking with the same `agent_id` is idempotent).
- Locked by a *different* `agent_id` → `409 Conflict`.
- Unknown task id → `404`.

### `POST /tasks/:id/release` — release_lock

```bash
curl -X POST http://localhost:4000/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "host-a", "status": "done"}'
```

- `agent_id` — required unless `force: true`.
- `status` (optional) — `"done"` or `"blocked"`, transitions the task's
  status atomically as part of the same call. Omit it to just clear the
  lock and leave status as `"open"`.
- `force: true` — admin/ORCH override. Releases the lock regardless of
  which `agent_id` currently holds it — for unsticking a task after a
  host died mid-work:

  ```bash
  curl -X POST http://localhost:4000/tasks/42/release \
    -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"force": true}'
  ```

Without `force: true`, releasing a lock held by a different `agent_id`
than the caller supplied fails with `409 Conflict`.

### `GET /health`

No auth required — for the infra deploy pipeline's health check.

```bash
curl http://localhost:4000/health
# {"status":"ok"}
```

## Running locally

```bash
mix deps.get
mix ecto.setup      # ecto.create + ecto.migrate + seeds
mix phx.server
```

The dev config (`config/dev.exs`) has a hardcoded fallback auth token
(`dev-secret-token`) so you don't need to set `QUEUE_AUTH_TOKEN` locally.
Override it with the real env var if you want to test the boot-time
read path.

## Running tests

```bash
mix test
```

This includes `test/letflow_queue/tasks_test.exs`, which exercises all
four context functions directly (not just over HTTP) — including a
concurrency test that spawns two (and, separately, ten) simultaneous
`get_next_task/1` callers against the same eligible row and asserts
exactly one receives it. There's also an HTTP-level test suite in
`test/letflow_queue_web/controllers/task_controller_test.exs` covering
auth, status codes, and the response envelope.

## Deploying

See `deploy/`:

- `deploy/Dockerfile` — multi-stage build (Elixir builder → Debian
  slim runtime via `mix release`), runs as a non-root user, exposes
  port `4000` internally, persists the SQLite file to
  `/app/data/queue.db` (mount a volume there).
- `deploy/docker-compose.test.yml` / `docker-compose.prod.yml` —
  single-service compose files. `env_file: .env` is resolved relative
  to `deploy/` — copy `deploy/.env.example` to `deploy/.env` and fill
  in real values first. Host ports `127.0.0.1:3120` (test) and
  `127.0.0.1:3102` (prod) only — this is an internal coordination
  service; nginx fronts it.
- `deploy/nginx/letflow-queue-test.conf` / `letflow-queue.conf` — nginx
  vhost snippets for `queue-test.ai-dala.com` / `queue.ai-dala.com`,
  proxying to the host ports above.

Host ports: `127.0.0.1:3112` (test) and `127.0.0.1:3102` (prod) — the
next free slots in `ai-dala-infra`'s declared `3110-3119` (test) and
`3100-3109` (prod) blocks respectively, per
`ai-dala-infra/landscape/services.md`/`shared/app-registry.md` as of
2026-08-15 (`3100`, `3101`, `3110`, `3111` occupied). Re-verify against
the live port registry before actually deploying, since that file can
drift — `ai-dala-infra`'s own setup task for this service
(`T-0107-setup-letflow-queue-deploy-infra`) carries the same reminder.
