defmodule LetflowQueue.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :description, :text, null: false
      add :acceptance_criteria, :text, null: false
      add :depends_on, :text, null: false, default: "[]"
      add :stage, :string
      add :status, :string, null: false, default: "open"
      add :locked_by, :string
      add :locked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Supports the get_next_task claim query: lowest impl_order (id) among
    # open, unlocked tasks. status/locked_by are the selective filters;
    # id ordering is a range scan on the primary key within the filtered set.
    create index(:tasks, [:status, :locked_by, :id])
  end
end
