defmodule LetflowQueueWeb.TaskController do
  use LetflowQueueWeb, :controller

  alias LetflowQueue.Tasks
  alias LetflowQueue.Tasks.Task

  # POST /tasks
  def register(conn, params) do
    case Tasks.register_task(params) do
      {:ok, task} ->
        conn
        |> put_status(:created)
        |> json(%{data: Task.to_json_map(task), error: nil})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: nil, error: changeset_error_message(changeset)})
    end
  end

  # GET /tasks/next?agent_id=<id>
  def next(conn, %{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "" do
    case Tasks.get_next_task(agent_id) do
      {:ok, task} ->
        json(conn, %{data: Task.to_json_map(task), error: nil})

      {:error, :no_eligible_task} ->
        conn
        |> put_status(:not_found)
        |> json(%{data: nil, error: "no_eligible_task"})
    end
  end

  def next(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{data: nil, error: "agent_id is required"})
  end

  # POST /tasks/:id/lock  body: {"agent_id": "..."}
  def lock(conn, %{"id" => id, "agent_id" => agent_id})
      when is_binary(agent_id) and agent_id != "" do
    case parse_id(id) do
      {:ok, id} ->
        case Tasks.set_lock(id, agent_id) do
          {:ok, task} ->
            json(conn, %{data: Task.to_json_map(task), error: nil})

          {:error, :locked_by_other} ->
            conn
            |> put_status(:conflict)
            |> json(%{data: nil, error: "task is locked by a different agent"})

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{data: nil, error: "task not found"})
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{data: nil, error: "invalid task id"})
    end
  end

  def lock(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{data: nil, error: "agent_id is required"})
  end

  # POST /tasks/:id/release  body: {"agent_id": "...", "status": "done", "force": false}
  def release(conn, %{"id" => id} = params) do
    with {:ok, id} <- parse_id(id) do
      opts = [
        agent_id: Map.get(params, "agent_id"),
        status: Map.get(params, "status"),
        force: truthy?(Map.get(params, "force", false))
      ]

      case Tasks.release_lock(id, opts) do
        {:ok, task} ->
          json(conn, %{data: Task.to_json_map(task), error: nil})

        {:error, :locked_by_other} ->
          conn
          |> put_status(:conflict)
          |> json(%{data: nil, error: "task is locked by a different agent"})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{data: nil, error: "task not found"})

        {:error, :agent_id_required} ->
          conn
          |> put_status(:bad_request)
          |> json(%{data: nil, error: "agent_id is required unless force is true"})

        {:error, :invalid_status} ->
          conn
          |> put_status(:bad_request)
          |> json(%{data: nil, error: "status must be one of: open, done, blocked"})
      end
    else
      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{data: nil, error: "invalid task id"})
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp changeset_error_message(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    errors
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end
end
