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
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
ENV_NAME="${MCP_RUNTIME_ENV_NAME:-agent-mcp}"
PACK="${MCP_RUNTIME_PACK:-}"
DEFAULT_SECRETS_ENV="${ROOT_DIR}/secrets/mcp/agent_service.env"
if [ ! -f "${DEFAULT_SECRETS_ENV}" ] && [ -f "${ROOT_DIR}/secrets/mcp/openclaw_service.env" ]; then
  DEFAULT_SECRETS_ENV="${ROOT_DIR}/secrets/mcp/openclaw_service.env"
fi
SECRETS_ENV="${MCP_SECRETS_ENV:-${DEFAULT_SECRETS_ENV}}"
SKILLS_DIR="${HARNESS_OPENCLAW_SKILL_DIRS:-${HARNESS_AGENT_SKILL_DIRS:-}}"
SMOKE_PSMS="${MCP_SMOKE_PSMS:-}"
COMPAT_PYTHON="${MCP_COMPAT_PYTHON:-/Users/bytedance/miniconda3/bin/python}"
REQUIRE_NODE="${MCP_RUNTIME_REQUIRE_NODE:-1}"
FORCE=0

usage() {
  cat <<'EOF'
Usage: materialize_mcp_runtime.sh [options]

Restore the MCP Python runtime pack, sync the MCP secrets env, and optionally
smoke-test MCP PSMs through a materialized skills/mcp_tools_usage caller.

Options:
  --pack PATH           MCP runtime pack. Defaults to newest mcp-runtime-*-ENV.tar.gz
  --env-name NAME       Env name under LOCAL_ENVS_DIR (default agent-mcp)
  --local-envs-dir DIR  Local env root
  --local-runtime-dir DIR
                        Local runtime root
  --secrets-env PATH    Shared MCP secrets env
  --skills-dir DIR      Materialized business skills dir
  --compat-python PATH  Optional hardcoded skill-doc Python path to provide
                        (default /Users/bytedance/miniconda3/bin/python)
  --no-require-node     Do not fail if node/npx is absent from the pack
  --smoke PSM[,PSM...]  Optional PSM list to smoke through mcp_tool_call auto transport
  --force               Re-extract even if hash marker matches
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pack) PACK=$2; shift 2 ;;
    --env-name) ENV_NAME=$2; shift 2 ;;
    --local-envs-dir) LOCAL_ENVS_DIR=$2; shift 2 ;;
    --local-runtime-dir) LOCAL_RUNTIME_DIR=$2; shift 2 ;;
    --secrets-env) SECRETS_ENV=$2; shift 2 ;;
    --skills-dir) SKILLS_DIR=$2; shift 2 ;;
    --compat-python) COMPAT_PYTHON=$2; shift 2 ;;
    --no-require-node) REQUIRE_NODE=0; shift ;;
    --smoke) SMOKE_PSMS=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${PACK}" ]; then
  PACK="$(ls -t "${PACK_DIR}"/mcp-runtime-*-"${ENV_NAME}".tar.gz 2>/dev/null | head -1 || true)"
fi
if [ -z "${PACK}" ] || [ ! -f "${PACK}" ]; then
  echo "Missing MCP runtime pack. Build it with build_mcp_runtime_pack.sh on the target image." >&2
  exit 1
fi

mkdir -p "${LOCAL_ENVS_DIR}" "${LOCAL_RUNTIME_DIR}/mcp"
PREFIX="${LOCAL_ENVS_DIR}/${ENV_NAME}"
PACK_SHA="$(if [ -f "${PACK}.sha256" ]; then awk '{print $1}' "${PACK}.sha256"; else sha256sum "${PACK}" | awk '{print $1}'; fi)"
STAMP="${PREFIX}/.pack.sha256"

if [ "${FORCE}" -eq 0 ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${PACK_SHA}" ]; then
  echo "MCP_RUNTIME_PREFIX=${PREFIX} (cached)"
else
  rm -rf "${PREFIX}.next"
  mkdir -p "${PREFIX}.next.parent"
  tar -xzf "${PACK}" -C "${PREFIX}.next.parent"
  test -x "${PREFIX}.next.parent/${ENV_NAME}/bin/python"
  rm -rf "${PREFIX}.old"
  if [ -e "${PREFIX}" ]; then
    mv "${PREFIX}" "${PREFIX}.old"
  fi
  mv "${PREFIX}.next.parent/${ENV_NAME}" "${PREFIX}"
  rm -rf "${PREFIX}.next.parent" "${PREFIX}.old"
  printf '%s\n' "${PACK_SHA}" > "${STAMP}"
  echo "MCP_RUNTIME_PREFIX=${PREFIX}"
fi

MCP_PYTHON="${PREFIX}/bin/python"
"${MCP_PYTHON}" - <<'PY'
import importlib.metadata as md
import sys

import bytedenv
import bytedance.mcp
import ztijwthelper

if not hasattr(bytedenv, "get_current_vregion"):
    raise SystemExit("bytedenv is too old; missing get_current_vregion")

print("MCP_RUNTIME_PYTHON=" + sys.version.split()[0])
for name in ("bytedenv", "bytedance.mcp", "bytedztijwthelper"):
    try:
        print(f"{name}={md.version(name)}")
    except md.PackageNotFoundError:
        print(f"{name}=not-found")
PY

NODE_BIN_DIR="${PREFIX}/nodejs-bin"
if [ -x "${NODE_BIN_DIR}/node" ] && [ -x "${NODE_BIN_DIR}/npx" ]; then
  echo "MCP_NODE=$("${NODE_BIN_DIR}/node" --version)"
  echo "MCP_NPX=$(PATH="${NODE_BIN_DIR}:${PATH}" "${NODE_BIN_DIR}/npx" --version)"
  for cmd in node npx; do
    wrapper="${PREFIX}/bin/${cmd}"
    tmp_wrapper="$(mktemp)"
    {
      echo '#!/usr/bin/env bash'
      printf 'exec %q "$@"\n' "${NODE_BIN_DIR}/${cmd}"
    } > "${tmp_wrapper}"
    chmod 755 "${tmp_wrapper}"
    install -m 755 "${tmp_wrapper}" "${wrapper}"
    rm -f "${tmp_wrapper}"
  done
  echo "MCP_NODE_WRAPPERS=installed"
elif [ "${REQUIRE_NODE}" -eq 1 ]; then
  echo "MCP runtime pack is missing node/npx under ${NODE_BIN_DIR}. Rebuild with build_mcp_runtime_pack.sh." >&2
  exit 1
else
  echo "MCP_NODE=missing"
  echo "MCP_NPX=missing"
fi

if [ -f "${SECRETS_ENV}" ]; then
  mkdir -p "${HOME}/.openclaw/service-env" "${HOME}/.hermes"
  cp "${SECRETS_ENV}" "${HOME}/.openclaw/service-env/ai.openclaw.gateway.env"
  cp "${SECRETS_ENV}" "${HOME}/.hermes/.env"
  chmod 600 "${HOME}/.openclaw/service-env/ai.openclaw.gateway.env" "${HOME}/.hermes/.env"
  echo "MCP_SECRETS_ENV_SYNCED=1"
else
  echo "MCP_SECRETS_ENV_SYNCED=0 (missing ${SECRETS_ENV})"
fi

RUNTIME_ENV="${LOCAL_RUNTIME_DIR}/mcp/mcp_runtime.env"
cat > "${RUNTIME_ENV}" <<EOF
export MCP_PYTHON='${MCP_PYTHON}'
export AGENT_MCP_PYTHON_BIN_DIR='${PREFIX}/bin'
export AGENT_MCP_NODE_BIN_DIR='${NODE_BIN_DIR}'
export HARNESS_AGENT_PYTHON_BIN_DIR='${PREFIX}/bin'
export HARNESS_AGENT_NODE_BIN_DIR='${NODE_BIN_DIR}'
export HARNESS_AGENT_ENV_FILE='${HOME}/.openclaw/service-env/ai.openclaw.gateway.env'
export MCP_COMPAT_PYTHON='${COMPAT_PYTHON}'
export PYTHONNOUSERSITE='1'
export PATH='${NODE_BIN_DIR}:${PREFIX}/bin:${PATH}'
EOF
if [ -n "${SKILLS_DIR}" ]; then
  cat >> "${RUNTIME_ENV}" <<EOF
export MCP_TOOL_CALL_PY='${SKILLS_DIR}/mcp_tools_usage/scripts/mcp_tool_call.py'
EOF
fi

export MCP_PYTHON
export AGENT_MCP_PYTHON_BIN_DIR="${PREFIX}/bin"
export AGENT_MCP_NODE_BIN_DIR="${NODE_BIN_DIR}"
export HARNESS_AGENT_PYTHON_BIN_DIR="${PREFIX}/bin"
export HARNESS_AGENT_NODE_BIN_DIR="${NODE_BIN_DIR}"
export HARNESS_AGENT_ENV_FILE="${HOME}/.openclaw/service-env/ai.openclaw.gateway.env"
export MCP_COMPAT_PYTHON="${COMPAT_PYTHON}"
export PYTHONNOUSERSITE=1
export PATH="${NODE_BIN_DIR}:${PREFIX}/bin:${PATH}"
if [ -n "${SKILLS_DIR}" ]; then
  export MCP_TOOL_CALL_PY="${SKILLS_DIR}/mcp_tools_usage/scripts/mcp_tool_call.py"
fi
echo "MCP_RUNTIME_ENV=${RUNTIME_ENV}"

resolved_python3="$(command -v python3 || true)"
echo "MCP_RUNTIME_PATH_PYTHON3=${resolved_python3}"
if [ -n "${resolved_python3}" ]; then
  python3 - <<'PY'
import sys

import bytedenv
import bytedance.mcp

if not hasattr(bytedenv, "get_current_vregion"):
    raise SystemExit("python3 resolves an incompatible bytedenv; missing get_current_vregion")

print("MCP_RUNTIME_PATH_PYTHON3_IMPORT=ok")
print("MCP_RUNTIME_PATH_PYTHON3_EXECUTABLE=" + sys.executable)
print("MCP_RUNTIME_PATH_BYTEDENV=" + getattr(bytedenv, "__file__", ""))
print("MCP_RUNTIME_PATH_BYTEDANCE_MCP=" + getattr(bytedance.mcp, "__file__", ""))
PY
fi

if [ -n "${COMPAT_PYTHON}" ]; then
  compat_dir="$(dirname "${COMPAT_PYTHON}")"
  compat_tmp="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    printf 'exec %q "$@"\n' "${MCP_PYTHON}"
  } > "${compat_tmp}"
  chmod 755 "${compat_tmp}"
  if [ -w "$(dirname "${compat_dir}")" ] || [ -w "${compat_dir}" ]; then
    mkdir -p "${compat_dir}"
    rm -f "${COMPAT_PYTHON}"
    install -m 755 "${compat_tmp}" "${COMPAT_PYTHON}"
    echo "MCP_COMPAT_PYTHON=${COMPAT_PYTHON}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "${compat_dir}"
    sudo rm -f "${COMPAT_PYTHON}"
    sudo install -m 755 "${compat_tmp}" "${COMPAT_PYTHON}"
    echo "MCP_COMPAT_PYTHON=${COMPAT_PYTHON}"
  else
    echo "MCP_COMPAT_PYTHON=skipped (no permission for ${COMPAT_PYTHON})"
  fi
  rm -f "${compat_tmp}"
  if [ -x "${COMPAT_PYTHON}" ]; then
    "${COMPAT_PYTHON}" - <<'PY'
import bytedance.mcp
print("MCP_COMPAT_PYTHON_IMPORT=ok")
PY
  fi
fi

if [ -f "${HOME}/.openclaw/service-env/ai.openclaw.gateway.env" ]; then
  # shellcheck disable=SC1090
  source "${HOME}/.openclaw/service-env/ai.openclaw.gateway.env"
  "${MCP_PYTHON}" - <<'PY'
import base64
import datetime as dt
import json
import os

for key in ("SERVICE_ACCOUNT_SECRET_KEY", "ZTI_TOKEN", "STUDIO_COOKIE", "MCP_GATEWAY_REGION"):
    value = os.environ.get(key, "")
    print(f"{key}=set:{bool(value)} len:{len(value)}")

token = os.environ.get("ZTI_TOKEN", "")
if token and token.count(".") >= 2:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    obj = json.loads(base64.urlsafe_b64decode(payload.encode()))
    exp = int(obj.get("expireTime", 0))
    if exp:
        print("ZTI_EXPIRE_UTC=" + dt.datetime.fromtimestamp(exp, dt.UTC).strftime("%Y-%m-%d %H:%M:%S UTC"))
PY
fi

if [ -n "${SKILLS_DIR}" ]; then
  CALLER="${SKILLS_DIR}/mcp_tools_usage/scripts/mcp_tool_call.py"
  test -f "${CALLER}"
  echo "MCP_TOOL_CALL_PY=${CALLER}"
fi

if [ -n "${SMOKE_PSMS}" ]; then
  if [ -z "${SKILLS_DIR}" ]; then
    echo "--smoke requires --skills-dir" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${HOME}/.openclaw/service-env/ai.openclaw.gateway.env"
  IFS=',' read -r -a psms <<< "${SMOKE_PSMS}"
  for psm in "${psms[@]}"; do
    psm="$(echo "${psm}" | xargs)"
    [ -n "${psm}" ] || continue
    out="$(mktemp "/tmp/mcp-smoke-${psm//./_}.XXXXXX.out")"
    err="${out%.out}.err"
    set +e
    "${MCP_PYTHON}" "${SKILLS_DIR}/mcp_tools_usage/scripts/mcp_tool_call.py" \
      --psm "${psm}" --tool_list --transport auto >"${out}" 2>"${err}"
    rc=$?
    set -e
    tools="$("${MCP_PYTHON}" - "${SKILLS_DIR}/mcp_tools_usage/outputs/tool_list/${psm}.json" <<'PY'
import json
import sys
from pathlib import Path
p = Path(sys.argv[1])
print(len(json.loads(p.read_text()).get("tools", [])) if p.exists() else -1)
PY
)"
    echo "MCP_SMOKE psm=${psm} rc=${rc} tools=${tools} err_bytes=$(wc -c < "${err}" | tr -d ' ')"
    grep -E "Forbidden|Unauthorized|not allowed|empty jwt|invalid zti|Traceback|McpError|Error:" "${err}" "${out}" 2>/dev/null \
      | grep -Eiv "x-jwt-token|Bearer|Cookie|SECRET|ZTI_TOKEN|STUDIO_COOKIE" \
      | head -5 \
      | sed 's/^/  /' || true
  done
fi
