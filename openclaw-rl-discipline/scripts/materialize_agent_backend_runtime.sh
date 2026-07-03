#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
BACKEND="${HARNESS_BACKEND:-openclaw}"
PACK="${AGENT_BACKEND_RUNTIME_PACK:-}"
TARGET_HOME="${AGENT_BACKEND_TARGET_HOME:-${HOME}}"
FORCE=0
ALLOW_DIRTY=0

usage() {
  cat <<'EOF'
Usage: materialize_agent_backend_runtime.sh --backend NAME [options]

Restore a standalone external-agent backend runtime onto node-local storage.
This only restores backend binaries/source. It does not install business
skills/persona packs and does not install MCP Python/Node dependencies.

Supported backends:
  openclaw   -> openclaw-rl-openclaw-runtime.tar.gz
  hermes     -> openclaw-rl-hermes-runtime.tar.gz
  deerflow   -> openclaw-rl-deerflow-runtime.tar.gz
  codex      -> delegates to materialize_codex_runtime.sh

Options:
  --backend NAME        openclaw|hermes|deerflow|codex
  --pack PATH           Runtime pack path. Defaults by backend.
  --pack-dir DIR        Shared pack directory
  --target-home DIR     Home-like target root. Default: $HOME
  --force               Re-extract even if hash marker matches
  --allow-dirty-pack    Allow packs containing runtime logs/cache/sessions
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND=$2; shift 2 ;;
    --pack) PACK=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --target-home) TARGET_HOME=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    --allow-dirty-pack) ALLOW_DIRTY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "${BACKEND}" in
  openclaw)
    DEFAULT_PACK="${PACK_DIR}/openclaw-rl-openclaw-runtime.tar.gz"
    TARGET_REL=".openclaw-rl-agent-backends/openclaw"
    ENV_NAME="OPENCLAW_BACKEND_RUNTIME_ENV"
    ;;
  hermes)
    DEFAULT_PACK="${PACK_DIR}/openclaw-rl-hermes-runtime.tar.gz"
    TARGET_REL=".hermes"
    ENV_NAME="HERMES_BACKEND_RUNTIME_ENV"
    ;;
  deerflow|deer-flow)
    BACKEND="deerflow"
    DEFAULT_PACK="${PACK_DIR}/openclaw-rl-deerflow-runtime.tar.gz"
    TARGET_REL=".openclaw-rl-agent-backends/deer-flow"
    ENV_NAME="DEERFLOW_BACKEND_RUNTIME_ENV"
    ;;
  codex)
    cmd=("${SCRIPT_DIR}/materialize_codex_runtime.sh" --pack-dir "${PACK_DIR}")
    if [ -n "${PACK}" ]; then
      cmd+=(--pack "${PACK}")
    fi
    if [ "${FORCE}" -eq 1 ]; then
      cmd+=(--force)
    fi
    exec "${cmd[@]}"
    ;;
  *)
    echo "Unsupported backend: ${BACKEND}" >&2
    usage >&2
    exit 1
    ;;
esac

PACK="${PACK:-${DEFAULT_PACK}}"
if [ ! -f "${PACK}" ]; then
  echo "Missing backend runtime pack: ${PACK}" >&2
  exit 1
fi

PACK_SHA="$(if [ -f "${PACK}.sha256" ]; then awk '{print $1}' "${PACK}.sha256"; else sha256sum "${PACK}" | awk '{print $1}'; fi)"
TARGET="${TARGET_HOME}/${TARGET_REL}"
STAMP="${TARGET}/.pack.sha256"

bad_paths="$(tar -tzf "${PACK}" | grep -E '(^|/)(logs|sessions|cache|tmp|users)(/|$)' | grep -Ev '^\.openclaw-rl-agent-backends/[^/]+/releases/' || true)"
if [ -n "${bad_paths}" ] && [ "${ALLOW_DIRTY}" -eq 0 ]; then
  echo "Backend runtime pack contains mutable runtime state. Rebuild the pack or pass --allow-dirty-pack for one-off debugging." >&2
  echo "${bad_paths}" | head -20 >&2
  exit 1
fi

if [ "${FORCE}" -eq 0 ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${PACK_SHA}" ]; then
  echo "AGENT_BACKEND_RUNTIME=${TARGET} (cached)"
else
  tmp="$(mktemp -d /tmp/agent-backend-runtime.XXXXXX)"
  cleanup() { rm -rf "${tmp}"; }
  trap cleanup EXIT
  tar -xzf "${PACK}" -C "${tmp}"
  test -d "${tmp}/${TARGET_REL}"
  mkdir -p "$(dirname "${TARGET}")"
  rm -rf "${TARGET}.old" "${TARGET}.next"
  mv "${tmp}/${TARGET_REL}" "${TARGET}.next"
  if [ -e "${TARGET}" ]; then
    mv "${TARGET}" "${TARGET}.old"
  fi
  mv "${TARGET}.next" "${TARGET}"
  rm -rf "${TARGET}.old"
  printf '%s\n' "${PACK_SHA}" > "${STAMP}"
  echo "AGENT_BACKEND_RUNTIME=${TARGET}"

  if [ "${BACKEND}" = "openclaw" ] || [ "${BACKEND}" = "deerflow" ]; then
    node_rel=".openclaw-rl-agent-backends/nodejs-bin"
    if [ -d "${tmp}/${node_rel}" ]; then
      node_target="${TARGET_HOME}/${node_rel}"
      mkdir -p "$(dirname "${node_target}")"
      rm -rf "${node_target}.old" "${node_target}.next"
      mv "${tmp}/${node_rel}" "${node_target}.next"
      if [ -e "${node_target}" ]; then
        mv "${node_target}" "${node_target}.old"
      fi
      mv "${node_target}.next" "${node_target}"
      rm -rf "${node_target}.old"
      echo "AGENT_BACKEND_NODEJS=${node_target}"
    fi
  fi
fi

case "${BACKEND}" in
  openclaw)
    test -e "${TARGET}/openclaw.mjs" || test -e "${TARGET}/bin/openclaw" || true
    env_file="${TARGET}/openclaw_backend_runtime.env"
    cat > "${env_file}" <<EOF
export HARNESS_OPENCLAW_BACKENDS_HOME='${TARGET_HOME}/.openclaw-rl-agent-backends'
export HARNESS_OPENCLAW_BACKEND_DIR='${TARGET}'
export OPENCLAW_HOME='${TARGET_HOME}/.openclaw'
EOF
    ;;
  hermes)
    env_file="${TARGET}/hermes_backend_runtime.env"
    cat > "${env_file}" <<EOF
export HERMES_HOME='${TARGET}'
EOF
    ;;
  deerflow)
    env_file="${TARGET}/deerflow_backend_runtime.env"
    cat > "${env_file}" <<EOF
export HARNESS_OPENCLAW_BACKENDS_HOME='${TARGET_HOME}/.openclaw-rl-agent-backends'
export HARNESS_DEERFLOW_BACKEND_DIR='${TARGET}'
EOF
    ;;
esac

echo "${ENV_NAME}=${env_file}"
