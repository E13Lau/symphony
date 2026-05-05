defmodule SymphonyElixir.GitHubAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter

  defmodule FakeGitHubClient do
    def list_issues(repository, opts \\ []) do
      send(self(), {:github_list_issues_called, repository, opts})

      list_results = Process.get({__MODULE__, :list_results}, %{})
      state = Keyword.get(opts, :state, "open")
      labels = Keyword.get(opts, :labels)

      {:ok, Map.get(list_results, {state, labels}, [])}
    end

    def get_issue(repository, issue_id) do
      send(self(), {:github_get_issue_called, repository, issue_id})

      issue_results = Process.get({__MODULE__, :get_issue_results}, %{})
      Map.get(issue_results, issue_id, {:error, {:github_api_status, 404, %{}}})
    end

    def create_comment(repository, issue_id, body) do
      send(self(), {:github_create_comment_called, repository, issue_id, body})
      Process.get({__MODULE__, :create_comment_result}, :ok)
    end

    def replace_labels(repository, issue_id, labels) do
      send(self(), {:github_replace_labels_called, repository, issue_id, labels})
      Process.get({__MODULE__, :replace_labels_result}, :ok)
    end

    def close_issue(repository, issue_id) do
      send(self(), {:github_close_issue_called, repository, issue_id})
      Process.get({__MODULE__, :close_issue_result}, :ok)
    end
  end

  setup do
    previous_github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    on_exit(fn ->
      if is_nil(previous_github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_github_client_module)
      end
    end)

    :ok
  end

  test "fetch_candidate_issues reads active labels, skips PRs, and normalizes issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "gh-token",
      tracker_repository: "acme/repo",
      tracker_active_labels: ["status:ready-for-ai", "status:rework"]
    )

    issue_101 = github_issue(101, ["status:ready-for-ai", "priority:p1", "area:api"], "open")
    issue_102 = github_issue(102, ["status:rework"], "open")

    pr_103 =
      github_issue(103, ["status:rework"], "open")
      |> Map.put("pull_request", %{"url" => "https://api.github.com/repos/acme/repo/pulls/103"})

    Process.put(
      {FakeGitHubClient, :list_results},
      %{
        {"open", "status:ready-for-ai"} => [issue_101],
        {"open", "status:rework"} => [pr_103, issue_102, issue_101]
      }
    )

    assert {:ok, issues} = Adapter.fetch_candidate_issues()

    assert Enum.map(issues, & &1.id) == ["101", "102"]
    assert Enum.map(issues, & &1.identifier) == ["GH-101", "GH-102"]
    assert Enum.map(issues, & &1.state) == ["ready-for-ai", "rework"]
    assert Enum.map(issues, & &1.priority) == [2, nil]

    assert_receive {:github_list_issues_called, "acme/repo", opts_ready}
    assert Keyword.get(opts_ready, :state) == "open"
    assert Keyword.get(opts_ready, :labels) == "status:ready-for-ai"

    assert_receive {:github_list_issues_called, "acme/repo", opts_rework}
    assert Keyword.get(opts_rework, :state) == "open"
    assert Keyword.get(opts_rework, :labels) == "status:rework"
  end

  test "fetch_issues_by_states resolves state labels and also checks closed issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "gh-token",
      tracker_repository: "acme/repo"
    )

    issue_201 = github_issue(201, ["status:done"], "open")
    issue_202 = github_issue(202, ["status:closed"], "closed")
    issue_203 = github_issue(203, [], "closed")

    Process.put(
      {FakeGitHubClient, :list_results},
      %{
        {"all", "status:done"} => [issue_201],
        {"all", "status:closed"} => [issue_202],
        {"closed", nil} => [issue_203, issue_202]
      }
    )

    assert {:ok, issues} = Adapter.fetch_issues_by_states(["Done", "Closed"])

    assert Enum.map(issues, & &1.id) == ["201", "202", "203"]
    assert Enum.map(issues, & &1.state) == ["done", "closed", "closed"]

    assert_receive {:github_list_issues_called, "acme/repo", opts_done}
    assert Keyword.get(opts_done, :state) == "all"
    assert Keyword.get(opts_done, :labels) == "status:done"

    assert_receive {:github_list_issues_called, "acme/repo", opts_closed_label}
    assert Keyword.get(opts_closed_label, :state) == "all"
    assert Keyword.get(opts_closed_label, :labels) == "status:closed"

    assert_receive {:github_list_issues_called, "acme/repo", opts_closed_state}
    assert Keyword.get(opts_closed_state, :state) == "closed"
    assert Keyword.get(opts_closed_state, :labels) == nil
  end

  test "fetch_issue_states_by_ids skips not-found issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "gh-token",
      tracker_repository: "acme/repo"
    )

    Process.put(
      {FakeGitHubClient, :get_issue_results},
      %{
        "301" => {:ok, github_issue(301, ["status:ai-in-progress"], "open")},
        "302" => {:error, {:github_api_status, 404, %{}}}
      }
    )

    assert {:ok, issues} = Adapter.fetch_issue_states_by_ids(["301", "302", "301"])

    assert Enum.map(issues, & &1.id) == ["301"]
    assert Enum.map(issues, & &1.state) == ["ai-in-progress"]

    assert_receive {:github_get_issue_called, "acme/repo", "301"}
    assert_receive {:github_get_issue_called, "acme/repo", "302"}
  end

  test "create_comment delegates to the configured github client" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "gh-token",
      tracker_repository: "acme/repo"
    )

    assert :ok = Adapter.create_comment("401", "workpad update")

    assert_receive {:github_create_comment_called, "acme/repo", "401", "workpad update"}
  end

  test "update_issue_state rewrites status labels and closes done issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "gh-token",
      tracker_repository: "acme/repo"
    )

    Process.put(
      {FakeGitHubClient, :get_issue_results},
      %{
        "501" => {:ok, github_issue(501, ["status:ready-for-ai", "area:ios"], "open")},
        "502" => {:ok, github_issue(502, ["status:human-review"], "open")}
      }
    )

    assert :ok = Adapter.update_issue_state("501", "human-review")

    assert_receive {:github_get_issue_called, "acme/repo", "501"}
    assert_receive {:github_replace_labels_called, "acme/repo", "501", ["status:human-review", "area:ios"]}
    refute_receive {:github_close_issue_called, "acme/repo", "501"}

    assert :ok = Adapter.update_issue_state("502", "done")

    assert_receive {:github_get_issue_called, "acme/repo", "502"}
    assert_receive {:github_replace_labels_called, "acme/repo", "502", ["status:done"]}
    assert_receive {:github_close_issue_called, "acme/repo", "502"}
  end

  defp github_issue(number, label_names, state) do
    %{
      "id" => number * 10,
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => state,
      "labels" => Enum.map(label_names, &%{"name" => &1}),
      "html_url" => "https://github.com/acme/repo/issues/#{number}",
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end
end
