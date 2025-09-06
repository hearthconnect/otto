defmodule Otto.LLM.Providers.OpenAI do
  @moduledoc """
  Req plugin for OpenAI's API integration.

  This plugin provides a clean interface to OpenAI's APIs with support for:
  - Authentication with API key, organization, and project headers
  - Comprehensive error handling with structured error types
  - Request/response middleware for OpenAI-specific behavior

  ## Usage

      # Attach to a new Req client
      client =
        Req.new()
        |> Otto.LLM.Providers.OpenAI.attach(api_key: "your-api-key")

      # Make requests to OpenAI API
      {:ok, response} = Req.post(client,
        url: "/v1/responses",
        json: %{model: "o3", input: "Hello!"}
      )
  """

  require Logger
  alias Otto.LLM.Client.Base

  @default_base_url "https://api.openai.com"
  @default_receive_timeout 120_000

  @doc """
  Builds a pre-configured OpenAI client with application settings.

  This is the recommended way to create OpenAI clients as it automatically:
  - Applies the configured API key from application environment
  - Includes test options for mocking in tests
  - Enables VCR integration when available
  - Sets appropriate timeouts and retry logic

  ## Options

    * `:base_url` - Optional. Base URL for the API (defaults to #{@default_base_url})
    * `:organization` - Optional. Your OpenAI organization ID
    * `:project` - Optional. Your OpenAI project ID
    * `:receive_timeout` - Optional. Timeout in ms (defaults to #{@default_receive_timeout})

  ## Examples

      # Build client with default settings
      client = Otto.LLM.Providers.OpenAI.build_client()

      # Build client with custom timeout
      client = Otto.LLM.Providers.OpenAI.build_client(receive_timeout: 60_000)

      # Make requests to OpenAI API
      {:ok, response} = Req.post(client,
        url: "/v1/responses",
        json: %{model: "o3", input: "Hello!"}
      )
  """
  def build_client(opts \\ []) do
    openai_config = Application.get_env(:otto_llm, Otto.LLM.Providers.OpenAI, [])
    test_options = openai_config[:req_options] || []
    api_key = openai_config[:api_key]

    default_opts = [
      api_key: api_key,
      receive_timeout: 300_000
    ]

    Req.new()
    |> attach(Keyword.merge(default_opts, opts))
    |> Req.merge(test_options)
  end

  @doc """
  Attaches OpenAI plugin to a Req request.

  ## Options

    * `:api_key` - Required. Your OpenAI API key
    * `:base_url` - Optional. Base URL for the API (defaults to #{@default_base_url})
    * `:organization` - Optional. Your OpenAI organization ID
    * `:project` - Optional. Your OpenAI project ID
    * `:receive_timeout` - Optional. Timeout in ms (defaults to #{@default_receive_timeout})

  ## Examples

      # Attach to a new Req client
      client =
        Req.new()
        |> Otto.LLM.Providers.OpenAI.attach(api_key: "your-api-key")

      # Make requests to OpenAI API
      {:ok, response} = Req.post(client,
        url: "/v1/responses",
        json: %{model: "o3", input: "Hello!"}
      )
  """
  def attach(req, opts \\ []) do
    config = build_config(opts)

    req
    |> Req.Request.register_options([
      :openai_api_key,
      :openai_organization,
      :openai_project,
      :openai_errors
    ])
    |> Req.Request.append_request_steps(openai_auth: &put_auth_headers/1)
    |> Req.Request.append_response_steps(openai_errors: &handle_error/1)
    |> Req.merge(config)
    |> Base.maybe_attach_vcr(Otto.LLM.Providers.OpenAI.VCR)
  end

  defp build_config(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    organization = Keyword.get(opts, :organization)
    project = Keyword.get(opts, :project)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    Base.build_base_config(receive_timeout: receive_timeout)
    |> Keyword.merge([
      base_url: base_url,
      openai_api_key: api_key,
      openai_organization: organization,
      openai_project: project
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc false
  def put_auth_headers(request) do
    api_key = request.options[:openai_api_key]
    organization = request.options[:openai_organization]
    project = request.options[:openai_project]

    # Only add headers if api_key is present
    if api_key do
      request
      |> Base.put_header("authorization", "Bearer #{api_key}")
      |> Base.put_header("content-type", "application/json")
      |> Base.maybe_put_header("openai-organization", organization)
      |> Base.maybe_put_header("openai-project", project)
    else
      request
    end
  end

  @doc false
  def retry_with_timeout_errors(request, response_or_error) do
    case response_or_error do
      # OpenAI timeout errors that should be retryable
      %Otto.LLM.Providers.OpenAI.Error{status_code: 400, message: message} ->
        String.contains?(message, "Timeout while downloading")

      # Delegate to base retry logic
      _ ->
        Base.retry_with_timeout_errors(request, response_or_error)
    end
  end

  defp handle_error({request, response}) do
    case response do
      %{status: status, body: body} when status >= 400 ->
        error =
          case status do
            401 -> Otto.LLM.Providers.OpenAI.AuthenticationError.from_response(status, body, request)
            429 -> Otto.LLM.Providers.OpenAI.RateLimitError.from_response(status, body, request)
            _ -> Otto.LLM.Providers.OpenAI.Error.from_response(status, body, request)
          end

        {request, %{response | body: error}}

      _ ->
        {request, response}
    end
  end

  # Logging wrapper functions

  @doc """
  Logs an OpenAI API error.
  """
  def log_error(data, context \\ %{}) do
    Logger.error(data, [openai: true, event_type: "error"] ++ Map.to_list(context))
  end

  @doc """
  Logs an OpenAI API request.
  """
  def log_request(data, context \\ %{}) do
    Logger.info(data, [openai: true, event_type: "request"] ++ Map.to_list(context))
  end

  @doc """
  Logs an OpenAI API response.
  """
  def log_response(data, context \\ %{}) do
    Logger.info(data, [openai: true, event_type: "response"] ++ Map.to_list(context))
  end
end