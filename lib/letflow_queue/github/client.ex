defmodule LetflowQueue.GitHub.Client do
  @moduledoc """
  Behaviour for the low-level GitHub REST calls `LetflowQueue.GitHub` needs.
  Swappable via `Application.get_env(:letflow_queue, :github_client, ...)` so
  tests can substitute a fake and never make a real network call.
  """

  @doc "Create an issue. Returns `{:ok, issue_number}` or `{:error, reason}`."
  @callback create_issue(repo :: String.t(), title :: String.t(), body :: String.t()) ::
              {:ok, pos_integer()} | {:error, term()}

  @doc """
  List open issues for the repo. Returns
  `{:ok, [%{number: pos_integer(), title: String.t(), body: String.t()}]}`
  or `{:error, reason}`.
  """
  @callback list_open_issues(repo :: String.t()) ::
              {:ok, [%{number: pos_integer(), title: String.t(), body: String.t()}]}
              | {:error, term()}

  @doc "Close an issue. Returns `{:ok, :closed}` or `{:error, reason}`."
  @callback close_issue(repo :: String.t(), issue_number :: pos_integer()) ::
              {:ok, :closed} | {:error, term()}
end
