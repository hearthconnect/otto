defmodule Otto.LLM do
  @moduledoc """
  Main interface for Large Language Model operations.

  This module provides a unified interface for interacting with various LLM providers
  like OpenAI, Anthropic, etc. It handles message formatting, token counting, and
  response processing.

  ## Basic Usage

      # Simple completion
      {:ok, response} = Otto.LLM.complete("gpt-4", "Hello, how are you?")
      IO.puts(response.content)

      # Chat with conversation history
      messages = [
        %{role: "system", content: "You are a helpful assistant"},
        %{role: "user", content: "What's the weather like?"}
      ]
      {:ok, response} = Otto.LLM.chat("gpt-4", messages)

  ## Configuration

  Configure your API keys in config/config.exs:

      config :otto_llm, Otto.LLM.Providers.OpenAI,
        api_key: System.get_env("OPENAI_API_KEY")

  """

  @type message :: %{
    role: String.t(),
    content: String.t()
  }

  @type chat_response :: %{
    content: String.t(),
    model: String.t(),
    usage: %{
      prompt_tokens: integer(),
      completion_tokens: integer(),
      total_tokens: integer()
    },
    finish_reason: String.t()
  }

  @type completion_opts :: [
    max_tokens: integer(),
    temperature: float(),
    system_prompt: String.t(),
    functions: [map()],
    function_call: String.t() | map()
  ]

  @doc """
  Perform a simple text completion.

  ## Parameters

  - `model` - The model to use (e.g., "gpt-4", "gpt-3.5-turbo")
  - `prompt` - The prompt text
  - `opts` - Optional parameters like max_tokens, temperature, etc.

  ## Examples

      {:ok, response} = Otto.LLM.complete("gpt-4", "Hello, how are you?")
      {:ok, response} = Otto.LLM.complete("gpt-4", "Explain AI", max_tokens: 100)

  """
  @spec complete(String.t(), String.t(), completion_opts()) :: {:ok, chat_response()} | {:error, term()}
  def complete(model, prompt, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant.")

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]

    chat(model, messages, opts)
  end

  @doc """
  Perform a chat completion with conversation history.

  ## Parameters

  - `model` - The model to use (e.g., "gpt-4", "gpt-3.5-turbo")
  - `messages` - List of message maps with :role and :content
  - `opts` - Optional parameters

  ## Examples

      messages = [
        %{role: "system", content: "You are a helpful assistant"},
        %{role: "user", content: "What's the capital of France?"},
        %{role: "assistant", content: "The capital of France is Paris."},
        %{role: "user", content: "What about Germany?"}
      ]
      {:ok, response} = Otto.LLM.chat("gpt-4", messages)

  """
  @spec chat(String.t(), [message()], completion_opts()) :: {:ok, chat_response()} | {:error, term()}
  def chat(model, messages, opts \\ []) do
    case detect_provider(model) do
      :openai -> Otto.LLM.Providers.OpenAI.chat_completion(model, messages, opts)
      :anthropic -> {:error, :provider_not_implemented}
      :unknown -> {:error, {:unknown_model, model}}
    end
  end

  @doc """
  Get available models for a provider.

  ## Examples

      {:ok, models} = Otto.LLM.list_models(:openai)

  """
  @spec list_models(:openai | :anthropic) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(:openai) do
    Otto.LLM.Providers.OpenAI.list_models()
  end
  def list_models(:anthropic) do
    {:error, :provider_not_implemented}
  end

  # Private functions

  defp detect_provider(model) do
    cond do
      String.starts_with?(model, "gpt-") or String.starts_with?(model, "o1-") -> :openai
      String.starts_with?(model, "claude-") -> :anthropic
      true -> :unknown
    end
  end
end
