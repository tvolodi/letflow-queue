defmodule LetflowQueueWeb.ApiKeyControllerTest do
  use LetflowQueueWeb.ConnCase, async: false

  alias LetflowQueue.ApiKeys

  @legacy_token Application.compile_env(:letflow_queue, :auth_token)

  defp authed(conn, token \\ @legacy_token) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api_keys (create)" do
    test "mints a new key when authenticated with the legacy shared token", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api_keys", %{"label" => "test-host"})

      assert %{"data" => data, "error" => nil} = json_response(conn, 201)
      assert data["id"]
      assert data["label"] == "test-host"
      assert String.starts_with?(data["token"], "lfq_")
      assert data["revoked_at"] == nil
    end

    test "mints a new key when authenticated with another active api key", %{conn: conn} do
      {:ok, {bootstrap_token, _}} = ApiKeys.create_key("bootstrap-host")

      conn = conn |> authed(bootstrap_token) |> post(~p"/api_keys", %{"label" => "second-host"})

      assert %{"data" => data, "error" => nil} = json_response(conn, 201)
      assert data["label"] == "second-host"
    end

    test "requires auth", %{conn: conn} do
      conn = post(conn, ~p"/api_keys", %{"label" => "test-host"})
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects a revoked key used as the bootstrap credential", %{conn: conn} do
      {:ok, {token, api_key}} = ApiKeys.create_key("dead-host")
      assert {:ok, _} = ApiKeys.revoke(api_key.id)

      conn = conn |> authed(token) |> post(~p"/api_keys", %{"label" => "second-host"})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "requires a label", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api_keys", %{})
      assert json_response(conn, 400)["error"] =~ "label"
    end
  end

  describe "POST /api_keys/:id/revoke" do
    test "revokes a key", %{conn: conn} do
      {:ok, {_token, api_key}} = ApiKeys.create_key("test-host")

      conn = conn |> authed() |> post(~p"/api_keys/#{api_key.id}/revoke")

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["revoked_at"] != nil
    end

    test "404s for a nonexistent id", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api_keys/999999/revoke")
      assert json_response(conn, 404)
    end

    test "requires auth", %{conn: conn} do
      {:ok, {_token, api_key}} = ApiKeys.create_key("test-host")
      conn = post(conn, ~p"/api_keys/#{api_key.id}/revoke")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  describe "minted keys work end-to-end against the task endpoints" do
    test "a freshly minted key authenticates GET /tasks/next", %{conn: conn} do
      {:ok, {token, _}} = ApiKeys.create_key("test-host")

      conn = conn |> authed(token) |> get(~p"/tasks/next?agent_id=agent-1")

      assert json_response(conn, 404)["error"] == "no_eligible_task"
    end

    test "a revoked key is rejected on task endpoints", %{conn: conn} do
      {:ok, {token, api_key}} = ApiKeys.create_key("test-host")
      assert {:ok, _} = ApiKeys.revoke(api_key.id)

      conn = conn |> authed(token) |> get(~p"/tasks/next?agent_id=agent-1")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
