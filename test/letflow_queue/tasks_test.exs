defmodule LetflowQueue.TasksTest do
  use LetflowQueue.DataCase, async: false

  alias LetflowQueue.Repo
  alias LetflowQueue.Tasks
  # Aliased under a distinct name rather than `Task` so Elixir's own `Task`
  # module stays reachable from this file.
  alias LetflowQueue.Tasks.Task, as: TaskSchema

  @valid_attrs %{
    "title" => "Do the thing",
    "description" => "A thing that needs doing",
    "acceptance_criteria" => ["criterion one", "criterion two"],
    "task_type" => "requirement"
  }

  @issue_attrs Map.put(@valid_attrs, "task_type", "issue")

  describe "register_task/1" do
    test "creates a task with impl_order equal to id, status open" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert task.id
      assert task.title == "Do the thing"
      assert task.description == "A thing that needs doing"
      assert task.acceptance_criteria == ["criterion one", "criterion two"]
      assert task.depends_on == []
      assert task.status == "open"
      assert task.locked_by == nil
      assert task.stage == nil
      assert task.task_type == "requirement"
    end

    test "impl_order mirrors id in the JSON-facing map" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      json = LetflowQueue.Tasks.Task.to_json_map(task)
      assert json.impl_order == task.id
      assert json.id == task.id
    end

    test "assigns auto-incrementing impl_order across multiple tasks" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, t2} = Tasks.register_task(@valid_attrs)
      assert t2.id > t1.id
    end

    test "accepts optional depends_on and stage" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)

      assert {:ok, t2} =
               Tasks.register_task(
                 Map.merge(@valid_attrs, %{
                   "depends_on" => [t1.id],
                   "stage" => "S2"
                 })
               )

      assert t2.depends_on == [t1.id]
      assert t2.stage == "S2"
    end

    test "requires title, description, acceptance_criteria, and task_type" do
      assert {:error, changeset} = Tasks.register_task(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.title
      assert "can't be blank" in errors.description
      assert "can't be blank" in errors.acceptance_criteria
      assert "can't be blank" in errors.task_type
    end

    test "rejects an empty acceptance_criteria list" do
      assert {:error, changeset} =
               Tasks.register_task(Map.put(@valid_attrs, "acceptance_criteria", []))

      assert "should have at least 1 item(s)" in errors_on(changeset).acceptance_criteria
    end

    test "rejects a task_type outside requirement/issue" do
      assert {:error, changeset} =
               Tasks.register_task(Map.put(@valid_attrs, "task_type", "bogus"))

      assert "is invalid" in errors_on(changeset).task_type
    end
  end

  describe "get_next_task/1" do
    test "returns error when no tasks exist" do
      assert {:error, :no_eligible_task} = Tasks.get_next_task("agent-1")
    end

    test "claims the lowest impl_order open, unlocked task" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, _t2} = Tasks.register_task(@valid_attrs)

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == t1.id
      assert claimed.locked_by == "agent-1"
      assert claimed.locked_at != nil
    end

    test "does not return a task that is already locked" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == t1.id

      # second call must skip the now-locked t1 — nothing else eligible
      assert {:error, :no_eligible_task} = Tasks.get_next_task("agent-2")
    end

    test "does not return a task that is already done or blocked" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.release_lock(t1.id, force: true, status: "done")

      assert {:error, :no_eligible_task} = Tasks.get_next_task("agent-1")
    end

    test "depends_on gating: a task with an undone dependency is never returned" do
      assert {:ok, dep} = Tasks.register_task(@valid_attrs)

      assert {:ok, gated} =
               Tasks.register_task(Map.put(@valid_attrs, "depends_on", [dep.id]))

      # Lock (but don't finish) the dependency so it's no longer "open" +
      # unlocked either — the gated task still must not be returned,
      # because its dependency isn't status "done".
      assert {:ok, _} = Tasks.set_lock(dep.id, "agent-x")

      assert {:error, :no_eligible_task} = Tasks.get_next_task("agent-1")

      # Finishing the dependency makes the gated task claimable.
      assert {:ok, _} = Tasks.release_lock(dep.id, agent_id: "agent-x", status: "done")
      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == gated.id
    end

    test "depends_on gating with multiple dependencies: all must be done" do
      assert {:ok, dep1} = Tasks.register_task(@valid_attrs)
      assert {:ok, dep2} = Tasks.register_task(@valid_attrs)

      assert {:ok, gated} =
               Tasks.register_task(Map.put(@valid_attrs, "depends_on", [dep1.id, dep2.id]))

      assert {:ok, _} = Tasks.release_lock(dep1.id, force: true, status: "done")

      # dep2 still open -> gated must not be claimable; dep2 itself is the
      # only eligible task.
      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == dep2.id

      assert {:ok, _} = Tasks.release_lock(dep2.id, force: true, status: "done")
      assert {:ok, claimed2} = Tasks.get_next_task("agent-2")
      assert claimed2.id == gated.id
    end

    test "skips over locked tasks to find the next eligible one" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, t2} = Tasks.register_task(@valid_attrs)

      assert {:ok, _} = Tasks.set_lock(t1.id, "agent-1")

      assert {:ok, claimed} = Tasks.get_next_task("agent-2")
      assert claimed.id == t2.id
    end

    test "concurrent callers can never claim the same task" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      # Allow the spawned Task processes to use the same sandboxed DB
      # connection as this test process (shared mode, set up by
      # DataCase's setup_sandbox/1 since this test module is async: false).
      parent = self()

      results =
        [1, 2]
        |> Enum.map(fn n ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(LetflowQueue.Repo, parent, self())
            Tasks.get_next_task("agent-#{n}")
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, :no_eligible_task}, &1))

      assert length(successes) == 1
      assert length(failures) == 1

      {:ok, claimed} = List.first(successes)
      assert claimed.id == task.id
      assert claimed.locked_by in ["agent-1", "agent-2"]
    end

    test "many concurrent callers racing for one task: exactly one wins" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      parent = self()

      results =
        1..10
        |> Enum.map(fn n ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(LetflowQueue.Repo, parent, self())
            Tasks.get_next_task("agent-#{n}")
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(successes) == 1
      {:ok, claimed} = List.first(successes)
      assert claimed.id == task.id
    end
  end

  describe "get_next_task/1 issue-vs-requirement priority" do
    test "an eligible issue is claimed ahead of an older eligible requirement" do
      assert {:ok, _req} = Tasks.register_task(@valid_attrs)
      assert {:ok, issue} = Tasks.register_task(@issue_attrs)

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == issue.id
      assert claimed.task_type == "issue"
    end

    test "among multiple eligible issues, the newest (highest id) is claimed first" do
      assert {:ok, _issue1} = Tasks.register_task(@issue_attrs)
      assert {:ok, issue2} = Tasks.register_task(@issue_attrs)

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == issue2.id
    end

    test "falls back to the lowest-impl_order requirement once no eligible issue remains" do
      assert {:ok, req1} = Tasks.register_task(@valid_attrs)
      assert {:ok, _req2} = Tasks.register_task(@valid_attrs)
      assert {:ok, issue} = Tasks.register_task(@issue_attrs)

      assert {:ok, claimed1} = Tasks.get_next_task("agent-1")
      assert claimed1.id == issue.id

      # The issue is now locked (no longer eligible) -- falls through to
      # requirement FIFO order, unaffected by the issue's higher id.
      assert {:ok, claimed2} = Tasks.get_next_task("agent-2")
      assert claimed2.id == req1.id
      assert claimed2.task_type == "requirement"
    end

    test "a locked issue does not block requirement claims" do
      assert {:ok, req} = Tasks.register_task(@valid_attrs)
      assert {:ok, issue} = Tasks.register_task(@issue_attrs)

      assert {:ok, _} = Tasks.set_lock(issue.id, "agent-x")

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == req.id
    end
  end

  describe "set_lock/2" do
    test "locks an unlocked task" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, locked} = Tasks.set_lock(task.id, "agent-1")
      assert locked.locked_by == "agent-1"
      assert locked.locked_at != nil
    end

    test "re-locking with the same agent_id succeeds idempotently and refreshes locked_at" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, first} = Tasks.set_lock(task.id, "agent-1")

      # ensure a detectable time difference
      Process.sleep(1100)

      assert {:ok, second} = Tasks.set_lock(task.id, "agent-1")
      assert second.locked_by == "agent-1"
      assert DateTime.compare(second.locked_at, first.locked_at) == :gt
    end

    test "fails with 409-equivalent error when locked by a different agent_id" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:error, :locked_by_other} = Tasks.set_lock(task.id, "agent-2")
    end

    test "returns not_found for a nonexistent task" do
      assert {:error, :not_found} = Tasks.set_lock(999_999, "agent-1")
    end
  end

  describe "release_lock/2" do
    test "the holding agent releases its lock, leaving status open when status omitted" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} = Tasks.release_lock(task.id, agent_id: "agent-1")
      assert released.locked_by == nil
      assert released.locked_at == nil
      assert released.status == "open"
    end

    test "releasing with a status transitions the task atomically" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "done")

      assert released.status == "done"
      assert released.locked_by == nil
    end

    test "releasing with status blocked works too" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "blocked")

      assert released.status == "blocked"
    end

    test "fails with locked_by_other when a different agent releases without force" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:error, :locked_by_other} = Tasks.release_lock(task.id, agent_id: "agent-2")

      # lock must still be intact
      assert {:error, :locked_by_other} = Tasks.set_lock(task.id, "agent-2")
    end

    test "force: true releases the lock regardless of holder (admin/ORCH override)" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} = Tasks.release_lock(task.id, force: true)
      assert released.locked_by == nil
    end

    test "force: true also allows an included status transition" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:ok, released} = Tasks.release_lock(task.id, force: true, status: "blocked")
      assert released.status == "blocked"
      assert released.locked_by == nil
    end

    test "requires agent_id unless force is true" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(task.id, "agent-1")

      assert {:error, :agent_id_required} = Tasks.release_lock(task.id, [])
    end

    test "releasing an already-unlocked task by any agent succeeds (no-op on lock)" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert {:ok, released} = Tasks.release_lock(task.id, agent_id: "agent-1")
      assert released.locked_by == nil
    end

    test "returns not_found for a nonexistent task" do
      assert {:error, :not_found} = Tasks.release_lock(999_999, agent_id: "agent-1")
    end

    test "rejects an invalid status value" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert {:error, :invalid_status} =
               Tasks.release_lock(task.id, agent_id: "agent-1", status: "bogus")
    end
  end

  describe "issue_ref allocation" do
    # The point of issue_ref is that a caller cannot choose the number. These
    # assert it is DERIVED from the id -- and therefore inherits the primary
    # key's atomic allocation -- rather than asserting any literal value.
    # Note deliberately not tested here: that two concurrent registrations
    # get distinct refs. That property belongs to the database's autoincrement
    # primary key, not to this code, and a test driving concurrent writers
    # through the Ecto sandbox's single checked-out connection would exercise
    # the sandbox rather than the guarantee.

    test "an issue-type task gets a zero-padded ref derived from its id" do
      assert {:ok, task} = Tasks.register_task(@issue_attrs)

      assert TaskSchema.issue_ref(task) == "ISS-" <> String.pad_leading("#{task.id}", 4, "0")
      assert TaskSchema.to_json_map(task).issue_ref == TaskSchema.issue_ref(task)
    end

    test "a requirement-type task has no issue ref" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert TaskSchema.issue_ref(task) == nil
      assert TaskSchema.to_json_map(task).issue_ref == nil
    end

    test "separately registered issues get distinct refs" do
      assert {:ok, a} = Tasks.register_task(@issue_attrs)
      assert {:ok, b} = Tasks.register_task(@issue_attrs)

      assert TaskSchema.issue_ref(a) != TaskSchema.issue_ref(b)
    end
  end

  describe "list_tasks/1" do
    test "returns every task in the database" do
      assert {:ok, t1} = Tasks.register_task(@valid_attrs)
      assert {:ok, t2} = Tasks.register_task(@valid_attrs)

      ids = Tasks.list_tasks() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([t1.id, t2.id])
    end

    test "carries every field the other operations return" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      [listed] = Tasks.list_tasks()

      for key <- [
            :id,
            :impl_order,
            :issue_ref,
            :title,
            :description,
            :acceptance_criteria,
            :depends_on,
            :stage,
            :task_type,
            :status,
            :locked_by,
            :locked_at,
            :github_issue_number,
            :body,
            :inserted_at,
            :updated_at
          ] do
        assert Map.has_key?(listed, key), "expected listed task to carry #{key}"
      end

      assert listed.id == task.id
      assert listed.title == task.title
    end

    test "performs zero writes: two consecutive calls leave every row byte-identical and create no rows" do
      Application.put_env(:letflow_queue, :github_token, "test-token")
      Application.put_env(:letflow_queue, :github_repo, "tvolodi/letflow")
      LetflowQueue.GitHub.FakeClient.reset()

      LetflowQueue.GitHub.FakeClient.set_list_open_issues_result(
        {:ok, [%{number: 999, title: "Importable issue", body: "body text"}]}
      )

      assert {:ok, locked_task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(locked_task.id, "other-agent")

      before_rows = Repo.all(TaskSchema) |> Enum.map(&Map.from_struct/1) |> Enum.sort_by(& &1.id)

      assert _ = Tasks.list_tasks()
      assert _ = Tasks.list_tasks()

      after_rows = Repo.all(TaskSchema) |> Enum.map(&Map.from_struct/1) |> Enum.sort_by(& &1.id)

      assert before_rows == after_rows
      assert length(after_rows) == 1

      # The central property under test: list_tasks/1 must never reach the
      # GitHub import step get_next_task/1 runs first.
      assert LetflowQueue.GitHub.FakeClient.calls(:list_open_issues) == []

      Application.delete_env(:letflow_queue, :github_token)
      Application.delete_env(:letflow_queue, :github_repo)
    end

    test "blocked_by contains exactly the not-done dependency; eligible is false" do
      assert {:ok, done_dep} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.release_lock(done_dep.id, force: true, status: "done")

      assert {:ok, open_dep} = Tasks.register_task(@valid_attrs)

      assert {:ok, gated} =
               Tasks.register_task(
                 Map.put(@valid_attrs, "depends_on", [done_dep.id, open_dep.id])
               )

      listed = Tasks.list_tasks() |> Enum.find(&(&1.id == gated.id))

      assert listed.blocked_by == [open_dep.id]
      assert listed.eligible == false
    end

    test "blocked_by is [] and eligible is true when all dependencies are done" do
      assert {:ok, dep1} = Tasks.register_task(@valid_attrs)
      assert {:ok, dep2} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.release_lock(dep1.id, force: true, status: "done")
      assert {:ok, _} = Tasks.release_lock(dep2.id, force: true, status: "done")

      assert {:ok, task} =
               Tasks.register_task(Map.put(@valid_attrs, "depends_on", [dep1.id, dep2.id]))

      listed = Tasks.list_tasks() |> Enum.find(&(&1.id == task.id))

      assert listed.blocked_by == []
      assert listed.eligible == true
    end

    test "eligible agrees live with get_next_task/1: true before the claim, false after" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      before_claim = Tasks.list_tasks() |> Enum.find(&(&1.id == task.id))
      assert before_claim.eligible == true

      assert {:ok, claimed} = Tasks.get_next_task("agent-1")
      assert claimed.id == task.id

      after_claim = Tasks.list_tasks() |> Enum.find(&(&1.id == task.id))
      assert after_claim.eligible == false
    end

    test "filters by status" do
      assert {:ok, open_task} = Tasks.register_task(@valid_attrs)
      assert {:ok, done_task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.release_lock(done_task.id, force: true, status: "done")

      ids = Tasks.list_tasks(%{"status" => "done"}) |> Enum.map(& &1.id)
      assert ids == [done_task.id]
      refute open_task.id in ids
    end

    test "filters by task_type" do
      assert {:ok, req} = Tasks.register_task(@valid_attrs)
      assert {:ok, issue} = Tasks.register_task(@issue_attrs)

      ids = Tasks.list_tasks(%{"task_type" => "issue"}) |> Enum.map(& &1.id)
      assert ids == [issue.id]
      refute req.id in ids
    end

    test "filters by stage" do
      assert {:ok, s2} = Tasks.register_task(Map.put(@valid_attrs, "stage", "S2"))
      assert {:ok, _s3} = Tasks.register_task(Map.put(@valid_attrs, "stage", "S3"))

      ids = Tasks.list_tasks(%{"stage" => "S2"}) |> Enum.map(& &1.id)
      assert ids == [s2.id]
    end

    test "filters by eligible" do
      assert {:ok, eligible_task} = Tasks.register_task(@valid_attrs)
      assert {:ok, locked_task} = Tasks.register_task(@valid_attrs)
      assert {:ok, _} = Tasks.set_lock(locked_task.id, "agent-1")

      ids = Tasks.list_tasks(%{"eligible" => true}) |> Enum.map(& &1.id)
      assert ids == [eligible_task.id]

      ids_false = Tasks.list_tasks(%{"eligible" => false}) |> Enum.map(& &1.id)
      assert ids_false == [locked_task.id]
    end

    test "combining two filters intersects rather than unions" do
      assert {:ok, matching} =
               Tasks.register_task(Map.put(@issue_attrs, "stage", "S2"))

      assert {:ok, _wrong_type} = Tasks.register_task(Map.put(@valid_attrs, "stage", "S2"))
      assert {:ok, _wrong_stage} = Tasks.register_task(Map.put(@issue_attrs, "stage", "S3"))

      ids =
        Tasks.list_tasks(%{"task_type" => "issue", "stage" => "S2"})
        |> Enum.map(& &1.id)

      assert ids == [matching.id]
    end
  end

  describe "canonical title" do
    test "an issue-type task's title is prefixed with its ref" do
      assert {:ok, task} = Tasks.register_task(@issue_attrs)

      assert task.title == TaskSchema.issue_ref(task) <> ": Do the thing"
    end

    test "a caller-supplied leading ISS number is replaced by the authoritative one" do
      # The enforcement half: a caller that guesses a number must not be able
      # to smuggle it through into what a human later reads.
      attrs = Map.put(@issue_attrs, "title", "ISS-0110: guessed by the caller")

      assert {:ok, task} = Tasks.register_task(attrs)

      assert task.title == TaskSchema.issue_ref(task) <> ": guessed by the caller"
      refute task.title =~ "ISS-0110"
    end

    test "an ISS reference elsewhere in the title is left alone" do
      # Only a LEADING token is an id claim; anything else is a genuine
      # cross-reference to another issue and must survive verbatim.
      attrs = Map.put(@issue_attrs, "title", "regression of ISS-0046 under 1.20")

      assert {:ok, task} = Tasks.register_task(attrs)

      assert task.title == TaskSchema.issue_ref(task) <> ": regression of ISS-0046 under 1.20"
    end

    test "a requirement-type task's title is untouched" do
      assert {:ok, task} = Tasks.register_task(@valid_attrs)

      assert task.title == "Do the thing"
    end
  end
end
