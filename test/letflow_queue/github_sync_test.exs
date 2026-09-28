defmodule LetflowQueue.GithubSyncTest do
  @moduledoc """
  Covers the two-way GitHub Issues sync behavior added to
  `LetflowQueue.Tasks`: `register_task/1` creating an issue,
  `get_next_task/1` importing open issues, and `release_lock/2` closing an
  issue on a "done" transition — all against `LetflowQueue.GitHub.FakeClient`
  (configured as the `:github_client` in `config/test.exs`), so none of this
  makes a real network call.
  """

  use LetflowQueue.DataCase, async: false

  alias LetflowQueue.GitHub.FakeClient
  alias LetflowQueue.Tasks

  @valid_attrs %{
    "title" => "Do the thing",
    "description" => "A thing that needs doing",
    "acceptance_criteria" => ["criterion one", "criterion two"],
    "task_type" => "requirement"
  }

  setup do
    # GitHub sync is a no-op unless both are configured — set them for
    # every test in this module so the fake client is actually reached.
    # (Mirrors how config/runtime.exs populates these from GITHUB_TOKEN /
    # GITHUB_REPO at boot; tests set the resulting application config
    # directly rather than environment variables.)
    Application.put_env(:letflow_queue, :github_token, "test-token")
    Application.put_env(:letflow_queue, :github_repo, "tvolodi/letflow")
    FakeClient.reset()

    on_exit(fn ->
      Application.delete_env(:letflow_queue, :github_token)
      Application.delete_env(:letflow_queue, :github_repo)
    end)

    :ok
  end

  describe "register_task/1 GitHub issue creation" do
    test "calls the GitHub client to create an issue and stores the returned issue number" do
      FakeClient.set_create_issue_result({:ok, 4242})

      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert task.github_issue_number == 4242
      assert [{"tvolodi/letflow", "Do the thing", body}] = FakeClient.calls(:create_issue)
      assert body =~ "A thing that needs doing"
      assert body =~ "criterion one"
      assert body =~ "criterion two"
    end

    test "still succeeds and creates the task locally when the GitHub client errors" do
      FakeClient.set_create_issue_result({:error, :rate_limited})

      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert task.id
      assert task.title == "Do the thing"
      assert task.github_issue_number == nil
    end

    test "still succeeds when GitHub isn't configured at all (env vars unset)" do
      Application.delete_env(:letflow_queue, :github_token)
      Application.delete_env(:letflow_queue, :github_repo)

      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert task.github_issue_number == nil
      # not_configured short-circuits before ever reaching the client
      assert FakeClient.calls(:create_issue) == []
    end
  end

  describe "register_task/1 adopting a caller-filed GitHub issue" do
    @issue_attrs %{
      "title" => "Something broke",
      "description" => "and here is the diagnosis",
      "acceptance_criteria" => ["See linked GitHub issue for full description"],
      "task_type" => "issue"
    }

    test "adopts a supplied github_issue_number and creates no second issue" do
      FakeClient.set_create_issue_result({:ok, 4242})

      assert {:ok, task} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 354))

      assert task.github_issue_number == 354
      # The whole point: no mirror issue was filed alongside the caller's own.
      assert FakeClient.calls(:create_issue) == []
    end

    test "closing on done closes the ADOPTED issue, not a service-created mirror" do
      # This is the bug the adopt path fixes. Previously the task row pointed
      # at the service's mirror, so release_lock closed the mirror and left
      # the caller's real issue -- the one carrying the diagnosis -- open.
      FakeClient.set_create_issue_result({:ok, 355})
      FakeClient.set_close_issue_result({:ok, :closed})

      assert {:ok, task} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 354))

      assert {:ok, _} = Tasks.release_lock(task.id, agent_id: "agent-1", status: "done")

      assert [{"tvolodi/letflow", 354}] = FakeClient.calls(:close_issue)
    end

    test "still creates an issue when no number is supplied" do
      FakeClient.set_create_issue_result({:ok, 4242})

      assert {:ok, task} = Tasks.register_task(@issue_attrs)

      assert task.github_issue_number == 4242
      assert [{"tvolodi/letflow", _title, _body}] = FakeClient.calls(:create_issue)
    end

    test "the created issue's title carries the authoritative issue ref" do
      # A human scanning the GitHub issue list sees the same id as the local
      # record, without anyone having had to guess it.
      FakeClient.set_create_issue_result({:ok, 4242})

      assert {:ok, task} = Tasks.register_task(@issue_attrs)

      ref = LetflowQueue.Tasks.Task.issue_ref(task)
      assert [{"tvolodi/letflow", title, _body}] = FakeClient.calls(:create_issue)
      assert title == ref <> ": Something broke"
    end

    test "rejects a number already linked to another task rather than stealing the link" do
      assert {:ok, _first} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 354))

      assert {:error, changeset} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 354))

      assert %{github_issue_number: _} = errors_on(changeset)
    end
  end

  describe "get_next_task/1 GitHub issue import" do
    test "imports an open GitHub issue not yet tracked as a new, claimable local task" do
      FakeClient.set_list_open_issues_result(
        {:ok,
         [
           %{number: 777, title: "Fix the widget", body: "Full issue body text, verbatim."}
         ]}
      )

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")

      assert claimed.title == "Fix the widget"
      assert claimed.body == "Full issue body text, verbatim."
      assert claimed.github_issue_number == 777
      assert claimed.acceptance_criteria == ["See linked GitHub issue for full description"]
      assert claimed.depends_on == []
      assert claimed.stage == nil
      assert claimed.task_type == "issue"
      assert claimed.locked_by == "agent-1"
    end

    test "does not re-import an issue whose number is already present on an existing task" do
      FakeClient.set_list_open_issues_result(
        {:ok, [%{number: 555, title: "Already tracked", body: "body"}]}
      )

      assert {:ok, first_claim} = Tasks.get_next_task("agent-1")
      assert first_claim.github_issue_number == 555

      # release so it's eligible again, then call get_next_task a second
      # time with the SAME fake issue list — must not create a duplicate.
      assert {:ok, _} = Tasks.release_lock(first_claim.id, agent_id: "agent-1")

      assert {:ok, second_claim} = Tasks.get_next_task("agent-2")

      assert second_claim.id == first_claim.id
      assert Tasks.get_next_task("agent-3") == {:error, :no_eligible_task}
    end

    test "still works exactly as before when the GitHub client errors (import skipped)" do
      FakeClient.set_list_open_issues_result({:error, :unreachable})

      assert {:ok, existing} = Tasks.register_task(@valid_attrs)

      # the register_task call above already exercised create_issue against
      # the fake; reset call history but keep the list_open_issues failure
      # configured for the get_next_task call under test.
      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == existing.id
    end

    test "does not affect the atomic claim query when GitHub isn't configured" do
      Application.delete_env(:letflow_queue, :github_token)
      Application.delete_env(:letflow_queue, :github_repo)

      assert {:ok, existing} = Tasks.register_task(@valid_attrs)
      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == existing.id
    end
  end

  describe "get_next_task/1 stale-closed-issue reconciliation (ISS-0285)" do
    # Regression coverage for tvolodi/letflow ISS-0285: a task whose linked
    # GitHub issue was closed by some means OTHER than this service's own
    # release_lock/2 (e.g. the underlying defect was fixed and the Letflow
    # side's docs/issues/*.yaml record flipped to resolved, but the queue
    # task itself was never released) must stop being returned as claimable.
    # import_open_github_issues/0 only ever *added* new tasks for
    # not-yet-tracked issue numbers; it never looked at what happened to a
    # number it already tracks. A task's local `status` could therefore
    # drift out of sync with reality indefinitely, and get_next_task would
    # hand the exact same already-resolved task back out forever.
    @issue_attrs %{
      "title" => "Something broke",
      "description" => "and here is the diagnosis",
      "acceptance_criteria" => ["See linked GitHub issue for full description"],
      "task_type" => "issue"
    }

    test "a tracked open task whose GitHub issue is no longer open is not returned, and is marked done" do
      # Task 500 is tracked locally (adopted github_issue_number, never
      # released) but its GitHub issue is no longer among the repo's open
      # issues -- i.e. it was closed by some path this service didn't drive.
      assert {:ok, task} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 500))

      assert task.status == "open"

      FakeClient.set_list_open_issues_result({:ok, []})

      assert Tasks.get_next_task("agent-1") == {:error, :no_eligible_task}

      reloaded = LetflowQueue.Repo.get!(LetflowQueue.Tasks.Task, task.id)
      assert reloaded.status == "done"
      assert reloaded.locked_by == nil
    end

    test "a tracked open task whose GitHub issue is still open is unaffected" do
      assert {:ok, task} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 501))

      FakeClient.set_list_open_issues_result(
        {:ok, [%{number: 501, title: "Something broke", body: "still broken"}]}
      )

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == task.id
      assert claimed.status == "open"
      assert claimed.locked_by == "agent-1"
    end

    test "a task already locked by an active worker is left alone even if the issue closed underneath it" do
      assert {:ok, task} =
               Tasks.register_task(Map.put(@issue_attrs, "github_issue_number", 502))

      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      FakeClient.set_list_open_issues_result({:ok, []})

      # Nothing else eligible, and the locked task must not be silently
      # flipped to "done" out from under whoever is holding it.
      assert Tasks.get_next_task("agent-2") == {:error, :no_eligible_task}

      reloaded = LetflowQueue.Repo.get!(LetflowQueue.Tasks.Task, task.id)
      assert reloaded.status == "open"
      assert reloaded.locked_by == "agent-1"
    end
  end

  describe "release_lock/2 GitHub issue closing" do
    test "calls the GitHub client to close the issue when status: done and github_issue_number is set" do
      FakeClient.set_create_issue_result({:ok, 999})
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "done")

      assert released.status == "done"
      assert FakeClient.calls(:close_issue) == [{"tvolodi/letflow", 999}]
    end

    test "does not call the GitHub client when github_issue_number is nil" do
      FakeClient.set_create_issue_result({:error, :down})
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert task.github_issue_number == nil
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "done")

      assert released.status == "done"
      assert FakeClient.calls(:close_issue) == []
    end

    test "does not call the GitHub client for a non-done status transition" do
      FakeClient.set_create_issue_result({:ok, 111})
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "blocked")

      assert released.status == "blocked"
      assert FakeClient.calls(:close_issue) == []
    end

    test "release still succeeds locally when closing the GitHub issue fails" do
      FakeClient.set_create_issue_result({:ok, 222})
      FakeClient.set_close_issue_result({:error, :forbidden})

      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "done")

      assert released.status == "done"
      assert released.locked_by == nil
    end
  end
end
