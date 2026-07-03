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
PACK="${CODEX_RUNTIME_PACK:-}"
TARGET="${CODEX_RUNTIME_DIR:-${LOCAL_RUNTIME_DIR}/codex-runtime}"
FORCE=0

usage() {
  cat <<'EOF'
Usage: materialize_codex_runtime.sh [options]

Restore the Codex standalone CLI runtime onto node-local storage and write a
small env file. This does not create or modify CODEX_HOME.

Options:
  --pack PATH          Codex runtime pack. Defaults to newest codex-runtime-*.tar.gz
  --target DIR         Node-local runtime dir
  --pack-dir DIR       Shared pack directory
  --force              Re-extract even if hash marker matches
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pack) PACK=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${PACK}" ]; then
  PACK="$(ls -t "${PACK_DIR}"/codex-runtime-*.tar.gz 2>/dev/null | head -1 || true)"
fi
if [ -z "${PACK}" ] || [ ! -f "${PACK}" ]; then
  echo "Missing Codex runtime pack. Build it with pack_codex_runtime.sh." >&2
  exit 1
fi

mkdir -p "$(dirname "${TARGET}")"
pack_sha="$(if [ -f "${PACK}.sha256" ]; then awk '{print $1}' "${PACK}.sha256"; else sha256sum "${PACK}" | awk '{print $1}'; fi)"
stamp="${TARGET}/.pack.sha256"

if [ "${FORCE}" -eq 0 ] && [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${pack_sha}" ]; then
  echo "CODEX_RUNTIME_DIR=${TARGET} (cached)"
else
  tmp="${TARGET}.next"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  tar -xzf "${PACK}" -C "${tmp}"
  test -x "${tmp}/codex-runtime/current/bin/codex"
  rm -rf "${TARGET}.old"
  if [ -e "${TARGET}" ]; then
    mv "${TARGET}" "${TARGET}.old"
  fi
  mv "${tmp}/codex-runtime" "${TARGET}"
  rm -rf "${tmp}" "${TARGET}.old"
  printf '%s\n' "${pack_sha}" > "${stamp}"
  echo "CODEX_RUNTIME_DIR=${TARGET}"
fi

codex_bin="${TARGET}/current/bin/codex"
"${codex_bin}" --version
env_file="${TARGET}/codex_runtime.env"
cat > "${env_file}" <<EOF
export CODEX_RUNTIME_DIR='${TARGET}'
export CODEX_BIN='${codex_bin}'
export PATH='${TARGET}/current/bin:${PATH}'
EOF
echo "CODEX_RUNTIME_ENV=${env_file}"
