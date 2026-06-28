---
name: agentic-slime-discipline
description: "Use when editing, reviewing, launching, or debugging the agentic Slime RL training stack: configs/agent_env profiles, examples/agent_env rollout/reward/env code, MCP task/env configs, prompt-data alignment, Slime CLI adapters, launch profile boundaries, reward/filter/padding logic, sync/full-async training behavior, and non-invasive integration with upstream Slime."
---

# Agentic Slime Discipline

Keep the agentic Slime stack small, non-invasive, and auditable. Prefer one
clear owner for each behavior over copied profiles, wrappers, fallback branches,
or patch-style fixes.

## Core Boundary

- Do not modify Slime core for agent-env behavior unless explicitly asked.
  Prefer external hooks selected by Slime CLI arguments.
- Keep upstream Slime updateable. Agentic extensions live outside core Slime
  packages, usually under `examples/agent_env`, `configs/agent_env`, and
  launch/adapter scripts.
- Do not hide experiment semantics in launch scripts. Launchers orchestrate;
  profiles own configuration; env code owns environment behavior.
- Do not reimplement server keepalive or node materialization in agentic Slime.
  Use the server ops root interfaces, for example
  `${ROOT_DIR}/scripts/run_bench.sh`,
  `${ROOT_DIR}/scripts/gpu_idle_watchdog.sh`, and
  `${ROOT_DIR}/scripts/prepare_node_runtime.sh`.

Common hook paths:

```text
--custom-generate-function-path examples.agent_env.<env>.rollout.generate
--custom-reward-post-process-path examples.agent_env.reward_post_process.post_process_rewards
--dynamic-sampling-filter-path examples.agent_env.reward_post_process.check_reward_nonzero_std
--rollout-sample-filter-path examples.agent_env.rollout.glm_style_pad_groups_filter
--group-rm
--custom-rm-path examples.agent_env.group_rm.group_reward
--rollout-function-path examples.agent_env.fully_async_rollout.generate_rollout_fully_async
```

## Configuration Ownership

- `configs/agent_env/runs/*.env`: select env, env config, model profile, train
  profile, topology profile, optional aux profile, and experiment naming only.
- `configs/agent_env/models/*.env`: model identity, model args, loss-mask
  family, dropout/model extras, and model compatibility defaults.
- `configs/agent_env/train/*.env`: env-specific training baseline, algorithm,
  sync/full-async mode, rollout sampling/filtering, batch sizes, token budgets,
  TP/CP, actor/rollout allocation, checkpointing, logging, and Slime flags.
- `configs/agent_env/topology/*.env`: node indexes, visible GPUs, and ports
  only. Keep algorithm, batch, token, actor/rollout, model, and aux semantics
  out of topology.
- `configs/agent_env/aux/*.env`: auxiliary inference endpoint only.
- `configs/nodes/*.txt`: local node files only. Commit `*.txt.example`
  templates and ignore real IP files.
- `examples/agent_env/<env>/env_config.yaml`: environment semantics, reward
  fields, task/data settings, parser/interaction settings, and env server
  settings.
  Reward implementation and task-specific reward data also belong under this
  file's `reward:` section; use `reward.impl` and `reward.judge_mode` as the
  durable source of truth.

For `mcp_server`, keep it a generic MCP environment. IPR, search, and future
task families are selected through task-specific env configs such as
`examples/agent_env/mcp_server/env_config_ipr_product_check.yaml`. The run
profile selects the env config through `ENV_CONFIG`; train and launch profiles
must not hard-code IPR/search/task-family semantics.

Train profile names should be:

```text
<env>_<algorithm>_<sync|fullasync>_<nodes>x<gpus>.env
```

Do not include model names or aux providers in train profile names.

## Launch Contract

- Public launch resolves run/model/train/topology/aux profiles once and writes
  run-local artifacts under `RUN_ROOT/logs`. Internal head/worker roles must
  consume `resolved_launch.env` and must not re-parse git profiles.
- Treat `resolved_train.env` as the final train adapter contract: Slime CLI
  args, env semantics, model paths, and runtime overrides required by Ray
  actors. The train adapter should source this one file.
- Treat `resolved_launch.env` as launch-only state: SSH, node selectors, Ray
  ports, env service endpoints, aux lifecycle, bench/watchdog settings, and
  resolved run directories. Do not leak launch-only controls into train env.
- Allow only explicit runtime overrides from profiles or documented launcher
  inputs. Do not silently freeze arbitrary ambient shell variables into resolved
  files.
- Keep resolved files in run directories and out of git. They are audit
  artifacts, not source configuration.
- Support both image and conda-pack Slime runtimes through a small runtime
  resolver such as `scripts/utils/slime_runtime.sh`. Do not hard-code another
  repo's Megatron checkout, `/code/...` paths, or node-local development paths
  into generic launch scripts.

## Change Discipline

- Locate the current owner of a setting before editing.
- Change the existing owner instead of adding a wrapper, override layer, copied
  YAML/env file, or one-off profile.
- Create a new profile only for a durable reusable baseline.
- Add config keys only when they are consumed by the launcher/adapter or Slime
  CLI and visible in resolved profiles.
- Remove dead compatibility paths and abandoned scripts instead of preserving
  them for vague safety.
- Prefer direct APIs over thin wrappers that only rename, format one path, or
  forward arguments. Keep wrappers only when they own validation, lifecycle,
  compatibility, metrics, retry, async, or cross-module boundary behavior.

## Data Alignment

- Treat prompt data as the normalized Slime index table, not as the whole raw
  task dataset. Env-specific prompt-data builders should emit `prompt` plus
  `metadata` keys needed to reset the exact task and score it.
- Keep `ENV_CONFIG`, env server `--config`, Slime `--custom-config-path`, and
  prompt-data generation on the same file. For `mcp_server`, pass the same
  config to `prompt_data.py --config`; do not let it fall back to the mock
  `env_config.yaml` when a task-specific config is selected.
- Put task files, policy files, expected tools/skills, references, turn limits,
  and task-specific reward weights in the env config or task rows. Do not put
  those semantics in launch scripts or generic train profiles.
- Put ROPD teacher/student/rubric data paths under `reward.ropd.*`, keyed by a
  stable `join_key` such as `task_id`. Env vars may override for debugging, but
  they should not be the durable experiment definition.
- Use server-ops data materialization for physical data placement under
  `${ROOT_DIR}/data/...`. Do not hard-code old NAS paths in agentic Slime
  scripts or configs.

## Rollout And Reward Rules

- Env wrappers own prompt rendering, parser/action semantics, backend reset/step
  calls, success/score interpretation, and env-specific metadata.
- Generic rollout code owns message/token ledger, env HTTP lease lifecycle,
  sample shape, common dumping, and Slime data contracts.
- The selected RM implementation owns final reward composition: env score,
  format reward, truncation penalty, process reward, and optional judge reward.
  Keep separate implementations for naive, Valleydance-like, ROPD-like, and
  legacy behavior instead of mixing them in rollout post-processing.
- Select reward implementations through env config, for example
  `reward.impl: naive|valleydance|ropd|legacy`, with task-specific judge,
  teacher, rubric, and weight settings under that env config's `reward:`
  section. Aux profiles should describe endpoints only.
- Reward post-process should only adapt already-computed RM rewards to Slime's
  reward tensor contract, plus normalization if required by the train loop. It
  must not append env reward or format/truncation penalties.
- Group RM is the reward dispatch boundary. The default legacy implementation
  may preserve old combined behavior, but new reward logic should live under
  `examples/agent_env/rewards/`.
- Dynamic sampling drops zero-variance reward groups after RM reward
  computation. It does not resample individual samples; avoid custom
  compatibility filters that recompute a separate reward path.
- If `examples.agent_env.rollout.glm_style_pad_groups_filter` is enabled as a
  rollout sample filter, also enable a dynamic filter that drops groups with
  too few valid samples, for example
  `examples.agent_env.reward_post_process.check_reward_nonzero_std`. The sample
  filter repairs kept groups; it must not be the first layer that sees a bad
  group.
- GLM-style padding is for infra-discard recovery. Discard bad samples, then pad
  from valid samples; never train on discarded samples as real data.

## Training Pitfalls

- Disable model dropout for PPO/GRPO/RL training. Dropout corrupts old/current
  logprob comparisons and can make KL/clip metrics meaningless.
- In full-async training, use rollout-time logprobs as the old policy
  denominator, for example `USE_ROLLOUT_LOGPROBS=1`.
- Treat `train_rollout_logprob_abs_diff=0` under rollout-logprob mode as a
  metric wart if it compares rollout logprobs to themselves. Cross-check PPO KL,
  clipfrac, reward, length, and grad norm.
- Align `GLOBAL_BATCH_SIZE`, `ROLLOUT_BATCH_SIZE * N_SAMPLES_PER_PROMPT`, and
  full-async in-flight capacity unless deliberately testing staleness.
- `SGLANG_SERVER_CONCURRENCY` may limit request submission rather than SGLang's
  internal `max_running_requests`; verify the actual path before drawing
  throughput conclusions.
- Keep checkpointing sparse and capped during debugging.

## Review Checklist

- Is Slime core untouched?
- Is the run profile thin?
- Is each changed parameter in the right owner file?
- Are model, train, topology, aux, and env semantics separated?
- Are resolved profiles sufficient to audit the effective run?
- Did the change remove complexity rather than add a compensating patch?
