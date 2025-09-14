# Otto Phase 0: AI Agent Foundation

Otto is an Elixir/OTP-native AI agent foundation that provides reliable, observable, and cost-controlled infrastructure for building AI-powered applications. Built on proven Elixir patterns (GenServers, Supervisors, process isolation), Otto enables rapid agent development with built-in safety and production-ready primitives.

## Quick Start

Get a working agent running in under 15 minutes:

### 1. Installation

```bash
git clone <repository>
cd otto
mix deps.get
mix ecto.create
mix ecto.migrate
```

### 2. Create Your First Agent

Create `.otto/agents/helper.yml`:

```yaml
name: "helpful_assistant"
description: "A general-purpose coding assistant"
system_prompt: "You are a helpful coding assistant. Be concise and accurate."
model: "claude-3-haiku-20240307"
tools: ["fs.read", "fs.write", "grep"]
working_dir: "."
budgets:
  time_seconds: 300      # 5 minutes max
  tokens: 10000          # 10k tokens
  cost_cents: 50         # $0.50 max cost
```

### 3. Start the System

```bash
# Start Phoenix server with Otto components
mix phx.server

# Or with IEx for debugging
iex -S mix phx.server
```

### 4. Invoke Your Agent

```elixir
# In IEx or your application
{:ok, agent} = Otto.Agent.start_agent("helper")
{:ok, result} = Otto.Agent.invoke(agent, "Read the README file and summarize it")
IO.puts(result.content)
```

## Architecture Overview

Otto is structured as an Elixir umbrella application with four main components:

```
Otto Umbrella
├── OttoLive     # Phoenix LiveView web interface
├── Otto.Agent   # Agent runtime and lifecycle management
├── Otto.Manager # Project management and orchestration
└── Otto.LLM     # LLM provider integrations and streaming
```

### Supervision Tree

```
Otto.Supervisor
├── Otto.Registry          # Agent process registry
├── Otto.ToolBus           # Tool discovery and management
├── Otto.AgentSupervisor   # Dynamic supervisor for agents
├── Otto.ContextStore      # ETS-based context storage
├── Otto.Checkpointer      # Filesystem artifact persistence
└── Otto.CostTracker       # Budget enforcement and monitoring
```

## Core Concepts

### Agents

Agents are supervised GenServer processes that encapsulate:
- **Configuration**: Model, tools, budgets, system prompts
- **Context**: Conversation history, working directory, permissions
- **Lifecycle**: Startup, invocation, checkpointing, shutdown

### Tools

Tools are discrete capabilities that agents can invoke:
- **Built-in Tools**: File operations, HTTP requests, testing, parsing
- **Custom Tools**: Implement `Otto.Tool` behaviour for domain-specific needs
- **Permissions**: Read/write/execute controls enforced at runtime
- **Sandboxing**: Working directory isolation and resource limits

### Budgets

Multi-dimensional cost controls prevent runaway execution:
- **Time**: Maximum execution duration (seconds)
- **Tokens**: Input + output token limits
- **Cost**: Dollar-based spending limits with real-time tracking

### Checkpointing

Every agent invocation produces auditable artifacts:
- **Transcripts**: Full conversation history with timestamps
- **Results**: Structured outputs with metadata
- **Intermediates**: Tool outputs and state snapshots

## Built-in Tools

Otto Phase 0 includes essential tools for most workflows:

| Tool | Purpose | Permissions |
|------|---------|-------------|
| `fs.read` | Read files with size limits | read |
| `fs.write` | Atomic file writes with backup | write |
| `grep` | Pattern search with ripgrep | read |
| `http` | HTTP requests with domain allowlist | exec |
| `json` | JSON parsing and generation | read/write |
| `yaml` | YAML parsing and generation | read/write |
| `test` | Execute `mix test` with timeout | exec |

## Configuration

### Agent Configuration

Agents are configured via YAML files in `.otto/agents/`:

```yaml
# .otto/agents/example.yml
name: "example_agent"
description: "Demonstrates Otto capabilities"
system_prompt: |
  You are a helpful assistant that can read and write files.
  Always explain your actions clearly.

model: "claude-3-haiku-20240307"
tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "test"

working_dir: "."
sandbox: true

budgets:
  time_seconds: 600
  tokens: 20000
  cost_cents: 100

tool_config:
  fs:
    max_file_size: 2097152  # 2MB
    backup_on_overwrite: true
  http:
    timeout_ms: 30000
    allowed_domains: ["api.example.com", "docs.example.com"]
  grep:
    max_results: 1000
    timeout_ms: 10000
```

### Environment Variables

```bash
# LLM Provider Configuration
ANTHROPIC_API_KEY=your_api_key_here

# Otto Configuration
OTTO_ENABLED=true
OTTO_CHECKPOINT_DIR=var/otto/sessions
OTTO_DEFAULT_BUDGET_CENTS=100
OTTO_MAX_CONCURRENT_AGENTS=50

# Safety Controls
OTTO_KILL_SWITCH=false
OTTO_AUDIT_MODE=false
```

## Development

### Running Tests

```bash
# Run all tests
mix test

# Run specific app tests
mix test apps/otto_agent/test

# Run with coverage
mix test --cover
```

### Adding Custom Tools

```elixir
defmodule MyApp.Tools.Database do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "database"

  @impl Otto.Tool
  def permissions, do: [:read, :write]

  @impl Otto.Tool
  def call(%{query: query}, %Otto.ToolContext{} = context) do
    # Your tool implementation
    case MyApp.Repo.all(query) do
      {:ok, results} -> {:ok, %{data: results}}
      {:error, reason} -> {:error, reason}
    end
  end
end

# Register your tool
Otto.ToolBus.register_tool(MyApp.Tools.Database)
```

### Local Development

```bash
# Start with live code reloading
mix phx.server

# Access web interface
open http://localhost:4000

# Access Tidewave AI assistant
open http://localhost:4000/tidewave

# Access LiveDashboard
open http://localhost:4000/dashboard
```

## API Reference

### Otto.Agent

```elixir
# Start an agent from config
{:ok, pid} = Otto.Agent.start_agent("agent_name")

# Invoke with a task
{:ok, result} = Otto.Agent.invoke(pid, "Your task description")

# Check agent status
status = Otto.Agent.get_status(pid)

# Stop agent
Otto.Agent.stop_agent(pid)
```

### Otto.ToolBus

```elixir
# List available tools
tools = Otto.ToolBus.list_tools()

# Get tool details
{:ok, tool} = Otto.ToolBus.get_tool("fs.read")

# Register new tool
Otto.ToolBus.register_tool(MyTool)
```

### Otto.CostTracker

```elixir
# Get current usage
usage = Otto.CostTracker.get_usage(:agent, "agent_name")

# Get usage for time range
usage = Otto.CostTracker.get_usage(:all, ~D[2024-01-01], ~D[2024-01-31])
```

## Monitoring & Observability

### Telemetry Events

Otto emits structured telemetry for monitoring:

```elixir
# Agent lifecycle
[:otto, :agent, :started]
[:otto, :agent, :invoked]
[:otto, :agent, :completed]
[:otto, :agent, :failed]
[:otto, :agent, :stopped]

# Tool usage
[:otto, :tool, :called]
[:otto, :tool, :completed]
[:otto, :tool, :failed]

# Budget tracking
[:otto, :budget, :warning]    # 80% consumed
[:otto, :budget, :exceeded]   # 100% consumed
```

### Metrics

Key metrics to monitor:

- **Invocation Rate**: Agents started per minute
- **Success Rate**: Successful vs failed invocations
- **Budget Utilization**: Cost/time/token usage by agent
- **Tool Usage**: Most/least used tools
- **Response Time**: P50, P95, P99 invocation latency

### Health Checks

```elixir
# System health endpoint
GET /health

# Agent status
{:ok, status} = Otto.Health.check_agent(agent_name)

# Tool availability
{:ok, status} = Otto.Health.check_tools()
```

## Security & Sandboxing

### Working Directory Isolation

Agents operate within configurable sandboxes:

```yaml
# Restrict to project directory
working_dir: "."
sandbox: true

# Allow specific paths
allowed_paths:
  - "src/"
  - "test/"
  - "docs/"

# Deny patterns
denied_patterns:
  - ".env*"
  - "**/*.key"
  - ".aws/"
```

### Permission Model

Tools declare required permissions:

- **read**: File system reads, HTTP GET
- **write**: File system writes, database mutations
- **exec**: Shell commands, test execution
- **network**: HTTP requests, external APIs

### Secrets Management

Never store credentials in agent configs:

```yaml
# DON'T DO THIS
api_key: "sk-1234567890abcdef"

# DO THIS - use runtime env vars
tool_config:
  http:
    headers:
      Authorization: "${API_KEY}"  # Interpolated at runtime
```

## Production Deployment

### Resource Requirements

Minimum recommended specs:
- **CPU**: 2 cores
- **RAM**: 4GB (2GB for Otto, 2GB for agents)
- **Disk**: 20GB (logs, checkpoints, artifacts)
- **Network**: Reliable internet for LLM API calls

### Scaling Guidelines

Single node capacity:
- **Concurrent Agents**: 100+
- **Daily Invocations**: 10,000+
- **Checkpoint Storage**: 100GB+
- **Context Storage**: 10GB ETS

### Deployment Checklist

- [ ] Environment variables configured
- [ ] Checkpoint directory exists with proper permissions
- [ ] LLM provider API keys valid
- [ ] Budget limits appropriate for environment
- [ ] Monitoring/logging configured
- [ ] Health checks responding
- [ ] Kill switch tested

## Troubleshooting

### Common Issues

**Agent won't start**
- Check agent config YAML syntax
- Verify all referenced tools are registered
- Ensure working directory exists and is readable

**Budget exceeded errors**
- Review cost/token/time budgets in config
- Check CostTracker usage data
- Consider optimizing system prompts

**Tool permission denied**
- Verify tool permissions in config
- Check working directory sandbox settings
- Review file/directory permissions

**LLM API failures**
- Verify API key is valid and has credit
- Check rate limits and retry logic
- Review network connectivity

### Debug Mode

Enable verbose logging:

```bash
OTTO_LOG_LEVEL=debug mix phx.server
```

Access IEx for runtime inspection:

```elixir
# List running agents
Otto.Registry.list_agents()

# Inspect agent state
{:ok, state} = Otto.Agent.get_state(agent_pid)

# View recent logs
Otto.Logger.get_recent(:agent, agent_name)
```

## Contributing

Otto is an open-source project welcoming contributions:

1. **Issues**: Report bugs, request features
2. **Code**: Submit pull requests with tests
3. **Documentation**: Improve guides and examples
4. **Tools**: Create and share custom tools

### Development Setup

```bash
git clone <repository>
cd otto
mix deps.get
mix test
mix credo --strict
mix dialyzer
```

### Code Standards

- All public functions have `@doc` with examples
- Test coverage > 80% for new code
- Follow Elixir community style guidelines
- Include typespecs for public APIs

## Roadmap

### Phase 1: Multi-Agent Orchestration
- Workflow DSL for agent coordination
- Router with auto-delegation
- Inter-agent communication patterns

### Phase 2: Advanced Integrations
- Additional LLM providers (OpenAI, Cohere, local models)
- Git integration tooling
- Database operation tools

### Phase 3: Enterprise Features
- RBAC and audit logging
- Multi-tenant isolation
- Horizontal scaling patterns

### Phase 4: User Experience
- Web UI with LiveView dashboard
- Visual workflow builder
- Real-time monitoring interface

## License

Apache 2.0 License - see LICENSE file for details.

---

**Questions?** Open an issue or start a discussion. Otto is designed to be approachable for developers new to AI agents while providing the foundation for production-ready systems.
