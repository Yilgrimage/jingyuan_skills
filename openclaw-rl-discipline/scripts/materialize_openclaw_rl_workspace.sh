#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
LOCAL_RUNTIME_DIR="${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
PACK="${PACK:-${PACK_DIR}/openclaw-rl-workspace-data.tar.gz}"
TARGET="${OPENCLAW_RL_WORKSPACE_DATA_DIR:-${LOCAL_RUNTIME_DIR}/openclaw-rl/workspace-data/current}"
BACKENDS_HOME="${OPENCLAW_RL_AGENT_BACKENDS_HOME:-${HOME}/.openclaw-rl-agent-backends}"
SYNC_DEERFLOW=1
FORCE=0

usage() {
  cat <<'EOF'
Usage: materialize_openclaw_rl_workspace.sh [options]

Materialize the clean OpenClaw-RL workspace-data pack on the current node.
This is OpenClaw-RL-specific glue over server-ops packs; it does not SSH,
start bench, install envs, or launch training.

Options:
  --pack PATH          Workspace pack path
  --target PATH        Node-local target directory
  --backends-home DIR  OpenClaw agent backends home
  --no-deerflow-sync   Do not mirror skills to deer-flow/current/skills/custom
  --force              Re-extract even if hash marker matches
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pack) PACK=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --backends-home) BACKENDS_HOME=$2; shift 2 ;;
    --no-deerflow-sync) SYNC_DEERFLOW=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ ! -f "${PACK}" ]; then
  echo "Missing OpenClaw-RL workspace pack: ${PACK}" >&2
  exit 1
fi

sha_value() {
  if [ -f "${PACK}.sha256" ]; then
    awk '{print $1}' "${PACK}.sha256"
  else
    sha256sum "${PACK}" | awk '{print $1}'
  fi
}

PACK_SHA="$(sha_value)"
STAMP="${TARGET}/.pack.sha256"
if [ "${FORCE}" -eq 0 ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${PACK_SHA}" ]; then
  echo "OPENCLAW_RL_WORKSPACE_DATA_DIR=${TARGET} (cached)"
else
  tmp="${TARGET}.next"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  tar -xzf "${PACK}" -C "${tmp}"
  test -f "${tmp}/train_data/openclaw_rl_train.jsonl"
  test -d "${tmp}/skills"
  rm -rf "${TARGET}.old"
  if [ -e "${TARGET}" ]; then
    mv "${TARGET}" "${TARGET}.old"
  fi
  mv "${tmp}" "${TARGET}"
  printf '%s\n' "${PACK_SHA}" > "${STAMP}"
  rm -rf "${TARGET}.old"
  echo "OPENCLAW_RL_WORKSPACE_DATA_DIR=${TARGET}"
fi

skill_count="$(find "${TARGET}/skills" -name SKILL.md | wc -l | tr -d ' ')"
line_count="$(wc -l < "${TARGET}/train_data/openclaw_rl_train.jsonl" | tr -d ' ')"
echo "OPENCLAW_RL_WORKSPACE_SKILLS=${skill_count}"
echo "OPENCLAW_RL_WORKSPACE_ROWS=${line_count}"

if [ "${SYNC_DEERFLOW}" -eq 1 ]; then
  deer_root="${BACKENDS_HOME}/deer-flow/current"
  if [ -d "${deer_root}" ]; then
    mkdir -p "${deer_root}/skills"
    rm -rf "${deer_root}/skills/custom.next"
    cp -a "${TARGET}/skills" "${deer_root}/skills/custom.next"
    rm -rf "${deer_root}/skills/custom"
    mv "${deer_root}/skills/custom.next" "${deer_root}/skills/custom"
    deer_count="$(find "${deer_root}/skills/custom" -name SKILL.md | wc -l | tr -d ' ')"
    echo "DEERFLOW_SKILLS_CUSTOM=${deer_root}/skills/custom"
    echo "DEERFLOW_SKILLS=${deer_count}"
  else
    echo "DEERFLOW_SKILLS=skipped (missing ${deer_root})"
  fi
fi
