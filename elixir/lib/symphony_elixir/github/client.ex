defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for polling and mutating issues.
  """

  require Logger

  alias SymphonyElixir.Config

  @issue_page_size 100
  @default_base_url "https://api.github.com"
  @github_accept "application/vnd.github+json"
  @github_api_version "2022-11-28"
  @max_error_body_log_bytes 1_000
  @supported_request_methods [:get, :post, :put, :patch, :delete]

  @spec list_issues(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_issues(repository, opts \\ []) when is_binary(repository) and is_list(opts) do
    params =
      [
        {"state", normalize_state_param(Keyword.get(opts, :state, "open"))},
        {"per_page", @issue_page_size}
      ]
      |> maybe_put_labels(Keyword.get(opts, :labels))

    do_list_issues(repository, params, 1, [])
  end

  @spec get_issue(String.t(), String.t() | integer()) :: {:ok, map()} | {:error, term()}
  def get_issue(repository, issue_number) when is_binary(repository) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_path(repository, normalized_issue_number),
         {:ok, response} <- request(:get, path) do
      case response do
        %{} = issue -> {:ok, issue}
        _other -> {:error, :github_unknown_payload}
      end
    end
  end

  @spec create_comment(String.t(), String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def create_comment(repository, issue_number, body)
      when is_binary(repository) and is_binary(body) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_comments_path(repository, normalized_issue_number),
         {:ok, _response} <- request(:post, path, json: %{body: body}) do
      :ok
    end
  end

  @spec replace_labels(String.t(), String.t() | integer(), [String.t()]) :: :ok | {:error, term()}
  def replace_labels(repository, issue_number, labels)
      when is_binary(repository) and is_list(labels) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_labels_path(repository, normalized_issue_number),
         {:ok, _response} <- request(:put, path, json: %{labels: normalize_labels(labels)}) do
      :ok
    end
  end

  @spec add_labels(String.t(), String.t() | integer(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(repository, issue_number, labels)
      when is_binary(repository) and is_list(labels) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_labels_path(repository, normalized_issue_number),
         {:ok, _response} <- request(:post, path, json: %{labels: normalize_labels(labels)}) do
      :ok
    end
  end

  @spec remove_label(String.t(), String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def remove_label(repository, issue_number, label)
      when is_binary(repository) and is_binary(label) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_label_path(repository, normalized_issue_number, label),
         {:ok, _response} <- request(:delete, path) do
      :ok
    end
  end

  @spec close_issue(String.t(), String.t() | integer()) :: :ok | {:error, term()}
  def close_issue(repository, issue_number) when is_binary(repository) do
    with {:ok, normalized_issue_number} <- normalize_issue_number(issue_number),
         {:ok, path} <- issue_path(repository, normalized_issue_number),
         {:ok, _response} <- request(:patch, path, json: %{state: "closed"}) do
      :ok
    end
  end

  @spec api_request(atom() | String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def api_request(method, path, opts \\ []) when is_list(opts) do
    with {:ok, request_method} <- normalize_request_method(method),
         {:ok, request_path} <- normalize_request_path(path),
         {:ok, request_opts} <- build_api_request_opts(opts) do
      request(request_method, request_path, request_opts)
    end
  end

  defp do_list_issues(repository, params, page, acc) do
    with {:ok, path} <- issue_collection_path(repository),
         {:ok, response} <- request(:get, path, params: [{"page", page} | params]) do
      case response do
        issues when is_list(issues) ->
          updated_acc = Enum.reverse(issues, acc)

          if length(issues) < @issue_page_size do
            {:ok, Enum.reverse(updated_acc)}
          else
            do_list_issues(repository, params, page + 1, updated_acc)
          end

        _other ->
          {:error, :github_unknown_payload}
      end
    end
  end

  defp issue_collection_path(repository) do
    with {:ok, repo_root} <- repository_root_path(repository) do
      {:ok, repo_root <> "/issues"}
    end
  end

  defp issue_path(repository, issue_number) when is_binary(issue_number) do
    with {:ok, issues_path} <- issue_collection_path(repository) do
      {:ok, issues_path <> "/" <> issue_number}
    end
  end

  defp issue_comments_path(repository, issue_number) when is_binary(issue_number) do
    with {:ok, issue_path} <- issue_path(repository, issue_number) do
      {:ok, issue_path <> "/comments"}
    end
  end

  defp issue_labels_path(repository, issue_number) when is_binary(issue_number) do
    with {:ok, issue_path} <- issue_path(repository, issue_number) do
      {:ok, issue_path <> "/labels"}
    end
  end

  defp issue_label_path(repository, issue_number, label)
       when is_binary(issue_number) and is_binary(label) do
    with {:ok, labels_path} <- issue_labels_path(repository, issue_number) do
      {:ok, labels_path <> "/" <> URI.encode(String.trim(label))}
    end
  end

  defp repository_root_path(repository) when is_binary(repository) do
    with {:ok, owner, repo} <- parse_repository(repository) do
      {:ok, "/repos/" <> URI.encode(owner) <> "/" <> URI.encode(repo)}
    end
  end

  defp parse_repository(repository) when is_binary(repository) do
    case repository |> String.trim() |> String.split("/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner, repo}
      _other -> {:error, :invalid_github_repository}
    end
  end

  defp normalize_issue_number(issue_number) when is_integer(issue_number) and issue_number > 0 do
    {:ok, Integer.to_string(issue_number)}
  end

  defp normalize_issue_number(issue_number) when is_binary(issue_number) do
    normalized =
      issue_number
      |> String.trim()
      |> String.trim_leading("#")

    if String.match?(normalized, ~r/^\d+$/) do
      {:ok, normalized}
    else
      {:error, :invalid_github_issue_number}
    end
  end

  defp normalize_issue_number(_issue_number), do: {:error, :invalid_github_issue_number}

  defp maybe_put_labels(params, labels) do
    case normalize_labels_param(labels) do
      nil -> params
      normalized -> [{"labels", normalized} | params]
    end
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_labels(_labels), do: []

  defp normalize_labels_param(labels) when is_binary(labels) do
    trimmed = String.trim(labels)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_labels_param(labels) when is_list(labels) do
    case normalize_labels(labels) do
      [] -> nil
      normalized_labels -> Enum.join(normalized_labels, ",")
    end
  end

  defp normalize_labels_param(_labels), do: nil

  defp normalize_state_param(state) when is_binary(state) do
    case state |> String.trim() |> String.downcase() do
      "all" -> "all"
      "closed" -> "closed"
      _other -> "open"
    end
  end

  defp normalize_state_param(_state), do: "open"

  defp request(method, path, opts \\ []) when is_atom(method) and is_binary(path) do
    with {:ok, headers} <- github_headers() do
      case Req.request(
             Keyword.merge(
               [
                 method: method,
                 url: build_url(path),
                 headers: headers,
                 connect_options: [timeout: 30_000]
               ],
               opts
             )
           ) do
        {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "GitHub REST request failed method=#{String.upcase(to_string(method))} path=#{path} status=#{status} body=#{summarize_error_body(body)}"
          )

          {:error, {:github_api_status, status, body}}

        {:error, reason} ->
          Logger.warning(
            "GitHub REST request failed method=#{String.upcase(to_string(method))} path=#{path} reason=#{inspect(reason)}"
          )

          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp github_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"authorization", "Bearer #{token}"},
           {"accept", @github_accept},
           {"x-github-api-version", @github_api_version},
           {"user-agent", "symphony-elixir"}
         ]}

      _other ->
        {:error, :missing_github_api_token}
    end
  end

  defp build_url(path) do
    base_url =
      case Config.settings!().tracker.endpoint do
        endpoint when is_binary(endpoint) ->
          trimmed = String.trim(endpoint)

          cond do
            trimmed == "" -> @default_base_url
            String.ends_with?(trimmed, "/graphql") -> @default_base_url
            true -> trimmed
          end

        _other ->
          @default_base_url
      end

    String.trim_trailing(base_url, "/") <> path
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp normalize_request_method(method) when method in @supported_request_methods,
    do: {:ok, method}

  defp normalize_request_method(method) when is_binary(method) do
    case String.downcase(String.trim(method)) do
      "get" -> {:ok, :get}
      "post" -> {:ok, :post}
      "put" -> {:ok, :put}
      "patch" -> {:ok, :patch}
      "delete" -> {:ok, :delete}
      _other -> {:error, :invalid_github_api_method}
    end
  end

  defp normalize_request_method(_method), do: {:error, :invalid_github_api_method}

  defp normalize_request_path(path) when is_binary(path) do
    normalized_path = String.trim(path)

    cond do
      normalized_path == "" ->
        {:error, :invalid_github_api_path}

      String.starts_with?(normalized_path, "/") ->
        {:ok, normalized_path}

      true ->
        {:error, :invalid_github_api_path}
    end
  end

  defp normalize_request_path(_path), do: {:error, :invalid_github_api_path}

  defp build_api_request_opts(opts) when is_list(opts) do
    query = Keyword.get(opts, :query)
    body = Keyword.get(opts, :body, :missing)

    with :ok <- validate_api_query(query),
         :ok <- validate_api_body(body) do
      request_opts =
        []
        |> maybe_put_api_query(query)
        |> maybe_put_api_body(body)

      {:ok, request_opts}
    end
  end

  defp validate_api_query(nil), do: :ok
  defp validate_api_query(query) when is_map(query), do: :ok
  defp validate_api_query(_query), do: {:error, :invalid_github_api_query}

  defp validate_api_body(:missing), do: :ok
  defp validate_api_body(nil), do: :ok
  defp validate_api_body(body) when is_map(body) or is_list(body), do: :ok
  defp validate_api_body(_body), do: {:error, :invalid_github_api_body}

  defp maybe_put_api_query(request_opts, nil), do: request_opts

  defp maybe_put_api_query(request_opts, query) when is_map(query) do
    case map_size(query) do
      0 -> request_opts
      _size -> Keyword.put(request_opts, :params, query)
    end
  end

  defp maybe_put_api_body(request_opts, :missing), do: request_opts
  defp maybe_put_api_body(request_opts, nil), do: request_opts

  defp maybe_put_api_body(request_opts, body) when is_map(body) or is_list(body) do
    Keyword.put(request_opts, :json, body)
  end
end
