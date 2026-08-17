defmodule LetflowQueueWeb.AuthPlug do
  @moduledoc """
  Checks `Authorization: Bearer <token>` against either of two valid
  credential forms. Applied to every route except `GET /health`.

    1. The legacy single shared token (`QUEUE_AUTH_TOKEN`, read at boot
       in `config/runtime.exs`) -- kept valid so already-deployed clients
       aren't broken by the introduction of per-client keys, and so it
       can bootstrap a brand-new client's own key via `POST /api_keys`.
    2. A per-client API key minted via `POST /api_keys`
       (`LetflowQueue.ApiKeys`) -- the intended path for every client
       going forward: minted once, stored on that client, never
       requiring server/SSH access again to use the service.

  Returns 401 with the standard response envelope if the header is
  missing or neither check passes.
  """

  import Plug.Conn

  alias LetflowQueue.ApiKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- authorized?(token) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp authorized?(token) do
    legacy_token_match?(token) or ApiKeys.valid?(token)
  end

  defp legacy_token_match?(token) do
    expected = Application.get_env(:letflow_queue, :auth_token)
    is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(token, expected)
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{data: nil, error: "unauthorized"})
    |> halt()
  end
end
