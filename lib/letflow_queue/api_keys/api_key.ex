defmodule LetflowQueue.ApiKeys.ApiKey do
  @moduledoc """
  A per-client credential for authenticating to letflow-queue -- the
  successor, for new clients, to the single shared QUEUE_AUTH_TOKEN.

  Only `key_hash` (a SHA-256 hex digest of the raw token) is ever
  persisted. The raw token itself exists only in the HTTP response at
  creation time (see `LetflowQueue.ApiKeys.create_key/1`) and is never
  recoverable from the database afterward -- if it's lost, the only
  remedy is revoking the key and minting a new one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "api_keys" do
    field :label, :string
    field :key_hash, :string
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new key via LetflowQueue.ApiKeys.create_key/1."
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:label, :key_hash])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label, :key_hash])
    |> unique_constraint(:key_hash)
  end

  @doc """
  Returns the key as a plain map suitable for JSON encoding. Never
  includes the raw token or `key_hash` -- the token is only ever present
  in `create_key/1`'s immediate return value, and the hash has no
  legitimate reason to leave the database.
  """
  def to_json_map(%__MODULE__{} = api_key) do
    %{
      id: api_key.id,
      label: api_key.label,
      revoked_at: api_key.revoked_at,
      inserted_at: api_key.inserted_at
    }
  end
end
