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

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, LetflowQueue.Tasks.JSONList
    field :depends_on, LetflowQueue.Tasks.JSONIntList, default: []
    field :stage, :string
    field :status, :string, default: "open"
    field :locked_by, :string
    field :locked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new task via register_task/1."
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :acceptance_criteria, :depends_on, :stage])
    |> validate_required([:title, :description, :acceptance_criteria])
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

  @doc false
  def statuses, do: @statuses

  @doc """
  Returns the task as a plain map suitable for JSON encoding, with
  `impl_order` exposed alongside `id` (they are always equal).
  """
  def to_json_map(%__MODULE__{} = task) do
    %{
      id: task.id,
      impl_order: task.id,
      title: task.title,
      description: task.description,
      acceptance_criteria: task.acceptance_criteria,
      depends_on: task.depends_on,
      stage: task.stage,
      status: task.status,
      locked_by: task.locked_by,
      locked_at: task.locked_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end
end
