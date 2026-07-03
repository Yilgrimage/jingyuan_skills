#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
LOCAL_ENVS_DIR="${LOCAL_ENVS_DIR:-/tmp/server-ops-envs}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
ENV_NAME="${MCP_RUNTIME_ENV_NAME:-agent-mcp}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PIP_INDEX="${PIP_INDEX:-http://bytedpypi.byted.org/simple}"
PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-bytedpypi.byted.org}"
NODE_BIN_SOURCE_DIR="${NODE_BIN_SOURCE_DIR:-}"
INCLUDE_NODE=1
FORCE=0

usage() {
  cat <<'EOF'
Usage: build_mcp_runtime_pack.sh [options]

Build a node-local Python venv for MCP calls and publish it as a pack.
Run this on the target image/Python version. The venv is packed from and
restored to the same LOCAL_ENVS_DIR/ENV_NAME prefix.

Options:
  --env-name NAME       Env name under LOCAL_ENVS_DIR (default agent-mcp)
  --local-envs-dir DIR  Local env root (default /tmp/server-ops-envs)
  --pack-dir DIR        Shared pack directory
  --python PATH         Python executable (default python3)
  --node-bin-source DIR Directory containing node/npx/npm to include
  --no-node             Do not include node/npx in the MCP runtime
  --force               Rebuild the local venv even if it exists
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-name) ENV_NAME=$2; shift 2 ;;
    --local-envs-dir) LOCAL_ENVS_DIR=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --python) PYTHON_BIN=$2; shift 2 ;;
    --node-bin-source) NODE_BIN_SOURCE_DIR=$2; shift 2 ;;
    --no-node) INCLUDE_NODE=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "${LOCAL_ENVS_DIR}" "${PACK_DIR}"
PREFIX="${LOCAL_ENVS_DIR}/${ENV_NAME}"

if [ "${FORCE}" -eq 1 ]; then
  rm -rf "${PREFIX}"
fi

if [ ! -x "${PREFIX}/bin/python" ]; then
  rm -rf "${PREFIX}"
  "${PYTHON_BIN}" -m venv --copies "${PREFIX}"
fi

"${PREFIX}/bin/python" -m pip install --upgrade pip setuptools wheel \
  -i "${PIP_INDEX}" --trusted-host "${PIP_TRUSTED_HOST}"
"${PREFIX}/bin/python" -m pip install --upgrade \
  bytedenv bytedance.mcp sseclient-py \
  -i "${PIP_INDEX}" --trusted-host "${PIP_TRUSTED_HOST}"

if [ "${INCLUDE_NODE}" -eq 1 ] && [ -z "${NODE_BIN_SOURCE_DIR}" ]; then
  "${PREFIX}/bin/python" -m pip install --upgrade nodejs-wheel \
    -i "${PIP_INDEX}" --trusted-host "${PIP_TRUSTED_HOST}"
fi

"${PREFIX}/bin/python" - <<'PY'
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

if [ "${INCLUDE_NODE}" -eq 1 ]; then
  rm -rf "${PREFIX}/nodejs-bin"

  if [ -n "${NODE_BIN_SOURCE_DIR}" ] && [ -x "${NODE_BIN_SOURCE_DIR}/node" ] && [ -x "${NODE_BIN_SOURCE_DIR}/npx" ]; then
    cp -aL "${NODE_BIN_SOURCE_DIR}" "${PREFIX}/nodejs-bin"
  else
    PREFIX="${PREFIX}" "${PREFIX}/bin/python" - <<'PY'
import os
import stat
from pathlib import Path

import nodejs_wheel

prefix = Path(os.environ["PREFIX"]).resolve()
pkg = Path(nodejs_wheel.__file__).resolve().parent
node = pkg / "bin" / "node"
npm_cli = pkg / "lib" / "node_modules" / "npm" / "bin" / "npm-cli.js"
npx_cli = pkg / "lib" / "node_modules" / "npm" / "bin" / "npx-cli.js"
corepack_cli = pkg / "lib" / "node_modules" / "corepack" / "dist" / "corepack.js"

required = [node, npm_cli, npx_cli]
missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("nodejs-wheel is missing required files: " + ", ".join(missing))

out = prefix / "nodejs-bin"
out.mkdir(parents=True, exist_ok=True)

def rel(path: Path) -> str:
    return os.path.relpath(path, prefix)

node_rel = rel(node)

def write_wrapper(name: str, target_rel: str, cli_rel: str | None = None) -> None:
    path = out / name
    if cli_rel:
        exec_line = f'exec "$ROOT/{node_rel}" "$ROOT/{cli_rel}" "$@"'
    else:
        exec_line = f'exec "$ROOT/{target_rel}" "$@"'
    path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\n'
        f"{exec_line}\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

write_wrapper("node", node_rel)
write_wrapper("npm", node_rel, rel(npm_cli))
write_wrapper("npx", node_rel, rel(npx_cli))
if corepack_cli.exists():
    write_wrapper("corepack", node_rel, rel(corepack_cli))
PY
  fi
  test -x "${PREFIX}/nodejs-bin/node"
  test -x "${PREFIX}/nodejs-bin/npx"
  PATH="${PREFIX}/nodejs-bin:${PATH}" "${PREFIX}/nodejs-bin/node" --version
  PATH="${PREFIX}/nodejs-bin:${PATH}" "${PREFIX}/nodejs-bin/npx" --version
fi

py_tag="$("${PREFIX}/bin/python" - <<'PY'
import sys
print(f"py{sys.version_info.major}{sys.version_info.minor}")
PY
)"
PACK="${PACK_DIR}/mcp-runtime-${py_tag}-${ENV_NAME}.tar.gz"
tar -C "${LOCAL_ENVS_DIR}" -czf "${PACK}" "${ENV_NAME}"
sha256sum "${PACK}" > "${PACK}.sha256"
{
  echo "kind=mcp-runtime"
  echo "env_name=${ENV_NAME}"
  echo "prefix=${PREFIX}"
  echo "python_tag=${py_tag}"
  echo "created_utc=$(date -u +%Y%m%dT%H%M%SZ)"
  echo "pack_sha256=$(awk '{print $1}' "${PACK}.sha256")"
  "${PREFIX}/bin/python" - <<'PY'
import importlib.metadata as md
import sys
print("python=" + sys.version.split()[0])
for name in ("bytedenv", "bytedance.mcp", "bytedztijwthelper", "sseclient-py"):
    try:
        print(f"{name}={md.version(name)}")
    except md.PackageNotFoundError:
        print(f"{name}=not-found")
PY
  if [ -x "${PREFIX}/nodejs-bin/node" ]; then
    echo "node=$("${PREFIX}/nodejs-bin/node" --version)"
    echo "npx=$(PATH="${PREFIX}/nodejs-bin:${PATH}" "${PREFIX}/nodejs-bin/npx" --version)"
  else
    echo "node=not-included"
    echo "npx=not-included"
  fi
} > "${PACK%.tar.gz}.revision"

echo "MCP_RUNTIME_PACK=${PACK}"
echo "MCP_RUNTIME_PREFIX=${PREFIX}"
