defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.Client, GitHub.Issue}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = Config.settings!()
    repository = settings.tracker.repository

    with {:ok, raw_issues} <- fetch_issues_for_labels(repository, settings.tracker.active_labels, "open") do
      {:ok, normalize_issues(raw_issues)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    settings = Config.settings!()
    repository = settings.tracker.repository

    state_labels =
      state_names
      |> Enum.map(&Issue.status_label_for_state/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, issues_by_status_label} <- fetch_issues_for_labels(repository, state_labels, "all"),
         {:ok, closed_issues} <- maybe_fetch_closed_issues(repository, state_names) do
      {:ok, normalize_issues(issues_by_status_label ++ closed_issues)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    repository = Config.settings!().tracker.repository

    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case client_module().get_issue(repository, issue_id) do
        {:ok, raw_issue} ->
          case Issue.normalize(raw_issue) do
            nil -> {:cont, {:ok, acc}}
            normalized_issue -> {:cont, {:ok, [normalized_issue | acc]}}
          end

        {:error, {:github_api_status, 404, _body}} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(Config.settings!().tracker.repository, issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    repository = Config.settings!().tracker.repository

    with {:ok, raw_issue} <- client_module().get_issue(repository, issue_id),
         false <- Issue.pull_request_issue?(raw_issue),
         :ok <- update_issue_labels(repository, issue_id, raw_issue, state_name),
         :ok <- maybe_close_issue(repository, issue_id, state_name) do
      :ok
    else
      true -> {:error, :issue_is_pull_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_issue_labels(repository, issue_id, raw_issue, state_name)
       when is_binary(repository) and is_binary(issue_id) and is_map(raw_issue) and is_binary(state_name) do
    desired_status_label = Issue.status_label_for_state(state_name)

    non_status_labels =
      raw_issue
      |> Issue.extract_label_names()
      |> Enum.reject(&Issue.status_label?/1)

    next_labels =
      [desired_status_label | non_status_labels]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    client_module().replace_labels(repository, issue_id, next_labels)
  end

  defp maybe_close_issue(repository, issue_id, state_name)
       when is_binary(repository) and is_binary(issue_id) and is_binary(state_name) do
    normalized_state =
      state_name
      |> String.trim()
      |> String.downcase()

    if normalized_state in ["done", "closed"] do
      client_module().close_issue(repository, issue_id)
    else
      :ok
    end
  end

  defp maybe_fetch_closed_issues(repository, state_names) when is_list(state_names) do
    if has_state?(state_names, "closed") do
      client_module().list_issues(repository, state: "closed")
    else
      {:ok, []}
    end
  end

  defp has_state?(state_names, target_state) when is_list(state_names) and is_binary(target_state) do
    normalized_target_state = normalize_state_name(target_state)

    Enum.any?(state_names, fn state_name ->
      normalize_state_name(state_name) == normalized_target_state
    end)
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state_name(_state_name), do: ""

  defp fetch_issues_for_labels(repository, labels, issue_state)
       when is_binary(repository) and is_list(labels) and is_binary(issue_state) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      case client_module().list_issues(repository, state: issue_state, labels: label) do
        {:ok, issues} when is_list(issues) ->
          {:cont, {:ok, Enum.reverse(issues, acc)}}

        {:ok, _other} ->
          {:halt, {:error, :github_unknown_payload}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issues_for_labels(_repository, _labels, _issue_state), do: {:ok, []}

  defp normalize_issues(raw_issues) when is_list(raw_issues) do
    raw_issues
    |> Enum.map(&Issue.normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp normalize_issues(_raw_issues), do: []

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
