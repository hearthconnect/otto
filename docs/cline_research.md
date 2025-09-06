Title: Cline (aka “Klein”) Architecture Research for a Generic Multi‑Agent System

Executive Summary
- Cline packages a single-agent software-dev assistant around a clear core: a Controller (composition root) and a Task (agent-like session) that orchestrate LLM prompting, tool execution, context management, and UI streaming.
- Safety and UX are achieved by mode gating (plan vs act), auto-approval policies, path validation, and human-visible checkpoints/diff views.
- Extensibility relies on MCP for external tools/resources, a provider-agnostic LLM layer, and a prompt registry with model-family variants.
- For a multi-agent system, replicate and generalize: Task-as-Agent units, a root Orchestrator, shared state and artifacts, inter-agent messaging, and checkpointed changes with mediation.

Table of Contents
1. Architecture Overview
2. End-to-End Request Lifecycle
3. Controller and Task Deep Dive
4. Modes: Plan vs Act (Safety & UX)
5. Tooling Architecture
6. Prompting and Variants
7. Context Management and Condensing
8. Checkpoints and Diff Views
9. MCP Integration
10. API Providers and Streaming
11. State, Storage, and History
12. UI/Webview Bridge
13. Error Handling and Telemetry
14. Focus Chain
15. Security and Safety Controls
16. Scaling to Multi-Agent Systems
17. Implementation Roadmap for a Generic System
18. Risks and Pitfalls
19. Code Anchors

1) Architecture Overview
- Core Components:
  - Controller: Composition root; wires StateManager, Auth, MCP hub, telemetry; owns the current Task.
  - Task: Encapsulates execution state, messaging, tools, context, checkpointing, and model interactions.
  - WebviewProvider: Bridges UI; injects client ID, CSP; supports dev HMR.
  - HostProvider: Abstracts environment (VS Code vs external) for UI, logs, diff views, auth callback URIs.
  - Services: MCP hub, terminal manager, browser session, URL fetcher, telemetry, error handling.
- Startup Flow:
  - Standalone entry initializes host bridge and global handlers, then calls shared initialize() to set up storage, telemetry, and a sidebar webview.
  - A unique client ID maps to a Controller instance for routing events and state.
- Why this design works:
  - Separation of concerns and clear ownership per layer; a stable core that runs under different hosts (VS Code extension and standalone).

2) End-to-End Request Lifecycle
- User input arrives via the webview and is routed to the Controller for the active client ID.
- Controller.initTask() constructs a Task with current configuration and user input (task text/images/files or a history item to resume).
- Task builds a system prompt (PromptRegistry + builder), assembles context (ContextManager + trackers), and sends a streaming request via ApiHandler.createMessage().
- Streaming parser yields assistant content and tool-use blocks:
  - Partial assistant text is surfaced for live UI updates (sendPartialMessageEvent) without committing final state.
  - Tool-use blocks are routed to ToolExecutor, which enforces mode gating, validation, auto-approval, and per-tool handlers.
- After tool execution, ToolResult is pushed to the stream, states are saved, and checkpoints may be created. Loop continues until completion or user cancels.

2a) Lifecycle Diagram (ASCII)
```
 User
   |
   v
 Webview (UI) --------- partial updates <-----------------------------.
   |                                                          (delta) |
   v                                                                  |
 Controller (routes by clientId)                                       |
   | initTask()                                                        |
   v                                                                  |
 Task (agent session)                                                  |
   |  build prompt + context                                           |
   |  ApiHandler.createMessage()  --> Stream ----------------------.   |
   |                                      |                         |  |
   |                           (text) ----'                         |  |
   |                                      |                         |  |
   |                        (tool_use block)                        |  |
   |                                      v                         |  |
   |                             ToolExecutor                       |  |
   |                               | (validate, mode-gate,          |  |
   |                               |  auto-approve, execute)        |  |
   |                               v                                |  |
   |                      Tool Handlers (read/write/exec/web/MCP)   |  |
   |                               |                                |  |
   |                               v                                |  |
   |                      CheckpointManager + DiffView              |  |
   |                               |                                |  |
   |                               v                                |  |
   |                      StateManager/History update               |  |
   |                               |                                |  |
   |                               '------> Webview (full state) ---'  |
   |                                                                ^  |
   '-------------------------- cancel/abort -------------------------'  |
```

3) Controller and Task Deep Dive
- Controller responsibilities (src/core/controller/index.ts:1):
  - Create and initialize StateManager; run migrations; restore auth; wire MCP hub.
  - Manage Task lifecycle: init, cancel, toggle modes, update settings; post state to webview.
  - Fetch MCP marketplace; handle provider auth callbacks (e.g., OpenRouter).
- Task responsibilities (src/core/task/index.ts:1):
  - Maintain TaskState and MessageStateHandler; own say/ask UX methods.
  - Orchestrate ApiHandler calls and parse assistant messages into text/tool use.
  - Execute tools via ToolExecutor; coordinate BrowserSession/TerminalManager.
  - Track context (file/model), checkpoints, and focus chain; enforce strictPlanMode.
  - Persist history and state via StateManager; compute diffs and export markdown.
- Important nuance: The Task guards against race conditions by checking abort flags and using pWaitFor on cancel to avoid UI contamination from stale streaming promises.

4) Modes: Plan vs Act (Safety & UX)
- Strict Plan Mode: ToolExecutor blocks high-risk tools (file_new, file_edit, new_rule) in PLAN mode with explicit error messages and saves a checkpoint post-warning.
- Toggle Flow: Controller.togglePlanActMode switches mode, updates ApiHandler, and can auto-respond to a pending “plan ask” by posting a default response when switching to ACT.
- Rationale: Separates high-level reasoning (planning) from side-effecting execution. Users can review a plan before authorizing edits.
- Generalization: Add more modes (e.g., explore, simulate, deploy) to graduate risk; couple with approval thresholds and reviewer policies.

5) Tooling Architecture
- Coordinator Pattern (src/core/task/ToolExecutor.ts:1):
  - ToolExecutorCoordinator registers handlers; ToolValidator checks parameters and path safety (ClineIgnoreController); AutoApprove applies request budgets and allowlists.
  - Partial vs Complete: Partial blocks only update UI; complete blocks execute and push ToolResult via ToolResultUtils with consistent formatting.
  - Cross-cutting: browserSession lifecycle, close browser on non-browser tools, saveCheckpoint after execution, update Focus Chain.
- Example Flows:
  - File Edit: validate rel path and params; write via WriteToFileToolHandler; show diff; checkpoint.
  - Execute Command: run in TerminalManager with timeouts and output limits; checkpoint on success.
  - Web Fetch/Browser: UrlContentFetcher and BrowserSession produce artifacts/images; model-dependent webp handling.
- Policy Surfaces:
  - Auto-approval per-tool and per-path; max consecutive approvals; reset on limit changes.
  - Mode restrictions enforced centrally in ToolExecutor.

5a) Tool Execution Decision Flow (ASCII)
```
Input: ToolUse block (name, params, partial flag)

Task.ToolExecutor.execute(block)
  |
  |-- Coordinator.has(name)?
  |     |-- no -> return false (not handled)
  |     '-- yes
  |
  |-- taskState.didRejectTool?
  |     |-- yes -> append rejection message; return
  |     '-- no
  |
  |-- taskState.didAlreadyUseTool?
  |     |-- yes -> append "tool already used" message; return
  |     '-- no
  |
  |-- strictPlanModeEnabled && mode=='plan' && name in PLAN_RESTRICTED?
  |     |-- yes -> say(error), push toolError result, saveCheckpoint, return
  |     '-- no
  |
  |-- if name!='browser_action' -> browserSession.close()
  |
  |-- if block.partial == true
  |       |-- handler supports partial? -> handler.handlePartialBlock(block, uiHelpers)
  |       '-- return (no toolResult pushed on partial)
  |
  '-- else (complete block)
          |
          |-- Validate params & paths (ToolValidator + ClineIgnoreController)
          |     |-- invalid -> sayAndCreateMissingParamError(), push toolError, saveCheckpoint, return
          |
          |-- Auto-approval decision
          |     |-- shouldAutoApproveTool(name) or shouldAutoApproveToolWithPath(...)?
          |           |-- yes -> proceed
          |           '-- no  -> ask user (ClineAsk), wait; possibly set didRejectTool
          |
          |-- Execute handler via coordinator.execute(config, block)
          |     |-- success -> pushToolResult(formatResponse(...))
          |     '-- error   -> say(error); pushToolResult(toolError)
          |
          |-- focusChainSettings.enabled? -> updateFCListFromToolResponse(task_progress)
          |
          '-- saveCheckpoint()
```

Notes
- Partial blocks provide responsive UI without committing results; complete blocks are the single source of truth for state changes.
- Auto-approval supports per-tool and per-path policies with request budgets; changing maxRequests resets counters.
- Validation centralizes safety: required params, path normalization, ignore rules.

6) Prompting and Variants
- Registry & Builder (src/core/prompts/system-prompt/registry/PromptRegistry.ts:1):
  - getModelFamily selects variant (generic, next-gen, gpt‑5, XS/local, etc.); generic fallback ensures resilience.
  - Components library and TemplateEngine compose system prompts from labeled parts; versions/tags/labels choose variants.
- Generalization:
  - Use per-agent prompt variants by role (planner, researcher, coder, reviewer).
  - Maintain labeled components for reusability and testing; pin versions to ensure reproducibility.

7) Context Management and Condensing
- ContextManager plus trackers:
  - FileContextTracker marks what files were read/changed and manages warnings.
  - ModelContextTracker tracks context window usage across messages.
- Condense/Summarize:
  - SummarizeTask and Condense handlers compress history to fit token budgets; Task exposes updateUseAutoCondense with telemetry.
- Thinking Budgets:
  - buildApiHandler clips thinkingBudgetTokens to model maxTokens when needed to avoid API errors.
- Generalization:
  - For multi-agent, standardize “context contracts” and require structured summaries for handoffs. Centralize a shared memory that agents query via context APIs.

8) Checkpoints and Diff Views
- Checkpoint Manager:
  - Snapshots task state and FS changes; integrates with DiffViewProvider for human review (accept/discard); blocks unsafe flows on errors.
  - Provides doesLatestTaskCompletionHaveNewChanges and restore paths.
- Why it matters:
  - For multi-agent concurrency, checkpoints help prevent conflicts and enable arbitration.
  - Consider per-agent branches and a merge/review agent or human-in-the-loop.

9) MCP Integration
- McpHub (src/services/mcp/McpHub.ts:1):
  - Loads config, watches for changes, connects via stdio/SSE/streamable HTTP; fetches tools/resources/templates; streams server notifications.
  - Marks autoApprove tools from settings to streamline safe calls.
- Notifications:
  - Push as chat messages immediately (Task.say("mcp_notification", ...)).
- Generalization:
  - Treat MCP as the common plugin surface for domain tools; each agent can have a scoped server set.

9a) MCP Tool Invocation Flow (ASCII)
```
Tool handler -> McpHub
  |
  |-- resolve server by name -> connection (client, transport)
  |-- if disabled -> return empty capabilities/resources
  |-- request:
  |     - tools/list -> ListToolsResultSchema (zod)
  |     - resources/list -> ListResourcesResultSchema
  |     - resources/templates/list -> ListResourceTemplatesResultSchema
  |     - tools/call -> CallToolResultSchema
  |
  '-- response handling:
        - validate schemas
        - merge autoApprove from settings
        - stream notifications via client.notification + fallbackNotificationHandler

Transports
- stdio: spawn process; pipe stderr for logs; onerror/onclose update server status.
- sse: ReconnectingEventSource; headers for auth; onerror marks disconnected.
- streamableHttp: HTTP SSE-like; onerror marks disconnected.

Timeouts & Errors
- DEFAULT_REQUEST_TIMEOUT_MS for requests; errors append to server.error and update UI via sendMcpServersUpdate.
```

10) API Providers and Streaming
- Abstraction (src/core/api/index.ts:1):
  - ApiHandler with provider-specific handlers; createMessage returns ApiStream with usage accounting; retry hook updates UI messages with attempt/delay/error snippet.
  - Transform layers adapt providers’ streaming formats to a consistent internal stream.
- Generalization:
  - Keep a uniform streaming API; add circuit breakers and per-agent token budgets; report provider latency/errors into telemetry.

11) State, Storage, and History
- StateManager:
  - Manages global/workspace state, secrets, settings, history persistence (taskHistory.json), migrations, and sync of external changes.
- History:
  - Tasks persist ulid, favorited, deleted ranges, and checkpoint metadata; reinitExistingTaskFromId restores sessions.
- Generalization:
  - Central “ProjectStateManager” with per-agent state slices, shared artifacts catalog, and audit logs.

12) UI/Webview Bridge
- WebviewProvider (src/core/webview/WebviewProvider.ts:1):
  - Injects clientId and provider type; manages instances, visibility, and last-active controller; builds CSP for dev/prod.
- Messaging:
  - Partial message events send only delta for smooth UI; full state sync on important transitions.
- Generalization:
  - If not using VS Code, keep a UI abstraction with similar guarantees: safe HTML, consistent IDs, streaming updates.

12a) Webview Messaging Protocol (Summary)
- Identity: Each WebviewProvider instance has a unique `clientId` injected into the page; maps back to a specific Controller.
- Partial Messages: `sendPartialMessageEvent(protoMessage)` updates UI incrementally for streaming content and partial ask/say states.
- Full State Posts: `postStateToWebview()` sends the full serializable state when significant changes occur (mode toggle, settings change, task init/dispose).
- Visibility/Focus: WebviewProvider tracks last active/visible instance to route interactions properly.
- CSP & Dev: Nonce-based CSP; dev HMR path uses Vite server with explicit CSP allowances.

12b) Event Channels (ASCII)
```
Webview UI <---- partial (event) ---- Controller/Task
      ^                               |
      |                               v
      '------ full state (post) ---- WebviewProvider

Keys
- partial = least-cost updates (streaming text, partial tool UIs)
- full state = authoritative snapshot (messages list, settings, history)
```

13) Error Handling and Telemetry
- Error Service & Providers; distinct IDs; PostHog integration; window messages with severity.
- Task emits telemetry on mode switches, condense toggles, terminal hangs; Controller emits activation and marketplace events.
- Generalization:
  - Multi-agent telemetry should include agentId, taskId, parentId, tool, tokens, latency, retry counts, approvals used.

14) Focus Chain
- Purpose:
  - Helps track progress and remind agents/users of next steps; integrates with Task mode and UI; can be gated by feature flags and settings.
- Generalization:
  - Treat as a lightweight orchestrator for single-agent; for multi-agent, elevate to a DAG scheduler.

14a) Focus Chain Internals
- Inputs: taskId, taskState, current mode, context, state manager, UI hooks, settings (enabled, remind interval).
- Behavior: Maintains a list of focus items/progress; updates from tool responses (`task_progress`); can prompt reminders based on interval.
- Settings Gating: Disabled by user or feature flag; Task only constructs FocusChainManager when effective settings enable it.
- Interactions: Updates the UI through `postStateToWebview`; responds to mode changes to adapt allowed behaviors.

Appendix A: Configuration Surfaces (Selected)
- Mode & Reasoning
  - `mode`: plan|act; `strictPlanModeEnabled`; `useAutoCondense`; `openaiReasoningEffort`; per-mode thinking budgets.
- Tools & Approvals
  - `autoApprovalSettings`: maxRequests, per-tool/path allowlists; resets counter when limit changes.
- Browser & Terminal
  - `browserSettings`; `shellIntegrationTimeout`; `terminalReuseEnabled`; `terminalOutputLineLimit`; `defaultTerminalProfile`.
- Providers & Keys
  - `planModeApiProvider`/`actModeApiProvider`; model IDs/information per provider; API keys/base URLs.
- Storage & History
  - Global/workspace state, taskHistory file, migrations; reinit by taskId via saved history.

15) Security and Safety Controls
- Mode gating for risky tools in plan mode.
- Auto-approval budgets and per-path/tool allowlists.
- TerminalManager timeouts, output limits, and profile selection.
- MCP server disabled/connected statuses and error surfacing.
- CSP-strict webview with nonce and limited sources.
- Generalization:
  - Add sandboxed FS scopes per agent, policy-as-code for approvals, and provenance tracking on artifacts.

16) Scaling to a Multi‑Agent System
- Orchestrator (ProjectController):
  - Decompose user goals into subprojects; plan a DAG with dependencies; spawn Task-as-Agent instances with role-specific toolsets and prompts.
  - Monitor progress, collect summaries, and mediate conflicts; escalate to human via checkpoints/diffs.
- Inter-Agent Protocol:
  - Event hub with topics keyed by projectId/agentId; messages include intent (request, result, blocker), artifact references, and summary.
- Shared Artifacts & Memory:
  - Central catalog (files, docs, URLs, datasets) with versions and metadata; agents read via context; write via checkpointed tools.
- Budgets & Governance:
  - Per-agent limits on tokens, tools, wall-clock, and approvals; automatic mode transitions based on confidence and reviews.
- Roles & Prompts:
  - Planner, Researcher, Coder, Reviewer, Integrator each with variant prompts and allowlisted tools; Reviewer mediates conflicts.

16a) Orchestration DAG Diagram (ASCII)
```
                       +---------------------+
                       |  Orchestrator (PC)  |
                       |  (ProjectController) |
                       +----------+----------+
                                  |
                     Plan DAG + budgets/policies
                                  |
                 .----------------+----------------.
                 v                                 v
        +--------+--------+                +-------+--------+
        |  Planner Agent  |                |  Integrator    |
        | (Task-as-Agent) |                |    Agent       |
        +--------+--------+                +-------+--------+
                 |                                 ^
     emits subgoals + deps                         |
                 |                                 |
        .--------+-----------.          merges artifacts/checkpoints
        v                    v                      |
 +------+-------+    +-------+------+               |
 | Researcher   |    |   Coder      |               |
 | Agent        |    |   Agent      |               |
 +------+-------+    +-------+------+               |
        |                    |                      |
        | via Event Bus      | via Event Bus        |
        v                    v                      |
  [Shared Artifacts Catalog & Checkpoints] <---------'
        ^                    ^
        |                    |
   +----+-----+        +-----+----+
   | Reviewer | <------ |  QA/Test |
   |  Agent   |        |  Agent   |
   +----------+        +----------+

Legend:
- Event Bus: topic(projectId/agentId)-scoped pub/sub for requests, results, blockers.
- Shared Artifacts: versioned files/docs/datasets; writers go through checkpoints/diff review.
- Policies: per-agent tools/paths, token/time budgets, mode gating; human-in-the-loop via Reviewer.
```

17) Implementation Roadmap
- Phase 1: Foundations
  - Extract HostProvider and WebviewBridge abstractions; implement ProjectStateManager and ProjectController.
  - Keep Cline’s ApiHandler abstraction and streaming transforms.
  - Build ToolRegistry with validators and policies; port Write/Edit/Browser/Fetch/Execute and MCP integration.
- Phase 2: Agentization
  - Wrap Task into Agent entity; add role-specific prompts; add event bus (in-process pub/sub) for inter-agent messages.
  - Implement artifact catalog and checkpoint review workflow.
- Phase 3: Orchestration
  - DAG planner; scheduler for parallel subtasks; mediator/reviewer agent; human-in-the-loop checkpoints.
  - Telemetry/observability by agent and tool; budget enforcement.

18) Risks and Pitfalls
- Streaming/state sync inconsistencies leading to UI desync or stale writes.
- Approval fatigue; mitigate with tiered modes and explainable policies.
- Tool sprawl; mitigate with allowlists, tags, and audits.
- Prompt drift; mitigate with pinned versions, tests, and labels.
- Checkpoint conflicts in parallel edits; mitigate with per-agent branches and merge mediation.

19) Code Anchors
- Startup: src/standalone/cline-core.ts:1
- Common init/teardown: src/common.ts:1
- Webview provider: src/core/webview/WebviewProvider.ts:1
- Controller (composition root): src/core/controller/index.ts:1
- Task core: src/core/task/index.ts:1
- Tool executor: src/core/task/ToolExecutor.ts:1
- System prompt registry: src/core/prompts/system-prompt/registry/PromptRegistry.ts:1
- API abstraction: src/core/api/index.ts:1
- MCP hub: src/services/mcp/McpHub.ts:1

20) Comparative Analysis with LangChain Step Mode and Agora Protocol

## Overview
This section compares Cline's architecture with Elixir LangChain's step mode and explores how Agora Protocol can enhance multi-agent communication.

## LangChain Step Mode (Elixir)

### Core Concept
LangChain's step mode provides granular control over AI workflow execution by allowing pauses at critical points and implementing conditional logic for continuation.

### Key Features
- **Execution Control**: `:step` mode for `LLMChain.run/2`
- **Conditional Logic**: `should_continue?` function for dynamic flow control
- **State Inspection**: Access to full chain state between executions
- **Safety Mechanisms**: Iteration limits and approval gates

### Implementation Pattern
```elixir
should_continue_fn = fn chain ->
  chain.needs_response && 
  !requires_approval?(chain) && 
  under_iteration_limit?(chain)
end

LLMChain.run(chain, [mode: :step, should_continue?: should_continue_fn])
```

## Comparative Analysis: Cline vs LangChain

| Aspect | Cline | LangChain Step Mode |
|--------|-------|-------------------|
| **Granularity** | Task-level with tool-specific policies | Step-level with event-based pauses |
| **State Management** | Full StateManager with history/migrations | Chain state inspection between steps |
| **Safety Model** | Mode-based (Plan/Act) + auto-approval | Conditional function-based |
| **Multi-agent Support** | Built-in orchestrator design | Requires external orchestration |
| **UI Integration** | Native WebView with streaming | API-focused, UI agnostic |
| **Complexity** | Heavy, enterprise-ready | Lightweight, composable |
| **Checkpointing** | Comprehensive diff views and rollback | Manual state management |
| **Tool Ecosystem** | MCP integration, extensive validators | Framework-native tools |

### Cline Strengths
- **Comprehensive orchestration** with Controller/Task architecture
- **Mode-based safety** (Plan vs Act) for risk management
- **Rich tooling ecosystem** with validators and auto-approval policies
- **UI-centric design** with streaming updates
- **Multi-agent ready** with ProjectController orchestration

### LangChain Step Mode Strengths
- **Lightweight control flow** with simple function-based decisions
- **Flexible inspection** of chain state at any point
- **Dynamic modification** of chain during execution
- **Framework native** integration with Elixir/OTP benefits

## Agora Protocol Integration

### Core Value Proposition
Agora Protocol provides a decentralized communication layer for multi-agent systems with:
- **98% token reduction** in agent communication
- **Protocol negotiation** using SHA1 hashes
- **Framework agnostic** design
- **No central broker** requirement

### Benefits for Multi-Agent Systems
1. **Standardized Communication**: Agents agree on protocols dynamically
2. **Efficiency**: Dramatic reduction in token usage for inter-agent messages
3. **Scalability**: Decentralized architecture supports large agent networks
4. **Flexibility**: Works across different agent implementations

## Recommendations for Otto Multi-Agent System

### Hybrid Architecture Approach

Combine the strengths of all three approaches:

1. **Individual Agent Control**: Use LangChain's step mode for fine-grained execution control
2. **Orchestration Layer**: Adopt Cline's Controller/Task patterns for high-level coordination
3. **Communication Protocol**: Implement Agora-style protocol negotiation for inter-agent messaging

### Implementation Strategy

#### Phase 1: Agent Foundation
```elixir
defmodule Otto.Agent.Worker do
  def execute_with_control(chain, opts) do
    should_continue? = fn chain ->
      !requires_user_approval?(chain) &&
      within_budget?(chain) &&
      !blocked_by_dependency?(chain)
    end
    
    LLMChain.run(chain, [
      mode: :step,
      should_continue?: should_continue?
    ])
  end
end
```

#### Phase 2: Protocol Registry
```elixir
defmodule Otto.Protocol.Registry do
  # Agora-inspired protocol management
  def register_protocol(name, definition) do
    hash = :crypto.hash(:sha, definition)
    # Store protocol with versioning
  end
  
  def negotiate_protocol(agent_a, agent_b) do
    # Find common protocol version
  end
end
```

#### Phase 3: Orchestration Layer
```elixir
defmodule Otto.Orchestrator do
  # Cline-inspired orchestration
  def init_project(user_goal) do
    %{
      controller: spawn_controller(),
      agents: %{},
      checkpoints: [],
      artifacts: SharedArtifactCatalog.new()
    }
  end
  
  def spawn_agent(role, protocol) do
    # Create agent with specific role and communication protocol
  end
end
```

### Alternative Architectural Patterns

1. **Actor Model with Supervision Trees**
   - Leverage Elixir's OTP for fault tolerance
   - Natural fit for agent lifecycle management

2. **Event Sourcing**
   - Track all agent decisions for audit/replay
   - Enable time-travel debugging

3. **CQRS Pattern**
   - Separate command (actions) from query (planning) paths
   - Optimize for different workload types

4. **Blackboard Architecture**
   - Shared knowledge base for agent coordination
   - Reduces direct agent-to-agent communication

### Key Design Decisions

1. **Control Flow**
   - Primary agent: Cline-style Task management with checkpointing
   - Worker agents: LangChain step mode for execution control
   - Communication: Agora-style protocols for efficiency

2. **Safety Mechanisms**
   - Mode gating (Plan/Act) at orchestrator level
   - Step-wise approval at agent level
   - Budget enforcement across all agents

3. **State Management**
   - Centralized state at orchestrator
   - Local state per agent
   - Checkpointed artifacts for rollback

4. **User Feedback Loop**
   - Primary agent aggregates worker results
   - Unified diff view for all changes
   - Approval workflow for critical operations

### Benefits of This Hybrid Approach

1. **Fine-grained Control**: Step mode for individual agent decisions
2. **Robust Orchestration**: Cline patterns for system-wide coordination
3. **Efficient Communication**: Agora concepts for inter-agent messaging
4. **Native Platform Benefits**: Full Elixir/OTP fault tolerance and distribution
5. **Scalability**: Decentralized communication with centralized orchestration
6. **Safety**: Multiple layers of approval and validation

### Implementation Roadmap

1. **Weeks 1-2**: Implement LangChain step mode in Otto.Agent
2. **Weeks 3-4**: Build protocol registry with Agora concepts
3. **Weeks 5-6**: Create orchestrator with Cline-inspired patterns
4. **Weeks 7-8**: Add checkpointing and diff management
5. **Weeks 9-10**: Implement user rollup and feedback mechanisms
6. **Weeks 11-12**: Testing, optimization, and documentation

This hybrid approach provides the control granularity of LangChain, the orchestration robustness of Cline, and the communication efficiency of Agora Protocol, creating a powerful foundation for autonomous multi-agent systems.
