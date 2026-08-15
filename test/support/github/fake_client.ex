defmodule LetflowQueue.GitHub.FakeClient do
  @moduledoc """
  Test-only `LetflowQueue.GitHub.Client` implementation. No network calls —
  behavior is entirely controlled per-test via the process dictionary, so
  concurrent/async tests using this fake don't interfere with each other's
  configuration.

  Usage in a test:

      setup do
        LetflowQueue.GitHub.FakeClient.set_create_issue_result({:ok, 123})
        LetflowQueue.GitHub.FakeClient.set_list_open_issues_result({:ok, []})
        :ok
      end

  Every call made to the fake is also recorded (see `calls/1`) so tests can
  assert whether e.g. `close_issue/2` was invoked at all.
  """

  @behaviour LetflowQueue.GitHub.Client

  # --- configuration (test setup) ---

  def set_create_issue_result(result), do: put(:create_issue_result, result)
  def set_list_open_issues_result(result), do: put(:list_open_issues_result, result)
  def set_close_issue_result(result), do: put(:close_issue_result, result)

  @doc "Returns the list of argument-tuples this fake was called with for `fun` (e.g. `:close_issue`), oldest first."
  def calls(fun), do: get({:calls, fun}) || []

  # --- LetflowQueue.GitHub.Client callbacks ---

  @impl true
  def create_issue(repo, title, body) do
    record(:create_issue, {repo, title, body})
    get(:create_issue_result) || {:ok, 1}
  end

  @impl true
  def list_open_issues(repo) do
    record(:list_open_issues, {repo})
    get(:list_open_issues_result) || {:ok, []}
  end

  @impl true
  def close_issue(repo, issue_number) do
    record(:close_issue, {repo, issue_number})
    get(:close_issue_result) || {:ok, :closed}
  end

  # --- shared state, backed by a public named ETS table ---
  #
  # A per-process dictionary would not work here: the existing concurrency
  # tests spawn `Task.async` workers that call into `LetflowQueue.Tasks`
  # (and transitively this fake) from processes other than the test
  # process. A public named ETS table is visible to every process
  # regardless of which one created it, so configuration set in test setup
  # (from the test process) is still visible to those worker processes.

  @table __MODULE__

  defp put(key, value) do
    ensure_table()
    :ets.insert(@table, {key, value})
    :ok
  end

  defp get(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp record(fun, args) do
    ensure_table()
    key = {:calls, fun}
    :ets.insert(@table, {key, (get(key) || []) ++ [args]})
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  end

  @doc "Resets all configured results and recorded calls. Call from test setup for isolation."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
