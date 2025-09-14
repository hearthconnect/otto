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

---

# REFINED IMPLEMENTATION STRATEGY

## 1. File Impact Map

### NEW FILES TO CREATE

#### Core Tool System (`apps/otto_manager/lib/otto/tool/`)
- `tool.ex` - Otto.Tool behaviour definition (40 lines)
- `bus.ex` - Otto.Tool.Bus GenServer for registration/permissions (120 lines)
- `fs/read.ex` - Otto.Tool.FS.Read implementation (80 lines)
- `fs/write.ex` - Otto.Tool.FS.Write implementation (90 lines)
- `grep.ex` - Otto.Tool.Grep implementation via ripgrep (100 lines)
- `http.ex` - Otto.Tool.HTTP implementation (110 lines)
- `json_yaml.ex` - Otto.Tool.JsonYaml parsing tool (70 lines)
- `test_runner.ex` - Otto.Tool.TestRunner for mix tests (130 lines)

#### Agent System (`apps/otto_manager/lib/otto/agent/`)
- `config.ex` - Otto.Agent.Config struct + YAML loader (150 lines)
- `server.ex` - Otto.Agent.Server GenServer orchestrator (200 lines)
- `session.ex` - Otto.Agent.Session state container (80 lines)
- `budget.ex` - Otto.Agent.Budget tracker/enforcer (100 lines)

#### State Management (`apps/otto_manager/lib/otto/manager/`)
- `context_store.ex` - Otto.Manager.ContextStore ETS-based storage (90 lines)
- `checkpointer.ex` - Otto.Manager.Checkpointer filesystem persistence (110 lines)
- `cost_tracker.ex` - Otto.Manager.CostTracker usage aggregation (120 lines)

#### Configuration Structure
- `.otto/agents/engineer.yml` - Example agent configuration (30 lines)
- `.otto/agents/reviewer.yml` - Example agent configuration (25 lines)
- `.otto/config.yml` - Global Otto settings (20 lines)
- `.otto/prompts/base.txt` - Base system prompt template (40 lines)

#### LLM Enhancement (`apps/otto_llm/lib/otto/llm/`)
- `tool_use.ex` - Otto.LLM.ToolUse protocol for function calling (160 lines)
- `streaming.ex` - Otto.LLM.Streaming response handler (140 lines)

### FILES TO MODIFY

#### Supervision Tree Updates
- `apps/otto_manager/lib/otto/manager/application.ex` - Add supervision children (15 line change)
- `apps/otto_manager/mix.exs` - Add yaml_elixir, nimble_options deps (3 line change)

#### Root Configuration
- `mix.exs` - Add ripgrep to system dependencies comment (2 line change)
- `.gitignore` - Add var/otto/ entries (2 line change)

## 2. MVP Definition

### MUST SHIP (Phase 0 Core)
✅ **Agent Creation**: Load YAML config, start agent process in < 500ms
✅ **Tool Execution**: FS.Read, FS.Write, Grep working with sandboxing
✅ **Budget Enforcement**: Time/token limits with graceful shutdown
✅ **LLM Integration**: Request/response with tool-use detection
✅ **State Persistence**: Session artifacts saved to filesystem
✅ **Example Working**: `engineer.yml` agent completes file modification task

### NICE-TO-HAVE (Phase 1+)
❌ **Streaming Responses**: Start with request/response, add streaming later
❌ **Advanced Tools**: HTTP, TestRunner, JsonYaml (defer if time constrained)
❌ **LiveView UI**: CLI-first approach, web interface in Phase 1
❌ **Complex Budgets**: Start with simple time limits, add token/cost later
❌ **Multi-agent**: Single agent orchestration first, parallelism later

## 3. Implementation Chunks (6 Parallel Workstreams)

### Chunk A: Tool Foundation (10-12 hrs)
**Owner**: Backend Implementer
**Files**: `tool.ex`, `bus.ex`, `fs/read.ex`, `fs/write.ex`
**Output**: Basic tool system with file I/O
**Blockers**: None

### Chunk B: Core Tools (12-14 hrs)
**Owner**: Backend Implementer
**Dependencies**: Chunk A complete
**Files**: `grep.ex`, `http.ex`, `json_yaml.ex`, `test_runner.ex`
**Output**: Full tool suite implemented

### Chunk C: Agent Configuration (8-10 hrs)
**Owner**: Backend Implementer
**Files**: `config.ex`, `.otto/` structure, YAML examples
**Output**: YAML loading and validation working
**Blockers**: None

### Chunk D: Agent Orchestration (14-16 hrs)
**Owner**: Backend Implementer
**Dependencies**: Chunks A & C complete
**Files**: `server.ex`, `session.ex`, `budget.ex`
**Output**: Agent lifecycle management

### Chunk E: LLM Enhancement (10-12 hrs)
**Owner**: Backend Implementer
**Files**: `tool_use.ex` in otto_llm app
**Output**: Function calling capability
**Blockers**: None (uses existing otto_llm base)

### Chunk F: State Management (12-14 hrs)
**Owner**: Backend Implementer
**Files**: `context_store.ex`, `checkpointer.ex`, `cost_tracker.ex`
**Output**: Persistence and cost tracking
**Blockers**: None

### Chunk G: Supervision Integration (6-8 hrs)
**Owner**: Backend Implementer
**Dependencies**: All chunks A-F complete
**Files**: Modify `application.ex`, wire up supervision tree
**Output**: Full system integration

### Chunk H: Testing & Examples (16-20 hrs)
**Owner**: Test Engineer
**Files**: Test files, integration scenarios, example workflows
**Output**: 80% test coverage, working examples
**Parallel**: Can start early with TDD approach

## 4. Critical Integration Points

### 1. Tool System ↔ Agent Server
**Integration**: Tool.Bus registration must happen before Agent.Server starts
**Risk**: Tool permission checking during agent execution
**Mitigation**: Well-defined tool registration API, clear error handling

### 2. LLM ↔ Tool Execution
**Integration**: otto_llm tool-use parsing must trigger otto_manager tool calls
**Risk**: Function calling protocol mismatch
**Mitigation**: Standardized tool schema, comprehensive integration tests

### 3. Budget Enforcement ↔ All Systems
**Integration**: Budget checks in tool execution, LLM calls, state operations
**Risk**: Budget overruns due to async operations
**Mitigation**: Synchronous budget checks, aggressive timeouts

### 4. State Management ↔ Agent Sessions
**Integration**: Context/checkpoints must persist across agent restarts
**Risk**: State corruption or data loss
**Mitigation**: Atomic filesystem operations, recovery procedures

### 5. Supervision Tree ↔ Agent Lifecycle
**Integration**: DynamicSupervisor must handle agent crashes gracefully
**Risk**: Resource leaks or zombie processes
**Mitigation**: Proper GenServer cleanup, test supervision failures

## 5. Technical Risk Assessment

### HIGH RISK 🔴
**Tool Security Sandbox**: File operations restricted to working directory
- *Risk*: Path traversal attacks, unauthorized file access
- *Mitigation*: Path validation, chroot-like restrictions, comprehensive security tests
- *Owner*: Backend Implementer
- *Timeline*: Must be solved in Chunk A

**Budget Enforcement Races**: Async tool calls vs budget limits
- *Risk*: Cost overruns, infinite loops, resource exhaustion
- *Mitigation*: Sync budget checks, hard timeouts, circuit breakers
- *Owner*: Backend Implementer
- *Timeline*: Critical for Chunk D

### MEDIUM RISK 🟡
**YAML Configuration Validation**: Complex agent configs with unclear errors
- *Risk*: Poor developer experience, hard-to-debug failures
- *Mitigation*: Comprehensive validation, clear error messages, schema examples
- *Owner*: Backend Implementer
- *Timeline*: Handle in Chunk C

**LLM Tool-Use Protocol**: OpenAI function calling integration
- *Risk*: Function schema mismatches, parsing failures
- *Mitigation*: Start simple, comprehensive tool calling tests, fallback handling
- *Owner*: Backend Implementer
- *Timeline*: Primary focus for Chunk E

### LOW RISK 🟢
**Performance Targets**: < 500ms startup, < 100ms tool overhead
- *Risk*: Slow agent initialization
- *Mitigation*: ETS for fast lookups, minimize supervision tree depth
- *Timeline*: Measure during integration (Chunk G)

**Test Coverage 80%**: Achieving comprehensive test coverage
- *Risk*: Insufficient testing leading to production issues
- *Mitigation*: TDD approach, integration test focus
- *Owner*: Test Engineer
- *Timeline*: Parallel to all development chunks

## 6. Success Metrics & Checkpoints

### Week 1 Checkpoint
- [ ] Tool system foundation working (Chunks A, C complete)
- [ ] Agent can load YAML config and execute basic file tools
- [ ] Security sandbox prevents path traversal
- [ ] < 15 minutes from YAML to working agent

### Week 2 Checkpoint
- [ ] Full tool suite implemented (Chunk B complete)
- [ ] Agent orchestration handles budgets (Chunk D complete)
- [ ] LLM function calling working (Chunk E complete)
- [ ] Example engineer agent completes file modification task

### Week 3 Checkpoint (MVP Complete)
- [ ] State management operational (Chunk F complete)
- [ ] Full supervision tree integrated (Chunk G complete)
- [ ] 80% test coverage achieved (Chunk H complete)
- [ ] Performance targets met: < 500ms startup, < 100ms tool overhead
- [ ] Security review passed for tool sandboxing

## Development Progress

**Current Status**: Tech lead analysis complete, ready for parallel implementation

### Next Actions (Start Immediately)
1. **Chunk A**: Begin tool behaviour and basic file tools
2. **Chunk C**: Begin YAML configuration system
3. **Chunk H**: Begin TDD test development in parallel
4. **Chunk E**: Begin LLM tool-use enhancement (leverages existing otto_llm)

### Dependency Chain
```
Chunk A (Tools) → Chunk B (More Tools)
     ↓
Chunk D (Agent Server) → Chunk G (Integration)
     ↑
Chunk C (Config)

Chunk E (LLM) ─┐
Chunk F (State) ┴→ Chunk G (Integration)

Chunk H (Tests) → Continuous validation
```