---
name: openclaw-rl-discipline
description: "Use when editing, launching, reviewing, or debugging the OpenClaw-RL training/evaluation stack: mlf-dev based OpenClaw-RL forks, Hermes/OpenClaw/DeerFlow rollout backends, OpenClaw agent runtime materialization, business skills exposure, BatchQA/OpenClaw QA data, ROPD reward integration, trace/proxy diagnostics, and keeping OpenClaw-RL responsibilities separate from server ops and agentic Slime."
---

# OpenClaw-RL Discipline

## Boundaries

Use this skill for OpenClaw-RL repo behavior and runtime semantics. Keep these responsibilities separate:

- `server-ops-discipline`: node files, SSH fanout, bench/watchdog, root layout, env/data packs, node-local materialization.
- `agentic-slime-discipline`: agentic Slime configs, env abstraction, Slime-specific launch contracts.
- `openclaw-rl-discipline`: OpenClaw-RL fork diffs, rollout backend choice, Hermes/OpenClaw adapter behavior, skills loading, BatchQA/OpenClaw QA data, ROPD reward, trace/proxy diagnostics.

Do not move OpenClaw-RL-specific rules into server ops. Do not copy generic bench/watchdog/materialization logic into OpenClaw-RL.

## First Checks

Before changing code or launching a run:

1. Check the active repo and branch with `git status --short --branch`.
2. Identify whether the checkout is upstream `mlf_dev`, a user branch, or a migration branch.
3. Inspect the effective backend: `OPENCLAW_QA_ROLLOUT_BACKEND`.
4. Treat Hermes, OpenClaw, and DeerFlow as validated mlf-dev training backends unless current logs prove otherwise. If one fails in a fork, first suspect runtime materialization, env packs, credentials, paths, or dependency conflicts.
5. Verify selected node-local backend runtime files before starting GPUs:
   - Hermes backend: `~/.hermes/hermes-agent-local/current/run_agent.py`, `~/.hermes/skills`, `~/.hermes/config.yaml`, `~/.hermes/.env`.
   - OpenClaw backend: `~/.openclaw-rl-agent-backends/openclaw/current/openclaw.mjs`, `~/.local/bin/openclaw-rl-agent-openclaw-adapter`.
   - DeerFlow backend: `~/.openclaw-rl-agent-backends/deer-flow/current` and its configured gateway.
6. Stop bench only immediately before training; restart bench if the run fails or leaves GPUs idle.

## Backend Semantics

`OPENCLAW_QA_ROLLOUT_BACKEND=hermes` means OpenClaw-RL calls Hermes AIAgent directly. A known-good Hermes setup uses NAS as source, but runs node-local:

- source repo: shared checkout such as `.../mlf/code/hermes-agent`
- node-local runtime: `~/.hermes/hermes-agent-local/current`
- node-local skills: `~/.hermes/skills`
- skills source: a shared zip such as `.../mlf/code/tmp_data/skills_0430.zip`

`OPENCLAW_QA_ROLLOUT_BACKEND=openclaw` means OpenClaw-RL calls the OpenClaw agent command. It needs a separate Node/OpenClaw runtime:

- source repo may be shared storage, for example `.../mlf/code/openclaw`
- node-local runtime must contain `~/.openclaw-rl-agent-backends/openclaw/current/openclaw.mjs`
- wrapper must exist at `~/.local/bin/openclaw-rl-agent-openclaw-adapter`
- business skills are controlled by `OPENCLAW_RL_AGENT_SKILL_DIRS` and `OPENCLAW_RL_AGENT_SKILLS`

`OPENCLAW_QA_ROLLOUT_BACKEND=deerflow` means OpenClaw-RL calls the DeerFlow agent service/gateway. It needs a node-local DeerFlow runtime under `~/.openclaw-rl-agent-backends/deer-flow/current`, a configured local gateway, and the same business skills exposed through the DeerFlow skill path.

Do not treat `hermes_openclaw_adapter.py` as proof that the Hermes backend is active. In OpenClaw backend runs, that process can be only the local OpenAI-compatible model bridge used by OpenClaw to call the policy server.

## Runtime Materialization

NAS is the source of truth; node-local is the runtime. Do not run Python or Node dependency trees directly from NAS when they contain many small files.

Prepare reusable backend packs for every backend that may be used in training. Packs should make a reset node reproducible without changing the agent harness:

- Hermes pack: local Hermes release/venv contract plus skills/env materialization inputs.
- OpenClaw pack: local OpenClaw release, Node/pnpm dependencies if needed, adapter wrapper, workspace/persona files, and business skills materialization inputs.
- DeerFlow pack: local DeerFlow release/env/gateway dependencies and business skills materialization inputs.

Build packs from the mlf-dev validated runtime or its bootstrap scripts, publish immutable artifacts under the shared `packs` area, and materialize them to node-local paths before launch. Fix pack/env conflicts instead of editing rollout behavior.

Use `scripts/materialize_openclaw_rl_workspace.sh` on each selected node to
unpack the clean `openclaw-rl-workspace-data.tar.gz` pack into node-local
`/tmp/server-ops-runtime/openclaw-rl/workspace-data/current` and mirror the
business skills into DeerFlow's `deer-flow/current/skills/custom` when that
backend is installed. This script is OpenClaw-RL-specific glue; it must not grow
SSH fanout, bench/watchdog, conda-pack, or generic data-pack responsibilities.

For Hermes, use the Hermes GPU bootstrap flow to bundle/copy the source into `~/.hermes/hermes-agent-local/releases/...`, install a local venv, unpack skills into `~/.hermes/skills`, and merge `.env`.

For OpenClaw backend, use the OpenClaw agent backend bootstrap flow to build/install OpenClaw under `~/.openclaw-rl-agent-backends/openclaw/releases/...`, update `current`, install the rollout skill/personality files, and install the adapter wrapper.

For DeerFlow backend, use the agent backend bootstrap flow to install DeerFlow under `~/.openclaw-rl-agent-backends/deer-flow/releases/...`, update `current`, install the expected skills, and verify the configured gateway reaches the policy adapter.

If a bootstrap fails after building dependencies, prefer rerunning configuration with a skip-install/reuse path rather than rebuilding large dependency trees.

## Harness Integrity

Training and production/evaluation harness behavior must match. Do not make training succeed by narrowing the agent's capability surface unless the experiment explicitly studies that intervention.

- Do not remove tools, hide skills, inject answer labels, or expose dataset metadata that production would not expose.
- Do not rewrite persona/system prompt files to compensate for model weakness. Use the mlf-dev validated persona/runtime files and only change documented configuration knobs.
- Do not patch Hermes/OpenClaw/DeerFlow control flow to bypass real tool selection, skill discovery, MCP calls, or final-answer extraction.
- Do not add smoke-only prompt hints, tool allowlists, fake skills, or backend-specific shortcuts to a real training run.
- If model behavior is poor under the real harness, treat it as data/model/reward signal. If the harness crashes or cannot start, treat it as environment/materialization work.

## Trace Diagnostics

Do not judge a rollout only from the main log. Always inspect run artifacts:

- `trace.jsonl`: per-sample backend result, status, final response extraction, reward deferral, and remove-sample flag.
- `proxy_record.jsonl`: policy-server calls recorded by the local OpenAI-compatible proxy.
- `train_metrics.jsonl`: Slime/OpenClaw-RL reward and train metrics.

Key interpretations:

- `OpenClaw entrypoint not found: .../openclaw.mjs` means OpenClaw backend runtime is not materialized. It is not a model quality result.
- `emitted no OpenClaw samples` plus empty `proxy_record.jsonl` means the external agent did not reach the policy model.
- `status=aborted` and `remove_sample=true` means the sample should not be treated as useful training signal.
- Empty final response can be a parser/runtime issue; check backend raw result and proxy records before blaming the model.

## ROPD Integration

Keep ROPD as a reward-model path, not post-process reward glue:

- use `CUSTOM_RM_PATH=ropd_reward.reward_func`
- use `GROUP_RM=1` when the reward needs a group of student rollouts
- keep rollout generation separate from reward scoring
- prefer trace-aware answer modes that fit context, such as `final_with_no_tool_trace`, when full tool responses are too long

A reasonable ROPD group contains the question/task, teacher/reference answer or trace, and multiple student rollouts. Rubric generation may know teacher/student roles. Verification should anonymize or shuffle answers when comparing scores.

If the judge/rubric provider has TPM pressure, split rubric and judge across separate keys/endpoints before disabling reasoning or silently truncating traces.

## Data And Skills

Do not assume dataset metadata labels are available to the model at runtime. If production OpenClaw expects the model to discover skills from the skill directory, training/eval should preserve that behavior unless the experiment intentionally studies labeled skill hints.

Keep OpenClaw-RL workspace/data packs clean and whitelist-based. Do not pack a whole `tmp_data` directory when it contains sessions, logs, historical archives, test scripts, eval scratch, or secrets. A training workspace pack should normally include only:

- `train_data/` or the explicit training JSONL files required by the run
- `skills/` containing the business skills that production/eval would expose
- persona/workspace files such as `agents.md`, `soul.md`, and `IDENTITY.md` when the backend expects them

Exclude `.env`, API keys, `sessions.zip`, `span.log`, `test_*.py`, old skills zip/tar archives, generated reports, and unrelated eval sets unless a specific run config explicitly needs one of them. Extra files in the agent workspace can change model behavior because the real harness may let the agent inspect local files.

When a model repeatedly reads random local files or generic skills:

1. Inspect the actual sample distribution and required skills/tools metadata.
2. Verify `OPENCLAW_RL_AGENT_SKILL_DIRS` points at the intended business skills.
3. Verify the runtime prompt tells the agent how to read `SKILL.md` files without giving away answer labels.
4. Compare against mlf-dev's actual training chain before adding harness shortcuts.

## Change Discipline

Prefer new scripts/profiles for user experiments. Do not overwrite upstream mlf-dev paths unless explicitly syncing upstream. Keep uncommitted changes visible with `git status`; do not reset or delete user branches.

Avoid patch piles in generic launchers. If a variable is backend-specific, keep it close to the OpenClaw-RL profile or adapter that owns it. Treat legacy names like `HERMES_*` as compatibility names only; verify the actual backend from `OPENCLAW_QA_ROLLOUT_BACKEND`.

When a run fails, stop only selected OpenClaw-RL/Ray/SGLang/backend processes. Do not kill unrelated user processes or unrelated env servers.
