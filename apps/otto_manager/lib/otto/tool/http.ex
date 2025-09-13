defmodule Otto.Tool.HTTP do
  @moduledoc """
  Tool for making HTTP requests with domain allowlisting and security controls.

  This tool provides HTTP client capabilities with strict domain validation
  to ensure requests can only be made to pre-approved domains. Includes
  request/response size limits and timeout controls.
  """

  use Otto.Tool
  require Logger

  @max_response_size 50 * 1024 * 1024  # 50 MB
  @max_request_size 10 * 1024 * 1024   # 10 MB
  @default_timeout 30_000

  @impl Otto.Tool
  def execute(args, context) do
    with :ok <- validate_args(args),
         {:ok, url} <- get_url(args),
         {:ok, method} <- get_method(args),
         {:ok, allowed_domains} <- get_allowed_domains(context),
         :ok <- validate_domain_allowed(url, allowed_domains),
         {:ok, headers} <- get_headers(args),
         {:ok, body} <- get_body(args),
         {:ok, options} <- get_options(args),
         {:ok, response} <- make_http_request(method, url, body, headers, options, context) do

      Logger.info("HTTP request completed",
        session_id: Map.get(context, :session_id),
        method: method,
        url: scrub_url_for_logging(url),
        status_code: response.status_code,
        response_size: byte_size(response.body)
      )

      {:ok, %{
        url: url,
        method: String.upcase(to_string(method)),
        status_code: response.status_code,
        headers: format_response_headers(response.headers),
        body: response.body,
        size: byte_size(response.body)
      }}
    else
      {:error, reason} ->
        Logger.warning("HTTP request failed",
          session_id: Map.get(context, :session_id),
          method: Map.get(args, "method", "GET"),
          url: scrub_url_for_logging(Map.get(args, "url", "")),
          reason: reason
        )
        {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_args(args) do
    with {:ok, _} <- validate_url(args),
         {:ok, _} <- validate_method(args),
         :ok <- validate_headers(args),
         :ok <- validate_body(args) do
      :ok
    end
  end

  @impl Otto.Tool
  def sandbox_config do
    %{
      timeout: @default_timeout + 10_000,  # Add buffer for cleanup
      memory_limit: 100 * 1024 * 1024,     # 100 MB
      filesystem_access: :none,
      network_access: true
    }
  end

  @impl Otto.Tool
  def metadata do
    %{
      name: "http",
      description: "Make HTTP requests to allowlisted domains",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "URL to make the request to (must be in allowed domains)"
          },
          "method" => %{
            "type" => "string",
            "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"],
            "description" => "HTTP method",
            "default" => "GET"
          },
          "headers" => %{
            "type" => "object",
            "description" => "HTTP headers as key-value pairs",
            "default" => %{}
          },
          "body" => %{
            "type" => "string",
            "description" => "Request body (for POST, PUT, PATCH methods)"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Request timeout in milliseconds",
            "minimum" => 1000,
            "maximum" => 60000,
            "default" => @default_timeout
          },
          "follow_redirects" => %{
            "type" => "boolean",
            "description" => "Follow HTTP redirects",
            "default" => true
          }
        },
        "required" => ["url"]
      },
      examples: [
        %{
          "description" => "GET request to an API",
          "args" => %{
            "url" => "https://api.example.com/data",
            "method" => "GET",
            "headers" => %{"Accept" => "application/json"}
          },
          "result" => %{
            "url" => "https://api.example.com/data",
            "method" => "GET",
            "status_code" => 200,
            "headers" => %{"content-type" => "application/json"},
            "body" => "{\"data\": \"example\"}",
            "size" => 20
          }
        },
        %{
          "description" => "POST request with JSON body",
          "args" => %{
            "url" => "https://api.example.com/submit",
            "method" => "POST",
            "headers" => %{"Content-Type" => "application/json"},
            "body" => "{\"key\": \"value\"}"
          },
          "result" => %{
            "url" => "https://api.example.com/submit",
            "method" => "POST",
            "status_code" => 201,
            "headers" => %{"content-type" => "application/json"},
            "body" => "{\"id\": 123}",
            "size" => 11
          }
        }
      ],
      version: "1.0.0"
    }
  end

  # Private helper functions

  defp validate_url(args) do
    case Map.get(args, "url") do
      nil ->
        {:error, "url parameter is required"}

      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            {:ok, url}

          _ ->
            {:error, "url must be a valid HTTP or HTTPS URL"}
        end

      _ ->
        {:error, "url must be a string"}
    end
  end

  defp validate_method(args) do
    case Map.get(args, "method", "GET") do
      method when method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] ->
        {:ok, String.downcase(method)}

      method when is_binary(method) ->
        upper_method = String.upcase(method)
        if upper_method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] do
          {:ok, String.downcase(method)}
        else
          {:error, "unsupported HTTP method: #{method}"}
        end

      _ ->
        {:error, "method must be a string"}
    end
  end

  defp validate_headers(args) do
    case Map.get(args, "headers", %{}) do
      headers when is_map(headers) ->
        # Check that all header names and values are strings
        invalid_headers =
          headers
          |> Enum.reject(fn {k, v} -> is_binary(k) and is_binary(v) end)

        if Enum.empty?(invalid_headers) do
          :ok
        else
          {:error, "all header names and values must be strings"}
        end

      _ ->
        {:error, "headers must be an object"}
    end
  end

  defp validate_body(args) do
    case Map.get(args, "body") do
      nil ->
        :ok

      body when is_binary(body) ->
        if byte_size(body) > @max_request_size do
          {:error, "request body too large (max #{@max_request_size} bytes)"}
        else
          :ok
        end

      _ ->
        {:error, "body must be a string"}
    end
  end

  defp get_url(args) do
    {:ok, Map.get(args, "url")}
  end

  defp get_method(args) do
    method = Map.get(args, "method", "GET")
    {:ok, String.downcase(method) |> String.to_atom()}
  end

  defp get_allowed_domains(context) do
    case Map.get(context, :allowed_domains) do
      domains when is_list(domains) ->
        {:ok, domains}

      nil ->
        {:ok, []}  # No domains allowed by default

      _ ->
        {:error, "invalid allowed_domains configuration"}
    end
  end

  defp validate_domain_allowed(url, allowed_domains) do
    if Enum.empty?(allowed_domains) do
      {:error, "no HTTP domains are allowed for this agent"}
    else
      %URI{host: host} = URI.parse(url)

      if host in allowed_domains do
        :ok
      else
        {:error, "domain '#{host}' is not in the allowed domains list"}
      end
    end
  end

  defp get_headers(args) do
    headers = Map.get(args, "headers", %{})
    # Convert to list of tuples for HTTPoison
    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)
    {:ok, header_list}
  end

  defp get_body(args) do
    {:ok, Map.get(args, "body", "")}
  end

  defp get_options(args) do
    timeout = Map.get(args, "timeout", @default_timeout)
    follow_redirects = Map.get(args, "follow_redirects", true)

    options = [
      timeout: timeout,
      recv_timeout: timeout,
      follow_redirect: follow_redirects,
      max_body_length: @max_response_size
    ]

    {:ok, options}
  end

  defp make_http_request(method, url, body, headers, options, context) do
    case HTTPoison.request(method, url, body, headers, options) do
      {:ok, %HTTPoison.Response{} = response} ->
        if byte_size(response.body) > @max_response_size do
          {:error, "response too large (max #{@max_response_size} bytes)"}
        else
          {:ok, response}
        end

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, "request timeout"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("HTTP request exception",
        session_id: Map.get(context, :session_id),
        error: inspect(error)
      )
      {:error, "request execution failed"}
  end

  defp format_response_headers(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
    |> Enum.into(%{})
  end

  defp scrub_url_for_logging(url) when is_binary(url) do
    # Remove sensitive query parameters and auth info for logging
    case URI.parse(url) do
      %URI{} = uri ->
        %{uri | userinfo: nil, query: nil}
        |> URI.to_string()

      _ ->
        "[invalid-url]"
    end
  end

  defp scrub_url_for_logging(_), do: "[invalid-url]"
end