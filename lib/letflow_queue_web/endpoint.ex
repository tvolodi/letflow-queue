defmodule LetflowQueueWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :letflow_queue

  # Pure JSON API — no HTML, no LiveView, no cookies/sessions.

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :letflow_queue
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug LetflowQueueWeb.Router
end
