defmodule LetflowQueue.ApiKeys do
  @moduledoc """
  Per-client API key management -- the successor to the single shared
  `QUEUE_AUTH_TOKEN` for day-to-day client auth.

  `QUEUE_AUTH_TOKEN` remains valid (see `LetflowQueueWeb.AuthPlug`) as the
  bootstrap credential: it's the one already-valid credential a brand-new
  client uses to mint its own key via `create_key/1` (over `POST
  /api_keys`), after which that client authenticates with its own key and
  never needs `QUEUE_AUTH_TOKEN` -- or server/SSH access to retrieve it --
  again. An already-active key can mint further keys the same way, so the
  legacy token only has to be used once per deployment, not once per
  client.
  """

  import Ecto.Query, warn: false

  alias LetflowQueue.ApiKeys.ApiKey
  alias LetflowQueue.Repo

  @type api_key :: ApiKey.t()

  @token_bytes 32
  @token_prefix "lfq_"

  @doc """
  Generates a new random token, stores only its SHA-256 hash, and
  returns `{:ok, {token, api_key}}` -- the plaintext token alongside the
  created record. The plaintext token is never persisted anywhere; this
  is the only place it is ever available. Callers must hand it to the
  client immediately and have the client store it locally -- it cannot
  be retrieved again, only revoked and replaced.
  """
  @spec create_key(String.t()) :: {:ok, {String.t(), ApiKey.t()}} | {:error, Ecto.Changeset.t()}
  def create_key(label) when is_binary(label) do
    token = generate_token()

    %ApiKey{}
    |> ApiKey.create_changeset(%{label: label, key_hash: hash(token)})
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {:ok, {token, api_key}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Whether `token` matches an active (non-revoked) key. Always a hash
  lookup -- the raw token is never stored, so there is no other possible
  check.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(token) when is_binary(token) and token != "" do
    Repo.exists?(from k in ApiKey, where: k.key_hash == ^hash(token) and is_nil(k.revoked_at))
  end

  def valid?(_), do: false

  @doc """
  Revokes a key by id. Idempotent: revoking an already-revoked key
  succeeds without changing its original `revoked_at`, rather than
  erroring.
  """
  @spec revoke(integer()) :: {:ok, ApiKey.t()} | {:error, :not_found}
  def revoke(id) do
    case Repo.get(ApiKey, id) do
      nil ->
        {:error, :not_found}

      %ApiKey{revoked_at: nil} = api_key ->
        api_key
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      %ApiKey{} = api_key ->
        {:ok, api_key}
    end
  end

  defp generate_token do
    @token_prefix <> (@token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp hash(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end
end
