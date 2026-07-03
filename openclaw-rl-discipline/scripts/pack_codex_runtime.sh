#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
SOURCE_DIR="${CODEX_RUNTIME_SOURCE_DIR:-}"

usage() {
  cat <<'EOF'
Usage: pack_codex_runtime.sh [options]

Pack the Codex standalone CLI runtime only. This does not pack CODEX_HOME,
auth.json, user skills, caches, business skills, or MCP runtime.

Options:
  --source DIR       Codex standalone release dir containing bin/codex
  --codex-bin PATH   Codex binary used to infer the release dir
  --pack-dir DIR     Output pack directory
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR=$2; shift 2 ;;
    --codex-bin) CODEX_BIN=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${SOURCE_DIR}" ]; then
  if [ -z "${CODEX_BIN}" ]; then
    echo "Missing codex binary. Pass --source or --codex-bin." >&2
    exit 1
  fi
  CODEX_BIN="$(readlink -f "${CODEX_BIN}")"
  SOURCE_DIR="$(cd "$(dirname "${CODEX_BIN}")/.." && pwd -P)"
fi

SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -P)"
test -x "${SOURCE_DIR}/bin/codex"
mkdir -p "${PACK_DIR}"

version="$("${SOURCE_DIR}/bin/codex" --version | awk '{print $2}')"
if [ -z "${version}" ]; then
  version="unknown"
fi
arch="$(basename "${SOURCE_DIR}" | sed 's/.*-//')"
pack="${PACK_DIR}/codex-runtime-${version}-${arch}.tar.gz"

tmp="$(mktemp -d /tmp/codex-runtime-pack.XXXXXX)"
cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

mkdir -p "${tmp}/codex-runtime"
cp -a "${SOURCE_DIR}" "${tmp}/codex-runtime/current"
rm -rf "${tmp}/codex-runtime/current/.git" \
       "${tmp}/codex-runtime/current/cache" \
       "${tmp}/codex-runtime/current/logs" \
       "${tmp}/codex-runtime/current/tmp"

tar -C "${tmp}" -czf "${pack}" codex-runtime
sha256sum "${pack}" > "${pack}.sha256"
{
  echo "kind=codex-runtime"
  echo "source=${SOURCE_DIR}"
  echo "version=${version}"
  echo "created_utc=$(date -u +%Y%m%dT%H%M%SZ)"
  echo "pack_sha256=$(awk '{print $1}' "${pack}.sha256")"
} > "${pack%.tar.gz}.revision"

echo "CODEX_RUNTIME_PACK=${pack}"
echo "CODEX_RUNTIME_VERSION=${version}"
