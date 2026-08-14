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

  alias Ecto.Multi
  alias LetflowQueue.Repo
  alias LetflowQueue.Tasks.Task

  @type task :: Task.t()

  @doc """
  Creates a new task with an auto-incrementing `impl_order` (== `id`).
  Status starts as `"open"`.

  Returns `{:ok, task}` or `{:error, changeset}`.
  """
  @spec register_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def register_task(attrs) when is_map(attrs) do
    %Task{}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Atomically finds and claims the lowest-`impl_order` task that is
  `status = "open"`, unlocked, and whose every `depends_on` id is
  `status = "done"` — then sets `locked_by`/`locked_at` for it, all in a
  single SQL statement so two concurrent callers can never claim the same
  row.

  Returns `{:ok, task}` on success, or `{:error, :no_eligible_task}` if
  nothing is currently claimable.
  """
  @spec get_next_task(String.t()) :: {:ok, Task.t()} | {:error, :no_eligible_task}
  def get_next_task(agent_id) when is_binary(agent_id) and agent_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The eligibility predicate (open, unlocked, all dependencies done) is
    # evaluated inside the same UPDATE statement that performs the claim,
    # via a correlated subquery selecting the single lowest-impl_order
    # candidate row. SQLite executes writers serially, and wrapping this in
    # an explicit transaction ensures the SELECT-then-UPDATE the query
    # planner performs internally can't interleave with another writer —
    # so two concurrent callers can never both claim the same row.
    query = """
    UPDATE tasks
    SET locked_by = ?1, locked_at = ?2, updated_at = ?2
    WHERE id = (
      SELECT t.id FROM tasks t
      WHERE t.status = 'open'
        AND t.locked_by IS NULL
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
    RETURNING id, title, description, acceptance_criteria, depends_on,
      stage, status, locked_by, locked_at, inserted_at, updated_at
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

  # The column order returned by the hand-written RETURNING clause above —
  # kept explicit (rather than trusting driver-reported column metadata,
  # which exqlite doesn't populate for UPDATE ... RETURNING) so the
  # positional row can be zipped back into a column-name => value map and
  # run through the schema's Ecto.Type loaders (decoding the JSON text
  # columns).
  @returning_columns ~w(id title description acceptance_criteria depends_on
    stage status locked_by locked_at inserted_at updated_at)

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
        else
          {:error, :locked_by_other}
        end
    end
  end
end
