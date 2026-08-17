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

  # The task-queue surface: exactly four operations, all bearer-token
  # gated. Nothing else task-related is routed.
  scope "/tasks", LetflowQueueWeb do
    pipe_through [:api, :authenticated]

    post "/", TaskController, :register
    get "/next", TaskController, :next
    post "/:id/lock", TaskController, :lock
    post "/:id/release", TaskController, :release
  end

  # Admin-facing key management -- a separate concern from the four task
  # operations above (see README.md "Client API keys"). Same bearer-auth
  # gate: minting a new key requires already holding a valid credential
  # (the legacy QUEUE_AUTH_TOKEN, or another still-active api key).
  scope "/api_keys", LetflowQueueWeb do
    pipe_through [:api, :authenticated]

    post "/", ApiKeyController, :create
    post "/:id/revoke", ApiKeyController, :revoke
  end
end
