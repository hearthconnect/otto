defmodule Otto.LLM.Client.Base do
  @moduledoc """
  Base functionality shared across all LLM provider clients.
  
  Provides common patterns for:
  - Req plugin architecture
  - Error handling
  - Retry logic
  - VCR integration
  - Usage tracking
  """

  require Logger

  @doc """
  Builds a base Req configuration with common settings.
  """
  def build_base_config(opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)

    [
      receive_timeout: receive_timeout,
      retry: &retry_with_timeout_errors/2,
      max_retries: 3
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Common retry logic for transient errors across providers.
  """
  def retry_with_timeout_errors(_request, response_or_error) do
    case response_or_error do
      # Standard transient errors
      %{status: status} when status in [408, 429, 500, 502, 503, 504] ->
        true

      # Network/transport errors
      %Req.TransportError{reason: reason} when reason in [:timeout, :econnrefused, :closed] ->
        true

      # HTTP/2 errors
      %Req.HTTPError{protocol: :http2, reason: :unprocessed} ->
        true

      # Default: don't retry
      _ ->
        false
    end
  end

  @doc """
  Puts a header in the request, handling the Req header format.
  """
  def put_header(request, name, value) do
    %{request | headers: Map.put(request.headers, name, [value])}
  end

  @doc """
  Conditionally puts a header if the value is present.
  """
  def maybe_put_header(request, name, value) when is_binary(value) do
    put_header(request, name, value)
  end

  def maybe_put_header(request, _name, _value), do: request

  @doc """
  Conditionally attaches VCR plugin if available and enabled.
  """
  def maybe_attach_vcr(req, vcr_module) do
    if Code.ensure_loaded?(vcr_module) and vcr_module.enabled?() do
      vcr_module.attach(req)
    else
      req
    end
  end
end