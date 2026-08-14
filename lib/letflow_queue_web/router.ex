defmodule LetflowQueueWeb.Router do
  use LetflowQueueWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug LetflowQueueWeb.AuthPlug
  end

  # No auth required — used by the infra deploy pipeline's health check.
  scope "/", LetflowQueueWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # The entire externally-callable surface: exactly four operations on the
  # task queue, all bearer-token gated. Nothing else is routed.
  scope "/tasks", LetflowQueueWeb do
    pipe_through [:api, :authenticated]

    post "/", TaskController, :register
    get "/next", TaskController, :next
    post "/:id/lock", TaskController, :lock
    post "/:id/release", TaskController, :release
  end
end
