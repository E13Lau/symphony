defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql and github_api input contracts" do
    specs = DynamicTool.tool_specs()

    assert linear_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert linear_spec["inputSchema"] == %{
             "additionalProperties" => false,
             "properties" => %{
               "query" => %{
                 "description" => "GraphQL query or mutation document to execute against Linear.",
                 "type" => "string"
               },
               "variables" => %{
                 "additionalProperties" => true,
                 "description" => "Optional GraphQL variables object.",
                 "type" => ["object", "null"]
               }
             },
             "required" => ["query"],
             "type" => "object"
           }

    assert linear_spec["description"] =~ "Linear"

    assert github_spec = Enum.find(specs, &(&1["name"] == "github_api"))
    assert github_spec["description"] =~ "GitHub REST"

    assert github_spec["inputSchema"] == %{
             "additionalProperties" => false,
             "properties" => %{
               "body" => %{
                 "additionalProperties" => true,
                 "description" => "Optional JSON body for write requests.",
                 "type" => ["object", "array", "null"]
               },
               "method" => %{
                 "description" => "HTTP method (GET, POST, PUT, PATCH, DELETE).",
                 "type" => "string"
               },
               "path" => %{
                 "description" => "GitHub REST path starting with /, e.g. /repos/owner/repo/issues.",
                 "type" => "string"
               },
               "query" => %{
                 "additionalProperties" => true,
                 "description" => "Optional query string parameters.",
                 "type" => ["object", "null"]
               }
             },
             "required" => ["method", "path"],
             "type" => "object"
           }
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "github_api"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Dynamic tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "github_api executes valid REST requests and returns response payload" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_api",
        %{
          "method" => "GET",
          "path" => "/repos/openai/symphony/issues",
          "query" => %{"state" => "open", "labels" => "status:ready-for-ai"}
        },
        github_client: fn method, path, opts ->
          send(test_pid, {:github_client_called, method, path, opts})
          {:ok, [%{"id" => 1}]}
        end
      )

    assert_received {:github_client_called, :get, "/repos/openai/symphony/issues",
                     [query: %{"state" => "open", "labels" => "status:ready-for-ai"}, body: nil]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == [%{"id" => 1}]
  end

  test "github_api validates required arguments before calling GitHub" do
    missing_method = DynamicTool.execute("github_api", %{"path" => "/repos/openai/symphony/issues"})

    assert missing_method["success"] == false

    assert Jason.decode!(missing_method["output"]) == %{
             "error" => %{
               "message" => "`github_api` requires a non-empty `method` string."
             }
           }

    missing_path = DynamicTool.execute("github_api", %{"method" => "GET"})

    assert missing_path["success"] == false

    assert Jason.decode!(missing_path["output"]) == %{
             "error" => %{
               "message" => "`github_api` requires a non-empty `path` that starts with `/`."
             }
           }
  end

  test "github_api validates method, path, query, and body types" do
    invalid_method =
      DynamicTool.execute("github_api", %{"method" => "TRACE", "path" => "/repos/openai/symphony/issues"})

    assert Jason.decode!(invalid_method["output"]) == %{
             "error" => %{
               "message" => "`github_api.method` must be one of GET, POST, PUT, PATCH, or DELETE."
             }
           }

    invalid_path =
      DynamicTool.execute("github_api", %{"method" => "GET", "path" => "repos/openai/symphony/issues"})

    assert Jason.decode!(invalid_path["output"]) == %{
             "error" => %{
               "message" => "`github_api.path` must start with `/`, for example `/repos/owner/repo/issues`."
             }
           }

    invalid_query =
      DynamicTool.execute("github_api", %{
        "method" => "GET",
        "path" => "/repos/openai/symphony/issues",
        "query" => ["bad"]
      })

    assert Jason.decode!(invalid_query["output"]) == %{
             "error" => %{
               "message" => "`github_api.query` must be a JSON object when provided."
             }
           }

    invalid_body =
      DynamicTool.execute("github_api", %{
        "method" => "POST",
        "path" => "/repos/openai/symphony/issues",
        "body" => "bad"
      })

    assert Jason.decode!(invalid_body["output"]) == %{
             "error" => %{
               "message" => "`github_api.body` must be a JSON object or array when provided."
             }
           }
  end

  test "github_api formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/openai/symphony/issues"},
        github_client: fn _method, _path, _opts -> {:error, :missing_github_api_token} end
      )

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    status_error =
      DynamicTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/openai/symphony/issues"},
        github_client: fn _method, _path, _opts -> {:error, {:github_api_status, 403, %{"message" => "Forbidden"}}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "GitHub REST API request failed with HTTP 403.",
               "status" => 403,
               "body" => %{"message" => "Forbidden"}
             }
           }

    request_error =
      DynamicTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/openai/symphony/issues"},
        github_client: fn _method, _path, _opts -> {:error, {:github_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "GitHub REST API request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
