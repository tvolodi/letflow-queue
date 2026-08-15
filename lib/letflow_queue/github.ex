defmodule LetflowQueue.GitHub do
  @moduledoc """
  Best-effort two-way sync surface between the local task queue and GitHub
  Issues on a single configured repo. Every function here degrades to
  `{:error, :not_configured}` (never raises) when `GITHUB_TOKEN` or
  `GITHUB_REPO` is unset — callers in `LetflowQueue.Tasks` treat that
  exactly like any other GitHub failure: log and continue, never block the
  core queue operation.

  The actual HTTP request-building/parsing lives in the configured
  `LetflowQueue.GitHub.Client` implementation (`LetflowQueue.GitHub.ReqClient`
  in dev/prod, a fake in tests), selected via
  `Application.get_env(:letflow_queue, :github_client, ...)` so this module
  — and `Tasks` above it — never needs to know it's a fake in tests.
  """

  @doc """
  Creates a GitHub Issue for a newly-registered task.

  Returns `{:ok, issue_number}` on success. Returns `{:error, reason}`
  (never raises) if GitHub sync isn't configured or the API call fails —
  callers must treat this as best-effort and proceed regardless.
  """
  @spec create_issue(String.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def create_issue(title, body) do
    with {:ok, repo} <- configured_repo() do
      client().create_issue(repo, title, body)
    end
  end

  @doc """
  Lists open GitHub Issues on the configured repo.

  Returns `{:ok, [%{number:, title:, body:}]}` on success, `{:error, reason}`
  if GitHub sync isn't configured or the API call fails.
  """
  @spec list_open_issues() ::
          {:ok, [%{number: pos_integer(), title: String.t(), body: String.t()}]}
          | {:error, term()}
  def list_open_issues do
    with {:ok, repo} <- configured_repo() do
      client().list_open_issues(repo)
    end
  end

  @doc """
  Closes a GitHub Issue (used when a task with a linked issue transitions
  to `status: "done"`).

  Returns `{:ok, :closed}` on success, `{:error, reason}` if GitHub sync
  isn't configured or the API call fails.
  """
  @spec close_issue(pos_integer()) :: {:ok, :closed} | {:error, term()}
  def close_issue(issue_number) do
    with {:ok, repo} <- configured_repo() do
      client().close_issue(repo, issue_number)
    end
  end

  defp configured_repo do
    case Application.get_env(:letflow_queue, :github_repo) do
      nil -> {:error, :not_configured}
      "" -> {:error, :not_configured}
      repo -> if token_configured?(), do: {:ok, repo}, else: {:error, :not_configured}
    end
  end

  defp token_configured? do
    case Application.get_env(:letflow_queue, :github_token) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp client do
    Application.get_env(:letflow_queue, :github_client, LetflowQueue.GitHub.ReqClient)
  end
end
