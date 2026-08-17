defmodule LetflowQueue.ApiKeysTest do
  use LetflowQueue.DataCase, async: false

  alias LetflowQueue.ApiKeys
  alias LetflowQueue.ApiKeys.ApiKey
  alias LetflowQueue.Repo

  describe "create_key/1" do
    test "returns a plaintext token and a persisted record" do
      assert {:ok, {token, api_key}} = ApiKeys.create_key("test-client")

      assert String.starts_with?(token, "lfq_")
      assert api_key.id
      assert api_key.label == "test-client"
      assert api_key.revoked_at == nil
    end

    test "never persists the plaintext token" do
      assert {:ok, {token, api_key}} = ApiKeys.create_key("test-client")

      stored = Repo.get!(ApiKey, api_key.id)
      refute stored.key_hash == token
      assert is_binary(stored.key_hash)
    end

    test "each call generates a distinct token" do
      assert {:ok, {token1, _}} = ApiKeys.create_key("client-a")
      assert {:ok, {token2, _}} = ApiKeys.create_key("client-b")

      assert token1 != token2
    end

    test "requires a non-blank label" do
      assert {:error, changeset} = ApiKeys.create_key("")
      assert "can't be blank" in errors_on(changeset).label
    end

    test "rejects a whitespace-only label" do
      assert {:error, changeset} = ApiKeys.create_key("   ")
      assert "can't be blank" in errors_on(changeset).label
    end
  end

  describe "valid?/1" do
    test "true for a freshly minted key" do
      assert {:ok, {token, _}} = ApiKeys.create_key("test-client")
      assert ApiKeys.valid?(token)
    end

    test "false for an unknown token" do
      refute ApiKeys.valid?("lfq_totally-made-up")
    end

    test "false for a revoked key" do
      assert {:ok, {token, api_key}} = ApiKeys.create_key("test-client")
      assert {:ok, _} = ApiKeys.revoke(api_key.id)

      refute ApiKeys.valid?(token)
    end

    test "false for a blank token" do
      refute ApiKeys.valid?("")
    end
  end

  describe "revoke/1" do
    test "sets revoked_at on an active key" do
      assert {:ok, {_token, api_key}} = ApiKeys.create_key("test-client")
      assert {:ok, revoked} = ApiKeys.revoke(api_key.id)

      assert revoked.revoked_at != nil
    end

    test "revoking an already-revoked key is idempotent" do
      assert {:ok, {_token, api_key}} = ApiKeys.create_key("test-client")
      assert {:ok, first} = ApiKeys.revoke(api_key.id)
      assert {:ok, second} = ApiKeys.revoke(api_key.id)

      assert DateTime.compare(first.revoked_at, second.revoked_at) == :eq
    end

    test "returns not_found for a nonexistent id" do
      assert {:error, :not_found} = ApiKeys.revoke(999_999)
    end
  end
end
