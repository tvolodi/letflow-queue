defmodule LetflowQueue.Tasks.Task do
  @moduledoc """
  A single unit of work in the shared queue.

  `id` is the task's auto-incrementing primary key. It also serves as the
  task's `impl_order` (implementation/queue order) — the two are the same
  integer, but `impl_order` is exposed explicitly wherever a task is
  serialized so callers don't have to know that "id" doubles as the
  ordering key.

  `acceptance_criteria` and `depends_on` are stored as JSON-encoded text
  columns and decoded on read via `Ecto.Type` casts defined below.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open done blocked)
  @task_types ~w(requirement issue)

  # Matches a leading "ISS-0123:" token (any digit count, any case, tolerant
  # of surrounding whitespace) so a caller-supplied one can be stripped and
  # replaced by the authoritative ref. See `canonical_title/1`.
  @iss_prefix ~r/\A\s*ISS-\d+\s*:\s*/i

  # Width of the zero-padded numeric part of an issue ref. Four digits
  # matches the ISS-NNNN convention Letflow's docs/issues/ directory already
  # uses. Ids past 9999 simply render wider; nothing breaks.
  @issue_ref_width 4

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, LetflowQueue.Tasks.JSONList
    field :depends_on, LetflowQueue.Tasks.JSONIntList, default: []
    field :stage, :string
    field :status, :string, default: "open"
    # "requirement" (planned WF-01 work) or "issue" (incidental, via
    # ISSUE_QUEUE.md, or imported from a GitHub Issue). Drives
    # get_next_task/1's claim priority — see LetflowQueue.Tasks.
    field :task_type, :string
    field :locked_by, :string
    field :locked_at, :utc_datetime
    # Non-nil when this task has a linked GitHub Issue — either created by
    # register_task/1 (best-effort) or imported from GitHub by
    # get_next_task/1. See LetflowQueue.GitHub.
    field :github_issue_number, :integer
    # Full verbatim GitHub issue body. Only populated for tasks imported
    # from GitHub; register_task/1-created tasks leave this nil (they
    # already have `description`).
    field :body, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new task via register_task/1.

  `task_type` is required — the caller (always ORCH) must state whether
  this is a planned requirement or an incidental issue; get_next_task/1
  has no reliable way to infer it after the fact.
  """
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :acceptance_criteria,
      :depends_on,
      :stage,
      :task_type,
      # Optional. When the caller has ALREADY filed the GitHub issue itself,
      # it passes the number here and register_task/1 adopts it instead of
      # creating a second one. Omitting it keeps the original behaviour (the
      # service files the issue). See LetflowQueue.Tasks.register_task/1.
      :github_issue_number
    ])
    |> validate_required([:title, :description, :acceptance_criteria, :task_type])
    |> validate_inclusion(:task_type, @task_types)
    |> unique_constraint(:github_issue_number)
    |> validate_length(:acceptance_criteria, min: 1)
    |> validate_change(:acceptance_criteria, fn :acceptance_criteria, list ->
      if is_list(list) and Enum.all?(list, &is_binary/1) do
        []
      else
        [acceptance_criteria: "must be a list of strings"]
      end
    end)
    |> validate_change(:depends_on, fn :depends_on, list ->
      if is_list(list) and Enum.all?(list, &is_integer/1) do
        []
      else
        [depends_on: "must be a list of integers"]
      end
    end)
    |> put_default_depends_on()
  end

  defp put_default_depends_on(changeset) do
    case get_field(changeset, :depends_on) do
      nil -> put_change(changeset, :depends_on, [])
      _ -> changeset
    end
  end

  @doc """
  Changeset for importing a task from an open GitHub Issue
  (`get_next_task/1`'s best-effort import step). `acceptance_criteria` is a
  fixed placeholder (a raw issue body doesn't map to a criteria list) and
  `depends_on` is always empty (GitHub-originated tasks have no way to
  express queue-native dependencies). `description` is a required NOT NULL
  column at the DB level but isn't meaningful for a GitHub-imported task
  (the verbatim issue text lives in `body` instead), so it's set to an
  empty string here rather than left unset. `task_type` is always
  `"issue"` — a raw GitHub Issue is by definition incidental, never a
  planned requirement (those always come through register_task/1 with an
  explicit `task_type`).
  """
  def github_import_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :body, :github_issue_number])
    |> validate_required([:title, :github_issue_number])
    |> put_change(:description, "")
    |> put_change(:acceptance_criteria, ["See linked GitHub issue for full description"])
    |> put_change(:depends_on, [])
    |> put_change(:stage, nil)
    |> put_change(:task_type, "issue")
    |> unique_constraint(:github_issue_number)
  end

  @doc "Changeset for attaching a GitHub issue number to an existing task."
  def github_issue_changeset(task, github_issue_number) do
    change(task, github_issue_number: github_issue_number)
  end

  @doc """
  The canonical issue reference for an issue-type task — `"ISS-"` followed
  by the task's zero-padded `id`, e.g. task 186 => `"ISS-0186"`. Returns
  `nil` for `task_type: "requirement"` (requirements are referred to by
  `REQ-NNN` in Letflow's own docs and are not issues).

  **Why this is derived from `id` rather than allocated separately.** The
  number has to be unique across every host working the project at once,
  and `id` already is: it's an autoincrement primary key, so the database
  allocates it atomically and no two callers can ever receive the same one.
  Deriving the ref from it inherits that guarantee for free — there is no
  second sequence to keep consistent, no read-then-write window, and
  nothing to retry on conflict.

  The alternative this replaces was for each agent to scan a directory of
  existing `ISS-NNNN.yaml` files and take the highest plus one. That is a
  read-then-write race with no lock between the halves, and it collided
  **eight** separate times across concurrent Letflow sessions — including
  once where the losing side's file was silently overwritten with a live
  GitHub issue still pointing at it, and once where a run scanned every
  remote branch first (exactly as its own anti-patterns doc prescribed),
  still collided, because the colliding numbers did not exist on any branch
  at the moment it looked. A scan cannot reserve a number; only an
  allocator can.

  Refs are consequently **not contiguous** — ids are shared with
  requirement-type tasks, and Letflow's pre-existing hand-numbered issues
  occupy a lower range. That is deliberate. Contiguity was never a property
  worth having (the collisions and their renumbering had already broken it)
  and it is precisely what cannot be delivered without a guess.
  """
  @spec issue_ref(t_or_struct :: %__MODULE__{}) :: String.t() | nil
  def issue_ref(%__MODULE__{task_type: "issue", id: id}) when is_integer(id) do
    "ISS-" <> String.pad_leading(Integer.to_string(id), @issue_ref_width, "0")
  end

  def issue_ref(%__MODULE__{}), do: nil

  @doc """
  The task's title with its authoritative `issue_ref/1` as a prefix.

  For an issue-type task, any leading caller-supplied `ISS-NNNN:` token is
  **stripped and replaced** with the ref derived from the id. This is the
  enforcement half of `issue_ref/1`: a caller that guesses a number and puts
  it in the title would otherwise reintroduce the collision the derived ref
  exists to prevent, and the guess would then be what a human sees in the
  GitHub issue list. Only a leading token is touched — an `ISS-` reference
  appearing anywhere else in the title is left alone, since it is a genuine
  cross-reference to some other issue.

  Requirement-type titles are returned unchanged.
  """
  @spec canonical_title(%__MODULE__{}) :: String.t()
  def canonical_title(%__MODULE__{title: title} = task) do
    case issue_ref(task) do
      nil -> title
      ref -> ref <> ": " <> String.replace(title, @iss_prefix, "")
    end
  end

  @doc false
  def statuses, do: @statuses

  @doc false
  def task_types, do: @task_types

  @doc """
  Returns the task as a plain map suitable for JSON encoding, with
  `impl_order` exposed alongside `id` (they are always equal).
  """
  def to_json_map(%__MODULE__{} = task) do
    %{
      id: task.id,
      impl_order: task.id,
      # nil for requirement-type tasks. For issue-type tasks this is the
      # canonical, atomically-allocated issue id the caller should name its
      # local record with — see issue_ref/1 for why it is derived from id.
      issue_ref: issue_ref(task),
      title: task.title,
      description: task.description,
      acceptance_criteria: task.acceptance_criteria,
      depends_on: task.depends_on,
      stage: task.stage,
      task_type: task.task_type,
      status: task.status,
      locked_by: task.locked_by,
      locked_at: task.locked_at,
      github_issue_number: task.github_issue_number,
      body: task.body,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end
end
