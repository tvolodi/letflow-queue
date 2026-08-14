defmodule LetflowQueue.TasksTest do
  use LetflowQueue.DataCase, async: false

  alias LetflowQueue.Tasks

  @valid_attrs %{
    "title" => "Do the thing",
    "description" => "A thing that needs doing",
    "acceptance_criteria" => ["criterion one", "criterion two"]
  }

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

    test "requires title, description, and at least one acceptance criterion" do
      assert {:error, changeset} = Tasks.register_task(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.title
      assert "can't be blank" in errors.description
      assert "can't be blank" in errors.acceptance_criteria
    end

    test "rejects an empty acceptance_criteria list" do
      assert {:error, changeset} =
               Tasks.register_task(Map.put(@valid_attrs, "acceptance_criteria", []))

      assert "should have at least 1 item(s)" in errors_on(changeset).acceptance_criteria
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
end
