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

The task queue itself has exactly **four** externally-callable
operations. This is deliberate: an AI agent driving this service can
register a task, claim the next eligible one, and lock/release —
nothing else. There is no generic CRUD, no way to list/edit/delete
tasks outside that lock protocol, and no way to bypass the atomic-claim
semantics. (A separate, small key-management surface — "Client API
keys" below — exists alongside this for auth administration; it isn't
part of the four.)

1. **register_task** — create a new task.
2. **get_next_task** — atomically claim the single next eligible task
   (`status = "open"`, unlocked, all dependencies `"done"`). Two-tier
   priority: the **newest** eligible `task_type: "issue"` task if one
   exists, else the **lowest-`impl_order`** eligible `task_type:
   "requirement"` task.
3. **set_lock** — explicit manual (re-)lock of a task you already know
   the id of (e.g. re-acquiring your own lock after a crash).
4. **release_lock** — release a lock, optionally transitioning status,
   with an admin/ORCH `force` override to unstick a task if a host died
   mid-work.

Every task row: `id` (= `impl_order`, autoincrement primary key),
`title`, `description`, `acceptance_criteria` (JSON list of strings),
`depends_on` (JSON list of other task ids), `stage` (free-form string,
purely informational — mirrors Letflow's S0–S8 stage tags with no
validation), `task_type` (`"requirement"` | `"issue"` — required on
`register_task`; drives `get_next_task`'s claim priority, see below),
`status` (`"open"` | `"done"` | `"blocked"`), `locked_by`,
`locked_at`, `github_issue_number` (nullable — see "GitHub Issues sync"
below), `body` (nullable — full verbatim GitHub issue text, only set for
tasks imported from GitHub), `inserted_at`/`updated_at`.

`impl_order` and `id` are always the same integer. The field is exposed
under both names in every JSON response so callers don't have to know
that "id" doubles as the queue's implementation order.

## Issue refs — why the queue allocates them

Every response also carries **`issue_ref`**: for `task_type: "issue"`,
`"ISS-"` plus the zero-padded `id` (task 186 → `"ISS-0186"`); `null` for
requirements. This is the id a caller should name its own local issue
record with, and for issue-type tasks the queue also rewrites the task's
`title` to carry the ref as a prefix — replacing any `ISS-NNNN:` the
caller supplied.

**This exists because callers cannot safely pick the number themselves.**
Letflow's agents previously derived the next id by scanning a directory
of `ISS-NNNN.yaml` files and taking the highest plus one. That is a
read-then-write race with no lock between the halves, and across
concurrent sessions on different hosts it collided **eight** separate
times — once silently overwriting another session's file while a live
GitHub issue still pointed at it, and once in a run that scanned every
remote branch first, exactly as its own documentation prescribed, and
collided anyway because the colliding numbers did not exist on any branch
at the moment it looked.

A scan cannot reserve a number; only an allocator can. `id` is an
autoincrement primary key, so the database allocates it atomically and no
two callers can ever receive the same one — deriving the ref from it
inherits that guarantee with no second sequence to keep consistent, no
retry path, and nothing to go wrong under concurrency.

The trade is that refs are **not contiguous**: ids are shared with
requirement-type tasks, and any pre-existing hand-numbered issues occupy a
lower range. That is deliberate. Contiguity was never worth having — the
collisions and the renumbering they forced had already destroyed it — and
it is exactly the property that cannot be delivered without a guess.

The title rewrite is the enforcement half. Without it a caller could still
put a guessed number in the title, and that guess — not the allocated ref
— is what a human would read in the GitHub issue list. Only a *leading*
`ISS-NNNN:` token is replaced; an `ISS-` reference elsewhere in the title
is a genuine cross-reference to another issue and is left verbatim.

## GitHub Issues sync

The four operations above remain the only *control* surface — agents
never read or write GitHub Issues to drive the queue. Separately, this
service optionally mirrors queue state into GitHub's own UI for human
visibility, in both directions:

1. **`register_task` → GitHub.** By default, `register_task` also creates
   a GitHub Issue on the configured repo: title = the canonical title
   (carrying the `issue_ref` prefix, see above), body = task description +
   acceptance criteria. The returned issue number is stored on the task row
   as `github_issue_number`.

   **Unless the caller passes `github_issue_number` itself**, in which case
   the service *adopts* that number and creates nothing. This matters when
   the caller has already filed the issue — previously the unconditional
   create left it with two issues for one finding: its own, carrying the
   real diagnosis, and a service-created mirror. The task row pointed at
   the mirror, so the close-on-done in (3) below closed the mirror and left
   the real issue open, and each pair had to be reconciled by a hand-written
   note in the local record. A supplied number already linked to another
   task is rejected (unique index) rather than silently re-pointed.
2. **GitHub → `get_next_task`.** Every call to `get_next_task` first
   pulls the repo's open issues and imports any not already tracked
   (matched by `github_issue_number`) as new local tasks — title = issue
   title, `body` = the full issue body verbatim (not parsed),
   `acceptance_criteria` = `["See linked GitHub issue for full description"]`
   (a raw issue body doesn't map onto a structured criteria list),
   `depends_on = []` (GitHub-originated tasks have no way to express
   queue-native dependencies — a known, accepted limitation), `stage =
   nil`, `task_type = "issue"` (a raw GitHub Issue is always incidental,
   never a planned requirement). This import runs *before* the existing
   atomic-claim query, so an imported issue can be claimed in the same
   call that imported it.
3. **`release_lock` → GitHub.** Releasing a task's lock with
   `status: "done"` closes the linked GitHub Issue, if the task has a
   non-nil `github_issue_number`.

**All three directions are best-effort.** GitHub sync requires two
environment variables — `GITHUB_TOKEN` (a personal access token) and
`GITHUB_REPO` (e.g. `tvolodi/letflow`). If either is unset, or the
GitHub API call fails for any reason (network error, rate limit, bad
token), the sync step is skipped and logged
(`Logger.warning/1`) — it never blocks, fails, or changes the result of
the underlying queue operation. The service works fully without any
GitHub configuration at all; you only lose the GitHub-side visibility.

## Auth

Every endpoint except `GET /health` requires
`Authorization: Bearer <token>`. Two credential forms are accepted
(`LetflowQueueWeb.AuthPlug`):

1. **The legacy shared token** — `QUEUE_AUTH_TOKEN`, an environment
   variable read at boot (`config/runtime.exs`, never hardcoded),
   provisioned out of band on the server. Still valid so already-deployed
   clients keep working, and because it's what bootstraps a brand-new
   client's own key (below). New clients shouldn't adopt it directly —
   it's shared and can't be revoked per-client.
2. **A per-client API key** (`LetflowQueue.ApiKeys`) — the intended path
   for every client going forward. Minted once via `POST /api_keys`,
   handed to that client in the response, and never retrievable again.
   Independently revocable, and doesn't require server/SSH access to
   obtain — see "Client API keys" below.

Both forms are checked on every authenticated request: the legacy token
via constant-time comparison, a per-client key via a SHA-256 hash lookup
(the raw token itself is never stored, so a leaked database dump doesn't
expose usable credentials).

## Client API keys

The problem this solves: previously, `QUEUE_AUTH_TOKEN` was the *only*
credential, and it lived solely in the server's own `.env` file — so any
new client (a fresh host, a fresh agent session) had to SSH into the
server just to read the value it needed to make its first API call. Per-
client keys remove that: a client that already holds *any* valid
credential can mint itself (or another client) a new one over the API,
no server access required.

**Bootstrapping the very first key for a new deployment** still requires
`QUEUE_AUTH_TOKEN` once (there's nothing else to authenticate with yet).
After that, minting further keys — for additional hosts, or to rotate an
existing client off the legacy token — only needs an already-active key.

```bash
# Mint a new key (requires an existing valid credential — the legacy
# token, or another active key — as the bearer token below):
curl -X POST https://queue-test.ai-dala.com/api_keys \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"label": "vlad-workstation"}'
```

```json
{
  "data": {
    "id": 1,
    "label": "vlad-workstation",
    "token": "lfq_9f2c...redacted...",
    "revoked_at": null,
    "inserted_at": "2026-08-17T00:00:00Z"
  },
  "error": null
}
```

`token` is present **only in this create response** — store it locally
on that client immediately (never in a tracked file); it cannot be
retrieved again. From then on, that client authenticates with
`Authorization: Bearer lfq_9f2c...` on every call, including future
`POST /api_keys` calls to mint keys for other clients.

```bash
# Revoke a leaked or retired key (also requires a valid credential):
curl -X POST https://queue-test.ai-dala.com/api_keys/1/revoke \
  -H "Authorization: Bearer $SOME_STILL_VALID_TOKEN"
```

Revoking is idempotent — calling it again on an already-revoked key
succeeds without error. There's no list/enumerate endpoint (same
minimal-surface philosophy as the task queue itself) — record each
key's `label` ↔ purpose in `ai-dala-infra`'s secrets-inventory when you
mint it, the same convention already used for `QUEUE_AUTH_TOKEN` itself.

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
    "stage": "S2",
    "task_type": "requirement"
  }'
```

`title`, `description`, `acceptance_criteria` (non-empty list of
strings), and `task_type` (`"requirement"` or `"issue"`) are required.
`depends_on` (list of other task ids) and `stage` are optional, as is
`github_issue_number` — pass it only when you have already filed the
GitHub issue yourself and want the service to adopt it instead of
creating a second one (see "GitHub Issues sync" above).

For `task_type: "issue"`, the response's `issue_ref` is the allocated id
to name your local record with, and `title` comes back rewritten with that
ref as a prefix (see "Issue refs" above). Do **not** put a guessed
`ISS-NNNN:` in the title you send — a leading one is stripped and replaced.

Response (`201 Created`):

```json
{
  "data": {
    "id": 42,
    "impl_order": 42,
    "issue_ref": null,
    "title": "Implement REQ-042",
    "description": "Add the foo endpoint per docs/requirements.yaml",
    "acceptance_criteria": ["mix test passes", "REVIEWER sign-off recorded"],
    "depends_on": [12, 13],
    "stage": "S2",
    "task_type": "requirement",
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

Atomically claims a task that is `status = "open"`, unlocked, and whose
every `depends_on` id is `status = "done"`, in the same statement that
sets `locked_by`/`locked_at` — so two concurrent callers can never
receive the same task. Priority is two-tier: the **newest** (highest
`impl_order`) eligible `task_type: "issue"` task if one exists, else the
**lowest-`impl_order`** eligible `task_type: "requirement"` task.

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

GitHub sync is entirely optional locally too: set `GITHUB_TOKEN` (a
personal access token) and `GITHUB_REPO` (e.g. `tvolodi/letflow`) as
environment variables before starting the server if you want to exercise
it against the real GitHub API; leave them unset and every sync step
silently no-ops.

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

`test/letflow_queue/github_sync_test.exs` covers the GitHub Issues sync
behavior described above, against `LetflowQueue.GitHub.FakeClient`
(`test/support/github/fake_client.ex`) — an in-memory fake standing in for
`LetflowQueue.GitHub.ReqClient`, configured via
`config :letflow_queue, github_client: ...` in `config/test.exs`. No test
in this suite makes a real network call to GitHub.

`test/letflow_queue/api_keys_test.exs` and
`test/letflow_queue_web/controllers/api_key_controller_test.exs` cover
per-client key minting, hashing (the plaintext token is never persisted),
revocation, and the dual-credential `AuthPlug` behavior end-to-end
against the task endpoints (a minted key authenticates `GET /tasks/next`;
a revoked one is rejected).

## Deploying

See `deploy/`:

- `deploy/Dockerfile` — multi-stage build (Elixir builder → Debian
  slim runtime via `mix release`), runs as a non-root user, exposes
  port `4000` internally, persists the SQLite file to
  `/app/data/queue.db` (mount a volume there).
- `deploy/docker-compose.test.yml` / `docker-compose.prod.yml` —
  single-service compose files. `env_file: .env` is resolved relative
  to `deploy/` — copy `deploy/.env.example` to `deploy/.env` and fill
  in real values first. Host ports `127.0.0.1:3112` (test) and
  `127.0.0.1:3102` (prod) only — this is an internal coordination
  service; nginx fronts it.
- `deploy/nginx/letflow-queue-test.conf` / `letflow-queue.conf` — nginx
  vhost snippets for `queue-test.ai-dala.com` / `queue.ai-dala.com`,
  proxying to the host ports above.
- `deploy/redeploy-test.sh` — git pull + rebuild + force-recreate +
  health-check-with-retry, run on the host. Used both for manual
  redeploys and by CD (below).

Host ports: `127.0.0.1:3112` (test) and `127.0.0.1:3102` (prod) — the
next free slots in `ai-dala-infra`'s declared `3110-3119` (test) and
`3100-3109` (prod) blocks respectively, per
`ai-dala-infra/landscape/services.md`/`shared/app-registry.md` as of
2026-08-15 (`3100`, `3101`, `3110`, `3111` occupied). Re-verify against
the live port registry before actually deploying, since that file can
drift — `ai-dala-infra`'s own setup task for this service
(`T-0107-setup-letflow-queue-deploy-infra`) carries the same reminder.

## Continuous deployment

`.github/workflows/cd.yml` redeploys the **test** environment automatically:
on every push to `master`, once `.github/workflows/ci.yml` passes, a job
SSHes into `hetzner-prod` and runs `deploy/redeploy-test.sh`.

The SSH key used (`HETZNER_DEPLOY_SSH_KEY`, a GitHub Actions secret on this
repo, alongside `HETZNER_DEPLOY_HOST`/`HETZNER_DEPLOY_USER`) is deliberately
narrow: its `authorized_keys` entry on the host is restricted via a
`command=` forced-command option (`sudo bash .../redeploy-test.sh`) plus
`restrict` to run *only* that one script — it cannot open an interactive
shell or run any other command, even if the secret leaked. Verified live at
provisioning time: both an unrelated command and a deliberately destructive
one (`rm -rf` the app directory), sent over the key, ran the forced redeploy
script instead of the requested command. See `ai-dala-infra`'s
`T-0111-provision-letflow-queue-cd-deploy-key.md` and
`landscape/hosts/hetzner-prod.md`'s "Inbound CD deploy keys" section for the
full detail. This repo's own agents/CI cannot create or rotate that key —
it's generated on the host and handed to a human (or, per `T-0111`, set
directly via `gh secret set` once generated) to add as a secret here.

There is no CD for **prod** — `queue.ai-dala.com` isn't deployed yet, and
when it is, promotion to prod should stay a deliberate, separately-triggered
step (e.g. a tag push or manual workflow dispatch), not another effect of
pushing to `master`.
