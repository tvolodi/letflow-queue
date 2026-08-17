defmodule LetflowQueue.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :label, :string, null: false
      add :key_hash, :string, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # key_hash lookup is the entire hot path for every authenticated
    # request (LetflowQueueWeb.AuthPlug), and must also be unique -- two
    # keys hashing to the same value would be a collision, not a valid
    # state.
    create unique_index(:api_keys, [:key_hash])
  end
end
