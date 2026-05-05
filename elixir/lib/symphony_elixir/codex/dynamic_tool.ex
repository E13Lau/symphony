defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @github_api_tool "github_api"
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured GitHub auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method (GET, POST, PUT, PATCH, DELETE)."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path starting with /, e.g. /repos/owner/repo/issues."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query string parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "null"],
        "description" => "Optional JSON body for write requests.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @github_api_tool ->
        execute_github_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &GitHubClient.api_request/3)

    with {:ok, method, path, query, body} <- normalize_github_api_arguments(arguments),
         {:ok, response} <- github_client.(method, path, query: query, body: body) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_github_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_github_api_method(arguments),
         {:ok, path} <- normalize_github_api_path(arguments),
         {:ok, query} <- normalize_github_api_query(arguments),
         {:ok, body} <- normalize_github_api_body(arguments) do
      {:ok, method, path, query, body}
    end
  end

  defp normalize_github_api_arguments(_arguments), do: {:error, :invalid_github_api_arguments}

  defp normalize_github_api_method(arguments) do
    case Map.get(arguments, "method") || Map.get(arguments, :method) do
      method when is_binary(method) ->
        normalized_method =
          method
          |> String.trim()
          |> String.downcase()

        case normalized_method do
          "get" -> {:ok, :get}
          "post" -> {:ok, :post}
          "put" -> {:ok, :put}
          "patch" -> {:ok, :patch}
          "delete" -> {:ok, :delete}
          "" -> {:error, :missing_github_api_method}
          _other -> {:error, :invalid_github_api_method}
        end

      nil ->
        {:error, :missing_github_api_method}

      _other ->
        {:error, :invalid_github_api_method}
    end
  end

  defp normalize_github_api_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        normalized_path = String.trim(path)

        cond do
          normalized_path == "" ->
            {:error, :missing_github_api_path}

          String.starts_with?(normalized_path, "/") ->
            {:ok, normalized_path}

          true ->
            {:error, :invalid_github_api_path}
        end

      nil ->
        {:error, :missing_github_api_path}

      _other ->
        {:error, :invalid_github_api_path}
    end
  end

  defp normalize_github_api_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      nil -> {:ok, nil}
      query when is_map(query) -> {:ok, query}
      _other -> {:error, :invalid_github_api_query}
    end
  end

  defp normalize_github_api_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      nil -> {:ok, nil}
      body when is_map(body) or is_list(body) -> {:ok, body}
      _other -> {:error, :invalid_github_api_body}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_github_api_method) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `method` string."
      }
    }
  end

  defp tool_error_payload(:invalid_github_api_method) do
    %{
      "error" => %{
        "message" => "`github_api.method` must be one of GET, POST, PUT, PATCH, or DELETE."
      }
    }
  end

  defp tool_error_payload(:missing_github_api_path) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `path` that starts with `/`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_api_path) do
    %{
      "error" => %{
        "message" => "`github_api.path` must start with `/`, for example `/repos/owner/repo/issues`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_api_query) do
    %{
      "error" => %{
        "message" => "`github_api.query` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_github_api_body) do
    %{
      "error" => %{
        "message" => "`github_api.body` must be a JSON object or array when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_github_api_arguments) do
    %{
      "error" => %{
        "message" => "`github_api` expects an object with required `method` and `path`, plus optional `query` and `body`."
      }
    }
  end

  defp tool_error_payload(:missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_status, status, body}) do
    %{
      "error" => %{
        "message" => "GitHub REST API request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub REST API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
