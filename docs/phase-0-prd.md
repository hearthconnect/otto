# Phase 0: Otto Foundation Components - Product Requirements Document

## Context & Why Now

**Problem**: Building reliable AI agent systems requires significant boilerplate - tool management, context isolation, budget control, and orchestration primitives. Current solutions lack OTP-native patterns and force developers into imperative, error-prone coordination logic.

**Opportunity**: Elixir/OTP provides ideal primitives (GenServers, Supervisors, process isolation) for agent runtime. Phase 0 establishes the minimal foundation to enable rapid agent development with built-in safety, observability, and cost control.

**Timing**: AI agent adoption is accelerating. Teams need production-ready foundations now, not complex frameworks. 80/20 approach delivers immediate value while preserving extensibility.

## Users & Jobs to Be Done

### Primary Users

**1. Elixir Developer Building AI Features**
- JTBD: "When I need to add AI capabilities to my Phoenix app, I want drop-in agent primitives so I can focus on business logic, not infrastructure."
- Pain: Writing LLM client code, managing tool permissions, tracking costs, handling failures

**2. Technical Lead Evaluating AI Agents**
- JTBD: "When exploring AI automation for my team, I want a controlled environment with clear budgets and audit trails so I can safely experiment without runaway costs."
- Pain: Unpredictable costs, lack of observability, security concerns with tool access

**3. Early Adopter Building Agent Workflows**
- JTBD: "When prototyping multi-step AI workflows, I want composable building blocks so I can iterate quickly without rewriting orchestration logic."
- Pain: Context management, state persistence, retry logic, tool integration

## Business Goals & Success Metrics

### Leading Indicators (Week 1-4)
- Time to first working agent: < 15 minutes from install
- Lines of code for basic agent: < 50 (YAML or Elixir)
- Tool integration time: < 30 minutes per tool
- Test coverage: > 80% for core modules

### Lagging Indicators (Month 2-3)
- Developer adoption: 10+ teams using foundation components
- Production deployments: 3+ apps running agents in production
- Cost predictability: 95% of invocations within budget limits
- Failure recovery: 99% of transient failures auto-recovered

### Business Impact
- Accelerate AI feature delivery by 3-5x
- Reduce AI infrastructure development cost by 70%
- Enable safe production AI deployment for risk-averse teams

## Functional Requirements

### 1. Otto.Tool Behaviour & ToolBus Registry

**Acceptance Criteria:**
- Define behaviour with name/0, permissions/0, call/2 callbacks
- ToolBus GenServer maintains registry of available tools
- Tools receive ToolContext with agent_config, working_dir, budget_guard
- Tool registration supports hot-reload without restart
- Permissions enforced at invocation time (read/write/exec)

### 2. Base Tool Implementations

**Acceptance Criteria:**
- **FS.Read**: Read files with configurable size limits (default 2MB)
- **FS.Write**: Write files with atomic operations, backup on overwrite
- **Grep**: Pattern search with ripgrep backend, timeout protection
- **HTTP**: GET/POST with timeout, rate limiting, domain allowlist
- **JSON/YAML**: Parse/generate with schema validation option
- **TestRunner**: Execute mix test with timeout, structured output parsing
- All tools respect working_dir sandbox when configured
- All tools emit telemetry events for observability

### 3. AgentConfig Struct & YAML Loader

**Acceptance Criteria:**
- AgentConfig struct with fields: name, description, model, tools, budgets, system_prompt
- YAML parser loads from .otto/agents/*.yml on startup
- Validation ensures required fields, valid tool references
- Support for environment variable interpolation in configs
- Conflict resolution: project-level overrides user-level configs

### 4. AgentServer GenServer

**Acceptance Criteria:**
- Start with AgentConfig, initialize context_id, budgets, transcript
- invoke/1 accepts TaskSpec, returns {:ok, result} or {:error, reason}
- Enforce time budget (default 5 min), token budget, cost budget ($)
- Capture full transcript with bounded memory (last N messages)
- Clean shutdown on budget exceeded or timeout
- Process isolation: crash doesn't affect other agents

### 5. LLM Client with Tool-Use Hooks

**Acceptance Criteria:**
- Provider-agnostic client behaviour (start with Anthropic)
- Streaming support with incremental tool call detection
- Tool execution hooks during streaming (not post-completion)
- Automatic retry with exponential backoff on rate limits
- Token counting and cost calculation per model
- Structured error types for different failure modes

### 6. ContextStore (ETS-based)

**Acceptance Criteria:**
- Per-agent context storage keyed by context_id
- Automatic cleanup on agent termination
- Support for metadata: task_id, parent_workflow, timestamps
- Bounded size with LRU eviction (configurable, default 100MB)
- Concurrent read access, serialized writes per context

### 7. Checkpointer (Filesystem)

**Acceptance Criteria:**
- Persist artifacts to var/otto/sessions/<session_id>/
- Atomic writes with temp file + rename pattern
- Support artifact types: transcript, result, intermediate
- Automatic directory creation with proper permissions
- Configurable retention policy (default 7 days)
- Return ArtifactRef with path, type, size, checksum

### 8. CostTracker

**Acceptance Criteria:**
- Track tokens (input/output) per invocation
- Calculate costs based on model pricing configuration
- Aggregate by agent, workflow, session
- Expose current usage via API: get_usage(scope, time_range)
- Emit warnings at 80% budget, hard stop at 100%
- Persist usage data for billing/reporting

### 9. Registry & DynamicSupervisor Wiring

**Acceptance Criteria:**
- Registry for agent process lookup by name/id
- DynamicSupervisor spawns AgentServer instances on demand
- Supervisor tree: Otto.Supervisor > [Registry, ToolBus, AgentSupervisor, ContextStore, Checkpointer, CostTracker]
- Graceful shutdown preserves in-flight work
- Restart strategies: permanent for infrastructure, transient for agents

## Non-Functional Requirements

### Performance
- Agent spawn time: < 50ms
- Tool invocation overhead: < 10ms
- Checkpoint write: < 100ms for artifacts up to 10MB
- Support 100+ concurrent agents per node

### Scale
- Handle 10,000 agent invocations/day on single node
- ContextStore: 10GB aggregate storage
- Checkpointer: 100GB artifact storage

### SLOs/SLAs
- System availability: 99.9% (excluding LLM provider downtime)
- Budget enforcement accuracy: 100% (never exceed limits)
- Data durability: 99.99% for checkpointed artifacts

### Privacy & Security
- No credential storage in configs (use runtime env vars)
- Tool permissions enforced at kernel level (no bypass)
- Sensitive data redaction in transcripts (configurable patterns)
- Working directory isolation between agents

### Observability
- Structured logs with correlation IDs (workflow > task > agent)
- Telemetry events for all state transitions
- Metrics: invocation count, duration, token usage, cost, errors
- Health endpoint exposing readiness/liveness

## Scope

### In Scope (Phase 0)
- Core behaviours and GenServers
- Base tool set (FS, HTTP, Test, Parse)
- Single-agent invocation API
- Local filesystem checkpointing
- Anthropic Claude provider
- Basic cost tracking
- YAML configuration

### Out of Scope (Future Phases)
- Multi-agent orchestration (Phase 1)
- Workflow DSL (Phase 1)
- Router with auto-delegation (Phase 1)
- Git integration (Phase 4)
- Database checkpointing (Phase 4)
- Web UI/LiveView dashboard (Phase 4)
- Additional LLM providers (Phase 2+)

## Rollout Plan

### Week 1-2: Core Infrastructure
- Otto.Tool behaviour + ToolBus
- AgentConfig + YAML loader
- AgentServer basic implementation
- Initial test suite

### Week 3: Tools & Integration
- Implement all base tools
- LLM client with Anthropic
- Tool-use streaming hooks
- Integration tests

### Week 4: Production Readiness
- ContextStore + Checkpointer
- CostTracker with budgets
- Supervisor tree wiring
- Documentation + examples

### Guardrails
- Feature flag: OTTO_ENABLED (default false)
- Budget limits: Hard-coded max $10/day initially
- Tool allowlist: Explicitly opt-in per tool
- Audit mode: Log-only before enforcement

### Kill Switch
- Environment variable: OTTO_KILL_SWITCH=true
- Graceful shutdown of in-flight work
- Disable new agent spawns
- Preserve checkpointed data

## Risks & Open Questions

### Technical Risks
- **LLM provider reliability** - Mitigation: Retry logic, circuit breakers, timeout protection
- **Memory growth from transcripts** - Mitigation: Bounded transcript size, automatic summarization
- **Runaway costs** - Mitigation: Hard budget limits, pre-flight cost estimation

### Open Questions
- Optimal transcript size before summarization trigger?
- Should tools support async execution patterns?
- How to handle multi-turn tool interactions efficiently?
- Best practice for secret management in agent configs?

### Dependencies
- Anthropic API availability and rate limits
- Filesystem permissions for checkpoint directory
- ripgrep binary for Grep tool

## Success Criteria Summary

Phase 0 succeeds when:
- Single developer can create and deploy a working agent in < 15 minutes
- All agent invocations respect budget limits with 100% accuracy
- System handles 1000 invocations/day without memory leaks or crashes
- Every invocation produces auditable artifacts and cost tracking
- Test coverage exceeds 80% with property-based tests for critical paths

## MVP Definition

The absolute minimum for Phase 0 launch:
- AgentServer that can invoke Anthropic Claude with a single tool
- FS.Read and FS.Write tools with basic sandbox
- YAML config loading for one agent definition
- Cost tracking with hard budget stop
- Filesystem checkpointing of results
- 50% test coverage of critical paths

This foundation enables teams to start building agents immediately while establishing patterns for safety, observability, and cost control that will scale through future phases.