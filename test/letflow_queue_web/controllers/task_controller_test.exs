defmodule LetflowQueueWeb.TaskControllerTest do
  use LetflowQueueWeb.ConnCase, async: false

  alias LetflowQueue.Tasks

  @token Application.compile_env(:letflow_queue, :auth_token)

  @valid_attrs %{
    "title" => "Do the thing",
    "description" => "A thing that needs doing",
    "acceptance_criteria" => ["criterion one"]
  }

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{@token}")
  end

  describe "auth" do
    test "requests without a bearer token are rejected with 401", %{conn: conn} do
      conn = post(conn, ~p"/tasks", @valid_attrs)
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "requests with the wrong bearer token are rejected with 401", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")
        |> post(~p"/tasks", @valid_attrs)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "GET /health requires no auth", %{conn: conn} do
      conn = get(conn, ~p"/health")
      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  describe "POST /tasks (register_task)" do
    test "creates a task and returns the envelope with impl_order", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/tasks", @valid_attrs)

      assert %{"data" => data, "error" => nil} = json_response(conn, 201)
      assert data["id"]
      assert data["impl_order"] == data["id"]
      assert data["status"] == "open"
      assert data["title"] == "Do the thing"
      assert data["acceptance_criteria"] == ["criterion one"]
      assert data["depends_on"] == []
    end

    test "returns 422 with error message when required fields are missing", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/tasks", %{})

      assert %{"data" => nil, "error" => error} = json_response(conn, 422)
      assert error =~ "title"
    end
  end

  describe "GET /tasks/next (get_next_task)" do
    test "returns 404 no_eligible_task when nothing is claimable", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/tasks/next?agent_id=agent-1")

      assert %{"data" => nil, "error" => "no_eligible_task"} = json_response(conn, 404)
    end

    test "claims and returns the next task", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)

      conn = conn |> authed() |> get(~p"/tasks/next?agent_id=agent-1")

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["id"] == task.id
      assert data["locked_by"] == "agent-1"
    end

    test "requires agent_id", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/tasks/next")
      assert json_response(conn, 400)["error"] =~ "agent_id"
    end
  end

  describe "POST /tasks/:id/lock (set_lock)" do
    test "locks a task", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)

      conn =
        conn |> authed() |> post(~p"/tasks/#{task.id}/lock", %{"agent_id" => "agent-1"})

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["locked_by"] == "agent-1"
    end

    test "409s when locked by a different agent", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)
      {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      conn =
        conn |> authed() |> post(~p"/tasks/#{task.id}/lock", %{"agent_id" => "agent-2"})

      assert %{"data" => nil, "error" => _} = json_response(conn, 409)
    end

    test "404s for a nonexistent task", %{conn: conn} do
      conn =
        conn |> authed() |> post(~p"/tasks/999999/lock", %{"agent_id" => "agent-1"})

      assert json_response(conn, 404)
    end
  end

  describe "POST /tasks/:id/release (release_lock)" do
    test "releases a lock held by the caller", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)
      {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      conn =
        conn
        |> authed()
        |> post(~p"/tasks/#{task.id}/release", %{"agent_id" => "agent-1"})

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["locked_by"] == nil
      assert data["status"] == "open"
    end

    test "releasing with status transitions the task", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)
      {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      conn =
        conn
        |> authed()
        |> post(~p"/tasks/#{task.id}/release", %{"agent_id" => "agent-1", "status" => "done"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "done"
    end

    test "409s releasing a lock held by a different agent without force", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)
      {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      conn =
        conn
        |> authed()
        |> post(~p"/tasks/#{task.id}/release", %{"agent_id" => "agent-2"})

      assert json_response(conn, 409)
    end

    test "force: true releases regardless of holder (ORCH override)", %{conn: conn} do
      {:ok, task} = Tasks.register_task(@valid_attrs)
      {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      conn =
        conn
        |> authed()
        |> post(~p"/tasks/#{task.id}/release", %{"force" => true})

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["locked_by"] == nil
    end
  end
end
