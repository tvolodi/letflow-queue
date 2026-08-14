defmodule LetflowQueueWeb.AuthPlug do
  @moduledoc """
  Checks `Authorization: Bearer <token>` against the single shared token
  configured via the `QUEUE_AUTH_TOKEN` environment variable (read at boot
  in `config/runtime.exs`). Applied to every route except `GET /health`.

  Returns 401 with the standard response envelope if the header is
  missing or the token doesn't match.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:letflow_queue, :auth_token)

    with true <- is_binary(expected) and expected != "",
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{data: nil, error: "unauthorized"})
    |> halt()
  end
end
