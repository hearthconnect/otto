# Otto Manager - Core OTP Components

This document provides an overview of the core OTP components implemented for Otto Phase 0.

## Architecture Overview

Otto Manager implements a supervision tree with the following core components:

### 1. Tool System Foundation

- **Otto.Tool Behaviour** (`lib/otto/tool/tool.ex`)
  - Defines callbacks: `execute/2`, `validate_args/1`, `sandbox_config/0`
  - Type specifications for tool arguments, results, and sandbox configuration
  - Provides `__using__` macro for easy tool implementation

- **Otto.Tool.Bus GenServer** (`lib/otto/tool/bus.ex`)
  - Centralized tool registration and permission management
  - ETS-based fast lookups for tools and permissions
  - Tool execution with sandboxing and telemetry support
  - Permission checking per agent per tool

### 2. Supervision Tree

- **Otto.Manager.Supervisor** (`lib/otto/manager/supervisor.ex`)
  - Main supervisor managing all Otto components
  - Registry for process naming using `{:via, Registry, {Otto.Registry, {type, id}}}`
  - DynamicSupervisor for agent lifecycle management
  - TaskSupervisor for async operations
  - Helper functions for agent management

### 3. State Management GenServers

- **Otto.Manager.ContextStore** (`lib/otto/manager/context_store.ex`)
  - ETS-based ephemeral storage for agent contexts and session data
  - TTL-based expiration with automatic cleanup
  - Support for complex data manipulation (lists, nested fields)
  - Memory-efficient with configurable cleanup intervals

- **Otto.Manager.Checkpointer** (`lib/otto/manager/checkpointer.ex`)
  - Filesystem-based persistence for agent states and checkpoints
  - JSON serialization with metadata
  - Organized storage by agent ID and checkpoint name
  - Automatic cleanup of old checkpoints
  - Full CRUD operations with error handling

- **Otto.Manager.CostTracker** (`lib/otto/manager/cost_tracker.ex`)
  - Usage aggregation for tools, LLM requests, and storage operations
  - ETS-based storage with time-based analytics
  - Cost breakdown by agent, tool, and time period
  - Global statistics and top usage reporting

## Updated Application Structure

- **Otto.Manager.Application** (`lib/otto/manager/application.ex`)
  - Updated to use the new supervision tree
  - Starts all core components in proper dependency order

## Key Features

### Process Management
- All components use proper OTP supervision patterns
- Registry-based process naming for clean lookups
- Graceful shutdown and cleanup handling
- Restart strategies configured for resilience

### Security & Sandboxing
- Tool permission system with agent-specific grants
- Sandbox configuration for tool execution isolation
- Argument validation before execution
- Error isolation and proper logging

### Performance
- ETS tables for fast lookups and data access
- Configurable cleanup intervals to prevent memory leaks
- Efficient data structures for time-series analytics
- Read concurrency optimization where appropriate

### Observability
- Comprehensive logging throughout the system
- Telemetry hooks for monitoring (graceful fallback when unavailable)
- Statistics APIs for operational insights
- Error tracking and metrics collection

## Testing

The implementation includes comprehensive tests:
- Unit tests for each GenServer (`test/otto/manager/`)
- Integration tests demonstrating component interaction (`test/integration_test.exs`)
- Application startup verification (`test/otto/manager/application_test.exs`)

All tests pass and demonstrate the system's functionality without external dependencies.

## Usage Example

```elixir
# Register a tool
:ok = Otto.Tool.Bus.register_tool(Otto.Tool.Bus, "my_tool", MyTool)

# Grant permission to an agent
:ok = Otto.Tool.Bus.grant_permission(Otto.Tool.Bus, "agent_123", "my_tool")

# Execute tool
context = %{agent_id: "agent_123", session_id: "session_456"}
{:ok, result} = Otto.Tool.Bus.execute_tool(Otto.Tool.Bus, "my_tool", %{"param" => "value"}, context)

# Store context
:ok = Otto.Manager.ContextStore.put(Otto.Manager.ContextStore, "session_456", %{messages: []})

# Track costs
:ok = Otto.Manager.CostTracker.record_tool_usage(Otto.Manager.CostTracker, %{
  agent_id: "agent_123",
  tool_name: "my_tool",
  execution_time_ms: 150,
  tokens_used: 100
})
```

This implementation provides the foundational OTP infrastructure for Otto's agent system with proper supervision, state management, and monitoring capabilities.

