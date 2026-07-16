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
SOURCE_DIR="${CODEX_EU_SOURCE_DIR:-/mnt/bn/ecomcommonnas/mlf/agents/codex_eu}"
STAMP="${PACK_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
PACK="${CODEX_EU_RUNTIME_PACK:-${PACK_DIR}/codex-eu-backend-runtime-${STAMP}.tar.gz}"

usage() {
  cat <<'EOF'
Usage: pack_codex_eu_online_runtime.sh [options]

Pack the online FireCodex/Codex-EU backend runtime needed by training.

This pack is whitelist-based. It includes the current Codex CLI wrapper/binary,
runtime config templates, explicit model catalog, python shims, plugins,
cc-connect/lark helper binaries, and online runtime preparation scripts. It
does not include business skills, MCP Python/Node runtime, secrets, auth state,
SQLite, sessions, logs, caches, tmp outputs, backups, or training/eval data.

Options:
  --source DIR       Online codex_eu source root
  --pack PATH        Output pack path
  --pack-dir DIR     Output pack directory
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR=$2; shift 2 ;;
    --pack) PACK=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -P)"
mkdir -p "${PACK_DIR}" "$(dirname "${PACK}")"

test -x "${SOURCE_DIR}/bin/codex"
test -x "${SOURCE_DIR}/bin/codex.real"
test -f "${SOURCE_DIR}/runtime/AGENTS.md"
test -f "${SOURCE_DIR}/runtime/config.toml"
test -f "${SOURCE_DIR}/runtime/model_catalog_1m.json"

tmp="$(mktemp -d /tmp/codex-eu-runtime-pack.XXXXXX)"
cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

root="${tmp}/codex-eu"
mkdir -p "${root}/bin" "${root}/runtime" "${root}/.cc-connect/data" "${root}/hw_scripts"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -e "${src}" ] || [ -L "${src}" ]; then
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
  fi
}

copy_if_exists "${SOURCE_DIR}/env.sh" "${root}/env.sh"
copy_if_exists "${SOURCE_DIR}/restore-wrapper.sh" "${root}/restore-wrapper.sh"

for name in codex codex.real load-auth-env.sh with-auth-env.sh bytedcli cc-connect; do
  copy_if_exists "${SOURCE_DIR}/bin/${name}" "${root}/bin/${name}"
done

copy_if_exists "${SOURCE_DIR}/.cc-connect/data/bin" "${root}/.cc-connect/data/bin"

for name in AGENTS.md config.toml model_catalog_1m.json version.json tmp.md; do
  copy_if_exists "${SOURCE_DIR}/runtime/${name}" "${root}/runtime/${name}"
done
copy_if_exists "${SOURCE_DIR}/runtime/plugins" "${root}/runtime/plugins"
copy_if_exists "${SOURCE_DIR}/runtime/python_shims" "${root}/runtime/python_shims"

for name in prepare_eval_runtime.py setup_eval_tool_runtime.py; do
  copy_if_exists "${SOURCE_DIR}/hw_scripts/${name}" "${root}/hw_scripts/${name}"
done

cat > "${root}/PACKING_NOTES.md" <<EOF
# codex-eu backend runtime pack

Source: ${SOURCE_DIR}
Created UTC: ${STAMP}

Included:
- current Codex CLI wrapper and binary from bin/
- runtime AGENTS/config/model_catalog/plugins/python_shims
- cc-connect data/bin helper binaries such as lark-cli/lark-auth
- online runtime preparation scripts under hw_scripts/

Excluded by design:
- business skills, packed separately with pack_agent_workspace_layers.sh
- MCP Python/Node runtime, packed separately
- auth.json, secrets, SQLite, sessions, shell snapshots, logs, cache, tmp,
  historical backups, eval outputs, source trees, and data
EOF

cat > "${root}/manifest.env" <<EOF
kind=codex-eu-backend-runtime
source=${SOURCE_DIR}
created_utc=${STAMP}
codex_bin_sha256=$(sha256sum "${SOURCE_DIR}/bin/codex" | awk '{print $1}')
codex_real_sha256=$(sha256sum "${SOURCE_DIR}/bin/codex.real" | awk '{print $1}')
runtime_agents_sha256=$(sha256sum "${SOURCE_DIR}/runtime/AGENTS.md" | awk '{print $1}')
runtime_config_sha256=$(sha256sum "${SOURCE_DIR}/runtime/config.toml" | awk '{print $1}')
model_catalog_sha256=$(sha256sum "${SOURCE_DIR}/runtime/model_catalog_1m.json" | awk '{print $1}')
EOF

tar -C "${tmp}" -czf "${PACK}" codex-eu
sha256sum "${PACK}" > "${PACK}.sha256"
{
  cat "${root}/manifest.env"
  echo "pack=${PACK}"
  echo "pack_sha256=$(awk '{print $1}' "${PACK}.sha256")"
} > "${PACK%.tar.gz}.revision"

echo "CODEX_EU_RUNTIME_PACK=${PACK}"
