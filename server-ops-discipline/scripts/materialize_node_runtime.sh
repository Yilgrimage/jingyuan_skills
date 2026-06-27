#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
LOCAL_ENVS_DIR="${LOCAL_ENVS_DIR:-/tmp/server-ops-envs}"
LOCAL_RUNTIME_DIR="${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}"
PACK_DIR=${PACK_DIR:-${ROOT_DIR}/packs}

ENVS=${ENVS:-none}
DATASETS=${DATASETS:-none}
MODELS=${MODELS:-none}
SOURCES=${SOURCES:-none}
FORCE=0
CHECK_HASH=1
SKIP_ENVS=0
SKIP_DATA=0
SKIP_MODELS=0
SKIP_SOURCES=0

usage() {
  cat <<'EOF'
Usage: materialize_node_runtime.sh [options]

Materialize conda packs, data packs, and source mirrors on the current node.
Models are intentionally read from shared storage and are not copied to node-local disk.
Nothing environment-specific is materialized unless explicitly selected.

Options:
  --envs LIST        Comma list of environment pack names, or none
  --data LIST        Comma list of dataset names, or none
  --models none      Kept for compatibility. Model copying is disabled.
  --sources LIST     Comma list of source checkout names, or none
  --force            Reinstall/copy even if local stamp matches
  --no-check-hash    Use existence checks only
  --skip-envs
  --skip-data
  --skip-models
  --skip-sources
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --envs) ENVS=$2; shift 2 ;;
    --data) DATASETS=$2; shift 2 ;;
    --models) MODELS=$2; shift 2 ;;
    --sources) SOURCES=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-check-hash) CHECK_HASH=0; shift ;;
    --skip-envs) SKIP_ENVS=1; shift ;;
    --skip-data) SKIP_DATA=1; shift ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    --skip-sources) SKIP_SOURCES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "${LOCAL_ENVS_DIR}" "${LOCAL_RUNTIME_DIR}"

if [ "${MODELS}" != "none" ]; then
  echo "Model materialization is disabled. Use --models none and read model checkpoints from ${ROOT_DIR}/models." >&2
  exit 2
fi

contains_item() {
  local list=$1
  local item=$2
  [ "${list}" != "none" ] || return 1
  case ",${list}," in
    *",${item},"*) return 0 ;;
    *) return 1 ;;
  esac
}

list_items() {
  local list=$1
  [ "${list}" != "none" ] || return 0
  printf '%s\n' "${list}" | tr ',' '\n' | awk 'NF {print $1}'
}

sha_file_value() {
  local sha_file=$1
  awk '{print $1}' "${sha_file}"
}

stamp_matches() {
  local stamp=$1
  local sha_file=$2
  [ "${CHECK_HASH}" -eq 1 ] || return 1
  [ -f "${stamp}" ] || return 1
  [ -f "${sha_file}" ] || return 1
  [ "$(cat "${stamp}")" = "$(sha_file_value "${sha_file}")" ]
}

write_stamp() {
  local stamp=$1
  local sha_file=$2
  if [ "${CHECK_HASH}" -eq 1 ] && [ -f "${sha_file}" ]; then
    sha_file_value "${sha_file}" > "${stamp}"
  fi
}

copy_tree_excluding_parts() {
  local src=$1
  local dst=$2
  mkdir -p "${dst}"
  tar -C "${src}" --exclude='*.parts' --exclude='*.part' -cf - . | tar -C "${dst}" -xf -
}

materialize_pack() {
  local name=$1
  local pack="${PACK_DIR}/${name}.tar.gz"
  local sha_file="${pack}.sha256"
  local target="${LOCAL_ENVS_DIR}/${name}"
  local stamp="${target}/.pack.sha256"
  if [ ! -f "${pack}" ]; then
    echo "Missing pack: ${pack}" >&2
    exit 1
  fi
  if [ "${FORCE}" -eq 0 ] && [ -x "${target}/bin/python" ]; then
    if [ "${CHECK_HASH}" -eq 0 ] || stamp_matches "${stamp}" "${sha_file}" || [ ! -f "${sha_file}" ]; then
      echo "${name}_ENV=${target} (cached)"
      return
    fi
  fi
  echo "Materializing env ${name} -> ${target}"
  rm -rf "${target}"
  mkdir -p "${target}"
  tar -xzf "${pack}" -C "${target}"
  "${target}/bin/conda-unpack"
  write_stamp "${stamp}" "${sha_file}"
  echo "${name}_ENV=${target}"
}

copy_dir_once() {
  local src=$1
  local dst=$2
  if [ -d "${src}" ] && { [ "${FORCE}" -eq 1 ] || [ ! -d "${dst}" ]; }; then
    rm -rf "${dst}"
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
  fi
}

copy_dir_once_excluding_data() {
  local src=$1
  local dst=$2
  if [ -d "${src}" ] && { [ "${FORCE}" -eq 1 ] || [ ! -d "${dst}" ]; }; then
    rm -rf "${dst}"
    mkdir -p "${dst}"
    tar -C "${src}" --exclude='./data' --exclude='data' -cf - . | tar -C "${dst}" -xf -
  fi
}

materialize_data() {
  local name=$1
  local src_dir="${ROOT_DIR}/data/${name}"
  local pack="${PACK_DIR}/${name}-data.tar.gz"
  local sha_file="${pack}.sha256"
  local dst="${LOCAL_RUNTIME_DIR}/data/${name}"
  local stamp="${dst}/.data-pack.sha256"
  mkdir -p "${LOCAL_RUNTIME_DIR}/data"
  if [ "${FORCE}" -eq 0 ] && [ -d "${dst}" ]; then
    if [ "${CHECK_HASH}" -eq 0 ] || stamp_matches "${stamp}" "${sha_file}" || { [ -d "${src_dir}" ] && [ ! -f "${sha_file}" ]; }; then
      echo "${name}_DATA=${dst} (cached)"
      return
    fi
  fi
  rm -rf "${dst}"
  if [ -f "${pack}" ]; then
    echo "Materializing data pack ${name} -> ${dst}"
    tar -xzf "${pack}" -C "${LOCAL_RUNTIME_DIR}/data"
    write_stamp "${stamp}" "${sha_file}"
  elif [ -d "${src_dir}" ]; then
    echo "Copying data directory ${name} -> ${dst}"
    copy_tree_excluding_parts "${src_dir}" "${dst}"
  else
    echo "Missing data source for ${name}: ${src_dir} or ${pack}" >&2
    exit 1
  fi
  echo "${name}_DATA=${dst}"
}

mirror_webshop_runtime_data() {
  if [ ! -d "${LOCAL_RUNTIME_DIR}/data/webshop" ] || [ ! -d "${LOCAL_RUNTIME_DIR}/code/WebShop" ]; then
    return
  fi
  if [ -d "${LOCAL_RUNTIME_DIR}/data/webshop/data" ]; then
    copy_tree_excluding_parts "${LOCAL_RUNTIME_DIR}/data/webshop/data" "${LOCAL_RUNTIME_DIR}/code/WebShop/data"
  fi
  if [ -d "${LOCAL_RUNTIME_DIR}/data/webshop/search_engine/indexes_1k" ]; then
    mkdir -p "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine"
    rm -rf "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine/indexes_1k"
    cp -a "${LOCAL_RUNTIME_DIR}/data/webshop/search_engine/indexes_1k" "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine/indexes_1k"
  fi
  if [ -d "${LOCAL_RUNTIME_DIR}/data/webshop/search_engine/indexes_100k" ]; then
    mkdir -p "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine"
    rm -rf "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine/indexes_100k"
    cp -a "${LOCAL_RUNTIME_DIR}/data/webshop/search_engine/indexes_100k" "${LOCAL_RUNTIME_DIR}/code/WebShop/search_engine/indexes_100k"
  fi
}

source_dst() {
  local name=$1
  case "${name}" in
    webshop) printf '%s\n' "${LOCAL_RUNTIME_DIR}/code/WebShop" ;;
    tau2) printf '%s\n' "${LOCAL_RUNTIME_DIR}/code/tau2-bench" ;;
    *) printf '%s\n' "${LOCAL_RUNTIME_DIR}/code/${name}" ;;
  esac
}

materialize_source() {
  local name=$1
  case "${name}" in
    webshop)
      copy_dir_once "${ROOT_DIR}/code/WebShop" "$(source_dst "${name}")"
      ;;
    tau2)
      copy_dir_once_excluding_data "${ROOT_DIR}/code/tau2-bench" "$(source_dst "${name}")"
      ;;
    *)
      copy_dir_once "${ROOT_DIR}/code/${name}" "$(source_dst "${name}")"
      ;;
  esac
}

if [ "${SKIP_ENVS}" -eq 0 ]; then
  for env_name in $(list_items "${ENVS}"); do
    materialize_pack "${env_name}"
  done
fi

if [ "${SKIP_SOURCES}" -eq 0 ]; then
  for source_name in $(list_items "${SOURCES}"); do
    materialize_source "${source_name}"
  done
fi

if [ "${SKIP_DATA}" -eq 0 ]; then
  for data_name in $(list_items "${DATASETS}"); do
    materialize_data "${data_name}"
  done
  if contains_item "${DATASETS}" "webshop"; then
    mirror_webshop_runtime_data
  fi
fi

echo "LOCAL_ENVS_DIR=${LOCAL_ENVS_DIR}"
echo "LOCAL_RUNTIME_DIR=${LOCAL_RUNTIME_DIR}"
echo "MODEL_ROOT=${ROOT_DIR}/models"
