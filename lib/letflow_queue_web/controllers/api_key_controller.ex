defmodule LetflowQueueWeb.ApiKeyController do
  use LetflowQueueWeb, :controller

  alias LetflowQueue.ApiKeys
  alias LetflowQueue.ApiKeys.ApiKey

  # POST /api_keys  body: {"label": "..."}
  def create(conn, %{"label" => label}) when is_binary(label) and label != "" do
    case ApiKeys.create_key(label) do
      {:ok, {token, api_key}} ->
        conn
        |> put_status(:created)
        |> json(%{data: Map.put(ApiKey.to_json_map(api_key), :token, token), error: nil})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: nil, error: changeset_error_message(changeset)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{data: nil, error: "label is required"})
  end

  # POST /api_keys/:id/revoke
  def revoke(conn, %{"id" => id}) do
    case parse_id(id) do
      {:ok, id} ->
        case ApiKeys.revoke(id) do
          {:ok, api_key} ->
            json(conn, %{data: ApiKey.to_json_map(api_key), error: nil})

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{data: nil, error: "api key not found"})
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{data: nil, error: "invalid api key id"})
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
