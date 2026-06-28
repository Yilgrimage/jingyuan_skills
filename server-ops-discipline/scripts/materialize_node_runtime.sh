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
AUTO_DOWNLOAD_DATASETS=${AUTO_DOWNLOAD_DATASETS:-0}
VALIDATE_DATA=${VALIDATE_DATA:-1}
VALIDATE_DATA_LOAD=${VALIDATE_DATA_LOAD:-0}

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
  --auto-download-data
                     Download supported datasets into ROOT_DIR/data when no
                     local source or data pack exists
  --no-validate-data Skip dataset layout validation after materialization
  --validate-data-load
                     Run supported env load smoke tests after materialization
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
    --auto-download-data) AUTO_DOWNLOAD_DATASETS=1; shift ;;
    --no-validate-data) VALIDATE_DATA=0; shift ;;
    --validate-data-load) VALIDATE_DATA_LOAD=1; shift ;;
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

bool_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

find_alfworld_downloader() {
  local candidate="${LOCAL_ENVS_DIR}/alfworld/bin/alfworld-download"
  if [ -x "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  command -v alfworld-download 2>/dev/null || return 1
}

alfworld_has_paired_game() {
  local split_dir=$1
  local game_file
  [ -d "${split_dir}" ] || return 1
  while IFS= read -r game_file; do
    [ -f "$(dirname "${game_file}")/traj_data.json" ] && return 0
  done < <(find "${split_dir}" -type f -name game.tw-pddl -print 2>/dev/null)
  return 1
}

validate_alfworld_data() {
  local data_dir=$1
  local split
  local missing=0
  for file in \
    "${data_dir}/logic/alfred.pddl" \
    "${data_dir}/logic/alfred.twl2"; do
    if [ ! -f "${file}" ]; then
      echo "ALFWorld data missing required file: ${file}" >&2
      missing=1
    fi
  done
  for split in train valid_seen valid_unseen; do
    if ! alfworld_has_paired_game "${data_dir}/json_2.1.1/${split}"; then
      echo "ALFWorld data split ${split} has no task containing both game.tw-pddl and traj_data.json under ${data_dir}/json_2.1.1/${split}" >&2
      missing=1
    fi
  done
  [ "${missing}" -eq 0 ]
}

smoke_alfworld_data_load() {
  local data_dir=$1
  local python="${LOCAL_ENVS_DIR}/alfworld/bin/python"
  [ -x "${python}" ] || {
    echo "Cannot run ALFWorld data load smoke: missing ${python}. Materialize the alfworld env first or set LOCAL_ENVS_DIR." >&2
    return 1
  }
  ALFWORLD_DATA="${data_dir}" "${python}" - "${data_dir}" <<'PY'
import os
import sys

data_dir = sys.argv[1]
alfworld_lib = os.path.join(data_dir, "pythonlibs", "alfworld_text")
if os.path.isdir(alfworld_lib) and alfworld_lib not in sys.path:
    sys.path.insert(0, alfworld_lib)

from alfworld.agents.environment import get_environment

config = {
    "dataset": {
        "data_path": f"{data_dir}/json_2.1.1/train",
        "eval_id_data_path": f"{data_dir}/json_2.1.1/valid_seen",
        "eval_ood_data_path": f"{data_dir}/json_2.1.1/valid_unseen",
        "num_train_games": -1,
        "num_eval_games": -1,
    },
    "env": {
        "type": "AlfredTWEnv",
        "domain_randomization": False,
        "task_types": [1, 2, 3, 4, 5, 6],
        "expert_type": "handcoded",
        "goal_desc_human_anns_prob": 0.0,
    },
    "general": {"training_method": "dqn"},
    "rl": {"training": {"max_nb_steps_per_episode": 1}},
    "dagger": {"training": {"max_nb_steps_per_episode": 1}},
    "logic": {
        "domain": f"{data_dir}/logic/alfred.pddl",
        "grammar": f"{data_dir}/logic/alfred.twl2",
    },
}

env_cls = get_environment("AlfredTWEnv")
for name, train_eval in {
    "train": "train",
    "valid_seen": "eval_in_distribution",
    "valid_unseen": "eval_out_of_distribution",
}.items():
    wrapper = env_cls(config, train_eval=train_eval)
    game_files = list(getattr(wrapper, "game_files", None) or [])
    if not game_files:
        raise RuntimeError(f"ALFWorld split {name} loaded no game files")
print("ALFWorld data load smoke passed")
PY
}

validate_data() {
  local name=$1
  local dst=$2
  bool_enabled "${VALIDATE_DATA}" || return 0
  case "${name}" in
    alfworld)
      validate_alfworld_data "${dst}" || return 1
      bool_enabled "${VALIDATE_DATA_LOAD}" || return 0
      smoke_alfworld_data_load "${dst}" || return 1
      ;;
    *)
      return 0
      ;;
  esac
}

download_alfworld_data() {
  local src_dir="${ROOT_DIR}/data/alfworld"
  local lock_dir="${ROOT_DIR}/data/.locks/alfworld-download.lock"
  local downloader
  local locked=0
  mkdir -p "${ROOT_DIR}/data" "$(dirname "${lock_dir}")"
  while ! mkdir "${lock_dir}" 2>/dev/null; do
    echo "Waiting for ALFWorld data download lock: ${lock_dir}"
    sleep 10
    if validate_alfworld_data "${src_dir}" >/dev/null 2>&1; then
      return 0
    fi
  done
  locked=1
  if validate_alfworld_data "${src_dir}" >/dev/null 2>&1; then
    rmdir "${lock_dir}" 2>/dev/null || true
    return 0
  fi
  downloader=$(find_alfworld_downloader) || {
    echo "Cannot auto-download ALFWorld data: alfworld-download not found. Materialize the alfworld env first or provide ${src_dir} / ${PACK_DIR}/alfworld-data.tar.gz." >&2
    rmdir "${lock_dir}" 2>/dev/null || true
    return 1
  }
  echo "Downloading ALFWorld data -> ${src_dir}"
  if ! "${downloader}" --data-dir "${src_dir}"; then
    [ "${locked}" -eq 0 ] || rmdir "${lock_dir}" 2>/dev/null || true
    return 1
  fi
  if ! validate_alfworld_data "${src_dir}"; then
    [ "${locked}" -eq 0 ] || rmdir "${lock_dir}" 2>/dev/null || true
    return 1
  fi
  [ "${locked}" -eq 0 ] || rmdir "${lock_dir}" 2>/dev/null || true
}

ensure_data_source() {
  local name=$1
  local src_dir="${ROOT_DIR}/data/${name}"
  local pack="${PACK_DIR}/${name}-data.tar.gz"
  if [ -f "${pack}" ]; then
    return 0
  fi
  if [ -d "${src_dir}" ]; then
    if validate_data "${name}" "${src_dir}"; then
      return 0
    fi
    if bool_enabled "${AUTO_DOWNLOAD_DATASETS}"; then
      case "${name}" in
        alfworld) download_alfworld_data; return 0 ;;
      esac
    fi
    return 1
  fi
  bool_enabled "${AUTO_DOWNLOAD_DATASETS}" || return 1
  case "${name}" in
    alfworld) download_alfworld_data ;;
    *) return 1 ;;
  esac
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
      validate_data "${name}" "${dst}"
      echo "${name}_DATA=${dst} (cached)"
      return
    fi
  fi
  rm -rf "${dst}"
  ensure_data_source "${name}" || {
    echo "Missing data source for ${name}: ${src_dir} or ${pack}" >&2
    if [ "${name}" = "alfworld" ]; then
      echo "Run with --auto-download-data after materializing the alfworld env, or provide a validated ALFWorld data directory/pack." >&2
    fi
    exit 1
  }
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
  validate_data "${name}" "${dst}"
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
