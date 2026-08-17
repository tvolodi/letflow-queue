defmodule LetflowQueue.Repo.Migrations.AddTaskTypeToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :task_type, :string, null: false, default: "issue"
    end

    # Backfill for rows that predate this column. A task with a non-nil
    # `stage` can only have come from register_task/1 called for a planned
    # WF-01 requirement (docs/agents/protocols/TASK_QUEUE.md) -- incidental
    # ISSUE_QUEUE.md-sourced tasks and GitHub-imported tasks never set
    # `stage`. The ADD COLUMN default above already backfilled every row to
    # "issue"; this promotes the ones that are actually requirements.
    execute(
      "UPDATE tasks SET task_type = 'requirement' WHERE stage IS NOT NULL",
      "UPDATE tasks SET task_type = 'issue' WHERE stage IS NOT NULL"
    )

    # Supports get_next_task's two-tier claim query (newest eligible issue,
    # else lowest-impl_order eligible requirement).
    create index(:tasks, [:task_type, :status, :locked_by, :id])
  end
end
