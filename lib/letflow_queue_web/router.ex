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

  # The task-queue surface, all bearer-token gated. Exactly one of these
  # mutates a claim (get_next_task via GET /tasks/next); the rest either
  # write something the caller explicitly asked for (register/lock/
  # release) or, for GET /tasks, write nothing at all — see
  # LetflowQueue.Tasks's moduledoc.
  scope "/tasks", LetflowQueueWeb do
    pipe_through [:api, :authenticated]

    get "/", TaskController, :index
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
