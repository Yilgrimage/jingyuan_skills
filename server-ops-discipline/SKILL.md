---
name: server-ops-discipline
description: "Use when preparing remote servers or GPU nodes, building/publishing reusable conda runtime packs or data packs, materializing node-local environments, handling node IP files, launching distributed jobs, preserving idle GPUs with watchdog/bench, separating durable shared-storage state from disposable local state, or moving this workflow to another cluster."
---

# Server Ops Discipline

Keep server operations reproducible. Durable state belongs on shared storage or
in git; node-local state is disposable and should be rebuilt from packs or
scripts.

## Bundled Scripts

This skill ships reusable ops scripts under `scripts/`. Install or sync them to
the shared cluster root before wiring project launchers to them:

```bash
mkdir -p "${ROOT_DIR}/scripts"
cp -a server-ops-discipline/scripts/. "${ROOT_DIR}/scripts/"
chmod +x "${ROOT_DIR}/scripts/"*.sh
```

Before using these scripts on a new machine or cluster, determine the current
shared workspace root with the user and confirm it explicitly. Store that value
in a local, non-git config file:

```bash
server-ops-discipline/scripts/configure_root.sh /path/to/current/root
```

By default this writes `${HOME}/.jingyuan/server_ops.env`. Do not commit this
file or any concrete root path. If a different config location is needed, set
`SERVER_OPS_CONFIG=/path/to/local/env`.

Use `ROOT_DIR` as the portable root for the cluster workspace. Do not introduce
project- or cluster-branded root variables in reusable ops scripts. The mounted
cloud disk, user, and workspace name can change across clusters; callers should
set `ROOT_DIR` explicitly or install the scripts under `${ROOT_DIR}/scripts` so
they can infer it from their location.

Stable interfaces:

```text
${ROOT_DIR}/scripts/run_bench.sh start|stop|status|restart [--nodes nodes.txt --node 0,1]
${ROOT_DIR}/scripts/gpu_idle_watchdog.sh start|stop|status|restart
${ROOT_DIR}/scripts/configure_root.sh /path/to/current/root
${ROOT_DIR}/scripts/prepare_node_runtime.sh --local-only|--all-nodes ...
${ROOT_DIR}/scripts/materialize_node_runtime.sh --envs ... --data ... --sources ...
${ROOT_DIR}/scripts/pack_data.sh
```

Launchers that need `bench_on_exit` must call `${ROOT_DIR}/scripts/run_bench.sh`
instead of embedding their own keepalive implementation. Watchdogs must call the
same `run_bench.sh` interface. Repo-specific launch code may set `ROOT_DIR`,
`LOCAL_ENVS_DIR`, `LOCAL_RUNTIME_DIR`, `PACK_DIR`, `BENCH_PYTHON`, SSH
variables, and node selectors, but should not duplicate these scripts.

Reusable ops scripts must not default to one training stack. Runtime
materialization defaults to `none`; callers choose environment packs, datasets,
and source mirrors explicitly. `run_bench.sh` defaults to system Python, and
training repos should pass `BENCH_PYTHON` when CUDA torch lives in a project
environment.

## State Model

- Treat shared storage as the source of truth for code, data, models, packs,
  secrets, and run outputs.
- Treat node-local disks as cache: envs, source mirrors, data mirrors, and temp
  runtime state can be deleted and materialized again.
- Do not install packages during normal training startup. Build reusable packs
  first, then materialize them onto nodes.
- Keep generated outputs out of git: run logs, checkpoints, W&B outputs, data,
  model weights, env packs, secrets, and node-local runtime files.

Recommended root layout:

```text
${ROOT_DIR}/code
${ROOT_DIR}/data
${ROOT_DIR}/models
${ROOT_DIR}/packs
${ROOT_DIR}/runs
${ROOT_DIR}/secrets
${ROOT_DIR}/scripts
${LOCAL_ENVS_DIR:-/tmp/server-ops-envs}
${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}
```

When moving clusters, preserve the same roles even if the paths change.

## Node And IP Handling

- Maintain one node file as the source of truth for current IPs.
- Let topology or launch profiles select nodes by index from that file.
- Do not scatter literal IPs through training configs, env configs, aux configs,
  or scripts.
- Keep real node files local and out of git. Commit only example templates such
  as `configs/nodes/agent_env_all.txt.example`; ignore filled `*.txt` files.
- After resource reset, update the node file first, then prepare runtime, then
  launch jobs.
- Prefer idempotent per-node setup commands. A repeated setup should either skip
  unchanged packs or rebuild only what is stale.

## Runtime Pack Discipline

- Split runtime packs by dependency domain. Do not create one giant mutable
  environment that every task edits.
- For foundation training stacks such as Slime, Verl, SGLang, vLLM, Megatron,
  and PyTorch, prefer the node/container image's preinstalled environment when
  it matches the target stack. If the image does not provide a compatible stack,
  use a separately packed conda environment as the fallback.
- Keep task or environment dependencies such as ALFWorld, WebShop, tau2, and
  custom env servers in dedicated conda environment packs even when the training
  stack comes from the image. Do not mix these env dependencies into the base
  training environment during launch.
- Use `${ROOT_DIR}/scripts/pack_data.sh`,
  `${ROOT_DIR}/scripts/prepare_node_runtime.sh`, and
  `${ROOT_DIR}/scripts/materialize_node_runtime.sh` as the shared vocabulary for
  pack creation and node-local installation.
- Keep data/source packs separate from conda or Python environment packs.
- Keep model checkpoints on shared storage unless local copies are explicitly
  needed and documented.
- Do not hot-edit dependency checkouts for temporary fixes. Store repeatable
  dependency changes as patch files and provide apply/check/reverse commands.
- Materialization scripts should be explicit about what they install, copy, or
  skip; avoid hidden package installation inside launch scripts.

## Env Pack Lifecycle

- Build or modify conda/task environments on node-local storage such as
  `${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}/envs/<name>` or another
  documented local path. Do not run Python directly from a NAS env directory;
  NAS envs have slow small-file IO and stale absolute prefixes.
- Use conda-pack for reusable runtime packs that need relocation. A copied venv
  or conda directory is not a pack; extracted conda packs must run
  `conda-unpack` before use.
- Publish only immutable pack artifacts to shared storage:
  `${ROOT_DIR}/packs/<name>.tar.gz`,
  `${ROOT_DIR}/packs/<name>.tar.gz.sha256`, and
  `${ROOT_DIR}/packs/<name>.revision`. Archive the previous pack under
  `${ROOT_DIR}/packs/archive/` before replacement.
- Prefer repo-owned env build scripts for env-specific dependencies. The skill
  owns the pack/materialize discipline; project repos own dependency lists such
  as ALFWorld, WebShop, tau2, or custom MCP server packages.
- Pin or record any package versions added during pack repair, then update the
  build script. Do not leave a pack that can only be reproduced from shell
  history.
- Validate before publishing: run `pip check` when applicable, import critical
  modules, and run an env-specific smoke test. For service envs, exercise the
  real transport path when possible, such as an MCP PSM tool call.
- After publishing, materialize with
  `${ROOT_DIR}/scripts/prepare_node_runtime.sh --all-nodes --envs <name> ...`
  and use `--force` when replacing an existing local env. Confirm each node's
  `${LOCAL_ENVS_DIR}/<name>/.pack.sha256` matches the published sha.
- Treat `conda-pack` warnings about missing package cache as non-fatal only
  after validating a fresh unpack on another node. The extracted env must pass
  imports and smoke tests after `conda-unpack`, which
  `materialize_node_runtime.sh` runs automatically.
- Keep secrets, node IP files, run logs, model weights, datasets, and editable
  source checkouts out of env packs. Pass secrets through `${ROOT_DIR}/secrets`
  or runtime environment variables.
- For foundation training stacks, prefer the image runtime when it already
  contains Slime, SGLang, Megatron, and Torch. Use a Slime conda pack only as a
  fallback, and never point generic launchers at another local repo checkout to
  borrow dependencies.

## Known Agent Env Packs

Agent environment packs use the same materialization interface. The skill
scripts unpack by pack name; environment-specific dependency construction stays
in the project repository that owns the adapter.

Common names:

```text
alfworld    ${ROOT_DIR}/packs/alfworld.tar.gz
webshop     ${ROOT_DIR}/packs/webshop.tar.gz
tau2        ${ROOT_DIR}/packs/tau2.tar.gz
appworld    ${ROOT_DIR}/packs/appworld.tar.gz
mcp_server  ${ROOT_DIR}/packs/mcp_server.tar.gz
```

For agentic Slime, keep build scripts such as
`scripts/utils/build_alfworld_env.sh` and
`scripts/utils/build_webshop_env.sh` in the Slime fork, because they encode
adapter-specific package versions and smoke tests. After publishing a pack,
install it on nodes through the root scripts:

```bash
${ROOT_DIR}/scripts/prepare_node_runtime.sh --all-nodes --envs alfworld --data alfworld --sources none
${ROOT_DIR}/scripts/prepare_node_runtime.sh --all-nodes --envs webshop --data webshop --sources webshop
```

Use `--force` when replacing an existing pack with a new sha. WebShop has a
source/data layout that requires `--sources webshop --data webshop`; ALFWorld
normally only needs the env pack and ALFWorld data because the adapter lives in
the agentic Slime repository.

## Launch And Process Discipline

- Separate runtime preparation from job launch.
- Launchers orchestrate services and submit jobs; they should not own algorithm
  or experiment semantics.
- Prefer tmux/system sessions with clear names and logs for long-running remote
  processes.
- Always leave an auditable run directory with resolved config, launch logs,
  service logs, and train logs.
- When resetting experiments, stop old train/Ray/env processes on selected nodes
  before starting the new run. Do not kill unrelated user processes.

## GPU Keepalive

- Keep GPU keepalive independent of the training framework.
- Watchdog should protect idle GPUs by utilization only, not by checking Slime,
  Ray, tmux session names, or process names.
- Bench should be a replaceable keepalive workload. Starting bench should not
  destroy unrelated tmux sessions or user processes.
- Put bench and watchdog under `${ROOT_DIR}/scripts`, not under a repo-specific
  `bash/` or `utils/` directory.
- Before launching training, stop bench on nodes used by the job. If a job fails
  and GPUs stay idle, watchdog should restart bench after the configured window.

## Debugging Order

When a remote run behaves strangely:

1. Confirm the node file and selected indexes are correct.
2. Confirm env/data packs are materialized on every selected node.
3. Check service logs and train logs before changing code.
4. Check GPU memory/utilization to distinguish startup, rollout, actor, and
   keepalive states.
5. Check resolved config files to catch shell/env pollution or stale values.
6. Add code or script changes only after locating the owning layer.
