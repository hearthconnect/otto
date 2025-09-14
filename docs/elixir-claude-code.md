Part A — Conceptual Model From the Posts + Docs

1. Key practices and patterns from “I Managed a Swarm of 20 AI Agents…”

- Plan-first alignment: Iterate on a plan (ticket/spec) with the model before execution. Cheaper to fix a bad plan than a bad implementation.
- Short-lived, focused agents: Long-running agents drift due to context compaction. Prefer shorter runs with clear objectives.
- Active memory management: Checkpoint progress externally (markdown/PR comment/issue) and restart with fresh context. Treat “memory” as a managed artifact, not a magic model property.
- Sub-agents assembly line: Decompose work into specialists (product manager, UX, engineer, reviewer), each with a clean context window. Parallelize where possible; sequence where dependencies exist.
- Autonomous execution loops: Define testable loops where agents run tests, analyze failures, refine, and repeat until acceptance criteria are met.
- Automate the system: Self-updating project docs (CLAUDE.md analog), self-refining commands, and system-level automation beyond code edits.
- Ruthless restarts + frequent commits: Kill misdirected trajectories early; safety-net via frequent commits/branches.
- Manage cost + fatigue: Parallelization is productive but mentally taxing; design for observability, fast resets, and budget awareness.

2. Key workflow details from “How to Use Claude Code Subagents to Parallelize Development”

- Parallel execution: Fan-out to specialists for speed (backend, frontend, QA, docs) with shared input (e.g., API docs), then gather results.
- Sequential handoffs: Planning agents produce structured artifacts (tickets); implementation agents consume those; reviewers gate merge.
- Context isolation: Each sub-agent works with its own fresh 200k context, improving quality by not mixing phases.
- Structured outputs: Reviewers produce machine-parseable reports so orchestration can loop intelligently.
- Practicalities: Costs, non-determinism, and synthesis are the hard parts. Save all agent outputs to files for auditability and deterministic downstream synthesis. Treat agent definitions as versioned code.

3. Critical capabilities from Anthropic Subagents docs

- Subagents are defined as files with a name, description, tools, and a system prompt (YAML frontmatter + body).
- Separate context windows per subagent: Main thread delegates to subagents; each subagent has its own tool permissions and clean slate.
- Explicit vs automatic invocation: Router delegates based on description and context; users can force a specific agent.
- Tool permissions and isolation: Tools can be inherited or whitelisted per subagent; use minimal toolsets for safety/focus.
- Chaining: Build higher-level flows that invoke agents in sequence.
- Management: Project-level vs user-level agents; conflicts resolved by priority.

Part B — Reimagined Architecture in Elixir/OTP

High-level goals

- OTP-native agent runtime: Each agent is a GenServer with a well-defined lifecycle, separate context, and strict budgets/timeouts.
- Subagent ergonomics: Define agents via config files (YAML/JSON or Elixir modules) for fast creation; use an Agent Registry.
- Orchestration patterns: Provide primitives for fan-out/fan-in (parallel), pipeline (sequential), retry/restart policies, and autonomous loops.
- Tooling: Tool behavior contracts with per-agent allowlists. Run tools sand-boxed where possible. Minimal external dependencies to start.
- Context/memory: Explicit checkpointing to durable stores; ephemeral in-process memory. Summarization and hand-off artifacts are first-class.
- Observability and safety: Strong logging, telemetry, cost budgets, transcripts, and auditable artifacts.
- Extensibility: Model-agnostic LLM client; later add Anthropic, OpenAI, or others.

Core processes and supervision tree

- Otto.Supervisor (top)

  - Otto.Registry (Registry) for agent and workflow process lookup
  - Otto.ToolBus (GenServer) registry of available tools (behaviours + adapters)
  - Otto.AgentSupervisor (DynamicSupervisor) to spawn AgentServer processes per subagent instance
  - Otto.TaskSupervisor (Task.Supervisor) for fan-out and background jobs
  - Otto.ContextStore (GenServer + ETS) to hold ephemeral per-agent context metadata
  - Otto.Checkpointer (GenServer) to persist artifacts to sinks (filesystem, DB, Git, PR comments, etc.)
  - Otto.Orchestrator (GenServer) for workflow execution, routing, parallelization, and lifecycle control
  - Otto.CostTracker (GenServer) aggregates token/cost usage by session/agent/workflow
  - Otto.EventBus (Phoenix.PubSub or :telemetry) to publish lifecycle and audit events

Core abstractions

- Agent configuration

  - Source: config files (e.g., .otto/agents/*.yml) or Elixir modules with use Otto.Agent
  - Fields: name (atom/string), description (routing hints), model (e.g., “sonnet-4.1” or provider alias), tools (list/allowlist), color/tags (optional), defaults (timeouts, token budgets, cost budgets), system_prompt (text), working_dir (optional sandbox), escalation_rules (optional).
  - Loader parses config files on startup; dynamic reload optional.

- AgentServer (GenServer)

  - State: agent_config, context_id, transcript (bounded), budget (tokens/cost/time), tool_permissions, current task metadata, working_dir, ephemeral memory store keys, last_checkpoint.

  - Public API:

    - start_link(config, opts)
    - invoke(task :: %TaskSpec{}) :: {:ok, result | %ArtifactRef{}} | {:error, reason}
    - cancel(task_id)
    - checkpoint(reason)
    - summarize()

  - Behavior:

    - Boot: allocate context_id, set budgets, mount working_dir sandbox, register in Registry
    - handle_invoke: prepare system + user messages, attach allowed tools, stream LLM responses and tool calls; capture transcript; enforce timeouts/budgets; finalize result as artifact(s); checkpoint if configured
    - On failure: emits :telemetry events; maybe auto-restart with exponential backoff if policy says so

- TaskSpec (struct)

  - id, title, description, inputs, artifacts (refs), acceptance_criteria, deadlines, budgets (tokens/time/cost), routing_hints (tags/skills), run_mode (single-shot vs loop), retry_policy

- Tools (behaviour Otto.Tool)

  - @callback name() :: atom
  - @callback permissions() :: [:read | :write | :exec | ...]
  - @callback call(params :: map, ctx :: ToolContext) :: {:ok, any} | {:error, any}
  - ToolContext contains: agent_config, working_dir, env, cancellation token, budget guard
  - Built-ins (phase 1): FS.Read, FS.Write, FS.Grep, Shell (guarded), HTTP (req), TestRunner (mix test or script), Git (optional), JSON/YAML parser, Markdown Renderer
  - ToolBus registers tools and resolves by name; AgentServer attaches only permitted tools to LLM

- Router (pure module + config)

  - route(task_spec, agents) -> [agents]
  - Uses term matching on routing_hints, description keyword matching, and optional learned rules
  - Supports explicit invocation: if task specifies agent names, bypass auto-routing
  - Supports dynamic selection (rank by description similarity, allowed tools, model capability)

- Orchestrator (GenServer)

  - Patterns:

    - Parallel fan-out: Task.Supervisor.async_stream over N subagents; collect results; handle partial failures with retries or fallbacks
    - Sequential pipeline: steps = [%Step{agent, inputs_from: prev}], run step-by-step; if failure, restart step(s)
    - Autonomous loop: a loop spec {builder_agent, test_agent, reviewer_agent, max_iters, stop_condition}; run until acceptance or budget/timeouts

  - Lifecycle control:

    - Start, cancel, restart tasks
    - Budget/time limit enforcement; “long-running agent is a bug” policy: break work into steps, require checkpoints, auto-restart fresh

  - Artifacts management: store all intermediate results in Checkpointer; pass only necessary summaries to next step to keep contexts small

  - Emission: :telemetry events for every phase, for UI/metrics

- Context & memory

  - Ephemeral memory in ETS keyed by context_id (small metadata); transcripts stored compressed on disk if needed

  - External checkpoint store:

    - Filesystem default: var/otto/sessions/<session_id>/…
    - Optional sinks: DB (Ecto), Git (branch + commits), PR comments, tickets

  - Summarizer agent/tool: when contexts get large, produce a crisp summary artifact (ticket.md, review.md, prd.md) for handoff

- Cost and usage tracking

  - Otto.CostTracker aggregates tokens/cost/time by workflow/task/agent
  - Enforce per-agent and per-workflow budgets with hard stops and graceful shutdown
  - Emit periodic cost telemetry

Agent lifecycles and policies

- Creation and discovery

  - On boot, AgentLoader scans .otto/agents/ for YAML; also reads any agent modules compiled into the codebase
  - Conflicts resolved by priority (project-level over user-level)

- Invocation

  - Auto-delegation via Router OR explicit agent name(s)
  - On invoke: spawn AgentServer instance (DynamicSupervisor) per concurrent task, not a singleton

- Timeouts & budgets

  - Per-invocation timeout (e.g., 2–8 minutes)
  - Token/cost budget guard injected into LLM client; early exit if exceeded

- Restart policy

  - If agent deviates (e.g., tool misuse, irrelevant chatter, stuck), Orchestrator cancels and restarts with tighter prompt and reduced scope
  - Aggressive early-stopping threshold configurable (rule #7)

Subagent definitions and developer ergonomics

- Config-first agent definitions (YAML)

  - Example .otto/agents/senior-software-engineer.yml

    - name: senior-software-engineer

    - description: Pragmatic IC… (include “Use PROACTIVELY …” to bias auto-routing)

    - model: sonnet-4.1 (or alias)

    - tools: [fs_read, fs_write, grep, http, test_runner]

    - budgets: { seconds: 300, tokens: 120_000, usd: 1.50 }

    - system_prompt: |

      - Principles…
      - Concise working loop…

- Elixir DSL (optional)
  - defmodule Agents.SeniorEngineer do use Otto.Agent, name: "senior-software-engineer", description: "…", model: :sonnet, tools: [:fs_read, :fs_write, :grep, :http, :test_runner], budgets: [seconds: 300, tokens: 120_000, usd: 1.50] def system_prompt, do: ~S""" … """ end

- Fast creation
  - mix otto.gen.agent MyAgent — creates YAML + optional Elixir module stub, with tool allowlist template and prompt scaffold

- List/inspect (optional APIs)

  - Otto.Agents.list/0 -> [%AgentConfig{}]
  - Otto.Agents.show(name)

- Invocation API (library-first, CLI optional later)

  - Otto.run(%WorkflowSpec{}) or Otto.invoke(agent_name, %TaskSpec{})
  - Returns {:ok, %ArtifactRef{}} | {:error, reason}

Workflows and orchestration DSL

- WorkflowSpec (struct)

  - name, description
  - mode: :parallel | :sequential | :loop
  - steps: list of %Step{agent, inputs, outputs, accepts}
  - budgets, stop_conditions

- Parallel example (Stripe integration scaffold)

  - steps = [ %Step{agent: :backend_specialist, inputs: [docs], outputs: [:api_code]}, %Step{agent: :frontend_specialist, inputs: [docs], outputs: [:react_code]}, %Step{agent: :qa_specialist, inputs: [:api_code], outputs: [:tests]}, %Step{agent: :docs_specialist, inputs: [:api_code, :react_code], outputs: [:readme]} ]
  - Orchestrator fan-outs, streams results into Checkpointer; returns consolidated artifact index

- Sequential example (planning → implement → review)

  - steps = [ %Step{agent: :product_manager, outputs: [:ticket]}, %Step{agent: :ux_designer, inputs: [:ticket], outputs: [:design_brief]}, %Step{agent: :senior_engineer, inputs: [:ticket, :design_brief], outputs: [:code_pr]}, %Step{agent: :code_reviewer, inputs: [:code_pr], outputs: [:review_report]} ]
  - Reviewer “NEEDS REVISION” triggers loop back to senior_engineer with bound iterations

- Autonomous loop (rule #5)
  - loop_spec = %Loop{ build_agent: :senior_engineer, test_agent: :test_runner, reviewer_agent: :code_reviewer, max_iters: 6, stop_when: fn artifacts -> artifacts[:tests] == :green and reviewer_approved? end }

Memory, context isolation, and checkpointing

- Context isolation by process: each AgentServer has its own context_id, transcript, budgets

- Externalized “memory”:

  - Artifacts saved as files: ticket.md, prd.md, design.md, review.md, code_diff.md, etc.
  - Summaries generated for handoffs (keep next agent’s input crisp and bounded)

- Self-updating docs:
  - Introduce OTTO.md with system rules and project practices; a “doc-maintainer” agent updates it post-runs with learnings (rule #6)

- Restart strategy:
  - Treat long runs as errors: time-slice work; require checkpoint after each slice; restart fresh with last artifact inputs

Tooling and safety

- Tool allowlists per agent; deny by default

- Working directory sandbox: tmp/otto/<agent_instance_id> to avoid global side effects (configurable for project-level edits)

- Shell tool guard:

  - Validate commands with a policy (deny network by default, allow whitelisted binaries)
  - Timeout and kill long processes

- HTTP tool:
  - Rate limiting, domain allowlists, redact secrets

- TestRunner:
  - Spawns mix test in a separate OS process; collects structured results; safe timeouts and cleanup

- Git tool (optional phase):
  - commit early and often to a per-agent branch; small diffs; attach commit ids to artifacts

- Policy engine (optional):
  - Declarative allow/deny rules, e.g., “senior-software-engineer cannot run shell unless in autonomous loop,” or “docs agent cannot write code files”

Observability, auditing, cost management

- Telemetry events:
  - [:otto, :agent, :start|:finish|:error], [:otto, :workflow, …], [:otto, :tool, …], [:otto, :checkpoint, …]
- Structured logs:
  - JSON logs with correlation IDs: workflow_id, task_id, agent_instance_id
- Transcripts and artifacts:
  - Store per-agent transcripts (redacted) and tool IO under var/otto/sessions/…
- Cost & budget:
  - Aggregate tokens and $ across agents; stop when budget reached
- Health & fatigue:
  - Expose metrics: average wall time per step, restart counts, failure modes, flakiness of workflows

Developer experience (DX)

- Quick subagent creation: mix otto.gen.agent, with templates for PM/UX/Engineer/Reviewer/TestRunner
- Configuration over code: YAML files for non-coders to adjust prompts/rules/tools
- Library-first API: embed in Phoenix, a CLI, or Livebook later; do not require CLI usage to begin
- Recipe library: ship built-in agent templates mirroring the blog post’s appendix (PM, UX, SWE, Reviewer) with Elixir-centric prompts (mix, ExUnit, Phoenix)

Phased implementation plan

Phase 0 — Foundations (LLM client, contracts, skeleton)

- Define Otto.Tool behaviour + ToolBus
- Implement base tools: FS.Read/Write, Grep, HTTP, JSON/YAML, TestRunner (mix)
- Define AgentConfig struct + YAML loader + validation
- Implement AgentServer (GenServer) with invoke/1, budgets, transcript capture
- Integrate LLM client (provider-agnostic) with streaming tool-use hooks
- Create ContextStore, Checkpointer (filesystem), CostTracker
- Build Registry and DynamicSupervisor wiring

Phase 1 — Orchestrator and Router

- Implement Router with description matching and explicit invocation

- Implement Orchestrator with:

  - Parallel fan-out (Task.Supervisor.async_stream with backpressure and timeouts)
  - Sequential pipeline execution
  - Autonomous loop controller

- Add restart policies: early stop, bounded retries, exponential backoff

- Add per-step checkpointing and hand-off artifact shape conventions

Phase 2 — Subagent ergonomics and DX

- YAML and Elixir DSL support for agent definitions; project-level vs user-level precedence
- mix otto.gen.agent scaffolder
- Built-in agent templates: product_manager, ux_designer, senior_software_engineer, code_reviewer, test_runner, doc_maintainer
- API: Otto.invoke/2 and Otto.run/1; artifact references and materialization helpers

Phase 3 — Observability and policy

- Telemetry events and JSON logging with correlation IDs
- Transcripts and artifact archiving with redaction and rotation
- Policy engine for tool permissions beyond static allowlists (rules per agent/workflow)
- Budget dashboards (counters + histograms)

Phase 4 — Advanced workflows and optional integrations

- Git tool: frequent commits on branches; branch per workflow
- Checkpointer sinks: DB/Ecto, GitHub PR comments, issue trackers
- Summarizer agent for long contexts (automatic when artifacts cross thresholds)
- Live dashboard (Phoenix LiveView or Livebook) to watch runs, cancel, restart

Example agent definitions (YAML-style)

- product-manager.yml

  - name: product-manager
  - description: Pragmatic PM… Use PROACTIVELY for features and spikes.
  - tools: [fs_write, http]
  - model: sonnet-4.1
  - budgets: { seconds: 180, tokens: 80_000, usd: 0.80 }
  - system_prompt: Rules for PRD, acceptance criteria, success metrics, scope, risks, rollout.

- ux-designer.yml

  - name: ux-designer
  - description: Designs UX specs, states, accessibility; escalates to SWE for feasibility.
  - tools: [fs_write]
  - model: sonnet-4.1
  - budgets: { seconds: 180, tokens: 80_000, usd: 0.80 }
  - system_prompt: Clarity-first, all states (empty/loading/error/success), accessibility, reuse patterns.

- senior-software-engineer.yml

  - name: senior-software-engineer
  - description: Pragmatic IC writing Elixir/Phoenix code with tests; small reversible changes; observability.
  - tools: [fs_read, fs_write, grep, http, test_runner]
  - model: sonnet-4.1
  - budgets: { seconds: 420, tokens: 120_000, usd: 1.50 }
  - system_prompt: Loop: clarify → plan milestones → TDD → verify (ExUnit + targeted manual) → deliver notes.

- code-reviewer.yml

  - name: code-reviewer
  - description: Principal engineer reviewer; produces structured report (Verdict, Blockers, High, Medium).
  - tools: [fs_read, grep]
  - model: sonnet-4.1
  - budgets: { seconds: 180, tokens: 80_000, usd: 0.80 }
  - system_prompt: Checklist (correctness, clarity, security, tests, SRP), structured output.

Example workflows

- Planning → Implementation → Review

  - Orchestrator sequentially invokes PM → UX → SWE → Reviewer
  - If reviewer verdict != approved, loop back to SWE with reviewer’s structured issues (bounded iterations)
  - Checkpointer writes ticket.md, design_brief.md, code_diff.md, review_report.md

- Parallel scaffold (docs, tests, code)

  - Fan-out to docs-specialist, qa-specialist, backend-specialist concurrently, share initial spec inputs
  - Collect artifacts, run test runner, attempt synthesis step (doc-maintainer updates OTTO.md)

- Autonomous execution loop (bug fix)

  - Input: failing test and stack trace
  - Loop: SWE proposes fix → TestRunner runs → Reviewer checks risky changes → stop when green + approved or hit max_iters

Testing strategy

- Unit tests
  - Router matching; ToolBus registration; budget guards; AgentServer timeouts and cancellation

- Integration tests (fake LLM)

  - Deterministic tool-call sequences and canned completions to validate orchestration logic
  - Simulate reviewer “NEEDS REVISION” to test bounded loop

- VCR-style recording for LLM (mock providers)
  - Record token usage; assert cost budgets enforced

- Property tests
  - Orchestrator resilience under randomized partial failures and timeouts

- Soak tests
  - Parallel fan-out with concurrency limits; ensure no mailbox growth/leaks

How Elixir/OTP strengths map to requirements

- Process-per-agent isolation: Perfect for separate contexts, timeouts, cancellation, and restarts
- Supervisors: Ruthless restart and failure isolation “for free”
- Task.Supervisor and async_stream: Elegant parallelization and backpressure
- ETS and :telemetry: Low-latency ephemeral memory and first-class instrumentation
- Pattern matching, behaviours, protocols: Stable contracts for tools and agent configs
- Phoenix/LiveView (later): Real-time UI for orchestration visibility

Summary

This plan recreates the core experience of Claude Code’s sub-agents in Elixir, optimized for OTP’s strengths:

- Agents are short-lived, focused, and strictly budgeted GenServers.
- Orchestrator composes agents into parallel or sequential workflows with well-defined loops and restarts.
- Context is treated as a managed asset: artifacts are checkpointed, summarized, and handed off, not carried in a single ballooning conversation.
- Tools are explicit, permissioned, and sandboxed; each agent gets only what it needs.
- Developer ergonomics prioritize fast agent creation, config-first customization, and version-controlled prompts/rules.
- Observability, cost tracking, and audit artifacts make the system operationally safe and scalable.

Deliverables you can implement directly from this plan (shortlist)

- Behaviours: Otto.Tool, Otto.Agent (module DSL)
- Processes: AgentServer, Orchestrator, ToolBus, Checkpointer, CostTracker
- Config loader: .otto/agents/*.yml → %AgentConfig{}
- Built-in tools: FS.Read/Write, Grep, HTTP, TestRunner
- Built-in agents: PM, UX, SWE, Reviewer, TestRunner, DocMaintainer
- Orchestration API: Otto.invoke/2, Otto.run/1 with WorkflowSpec
- Telemetry and transcripts: JSON logs with correlation IDs and archived artifacts
- mix otto.gen.agent for fast creation

This yields a Claude Code-style multi-agent runtime where adding a custom agent is as simple as adding a YAML file or a small Elixir module and calling a single function to run a workflow.
