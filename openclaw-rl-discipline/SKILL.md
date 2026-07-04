---
name: openclaw-rl-discipline
description: "Use when editing, launching, reviewing, or debugging OpenClaw-RL and its external-agent backends such as Hermes, OpenClaw, DeerFlow, or Codex; especially when checking adapter boundaries, prompt/skills/tool fidelity, rollout traces, ROPD reward integration, and upstream harness/runtime alignment."
---

# OpenClaw-RL Discipline

## Principle

Treat OpenClaw-RL as a thin RL outer loop around a real agent harness. The
training adapter must not become the harness. If a run only works because the
adapter changed prompts, tools, skills, memory, search, final-answer behavior,
or model-visible metadata, the run is not a faithful OpenClaw-RL rollout.

## Ownership

- `openclaw_batch_qa.py`: batch/group scheduling, external-agent subprocess
  launch, proxy sample collection, trace metadata, and reward hooks.
- Backend harness: Hermes/OpenClaw/DeerFlow/Codex prompt construction, tool
  selection, skill discovery, tool execution, and final-answer behavior.
- Backend adapter: isolated runtime setup, model-provider routing to the local
  policy proxy, non-model-visible session propagation, process launch, and
  result parsing.
- Server ops: node files, SSH fanout, bench/watchdog, env packs, and
  node-local materialization. Do not reimplement these in OpenClaw-RL.

## Adapter Boundary

An adapter may:

- Create an isolated home/workspace required by the backend.
- Point the backend's model provider at the OpenClaw-RL policy proxy.
- Pass `session_id` through environment variables, HTTP headers, request
  metadata, or command arguments that are not shown to the model.
- Expose the already-materialized business skills directory exactly as the
  backend expects, preferably by symlink.
- Start backend-local helper processes that are part of the real harness.
- Return structured stdout/stderr/final-response metadata to `openclaw_batch_qa`.

An adapter must not:

- Set `systemPromptOverride` or otherwise replace the backend's native system
  prompt for a real run.
- Write model-visible bootstrap files that tell the model how to behave for RL.
- Inject session ids, dataset labels, teacher answers, expected skills, or
  scoring hints into model-visible context.
- Remove or add tools/skills to compensate for model weakness.
- Patch final-answer extraction or tool protocols unless the same change is part
  of the real production/eval harness.
- Enable/disable memory, browser/search, or MCP runtime behavior only as an
  explicit run policy or runtime fix, and record it in the run artifacts.
- Treat synthetic trace text with zero logprobs as valid training data without
  an explicit experiment label.

## OpenClaw Backend Checks

For `HARNESS_BACKEND=openclaw`, the command should launch the real
OpenClaw agent path. OpenClaw itself should build the system prompt through its
native prompt builder and skills snapshot.

Before trusting any rollout data:

- Inspect generated OpenClaw config and confirm it has no `systemPromptOverride`.
- Confirm the model-provider request carries `X-Session-Id` or equivalent
  non-model-visible metadata.
- Inspect `proxy_record.jsonl` and confirm the effective prompt contains the
  native skills section expected by the selected OpenClaw version, for example
  `## Skills` / `<available_skills>` when that is how the source harness works.
- Confirm `trace.jsonl` has proxy samples with non-empty response ids/logprobs
  for completed model turns.
- Mark rollout data invalid if the adapter bypassed native skills prompt
  construction or if the prompt/tool surface differs from the target harness.

## Codex Backend Checks

For `HARNESS_BACKEND=codex`, Codex-specific code should stay in the
Codex adapter: isolated `CODEX_HOME`, Codex CLI invocation, and any protocol
translation needed to reach the policy proxy.

Codex uses the Responses API and can expose tools that chat-completions servers
cannot represent. The default Codex bridge should be Responses pass-through:
Codex talks to `/v1/responses`, and the middle layer only adds non-model-visible
session metadata or narrow compatibility fixes. A Responses-to-chat bridge is a
debug-only approximation and must require an explicit mode such as
`HARNESS_CODEX_BRIDGE_MODE=chat_compat`. Do not use chat-compat rollout data
for formal training/evaluation, and do not hide unsupported tools by adding
prompt-written schemas.

When `chat_compat` is used, Codex itself is still speaking Responses API to the
local adapter; the adapter translates a supported subset to a chat-completions
policy server such as SGLang. This can validate runtime, skills, MCP calls, and
tool parser behavior, but it is not a native Codex harness. Treat missing
Responses-only tools, such as built-in `web_search`, as an explicit run policy
if the experiment wants to force business-skill/MCP data access. The remaining
TODO for formal Codex rollouts is a Responses-compatible policy proxy that
preserves Codex's tool surface while still recording the trace/logprob data
needed by OpenClaw-RL.

Use `HARNESS_*` as the external adapter control namespace. Shared knobs use
`HARNESS_BACKEND`, `HARNESS_SESSION_ID`, `HARNESS_ADAPTER_BASE_URL`, and
`HARNESS_AGENT_MODEL`; backend-specific knobs use `HARNESS_OPENCLAW_*` or
`HARNESS_CODEX_*`. Do not introduce `OPENCLAW_RL_AGENT_*` compatibility
fallbacks. `OPENCLAW_QA_*` belongs to BatchQA scheduling/proxy internals, not
backend prompt or runtime mutation.

## Tool Call Parser Validation

For Qwen/Qwen-Coder style models, raw XML-like assistant text such as
`<tool_call><function=...>` is a parser failure unless the OpenAI-compatible
response contains structured `message.tool_calls`.

Before trusting rollouts that require tools:

- Run a forced tool-call smoke against the exact SGLang launch command.
- Inspect `proxy_record.jsonl` or bridge debug: `finish_reason=tool_calls`
  must have `has_tool_calls=true` and non-empty `tool_calls`.
- Treat `finish_reason=tool_calls` with `message.tool_calls=null` as broken,
  even if the assistant content contains a plausible XML tool call.
- Confirm the backend actually executed the tool and received tool output in
  the trace.
- Verify the effective SGLang parser from logs and responses, not only from
  the launch flag. `qwen`, `qwen25`, and `qwen3_coder` are not interchangeable,
  and auto-detection can override expectations.
- For Qwen3.5/Qwen-Coder-style tokenizer templates that instruct the model to
  emit XML calls like `<function=...><parameter=...>`, launch SGLang with
  `--tool-call-parser qwen3_coder`. Do not use `--tool-call-parser qwen` for
  that template: it expects JSON inside `<tool_call>`, can log
  `Failed to parse JSON part`, and can return `finish_reason=tool_calls` with
  `message.tool_calls=null`.
- After changing a parser, verify that the old server process is gone and the
  active port belongs to the new command. Killing a tmux session is not enough
  if an orphaned SGLang child still owns the port.
- Do not patch the adapter to execute content-only XML unless that exact
  behavior exists in the production/eval harness.

## Runtime And Skills

Keep runtime layers separate:

- Backend runtime: Hermes/OpenClaw/DeerFlow/Codex binaries and their own deps.
- Agent workspace: persona files and business skills exposed to the backend.
- MCP runtime: Python/Node tools and credentials used by business skills.
- Data: durable NAS files selected by the run config.

Use split packs:

- `agent-business-skills.tar.gz`: business skills only.
- `agent-persona.tar.gz`: `AGENTS.md`, `SOUL.md`, and `IDENTITY.md`.
- `mcp-runtime-py312-agent-mcp.tar.gz`: Python/Node MCP runtime.
- backend runtime packs such as `openclaw-rl-openclaw-runtime.tar.gz`,
  `openclaw-rl-hermes-runtime.tar.gz`, `openclaw-rl-deerflow-runtime.tar.gz`,
  and `codex-runtime-*.tar.gz`.

Pack responsibilities:

```text
Training runtime/image:
  Runs OpenClaw-RL, Slime, Ray, SGLang/vLLM, torch, and rollout exporters.
  It must be selected before sourcing MCP env files.

Backend runtime pack:
  Provides the external harness binary/source, for example OpenClaw, Hermes,
  DeerFlow, or Codex. It does not contain business skills, data, or MCP Python.

Agent workspace packs:
  `agent-business-skills.tar.gz` contains only reusable Skill directories.
  `agent-persona.tar.gz` contains only persona/bootstrap files.
  They are materialized once per node and then symlinked or exposed through
  native backend config. Do not copy them per conversation.

MCP runtime pack:
  Provides the Python/Node/npx dependencies used by Skill scripts and MCP
  callers, plus an env file pointing to secrets. It is for backend child
  processes and tool runners, not for launching OpenClaw-RL training code.

Data:
  Stays under durable NAS data paths selected by run config. Do not put data,
  sessions, logs, or scratch outputs in reusable runtime packs.
```

Materialize business skills/persona with
`scripts/materialize_agent_workspace_layers.sh`. Source the emitted
`agent_workspace.env`; it provides `HARNESS_OPENCLAW_WORKSPACE`,
`HARNESS_OPENCLAW_PERSONA_SOURCE_DIR`, `HARNESS_OPENCLAW_SKILL_DIRS`,
`HARNESS_OPENCLAW_SKILLS`, and corresponding `HARNESS_CODEX_*`/
`HARNESS_AGENT_*` paths.

Materialize backend binaries/source with
`scripts/materialize_agent_backend_runtime.sh --backend openclaw|hermes|deerflow|codex`.
This restores only the harness runtime. It does not install business skills,
persona, MCP Python/Node dependencies, credentials, data, or training packages.
The script validates that backend packs do not contain mutable runtime state
such as logs, sessions, caches, `tmp`, or user state. Rebuild dirty packs rather
than carrying historical sessions into a fresh node.

Materialize MCP dependencies with `scripts/materialize_mcp_runtime.sh`. Source
the emitted `mcp_runtime.env`; it provides `HARNESS_AGENT_ENV_FILE`,
`HARNESS_AGENT_PYTHON_BIN_DIR`, `HARNESS_AGENT_NODE_BIN_DIR`, `MCP_PYTHON`,
`AGENT_MCP_PYTHON_BIN_DIR`, and `AGENT_MCP_NODE_BIN_DIR`.

MCP runtime validation must cover the exact paths the agent can execute, not
only `MCP_PYTHON`. Some business Skill docs call `python3` or a compatibility
path such as `/Users/bytedance/miniconda3/bin/python`. After materialization,
verify that `python3`, the compatibility path, and `MCP_PYTHON` all import the
pack-provided `bytedenv` and `bytedance.mcp`. Set `PYTHONNOUSERSITE=1` for MCP
tool child processes so stale packages under `/home/*/.local` cannot shadow the
MCP runtime and cause errors such as `bytedenv` missing
`get_current_vregion`.

Do not let `mcp_runtime.env` choose the Python interpreter for OpenClaw-RL
itself. Capture the training Python before sourcing MCP env files, for example
`TRAIN_PYTHON=${TRAIN_PYTHON:-$(command -v python3)}`, and use that interpreter
for rollout exporters and training entrypoints. The adapter may load
`HARNESS_AGENT_ENV_FILE` and prepend MCP Python/Node paths only for the backend
child process it starts.

Do not copy the full skills tree into every conversation. Materialize skills
once per node and symlink them when the backend expects a workspace-local path.
Do not pack session logs, temporary data, credentials, or historical scratch
files into reusable runtime packs.

OpenClaw should see skills through its native config and skill loader:
`agents.*.skills` selects enabled skill names, the workspace points at the
materialized persona, and `${workspace}/skills` should be a symlink to the
single materialized skills root. Do not create one symlink per skill inside a
real `${workspace}/skills` directory: OpenClaw treats those child paths as
`symlink-escape` and skips them. The adapter must not write bootstrap files,
system prompt overrides, fake skills, or prompt-visible routing instructions.

When using a long persona, set OpenClaw's native bootstrap budget fields in the
generated config, for example `agents.defaults.bootstrapMaxChars` and
`agents.defaults.bootstrapTotalMaxChars`. Otherwise OpenClaw can truncate
`AGENTS.md` at the default per-file limit even if the model context is large.

Configure memory, browser, search, and MCP behavior in the backend runtime or
OpenClaw config. Do not patch those settings from the RL adapter.

MCP auth and QPS plumbing belong in the MCP runtime/tool runner, not in the
agent adapter. Validate auth by smoke-testing the actual PSMs used by the data;
do not infer support from hard-coded PSM allowlists. Authorization failures for
a PSM are not model behavior.

Expected node-local restore order:

```bash
scripts/materialize_agent_workspace_layers.sh
source /tmp/server-ops-runtime/agent-workspace/current/agent_workspace.env

scripts/materialize_mcp_runtime.sh \
  --skills-dir "${HARNESS_OPENCLAW_SKILL_DIRS}" \
  --smoke bytedance.mcp.machine_ipr
source /tmp/server-ops-runtime/mcp/mcp_runtime.env

scripts/materialize_agent_backend_runtime.sh --backend openclaw
```

Capture the training Python before sourcing `mcp_runtime.env` if the same shell
will launch OpenClaw-RL. MCP env intentionally prepends MCP Python/Node paths
for backend child processes; it must not silently switch the training runtime.

## Reward And ROPD

Keep ROPD as a reward path, not rollout post-processing:

- Use a custom/group reward function for rubric generation and judging.
- Keep rollout generation independent from reward scoring.
- Record the answer mode, teacher source, student trace source, judge model,
  context compression, and retry policy in run artifacts.
- Do not change the backend harness to make ROPD scoring easier.

## Minimum Validation

Run these checks before launching more than a smoke batch:

```bash
python -m py_compile openclaw-rl/openclaw_batch_qa.py openclaw-rl/openclaw_api_server.py mlf/agent_gpu_bootstrap/*agent_adapter.py
rg -n "systemPromptOverride|Session ID:|BOOTSTRAP.md|OPENCLAW_RL_AGENT_|openclaw-rl-rollout" mlf/agent_gpu_bootstrap openclaw-rl || true
bash -n mlf/agent_gpu_bootstrap/*.sh mlf/run_herms/*.sh
```

For a smoke rollout, inspect:

- `trace.jsonl`
- `proxy_record.jsonl`
- backend stdout/stderr
- generated backend config
- one effective prompt captured by the proxy
- materialized `agent_workspace.env` and `mcp_runtime.env`

If the effective prompt or tool surface does not match the target harness, stop
and mark the data invalid before scaling the run.
