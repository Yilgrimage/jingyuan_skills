#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
RAW_RUNTIME="${CODEX_RAW_RUNTIME:-${ROOT_DIR}/runtime_sources/codex_eu_online_20260715_raw/runtime}"
TARGET="${CODEX_TRAINING_WORKSPACE:-${ROOT_DIR}/runtime_sources/codex_eu_online_20260715_training_workspace}"
MODEL_CATALOG_OUT="${CODEX_MODEL_CATALOG_OUT:-${ROOT_DIR}/runtime_sources/codex/model_catalog_1m.json}"
OVERLAY="${MCP_RATE_LIMIT_OVERLAY:-${SCRIPT_DIR}/runtime_overlays/mcp_rate_limit_overlay.py}"
FORCE=0

usage() {
  cat <<'EOF'
Usage: derive_codex_training_workspace.sh [options]

Derive a training-safe Codex agent workspace from an online Codex runtime
mirror. The raw mirror remains the source of truth. This script preserves the
online skills tree except for clear runtime outputs/logs/caches, rewrites only
portable path references in AGENTS.md, and adds the training-only MCP QPS
overlay without changing online GNE/PSM routing semantics.

Options:
  --raw-runtime DIR       Raw online runtime mirror containing AGENTS.md/skills
  --target DIR            Derived training workspace output
  --model-catalog PATH    Durable model catalog copy output
  --overlay PATH          QPS overlay module to copy into mcp_tools_usage/scripts
  --force                 Replace existing target
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --raw-runtime) RAW_RUNTIME=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --model-catalog) MODEL_CATALOG_OUT=$2; shift 2 ;;
    --overlay) OVERLAY=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

RAW_RUNTIME="$(cd "${RAW_RUNTIME}" && pwd -P)"
test -f "${RAW_RUNTIME}/AGENTS.md"
test -d "${RAW_RUNTIME}/skills"
test -f "${RAW_RUNTIME}/skills/mcp_tools_usage/scripts/mcp_tool_call.py"
test -f "${OVERLAY}"

if [ -e "${TARGET}" ] && [ "${FORCE}" -ne 1 ]; then
  echo "Target exists; pass --force to replace: ${TARGET}" >&2
  exit 1
fi

tmp="${TARGET}.next"
rm -rf "${tmp}"
mkdir -p "${tmp}"

cp "${RAW_RUNTIME}/AGENTS.md" "${tmp}/AGENTS.md"
if [ -f "${RAW_RUNTIME}/model_catalog_1m.json" ]; then
  mkdir -p "$(dirname "${MODEL_CATALOG_OUT}")"
  cp "${RAW_RUNTIME}/model_catalog_1m.json" "${MODEL_CATALOG_OUT}"
fi

rsync -a --delete \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude '.DS_Store' \
  --exclude '._*' \
  --exclude '.env' \
  --exclude '*.env' \
  --exclude 'log/' \
  --exclude 'logs/' \
  --exclude 'sessions/' \
  --exclude 'outputs/' \
  --exclude 'cache/' \
  --exclude '.cache/' \
  --exclude '*.sqlite' \
  --exclude '*.sqlite-shm' \
  --exclude '*.sqlite-wal' \
  "${RAW_RUNTIME}/skills/" "${tmp}/skills/"

cp "${OVERLAY}" "${tmp}/skills/mcp_tools_usage/scripts/mcp_rate_limit_overlay.py"
METRICS_SOURCE="${MCP_RATE_LIMIT_METRICS:-${ROOT_DIR}/runtime_sources/agent_workspace/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py}"
if [ -f "${METRICS_SOURCE}" ]; then
  cp "${METRICS_SOURCE}" \
    "${tmp}/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py"
elif [ -f "${TARGET}/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py" ]; then
  cp "${TARGET}/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py" \
    "${tmp}/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py"
elif [ -f "${SCRIPT_DIR}/runtime_overlays/mcp_rate_limit_metrics.py" ]; then
  cp "${SCRIPT_DIR}/runtime_overlays/mcp_rate_limit_metrics.py" \
    "${tmp}/skills/mcp_tools_usage/scripts/mcp_rate_limit_metrics.py"
fi

TARGET="${tmp}" python3 - <<'PY'
from pathlib import Path
import os
import sys

target = Path(os.environ["TARGET"])
agents = target / "AGENTS.md"
text = agents.read_text(encoding="utf-8")
replacements = {
    "Canonical Codex Home: `/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime`.":
        "Canonical Codex Home: the active `CODEX_HOME` for this session.",
    "Reusable skills live under `/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime/skills`.":
        "Reusable skills live under the current workspace `./skills` symlink and the active `CODEX_HOME/skills`.",
    "Canonical Python interpreter: `/mnt/bn/ecomcommonnas/syx/miniconda3/envs/py310/bin/python`.":
        "Canonical Python interpreter: `/mnt/bn/ecomcommonnas/syx/miniconda3/envs/py310/bin/python`.",
    "normalize it to `/mnt/bn/ecomcommonnas/syx/miniconda3/envs/py310/bin/python` before execution unless a specific script has been verified to require another interpreter.":
        "normalize it to `/mnt/bn/ecomcommonnas/syx/miniconda3/envs/py310/bin/python` before execution unless a specific script has been verified to require another interpreter.",
    "MCP 通用 runner 的标准路径是 `/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime/skills/mcp_tools_usage/scripts/mcp_tool_call.py`。":
        "MCP 通用 runner 的标准路径是当前 workspace 下的 `./skills/mcp_tools_usage/scripts/mcp_tool_call.py`。",
    "重点检查 `/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime/skills`，必要时同时检查 `/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime/skills/.system`、`/mnt/bn/ecomcommonnas/mlf/agents/codex_eu/runtime/skills` 和插件缓存目录。":
        "重点检查当前 workspace 的 `./skills` 和 `CODEX_HOME/skills`，必要时同时检查 `./skills/.system` 和插件缓存目录。",
}
for old, new in replacements.items():
    text = text.replace(old, new)
agents.write_text(text, encoding="utf-8")

runner = target / "skills" / "mcp_tools_usage" / "scripts" / "mcp_tool_call.py"
code = runner.read_text(encoding="utf-8")
if "mcp_rate_limit_overlay" not in code:
    marker = "from tool_list_dirs import tool_list_output_candidates, default_output_dir\n"
    if marker not in code:
        print("Cannot patch MCP runner: import marker not found", file=sys.stderr)
        sys.exit(1)
    code = code.replace(marker, marker + "import mcp_rate_limit_overlay\n", 1)

old_tail = """    asyncio.run(
        main(
            args.psm,
            args.tool_list,
            args.tool_name,
            tool_params,
            args.transport,
            extra_headers=extra_headers,
            thunder_appid=args.thunder_appid,
            thunder_region=args.thunder_region,
            user_id=args.user_id,
            network=args.network,
            key_text=args.key_text,
        )
    )
"""
new_tail = """    with mcp_rate_limit_overlay.mcp_call_scope(args.psm, args.tool_name or args.key_text, transport=args.transport):
        asyncio.run(
            main(
                args.psm,
                args.tool_list,
                args.tool_name,
                tool_params,
                args.transport,
                extra_headers=extra_headers,
                thunder_appid=args.thunder_appid,
                thunder_region=args.thunder_region,
                user_id=args.user_id,
                network=args.network,
                key_text=args.key_text,
            )
        )
"""
if "mcp_rate_limit_overlay.mcp_call_scope" not in code:
    if old_tail not in code:
        print("Cannot patch MCP runner: asyncio.run tail marker not found", file=sys.stderr)
        sys.exit(1)
    code = code.replace(old_tail, new_tail, 1)
runner.write_text(code, encoding="utf-8")

skill_count = len(list((target / "skills").rglob("SKILL.md")))
if skill_count <= 0:
    print("No SKILL.md found after derivation", file=sys.stderr)
    sys.exit(1)
print(f"DERIVED_SKILLS={skill_count}")
print(f"DERIVED_AGENTS_CHARS={len(text)}")
print(f"DERIVED_MCP_RUNNER={runner}")
PY

python3 -m py_compile \
  "${tmp}/skills/mcp_tools_usage/scripts/mcp_tool_call.py" \
  "${tmp}/skills/mcp_tools_usage/scripts/mcp_rate_limit_overlay.py"

rm -rf "${TARGET}.old"
if [ -e "${TARGET}" ]; then
  mv "${TARGET}" "${TARGET}.old"
fi
mv "${tmp}" "${TARGET}"
rm -rf "${TARGET}.old"

echo "CODEX_TRAINING_WORKSPACE=${TARGET}"
if [ -f "${MODEL_CATALOG_OUT}" ]; then
  echo "CODEX_MODEL_CATALOG=${MODEL_CATALOG_OUT}"
fi
