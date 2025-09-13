# Otto Multi-Agent System - Phase 0 Implementation Plan

**Issue**: #1 - Implement Phase 0: Otto Multi-Agent System Foundations
**Branch**: issue-1-otto-multi-agent-foundations
**Status**: In Progress

## MVP Definition

Build foundational components for Otto, an Elixir/OTP-native multi-agent runtime providing AI agent capabilities with proper isolation, budgets, and tool access.

### Business Value
- 3-5x faster AI feature delivery for teams
- 70% reduction in infrastructure cost via shared runtime
- Enterprise-ready with budget controls and audit trails
- < 15 minutes to first working agent

## Core Components (Phase 0)

### 1. Tool System
- **Otto.Tool behaviour** - Pluggable tool interface
- **ToolBus GenServer** - Tool registration and permission checking
- **Base tools**: FS.Read, FS.Write, Grep, HTTP, JSON/YAML, TestRunner

### 2. Agent Management
- **AgentConfig struct** - YAML configuration loader and validation
- **AgentServer GenServer** - Main orchestrator with budgets and transcripts
- **Registry & DynamicSupervisor** - OTP supervision tree integration

### 3. LLM Integration
- **Enhanced LLM client** - Streaming responses with tool-use detection
- **Tool-use protocol** - Function calling with sandboxed execution

### 4. State Management
- **ContextStore** - Ephemeral context metadata (ETS-based)
- **Checkpointer** - Filesystem artifact persistence
- **CostTracker** - Usage aggregation by session/agent

## Implementation Architecture

### Supervision Tree
```
Otto.Manager.Supervisor
├── Registry (named: Otto.Registry)
├── DynamicSupervisor (named: Otto.AgentSupervisor)
├── Otto.Tool.Bus
├── Otto.Manager.ContextStore
├── Otto.Manager.Checkpointer
├── Otto.Manager.CostTracker
└── Task.Supervisor (named: Otto.TaskSupervisor)
```

### Directory Structure
```
.otto/
├── agents/           # Agent YAML definitions
├── prompts/          # Reusable system prompts
└── config.yml        # Global settings

var/otto/             # Runtime data (gitignored)
├── sessions/         # Session artifacts
└── logs/            # Structured logs
```

## Acceptance Criteria Checklist

### Functional Requirements
- [ ] Load agent configuration from YAML file in .otto/agents/
- [ ] Agent can read/write files within sandboxed working directory
- [ ] Agent can search files using grep tool (via ripgrep)
- [ ] Agent can make HTTP requests to allowlisted domains
- [ ] Agent can run mix tests and parse results
- [ ] LLM client supports tool-use with streaming responses
- [ ] Time, token, and cost budgets enforced with clean shutdown
- [ ] Artifacts checkpointed to filesystem in var/otto/sessions/
- [ ] Cost tracking aggregates usage by session/agent

### Core Components
- [ ] **Otto.Tool behaviour** defined with pluggable tool system
- [ ] **ToolBus GenServer** for tool registration and permission checking
- [ ] **Base tools implemented**: FS.Read, FS.Write, Grep, HTTP, JSON/YAML, TestRunner
- [ ] **AgentConfig struct** with YAML loader and validation
- [ ] **AgentServer GenServer** with invoke/1, budgets, and transcript capture
- [ ] **LLM client enhanced** with streaming and tool-use hooks
- [ ] **ContextStore** for ephemeral context metadata
- [ ] **Checkpointer** for filesystem artifact persistence
- [ ] **CostTracker** for usage aggregation
- [ ] **Registry and DynamicSupervisor** wiring

### Non-Functional Requirements
- [ ] Agent startup time < 500ms
- [ ] Tool execution overhead < 100ms
- [ ] Memory usage < 50MB per agent
- [ ] Graceful failure handling in supervision tree
- [ ] 80% test coverage on critical paths

### Developer Experience
- [ ] Create new agent via YAML in < 5 minutes
- [ ] Clear, actionable error messages
- [ ] Public APIs documented with examples
- [ ] Example agents (engineer, reviewer) working end-to-end

## Dependencies

### New Dependencies to Add
- `yaml_elixir ~> 2.9` - For YAML configuration parsing
- `nimble_options ~> 1.0` - For configuration validation

### System Requirements
- ripgrep binary (rg) installed for search functionality
- Elixir 1.18+ (already in project)
- File system access to project directory

## Technical Constraints
- Phase 0 uses filesystem storage only (no database required)
- No shell execution for security (only specific commands via System.cmd)
- HTTP requests limited to allowlisted domains
- File operations sandboxed to working directories

## Implementation Timeline

### Week 1: Foundation
1. Tool behaviour and ToolBus (8-12 hrs)
2. Base tools implementation (16-24 hrs)
3. Agent configuration with YAML loader (8-12 hrs)

### Week 2: Core Components
1. AgentServer GenServer (16-20 hrs)
2. LLM client enhancements (12-16 hrs)
3. State management (ContextStore, Checkpointer, CostTracker) (14-20 hrs)

### Week 3: Integration & Polish
1. Registry and supervision wiring (8-10 hrs)
2. Remaining tools and testing (16-20 hrs)
3. Documentation and examples (8-10 hrs)

## Risk Mitigations
- **LLM Streaming**: Start with request/response, add streaming after core works
- **Tool Security**: Strict sandboxing, no shell execution, file ops restricted to working dir
- **Budget Overruns**: Hard limits enforced, automatic cancellation, conservative defaults
- **Memory Growth**: Bounded transcripts, periodic cleanup, telemetry monitoring

## Otto Usage Rules Applied

From `/Users/jeffdeville/projects/otto/otto/CLAUDE.md`:

### Phoenix LiveView Patterns
- Use LiveView for interactive UI components (agent status monitoring)
- Components in `lib/otto_live_web/components/`
- Follow Phoenix 1.8+ patterns

### Ecto Patterns
- Use Repo transactions for multi-step operations
- Schemas in appropriate namespace (Otto.Manager for manager components)

### OTP Supervision
- Each Otto app has its own application module
- Use standard OTP supervision patterns
- Child specs in respective application modules

### Umbrella App Structure
- Root `mix.exs` contains only development dependencies
- Each app has its own dependencies in their respective `mix.exs`
- Each app can be developed and tested independently

## Development Progress

**Current Status**: Planning phase complete, launching parallel implementation teams

### Parallel Agent Tasks
- **Tech Lead**: MVP planning and file-impact mapping
- **Backend Implementer**: OTP components and supervision tree
- **Test Engineer**: Red→Green test development
- **Code Reviewer**: Continuous diff review for quality and scope
- **QA Analyst**: Manual verification against acceptance criteria
- **Docs Writer**: API documentation and usage examples

### Next Steps
1. Implement core Tool behaviour and ToolBus
2. Build base tools (FS, Grep, HTTP, Test)
3. Create AgentConfig with YAML support
4. Implement AgentServer GenServer
5. Add state management components
6. Wire up supervision tree
7. Integration testing and polish