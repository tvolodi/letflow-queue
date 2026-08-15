defmodule LetflowQueue.GitHub.ReqClient do
  @moduledoc """
  Real `LetflowQueue.GitHub.Client` implementation, backed by `Req` against
  the GitHub REST API (`https://api.github.com`). Auth is a personal
  access token read from application config (`:letflow_queue,
  :github_token`), populated from the `GITHUB_TOKEN` environment variable
  at boot in `config/runtime.exs` — same pattern as `QUEUE_AUTH_TOKEN`
  elsewhere in this app. The "not configured => no-op" degradation is
  handled one level up, in `LetflowQueue.GitHub` — this module is only
  reached when both `GITHUB_TOKEN` and `GITHUB_REPO` are already known to
  be set.
  """

  @behaviour LetflowQueue.GitHub.Client

  @base_url "https://api.github.com"

  @impl true
  def create_issue(repo, title, body) do
    request(:post, "/repos/#{repo}/issues", %{title: title, body: body})
    |> case do
      {:ok, %{status: status, body: %{"number" => number}}} when status in 200..299 ->
        {:ok, number}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:unexpected_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_open_issues(repo) do
    request(:get, "/repos/#{repo}/issues", nil, state: "open", per_page: 100)
    |> case do
      {:ok, %{status: 200, body: issues}} when is_list(issues) ->
        {:ok,
         issues
         # The issues endpoint also returns pull requests; exclude those.
         |> Enum.reject(&Map.has_key?(&1, "pull_request"))
         |> Enum.map(fn issue ->
           %{
             number: issue["number"],
             title: issue["title"],
             body: issue["body"] || ""
           }
         end)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:unexpected_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def close_issue(repo, issue_number) do
    request(:patch, "/repos/#{repo}/issues/#{issue_number}", %{state: "closed"})
    |> case do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, :closed}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:unexpected_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, path, json, params \\ []) do
    token = Application.get_env(:letflow_queue, :github_token)

    opts =
      [
        method: method,
        url: @base_url <> path,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer #{token}"},
          {"x-github-api-version", "2022-11-28"}
        ],
        params: params,
        receive_timeout: 10_000
      ]
      |> then(fn opts -> if json, do: Keyword.put(opts, :json, json), else: opts end)

    Req.request(opts)
  end
end
