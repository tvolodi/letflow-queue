defmodule LetflowQueue.Repo.Migrations.AddGithubSyncFieldsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Non-nil only for tasks that have a corresponding GitHub Issue —
      # either created by register_task/1 (best-effort) or imported from
      # GitHub by get_next_task/1. Used to avoid re-importing the same
      # issue twice and to know which issue to close on release_lock/2.
      add :github_issue_number, :integer

      # Full verbatim GitHub issue body, only populated for tasks imported
      # from GitHub (register_task/1-created tasks already have
      # `description` and leave this nil).
      add :body, :text
    end

    create unique_index(:tasks, [:github_issue_number])
  end
end
