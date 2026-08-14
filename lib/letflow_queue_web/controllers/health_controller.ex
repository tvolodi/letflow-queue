defmodule LetflowQueueWeb.HealthController do
  use LetflowQueueWeb, :controller

  # No auth required (see router) — for the infra deploy pipeline's health
  # check. Uses the plain `{"status":"ok"}` shape rather than the
  # `{"data":..., "error":...}` envelope used everywhere else, since this
  # endpoint is consumed by generic infra tooling (e.g. Docker
  # HEALTHCHECK / compose) that expects a minimal, stable body — see
  # README for the explicit deviation note.
  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
