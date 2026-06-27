#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
PACK_DIR=${PACK_DIR:-${ROOT_DIR}/packs}
DATASETS=${DATASETS:-none}

mkdir -p "${PACK_DIR}"

pack_dataset() {
  local name=$1
  local src="${ROOT_DIR}/data/${name}"
  local out="${PACK_DIR}/${name}-data.tar.gz"
  if [ ! -d "${src}" ]; then
    echo "Missing data directory: ${src}" >&2
    exit 1
  fi
  tar -C "${ROOT_DIR}/data" \
    --exclude='*.parts' \
    --exclude='*.part' \
    -czf "${out}" "${name}"
  sha256sum "${out}" > "${out}.sha256"
  {
    echo "name=${name}"
    echo "source=${src}"
    echo "archive=${out}"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bytes=$(stat -c %s "${out}")"
  } > "${PACK_DIR}/${name}-data.manifest"
  echo "${name}_DATA_PACK=${out}"
}

if [ "${DATASETS}" = "none" ]; then
  echo "No datasets selected. Set DATASETS='name1 name2' to create data packs."
  exit 0
fi

for dataset in ${DATASETS}; do
  pack_dataset "${dataset}"
done
