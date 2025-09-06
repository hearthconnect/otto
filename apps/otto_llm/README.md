# Otto.LLM

LLM client library for the Otto umbrella application. Provides a clean, extensible interface to multiple Large Language Model providers with comprehensive error handling, streaming support, and testing infrastructure.

## Architecture

Otto.LLM follows a provider-specific pattern built on the Req HTTP client:

- **`Otto.LLM.Client.Base`** - Shared functionality across all providers
- **`Otto.LLM.Providers.*`** - Provider-specific implementations  
- **`Otto.LLM.Router`** - Intelligent provider routing (future)

### Current Providers

- **OpenAI** - GPT models (GPT-4, GPT-3.5-turbo, etc.)

### Planned Providers  

- **Anthropic** - Claude models
- **Google** - Gemini models
- **Ollama** - Local models

## Development Setup

### Prerequisites

1. **API Keys**: Set `OPENAI_API_KEY` in your environment
   ```bash
   export OPENAI_API_KEY="your-key-here"
   ```

2. **Dependencies**: Run from Otto root directory
   ```bash
   mix deps.get
   ```

### Iterative Testing Workflow

Otto.LLM provides several test commands for efficient iterative development:

#### Unit Tests (Fast, No API calls)
```bash
# Run unit tests only - fast feedback loop
mix test.unit

# Quick failure mode - stops at first failure  
mix test.quick
```

#### Integration Tests (Live API calls)
```bash
# Run integration tests against live APIs
mix test.integration

# Run all tests (unit + integration)
mix test.all
```

#### Test Categories

- **Unit tests** - Mock/stub tests, no external dependencies
- **Integration tests** (tagged `:integration`) - Live API calls, requires API keys
- **Slow tests** (tagged `:slow`) - Longer-running tests, excluded by default

### Recommended Development Flow

1. **Red-Green-Refactor** with unit tests:
   ```bash
   mix test.quick          # Fast feedback on current feature
   ```

2. **Verify integration** periodically:
   ```bash
   mix test.integration    # Confirm API connectivity works
   ```

3. **Full test suite** before commits:
   ```bash
   mix test.all           # Comprehensive validation
   ```

### Example Usage

```elixir
# Build OpenAI client
client = Otto.LLM.Providers.OpenAI.build_client()

# Simple chat completion
{:ok, response} = Req.post(client,
  url: "/v1/chat/completions",
  json: %{
    model: "gpt-3.5-turbo",
    messages: [%{role: "user", content: "Hello!"}],
    max_tokens: 100
  }
)

# Extract response
choices = Map.get(response.body, "choices", [])
message = List.first(choices) |> Map.get("message")
content = Map.get(message, "content")
```

## Error Handling

Otto.LLM provides structured error handling with provider-specific exception types:

- `Otto.LLM.Providers.OpenAI.Error` - General API errors
- `Otto.LLM.Providers.OpenAI.AuthenticationError` - 401 authentication failures  
- `Otto.LLM.Providers.OpenAI.RateLimitError` - 429 rate limit exceeded

## Testing Strategy

### Unit Tests
- Mock HTTP requests using Req's built-in adapters
- Test error handling and edge cases
- Fast execution for tight development loops

### Integration Tests  
- Live API calls to verify connectivity
- Token usage tracking validation
- Model compatibility testing
- Graceful degradation testing

### Future: VCR Support
- Record/replay capabilities for deterministic testing
- Automatic request/response sanitization
- Support for streaming responses

## Configuration

Configure in your `config/*.exs` files:

```elixir
config :otto_llm, Otto.LLM.Providers.OpenAI,
  api_key: System.get_env("OPENAI_API_KEY"),
  req_options: []
```

## Contributing

1. Write unit tests first - they should pass without API keys
2. Add integration tests for new functionality  
3. Use the iterative testing commands for efficient development
4. Ensure all tests pass before submitting PRs

## Project Status

- ✅ Basic OpenAI client with error handling
- ✅ Integration test suite with live API validation  
- ✅ Iterative development workflow
- 🚧 VCR recording/playback system
- 📋 Additional provider implementations
- 📋 Smart routing between providers

