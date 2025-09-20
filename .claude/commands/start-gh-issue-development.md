-----
description: Kick off parallel, feedback-driven development for an existing GitHub issue using Claude Code sub-agents. Creates a branch and draft PR, runs multiple specialist agents concurrently (planner, implementers, tester, reviewer, docs, QA), and uses rigorous feedback gates to converge on a shippable MVP. Requires authenticated GitHub CLI (gh) in this repository.
argument-hint: "<issue-number-or-url> [--light|--standard|--deep] [--single|--multi] [--no-pr] [--frontend|--backend|--fullstack] [--fast]"

## Mission

Take a single GitHub issue and drive it to a draft, working solution as fast as practical using parallel sub-agents with strong feedback loops:
- Independent agents run concurrently on separate concerns (code, tests, docs, review).
- Tight feedback loops ensure each change is checked by self, peers, and automation.
- Ship a thin, verifiable slice first (MVP), then iterate.

## Preconditions

- You are in the root of this Git repo.
- gh is installed and authenticated. `gh auth status` returns OK.
- Working tree is clean or your uncommitted changes are unrelated to this issue.
- You have permission to push a branch and open a draft PR.

## Inputs and Flags

- Required: <issue-number-or-url> (e.g., `#123` or full URL)
- Depth:
  - `--light`: Minimal research. Skip deep triage; aim for a quick patch (≤ 2 hours).
  - `--standard` (default): Normal triage + parallel sub-agents.
  - `--deep`: Spike-level analysis; more rigorous planning and edge-case coverage.
- Scope splitting:
  - `--single`: Single PR flow even if larger.
  - `--multi`: Split into multiple sequential PRs if scope ≥ 2 days.
- Surface focus:
  - `--frontend` | `--backend` | `--fullstack` (default).
- Other:
  - `--no-pr`: Don’t create a draft PR immediately.
  - `--fast`: Aggressive timeboxes and smaller initial MVP.

## Repo-aware Defaults (Elixir Umbrella)

- Build/format/test:
  - `mix deps.get`
  - `mix compile`
  - `mix format --check-formatted` (or just `mix format` if allowed)
  - `mix test`
- Phoenix assets (if needed):
  - `npm ci --prefix apps/otto_live/assets`
  - `npm run build --prefix apps/otto_live/assets`
- If any tool isn’t configured (credo, dialyzer, etc.), skip gracefully.

## Core Roles (Sub-Agents)

Always run these as independent Claude Code sub-agents to enable true parallel progress and cross-checking. Use the Anthropic Claude Code sub-agent API to create named agents with clear goals and minimal, focused context per role.

- tech-lead (planner/orchestrator)
  - Produces: scope statement, file-level impact map, MVP definition, acceptance criteria refinement.
  - Maintains: the “plan.md” in-branch, updated as scope evolves.
- implementer-frontend (if applicable)
  - Implements UI and wiring. Keeps changes small and independently testable.
- implementer-backend (if applicable)
  - Implements API/domain/data changes. Adds instrumentation where helpful.
- test-engineer
  - Writes failing tests first (red). Coordinates with implementers to get to green.
- code-reviewer
  - Continuously reviews diffs; enforces conventions and keeps scope tight.
- docs-writer
  - Updates README, inline docs, ADR (if needed), and PR description. Focuses on operability and usage steps.
- qa-analyst
  - Runs the app, reproduces the issue, verifies the fix/feature against acceptance criteria and edge cases.
- security-review (optional for DEEP)
  - Threat model for surface area touched, checks PII/logging, authZ/authN boundaries.

## Feedback Mechanisms (Critical)

Power comes from checks and feedback:
- Self-check: Each agent maintains a checklist and confidence score. They block themselves if confidence is low.
- Cross-check:
  - test-engineer verifies implementers by writing failing tests first.
  - code-reviewer checks diffs continuously.
  - qa-analyst verifies user behavior, edge cases, and accessibility basics.
- Automated:
  - mix compile/test
  - formatters/linters if available
  - asset build (if UI changed)
- GitHub feedback:
  - Comment progress to the issue (checklist, links).
  - Keep draft PR updated with MVP scope and what’s left.
- Usage Rules & Tidewave:
  - Consult otto/Claude.md at intake; extract applicable rules (Phoenix, Ecto, OTP supervision, etc.) and record them in plan.md.
  - Run `mix usage_rules.search_docs` for relevant dependencies and capture key constraints in plan.md. If rules are outdated, run `mix usage_rules.update` and commit the sync.
  - For UI/backend debugging or runtime verification, use Tidewave at http://localhost:4000/tidewave (MCP endpoint at /tidewave/mcp) to:
    - Select UI elements, inspect assigns/state, and evaluate code.
    - Validate assumptions and generate small, reviewable patches.
    - Link notable Tidewave observations or artifacts in the PR description.

## Branch and PR Strategy

- Branch name: `issue-<number>-<kebab-title>` (truncate title to sane length).
- Commit style: Conventional commits referencing the issue (e.g., `feat(live): ... (#123)`).
- Draft PR early (unless `--no-pr`): link to the issue, include MVP and checklists.
- Push frequently; keep diffs small; let reviewer/QA comment early.

## Parallel Orchestration (Sub-Agent Task Graph)

All non-trivial work runs in parallel. Keep timeboxes tight.

```yaml
# Phase 0: Intake & Triage
- Task(tech-lead, "Ingest issue, confirm reproduction/goal, produce minimal MVP plan, file-impact map, risks")
- Task(code-reviewer, "Define code style/conventions to enforce; list sensitive areas to watch")
- Task(test-engineer, "Outline test plan; write initial failing test(s) for current behavior")

# Phase 1: Prepare Workspace (serial but fast)
- Task(tech-lead, "Create branch and draft PR; post initial checklists to issue/PR")
- Task(tech-lead, "Scaffold plan.md in branch with MVP definition and acceptance criteria")

# Phase 2: Build Cycle (fully parallel)
- Task(implementer-backend, "Implement backend slice for MVP")
- Task(implementer-frontend, "Implement frontend slice for MVP")
- Task(test-engineer, "Convert failing tests to passing incrementally")
- Task(docs-writer, "Document usage and operational notes as they emerge")
- Task(code-reviewer, "Continuously review diffs, enforce small PR chunks; request changes")
- Task(qa-analyst, "Manually verify MVP, accessibility basics, edge cases; record defects")

# Feedback Gates (repeat until green)
- Gate("compile", "mix compile")
- Gate("format", "mix format --check-formatted or mix format")
- Gate("tests", "mix test")
- Gate("review", "code-reviewer signs off on current diff")
- Gate("qa", "qa-analyst confirms acceptance criteria met")

# Phase 3: Finalization
- Task(docs-writer, "Polish README/PR description; link issue and add test coverage summary")
- Task(tech-lead, "Update plan.md with what shipped/what’s next; summarize risks left")
- Task(tech-lead, "Mark PR ready for review; update issue comment with final checklist status")
```

## Execution Flow (Detailed)

1) Intake
- `gh issue view <issue> --json number,title,body,url,labels,assignees`
- tech-lead synthesizes:
  - Scope statement & MVP
  - Acceptance criteria (tight, verifiable)
  - File-level impact map (which apps/directories/files are likely to change)
  - Risk list and constraints
- If `--light`: aggressively simplify. Aim for a minimal patch.

2) Branch & Draft PR
- Create branch: `git fetch origin && git checkout -b issue-<n>-<kebab>`
- Create draft PR (unless `--no-pr`):
  - `gh pr create --draft --title "WIP: <issue title> (#<n>)" --body "<link to issue>\n\n- MVP: ...\n- Checklist: ..."`
- Comment on issue with:
  - Branch name
  - Draft PR URL
  - Initial checklists (MVP items, test plan, docs plan)
  - Current confidence score from each agent

3) Parallel Work (Timeboxed)
- Default timeboxes:
  - tech-lead: 30–45m planning (DEEP up to 90m)
  - implementers: 60–120m per iteration
  - test-engineer: 45–90m per iteration
  - reviewer: continuous
  - docs: 30–60m
  - QA: 30–90m
- test-engineer writes failing tests first; “red” must be observed.
- implementers push narrow changes frequently; reference issue in commits.
- reviewer blocks merges if scope creep or risky changes appear.
- QA tests user flows as soon as there is a runnable slice.

4) Feedback Gates (Repeat)
- compile: `mix compile`
- format: `mix format --check-formatted` or auto-format if project settings allow
- assets (if UI changed): `npm ci --prefix apps/otto_live/assets && npm run build --prefix apps/otto_live/assets`
- tests: `mix test` must be green. If added tests are flaky, fix or quarantine with justification.
- review: code-reviewer signs off
- qa: acceptance criteria checked off

5) Wrap-up
- docs-writer finalizes docs and PR description.
- tech-lead updates plan.md with what shipped and leftover nice-to-haves.
- Convert PR from draft to ready:
  - `gh pr ready`
- Post final status to the issue with:
  - ✅ Criteria checklist (all checked)
  - ✅ Test summary (files, coverage delta if available)
  - ✅ PR link and “fixes #<n>” if policy allows auto-close on merge

## GitHub CLI Interactions

- Read issue:
  - `gh issue view <issue> --json number,title,body,url,labels,assignees`
- Comment progress:
  - `gh issue comment <issue> --body "<status markdown>"`
- Create draft PR:
  - `gh pr create --draft --title "WIP: <title> (#<n>)" --body "<body with MVP/checklists>"`
- Mark ready:
  - `gh pr ready`

## Conventions

- Branch: `issue-<n>-<kebab-title>`
- Commits: Conventional commits. Reference issue number.
- Plan doc: `plan.md` at repo root or affected app directory; link from PR.
- Tests are not optional: failing first, passing later.

## Done Definition

- All acceptance criteria checked.
- All tests passing; new tests cover the change.
- Reviewer approval (internal gate).
- QA sign-off on behavior.
- Docs updated (README, ADR if architectural).
- Draft PR converted to “ready for review.”

## Failure & Recovery

- If a gate fails repeatedly:
  - Reduce scope (MVP).
  - Split into smaller PRs (`--multi`).
  - Add a spike (switch to `--deep`) to de-risk.
- If two implementers conflict:
  - Re-slice the surfaces to avoid file contention.
  - Use feature flags or toggles to isolate.
- If ambiguity blocks work:
  - tech-lead posts clarifying questions as a GitHub issue comment and proceeds only with safe assumptions.
- Deadman switch:
  - If no meaningful progress in 90 minutes (STANDARD), post an issue comment detailing blockers and a proposed path (options A/B/C).

## Parallel Task Examples (Correct)

```yaml
# CORRECT: Independent and parallel with checks
- Task(tech-lead, "Produce MVP plan with file-impact map")
- Task(test-engineer, "Write failing test for bug reproduction path")
- Task(implementer-backend, "Add fix in apps/otto_llm/... and unit tests for provider edge case")
- Task(implementer-frontend, "Wire error handling to surface backend change in LiveView")
- Task(code-reviewer, "Review diffs every 30 min; enforce small commits")
- Task(qa-analyst, "Manual verify via Phoenix endpoint; confirm states")

# Gates
- Gate("compile", "mix compile")
- Gate("tests", "mix test")
- Gate("review", "code-reviewer sign-off")
- Gate("qa", "qa-analyst acceptance check")
```

## LIGHT vs STANDARD vs DEEP

- LIGHT:
  - Skip deep triage. Aim for a targeted change. Single implementer + tester + reviewer.
  - No multi-PR splitting. Keep it under 2 hours.
- STANDARD (default):
  - Full core team, normal timeboxes.
  - Split PRs only if scope ≥ 2 days or if diffs become large.
- DEEP:
  - Add security-review; extra effort on edge cases and architecture notes.
  - May produce an ADR and multiple sequential PRs.

## What This Command Will Do

- Read the GitHub issue and synthesize a plan.
- Create the branch and draft PR (unless `--no-pr`).
- Spin up sub-agents and run them concurrently with feedback gates:
  - Implementers write code.
  - test-engineer writes tests red→green.
  - reviewer blocks low-quality diffs.
  - docs-writer and qa-analyst keep pace with changes.
- Keep the issue and PR updated with progress and checklists.
- Converge on a ready-for-review PR meeting the acceptance criteria.

## Output

- Draft PR URL (or ready PR if already finalized).
- Updated issue comment with:
  - Linked branch and PR
  - MVP definition
  - Checklists and confidence scores
  - What shipped and what’s left

## Notes on Anthropic Claude Code Sub-Agents

- Use structured sub-agent invocations with narrow, role-specific prompts and minimal context.
- Keep agent context focused (files they own, checklists, gate outputs).
- Share artifacts via repo (plan.md, tests, docs) so agents can cross-reference without bloating context.
- Prefer small, frequent commits to keep reviewer/QA in the loop and to simplify backtracking.

## Otto Usage Rules & Tidewave Integration

- Source of truth: otto/Claude.md. The tech-lead must synthesize applicable rules during Phase 0 and record them in plan.md. All agents are expected to follow these rules when proposing or reviewing changes.
- Usage Rules tasks:
  - `mix usage_rules.search_docs` to pull guidance for touched deps (e.g., Phoenix LiveView, Ecto).
  - `mix usage_rules.update` if local rules are stale; commit the update in its own small commit.
- Tidewave workflow (when app surface is involved):
  - Start the app: `iex -S mix phx.server`
  - Open http://localhost:4000/tidewave and use:
    - point-and-click element selection to map UI to code
    - runtime evaluation to inspect assigns/process state
    - MCP tools at http://localhost:4000/tidewave/mcp for integrated automation
  - Capture key insights as comments in the PR and update plan.md accordingly.
- Gates augmented:
  - Add a “Usage Rules conformance” check: confirm code follows guidance discovered via usage_rules; reviewer enforces.
  - Add a “Tidewave validation” check for UI flows: record what was verified and outcomes in PR.
- Reporting:
  - Include links to Tidewave sessions or screenshots (if available) and the summarized rules applied, in the PR body under an “Operational Evidence” section.
