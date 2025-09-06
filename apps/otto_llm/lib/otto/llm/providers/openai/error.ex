defmodule Otto.LLM.Providers.OpenAI.Error do
  @moduledoc """
  Error handling for OpenAI API responses.
  """

  defexception [:status_code, :type, :message, :code, :param, :request_id, :body]

  @type t :: %__MODULE__{
          status_code: integer(),
          type: String.t() | nil,
          message: String.t(),
          code: String.t() | nil,
          param: String.t() | nil,
          request_id: String.t() | nil,
          body: map() | String.t() | nil
        }

  @doc """
  Creates an error from an API response.
  """
  def from_response(status_code, body, request) when is_binary(body) do
    # Try to parse as JSON first
    case Jason.decode(body) do
      {:ok, parsed} ->
        from_response(status_code, parsed, request)

      {:error, _} ->
        %__MODULE__{
          status_code: status_code,
          message: body,
          body: body
        }
    end
  end

  def from_response(status_code, body, request) when is_map(body) do
    error_details = Map.get(body, "error", %{})

    %__MODULE__{
      status_code: status_code,
      type: Map.get(error_details, "type"),
      message: Map.get(error_details, "message", "Unknown error"),
      code: Map.get(error_details, "code"),
      param: Map.get(error_details, "param"),
      request_id: get_request_id(request),
      body: body
    }
  end

  def from_response(status_code, body, request) do
    %__MODULE__{
      status_code: status_code,
      message: "Unexpected response format",
      request_id: get_request_id(request),
      body: inspect(body)
    }
  end

  @impl true
  def message(%__MODULE__{} = error) do
    parts = [
      "OpenAI API Error",
      error.status_code && "(#{error.status_code})",
      error.type && "[#{error.type}]",
      error.code && "#{error.code}:",
      error.message
    ]

    parts
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp get_request_id(response_or_request) do
    # Try to get request ID from response headers first, then request headers
    case response_or_request do
      %{headers: headers} when is_map(headers) ->
        # For responses with map headers
        case Map.get(headers, "x-request-id") do
          [id | _] -> id
          id when is_binary(id) -> id
          _ -> nil
        end

      %{headers: headers} when is_list(headers) ->
        # For requests with list headers
        case List.keyfind(headers, "x-request-id", 0) do
          {"x-request-id", id} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

defmodule Otto.LLM.Providers.OpenAI.AuthenticationError do
  @moduledoc """
  Authentication error for OpenAI API (401 status).
  """

  defexception [:status_code, :type, :message, :code, :param, :request_id, :body]

  @type t :: %__MODULE__{
          status_code: integer(),
          type: String.t() | nil,
          message: String.t(),
          code: String.t() | nil,
          param: String.t() | nil,
          request_id: String.t() | nil,
          body: map() | String.t() | nil
        }

  def from_response(status_code, body, request) do
    base_error = Otto.LLM.Providers.OpenAI.Error.from_response(status_code, body, request)

    %__MODULE__{
      status_code: base_error.status_code,
      type: base_error.type,
      message: base_error.message,
      code: base_error.code,
      param: base_error.param,
      request_id: base_error.request_id,
      body: base_error.body
    }
  end

  @impl true
  def message(%__MODULE__{} = error) do
    "OpenAI Authentication Error (#{error.status_code}): #{error.message}"
  end
end

defmodule Otto.LLM.Providers.OpenAI.RateLimitError do
  @moduledoc """
  Rate limit error for OpenAI API (429 status).
  """

  defexception [:status_code, :type, :message, :code, :param, :request_id, :body]

  @type t :: %__MODULE__{
          status_code: integer(),
          type: String.t() | nil,
          message: String.t(),
          code: String.t() | nil,
          param: String.t() | nil,
          request_id: String.t() | nil,
          body: map() | String.t() | nil
        }

  def from_response(status_code, body, request) do
    base_error = Otto.LLM.Providers.OpenAI.Error.from_response(status_code, body, request)

    %__MODULE__{
      status_code: base_error.status_code,
      type: base_error.type,
      message: base_error.message,
      code: base_error.code,
      param: base_error.param,
      request_id: base_error.request_id,
      body: base_error.body
    }
  end

  @impl true
  def message(%__MODULE__{} = error) do
    "OpenAI Rate Limit Error (#{error.status_code}): #{error.message}"
  end
end