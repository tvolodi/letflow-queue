defmodule LetflowQueue.Tasks do
  @moduledoc """
  Business logic for the shared task queue. This is the only module that
  touches `LetflowQueue.Repo` for task data — the web layer (controllers)
  calls into these four functions and nothing else, so this module *is*
  the entire externally-reachable surface for AI agents driving the queue.

    * `register_task/1` — create a new task
    * `get_next_task/1` — atomically claim the next eligible task
    * `set_lock/2` — explicit manual (re-)lock of a known task
    * `release_lock/2` — release a lock, optionally transitioning status,
      optionally with an admin/ORCH `force` override
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias LetflowQueue.GitHub
  alias LetflowQueue.Repo
  alias LetflowQueue.Tasks.Task

  @type task :: Task.t()

  @doc """
  Creates a new task with an auto-incrementing `impl_order` (== `id`).
  Status starts as `"open"`. `task_type` (`"requirement"` or `"issue"`)
  is required — it drives `get_next_task/1`'s claim priority and has no
  reliable way to be inferred after the fact.

  Also creates a corresponding GitHub Issue on the configured repo
  (`GITHUB_REPO`) as **best-effort** sync: title = task title, body = task
  description + acceptance criteria. If GitHub isn't configured or the API
  call fails for any reason, this is logged and `register_task/1` still
  succeeds — the local task is always created regardless of GitHub's
  availability, with `github_issue_number: nil` in that case.

  Returns `{:ok, task}` or `{:error, changeset}`.
  """
  @spec register_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def register_task(attrs) when is_map(attrs) do
    with {:ok, task} <- %Task{} |> Task.create_changeset(attrs) |> Repo.insert() do
      {:ok, maybe_create_github_issue(task)}
    end
  end

  defp maybe_create_github_issue(task) do
    case GitHub.create_issue(task.title, issue_body(task)) do
      {:ok, issue_number} ->
        task
        |> Task.github_issue_changeset(issue_number)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            updated

          {:error, changeset} ->
            Logger.warning(
              "letflow-queue: created GitHub issue ##{issue_number} for task #{task.id} " <>
                "but failed to persist github_issue_number: #{inspect(changeset.errors)}"
            )

            task
        end

      {:error, reason} ->
        Logger.warning(
          "letflow-queue: GitHub issue creation failed for task #{task.id} (#{inspect(reason)}); " <>
            "continuing without GitHub sync"
        )

        task
    end
  end

  defp issue_body(task) do
    criteria =
      task.acceptance_criteria
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    """
    #{task.description}

    Acceptance criteria:
    #{criteria}
    """
  end

  @doc """
  First imports any open GitHub Issues not yet tracked locally as new
  `"open"` tasks (best-effort — skipped entirely if GitHub isn't
  configured or the API call fails, never blocking the claim below), then
  atomically claims the next eligible task — `status = "open"`, unlocked,
  and every `depends_on` id `status = "done"` — setting
  `locked_by`/`locked_at` for it in a single SQL statement so two
  concurrent callers can never claim the same row.

  Claim priority is two-tier:

    1. If any eligible `task_type: "issue"` task exists, the **newest**
       one (highest id) is claimed — issues jump the line, most recent
       first.
    2. Otherwise, the eligible `task_type: "requirement"` task with the
       **lowest** `impl_order` (id) is claimed — unchanged FIFO order.

  Returns `{:ok, task}` on success, or `{:error, :no_eligible_task}` if
  nothing is currently claimable.
  """
  @spec get_next_task(String.t()) :: {:ok, Task.t()} | {:error, :no_eligible_task}
  def get_next_task(agent_id) when is_binary(agent_id) and agent_id != "" do
    import_open_github_issues()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The eligibility predicate (open, unlocked, all dependencies done) is
    # evaluated inside the same UPDATE statement that performs the claim.
    # The candidate id is COALESCE of two scalar subqueries: the newest
    # eligible issue-type task (id DESC), falling back to the
    # lowest-impl_order eligible requirement-type task (id ASC) only when
    # no eligible issue exists. SQLite executes writers serially, and
    # wrapping this in an explicit transaction ensures the SELECT-then-
    # UPDATE the query planner performs internally can't interleave with
    # another writer — so two concurrent callers can never both claim the
    # same row.
    query = """
    UPDATE tasks
    SET locked_by = ?1, locked_at = ?2, updated_at = ?2
    WHERE id = COALESCE(
      (
        SELECT t.id FROM tasks t
        WHERE t.status = 'open'
          AND t.locked_by IS NULL
          AND t.task_type = 'issue'
          AND NOT EXISTS (
            SELECT 1 FROM json_each(t.depends_on) dep
            WHERE NOT EXISTS (
              SELECT 1 FROM tasks dt
              WHERE dt.id = dep.value AND dt.status = 'done'
            )
          )
        ORDER BY t.id DESC
        LIMIT 1
      ),
      (
        SELECT t.id FROM tasks t
        WHERE t.status = 'open'
          AND t.locked_by IS NULL
          AND t.task_type = 'requirement'
          AND NOT EXISTS (
            SELECT 1 FROM json_each(t.depends_on) dep
            WHERE NOT EXISTS (
              SELECT 1 FROM tasks dt
              WHERE dt.id = dep.value AND dt.status = 'done'
            )
          )
        ORDER BY t.id ASC
        LIMIT 1
      )
    )
    RETURNING id, title, description, acceptance_criteria, depends_on,
      stage, task_type, status, locked_by, locked_at, github_issue_number,
      body, inserted_at, updated_at
    """

    case Repo.transaction(fn ->
           case Ecto.Adapters.SQL.query!(Repo, query, [agent_id, now]) do
             %{rows: [row]} ->
               load_task(row)

             %{rows: []} ->
               nil
           end
         end) do
      {:ok, nil} -> {:error, :no_eligible_task}
      {:ok, task} -> {:ok, task}
    end
  end

  # Best-effort import step run before the atomic claim query. Never raises
  # and never affects the claim below: a GitHub failure here just means the
  # import is skipped for this call, and the existing claim query proceeds
  # exactly as it did before this feature existed.
  defp import_open_github_issues do
    case GitHub.list_open_issues() do
      {:ok, issues} ->
        Enum.each(issues, &import_github_issue/1)

      {:error, reason} ->
        Logger.warning(
          "letflow-queue: GitHub issue import failed (#{inspect(reason)}); " <>
            "proceeding without import for this call"
        )
    end
  end

  defp import_github_issue(%{number: number, title: title, body: body}) do
    if Repo.exists?(from t in Task, where: t.github_issue_number == ^number) do
      :ok
    else
      attrs = %{"title" => title, "body" => body, "github_issue_number" => number}

      %Task{}
      |> Task.github_import_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _task} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "letflow-queue: failed to import GitHub issue ##{number} as a task: " <>
              inspect(changeset.errors)
          )
      end
    end
  end

  # The column order returned by the hand-written RETURNING clause above —
  # kept explicit (rather than trusting driver-reported column metadata,
  # which exqlite doesn't populate for UPDATE ... RETURNING) so the
  # positional row can be zipped back into a column-name => value map and
  # run through the schema's Ecto.Type loaders (decoding the JSON text
  # columns).
  @returning_columns ~w(id title description acceptance_criteria depends_on
    stage task_type status locked_by locked_at github_issue_number body
    inserted_at updated_at)

  defp load_task(row) when is_list(row) do
    @returning_columns
    |> Enum.zip(row)
    |> Map.new()
    |> then(&Repo.load(Task, &1))
  end

  @doc """
  Explicit manual (re-)lock of a task by id.

    * If the task is unlocked, or already locked by the same `agent_id`,
      the lock is set/refreshed and `{:ok, task}` is returned.
    * If the task is locked by a *different* agent_id, returns
      `{:error, :locked_by_other}`.
    * If the task doesn't exist, returns `{:error, :not_found}`.
  """
  @spec set_lock(integer(), String.t()) ::
          {:ok, Task.t()} | {:error, :locked_by_other} | {:error, :not_found}
  def set_lock(id, agent_id) when is_binary(agent_id) and agent_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:task, fn repo, _ ->
      case repo.get(Task, id) do
        nil -> {:error, :not_found}
        task -> {:ok, task}
      end
    end)
    |> Multi.run(:locked, fn repo, %{task: task} ->
      cond do
        is_nil(task.locked_by) or task.locked_by == agent_id ->
          task
          |> Ecto.Changeset.change(locked_by: agent_id, locked_at: now)
          |> repo.update()

        true ->
          {:error, :locked_by_other}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{locked: task}} -> {:ok, task}
      {:error, :task, :not_found, _} -> {:error, :not_found}
      {:error, :locked, :locked_by_other, _} -> {:error, :locked_by_other}
    end
  end

  @doc """
  Releases a task's lock.

  Options (keyword list):
    * `:agent_id` — the caller's agent id. Required unless `force: true`.
    * `:status` — if given (`"done"` or `"blocked"`), also transitions the
      task's status atomically as part of the same call. If omitted, the
      lock is cleared and status is left as-is (typically `"open"`).
    * `:force` — if `true`, releases the lock regardless of which
      agent_id currently holds it (admin/ORCH override for unsticking a
      task after a host died mid-work).

  Returns `{:ok, task}`, `{:error, :not_found}`,
  `{:error, :locked_by_other}` (releasing another agent's lock without
  `force: true`), or `{:error, :agent_id_required}`.
  """
  @spec release_lock(integer(), keyword()) ::
          {:ok, Task.t()}
          | {:error, :not_found}
          | {:error, :locked_by_other}
          | {:error, :agent_id_required}
  def release_lock(id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    status = Keyword.get(opts, :status)
    force = Keyword.get(opts, :force, false)

    cond do
      not force and (is_nil(agent_id) or agent_id == "") ->
        {:error, :agent_id_required}

      status not in [nil, "open", "done", "blocked"] ->
        {:error, :invalid_status}

      true ->
        do_release_lock(id, agent_id, status, force)
    end
  end

  defp do_release_lock(id, agent_id, status, force) do
    case Repo.get(Task, id) do
      nil ->
        {:error, :not_found}

      task ->
        if force or is_nil(task.locked_by) or task.locked_by == agent_id do
          changes = %{locked_by: nil, locked_at: nil}
          changes = if status, do: Map.put(changes, :status, status), else: changes

          task
          |> Ecto.Changeset.change(changes)
          |> Repo.update()
          |> tap_maybe_close_github_issue(status)
        else
          {:error, :locked_by_other}
        end
    end
  end

  # Best-effort: closes the linked GitHub issue (if any) when a release
  # transitions the task to "done". Never affects the release's own
  # result — a GitHub failure here is logged and swallowed.
  defp tap_maybe_close_github_issue(
         {:ok, %Task{status: "done", github_issue_number: n} = task},
         "done"
       )
       when is_integer(n) do
    case GitHub.close_issue(n) do
      {:ok, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "letflow-queue: failed to close GitHub issue ##{n} for task #{task.id} " <>
            "(#{inspect(reason)}); local status transition already committed"
        )
    end

    {:ok, task}
  end

  defp tap_maybe_close_github_issue(result, _status), do: result
end
