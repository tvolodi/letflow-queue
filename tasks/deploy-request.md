# Deploy request
app: letflow-queue
ref: master (15e388f)
env: test
ready: true
notes: >
  GitHub Issues sync feature (best-effort, two-way, visibility only —
  see README.md's "GitHub Issues sync" section). register_task now
  also creates a GitHub Issue; get_next_task imports untracked open
  issues before its claim query; release_lock(status: "done") closes
  the linked issue. All best-effort — degrades to a no-op without
  GITHUB_TOKEN/GITHUB_REPO configured, never blocks the core queue
  functions. 57/57 tests passing (46 pre-existing unmodified + 11 new),
  CI green. See ai-dala-infra's T-0110 for the redeploy task, which
  also needs a GitHub PAT (repo scope on tvolodi/letflow) added to
  .env as GITHUB_TOKEN before the sync behavior is actually live —
  the redeploy itself is safe without it (feature stays inert).
