#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
LOCAL_RUNTIME_DIR="${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
TARGET="${AGENT_WORKSPACE_LAYERS_DIR:-${LOCAL_RUNTIME_DIR}/agent-workspace/current}"
SKILLS_PACK="${SKILLS_PACK:-${PACK_DIR}/agent-business-skills.tar.gz}"
PERSONA_PACK="${PERSONA_PACK:-${PACK_DIR}/agent-persona.tar.gz}"
CODEX_HOME_TARGET="${CODEX_HOME_TARGET:-}"
SYNC_DEERFLOW=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: materialize_agent_workspace_layers.sh [options]

Materialize split agent workspace packs into node-local runtime storage.
This script does not install OpenClaw/Hermes/Codex backends and does not
install MCP Python/Node dependencies. Use materialize_mcp_runtime.sh for MCP.

Options:
  --target DIR          Node-local target directory
  --pack-dir DIR        Shared pack directory
  --skills-pack PATH    Skills pack
  --persona-pack PATH   Persona pack
  --codex-home DIR      Optional isolated CODEX_HOME to receive business skills
  --sync-deerflow       Mirror skills to deer-flow/current/skills/custom
  --force               Re-extract even if pack hashes match
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --skills-pack) SKILLS_PACK=$2; shift 2 ;;
    --persona-pack) PERSONA_PACK=$2; shift 2 ;;
    --codex-home) CODEX_HOME_TARGET=$2; shift 2 ;;
    --sync-deerflow) SYNC_DEERFLOW=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for pack in "${SKILLS_PACK}" "${PERSONA_PACK}"; do
  if [ ! -f "${pack}" ]; then
    echo "Missing pack: ${pack}" >&2
    exit 1
  fi
done

pack_sha() {
  local pack="$1"
  if [ -f "${pack}.sha256" ]; then
    awk '{print $1}' "${pack}.sha256"
  else
    sha256sum "${pack}" | awk '{print $1}'
  fi
}

COMBINED_SHA="$(
  {
    pack_sha "${SKILLS_PACK}"
    pack_sha "${PERSONA_PACK}"
  } | sha256sum | awk '{print $1}'
)"
STAMP="${TARGET}/.layers.sha256"

if [ "${FORCE}" -eq 0 ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${COMBINED_SHA}" ]; then
  echo "AGENT_WORKSPACE_LAYERS_DIR=${TARGET} (cached)"
else
  tmp="${TARGET}.next"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  tar -xzf "${SKILLS_PACK}" -C "${tmp}"
  tar -xzf "${PERSONA_PACK}" -C "${tmp}"
  test -d "${tmp}/skills"
  test -f "${tmp}/persona/AGENTS.md"
  test -f "${tmp}/persona/SOUL.md"
  test -f "${tmp}/persona/IDENTITY.md"
  rm -rf "${TARGET}.old"
  if [ -e "${TARGET}" ]; then
    mv "${TARGET}" "${TARGET}.old"
  fi
  mv "${tmp}" "${TARGET}"
  printf '%s\n' "${COMBINED_SHA}" > "${STAMP}"
  rm -rf "${TARGET}.old"
  echo "AGENT_WORKSPACE_LAYERS_DIR=${TARGET}"
fi

TARGET="${TARGET}" python3 - <<'PY'
import os
import sys
import shutil
from pathlib import Path

target = Path(os.environ["TARGET"])

for path in list(target.rglob("outputs")) + list(target.rglob("log")):
    if path.is_dir():
        shutil.rmtree(path)

log_dirs = sorted(str(path.relative_to(target)) for path in target.rglob("log") if path.is_dir())
outputs = sorted(str(path.relative_to(target)) for path in target.rglob("outputs") if path.is_dir())
if log_dirs or outputs:
    print(f"Workspace layers contain runtime dirs: log={log_dirs[:5]} outputs={outputs[:5]}", file=sys.stderr)
    sys.exit(1)

skills = target / "skills"
skill_count = len(list(skills.rglob("SKILL.md")))
agents_chars = len((target / "persona" / "AGENTS.md").read_text(encoding="utf-8"))
print(f"AGENT_WORKSPACE_SKILLS={skill_count}")
print(f"AGENT_PERSONA_AGENTS_CHARS={agents_chars}")
PY

ENV_FILE="${TARGET}/agent_workspace.env"
cat > "${ENV_FILE}" <<EOF
export AGENT_WORKSPACE_LAYERS_DIR='${TARGET}'
export HARNESS_OPENCLAW_WORKSPACE='${TARGET}/persona'
export HARNESS_OPENCLAW_PERSONA_SOURCE_DIR='${TARGET}/persona'
export HARNESS_OPENCLAW_SKILL_DIRS='${TARGET}/skills'
export HARNESS_OPENCLAW_SKILLS='all'
export HARNESS_CODEX_PERSONA_SOURCE_DIR='${TARGET}/persona'
export HARNESS_CODEX_SKILL_DIRS='${TARGET}/skills'
export HARNESS_AGENT_PERSONA_SOURCE_DIR='${TARGET}/persona'
export HARNESS_AGENT_SKILL_DIRS='${TARGET}/skills'
export SKILLS_ROOT='${TARGET}/skills'
EOF
echo "AGENT_WORKSPACE_ENV=${ENV_FILE}"

if [ -n "${CODEX_HOME_TARGET}" ]; then
  mkdir -p "${CODEX_HOME_TARGET}"
  rm -rf "${CODEX_HOME_TARGET}/skills" "${CODEX_HOME_TARGET}/agent-workspace"
  ln -s "${TARGET}/skills" "${CODEX_HOME_TARGET}/skills"
  ln -s "${TARGET}/persona" "${CODEX_HOME_TARGET}/agent-workspace"
  cat > "${CODEX_HOME_TARGET}/openclaw_business.env" <<EOF
export CODEX_HOME='${CODEX_HOME_TARGET}'
export HARNESS_CODEX_SKILL_DIRS='${TARGET}/skills'
export HARNESS_CODEX_PERSONA_SOURCE_DIR='${TARGET}/persona'
export HARNESS_AGENT_SKILL_DIRS='${TARGET}/skills'
export HARNESS_AGENT_PERSONA_SOURCE_DIR='${TARGET}/persona'
export SKILLS_ROOT='${TARGET}/skills'
export MCP_TOOL_CALL_PY='${TARGET}/skills/mcp_tools_usage/scripts/mcp_tool_call.py'
EOF
  echo "CODEX_HOME_TARGET=${CODEX_HOME_TARGET}"
  echo "CODEX_BUSINESS_SKILLS=$(find -L "${CODEX_HOME_TARGET}/skills" -name SKILL.md | wc -l | tr -d ' ')"
fi

if [ "${SYNC_DEERFLOW}" -eq 1 ]; then
  deer_root="${HARNESS_OPENCLAW_BACKENDS_HOME:-${HOME}/.openclaw-rl-agent-backends}/deer-flow/current"
  if [ -d "${deer_root}" ]; then
    mkdir -p "${deer_root}/skills"
    rm -rf "${deer_root}/skills/custom.next"
    cp -a "${TARGET}/skills" "${deer_root}/skills/custom.next"
    rm -rf "${deer_root}/skills/custom"
    mv "${deer_root}/skills/custom.next" "${deer_root}/skills/custom"
    echo "DEERFLOW_SKILLS_CUSTOM=${deer_root}/skills/custom"
  else
    echo "DEERFLOW_SKILLS=skipped (missing ${deer_root})"
  fi
fi
