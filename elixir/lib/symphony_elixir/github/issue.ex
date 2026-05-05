defmodule SymphonyElixir.GitHub.Issue do
  @moduledoc """
  Normalizes GitHub issue payloads into the tracker issue shape used by the orchestrator.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue, as: TrackerIssue

  @status_label_prefix "status:"

  @spec normalize(map()) :: TrackerIssue.t() | nil
  def normalize(raw_issue) when is_map(raw_issue) do
    if pull_request_issue?(raw_issue) do
      nil
    else
      case Map.get(raw_issue, "number") do
        number when is_integer(number) and number > 0 ->
          labels = extract_label_names(raw_issue)

          %TrackerIssue{
            id: Integer.to_string(number),
            identifier: "GH-#{number}",
            title: Map.get(raw_issue, "title"),
            description: Map.get(raw_issue, "body"),
            priority: priority_from_labels(labels),
            state: state_from_labels(labels, Map.get(raw_issue, "state")),
            branch_name: nil,
            url: Map.get(raw_issue, "html_url"),
            assignee_id: assignee_login(raw_issue),
            blocked_by: [],
            labels: labels,
            assigned_to_worker: true,
            created_at: parse_datetime(Map.get(raw_issue, "created_at")),
            updated_at: parse_datetime(Map.get(raw_issue, "updated_at"))
          }

        _ ->
          nil
      end
    end
  end

  def normalize(_raw_issue), do: nil

  @spec pull_request_issue?(map()) :: boolean()
  def pull_request_issue?(raw_issue) when is_map(raw_issue) do
    match?(%{}, Map.get(raw_issue, "pull_request"))
  end

  def pull_request_issue?(_raw_issue), do: false

  @spec extract_label_names(map()) :: [String.t()]
  def extract_label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _other -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  def extract_label_names(_raw_issue), do: []

  @spec status_label?(String.t()) :: boolean()
  def status_label?(label) when is_binary(label) do
    String.starts_with?(String.downcase(String.trim(label)), @status_label_prefix)
  end

  def status_label?(_label), do: false

  @spec status_label_for_state(String.t()) :: String.t() | nil
  def status_label_for_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> Schema.normalize_issue_state()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      normalized -> @status_label_prefix <> normalized
    end
  end

  def status_label_for_state(_state_name), do: nil

  @spec state_from_labels([String.t()], String.t() | nil) :: String.t() | nil
  def state_from_labels(labels, fallback_state) when is_list(labels) do
    case Enum.find(labels, &status_label?/1) do
      nil -> normalize_fallback_state(fallback_state)
      label -> String.replace_prefix(label, @status_label_prefix, "")
    end
  end

  def state_from_labels(_labels, fallback_state), do: normalize_fallback_state(fallback_state)

  defp normalize_fallback_state(state_name) when is_binary(state_name) do
    normalized =
      state_name
      |> String.trim()
      |> Schema.normalize_issue_state()

    if normalized == "", do: nil, else: normalized
  end

  defp normalize_fallback_state(_state_name), do: nil

  defp priority_from_labels(labels) do
    Enum.find_value(labels, fn
      "priority:p0" -> 1
      "priority:p1" -> 2
      "priority:p2" -> 3
      "priority:p3" -> 4
      _other -> nil
    end)
  end

  defp assignee_login(raw_issue) when is_map(raw_issue) do
    case Map.get(raw_issue, "assignee") do
      %{"login" => login} when is_binary(login) and login != "" ->
        login

      _other ->
        case Map.get(raw_issue, "assignees") do
          [%{"login" => login} | _] when is_binary(login) and login != "" -> login
          _ -> nil
        end
    end
  end

  defp assignee_login(_raw_issue), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw_value) when is_binary(raw_value) do
    case DateTime.from_iso8601(raw_value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_raw_value), do: nil
end
