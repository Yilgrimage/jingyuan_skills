#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SERVER_OPS_CONFIG:-${HOME}/.jingyuan/server_ops.env}"
if [ -z "${ROOT_DIR:-}" ] && [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
LOCAL_RUNTIME_DIR="${LOCAL_RUNTIME_DIR:-/tmp/server-ops-runtime}"
PACK_DIR="${PACK_DIR:-${ROOT_DIR}/packs}"
PACK="${CODEX_EU_RUNTIME_PACK:-}"
TARGET="${CODEX_EU_RUNTIME_DIR:-${LOCAL_RUNTIME_DIR}/codex-eu-runtime}"
CODEX_HOME_TARGET="${CODEX_HOME_TARGET:-${LOCAL_RUNTIME_DIR}/codex-eu-home}"
MODEL="${HARNESS_CODEX_MODEL:-harness-policy}"
MODEL_DISPLAY_NAME="${HARNESS_CODEX_MODEL_DISPLAY_NAME:-${MODEL}}"
MODEL_PROVIDER_ID="${HARNESS_CODEX_MODEL_PROVIDER_ID:-local-policy}"
MODEL_PROVIDER_BASE_URL="${HARNESS_CODEX_MODEL_PROVIDER_BASE_URL:-}"
MODEL_PROVIDER_WIRE_API="${HARNESS_CODEX_MODEL_PROVIDER_WIRE_API:-responses}"
MODEL_CONTEXT_WINDOW="${HARNESS_CODEX_MODEL_CONTEXT_WINDOW:-}"
MODEL_MAX_CONTEXT_WINDOW="${HARNESS_CODEX_MODEL_MAX_CONTEXT_WINDOW:-${MODEL_CONTEXT_WINDOW}}"
MODEL_AUTO_COMPACT_TOKEN_LIMIT="${HARNESS_CODEX_MODEL_AUTO_COMPACT_TOKEN_LIMIT:-}"
MODEL_TEMPLATE="${HARNESS_CODEX_MODEL_TEMPLATE:-gpt-5.6-terra}"
MODEL_REASONING_EFFORT="${HARNESS_CODEX_MODEL_REASONING_EFFORT:-medium}"
WEB_SEARCH="${HARNESS_CODEX_WEB_SEARCH:-disabled}"
TOOL_OUTPUT_TOKEN_LIMIT="${HARNESS_CODEX_TOOL_OUTPUT_TOKEN_LIMIT:-32768}"
SKILLS_DIR="${HARNESS_CODEX_SKILL_DIRS:-${HARNESS_AGENT_SKILL_DIRS:-}}"
FORCE=0

usage() {
  cat <<'EOF'
Usage: materialize_codex_eu_online_runtime.sh [options]

Restore the online Codex-EU backend runtime pack onto node-local storage and
build an isolated CODEX_HOME for the local policy model.

The pack contains online Codex templates only. The effective model metadata is
generated per run from explicit HARNESS_CODEX_* values, so changing 4B/9B/27B,
context length, or local policy endpoint does not require rebuilding the pack.

Required for local policy:
  --provider-base-url URL      Local Responses-compatible policy proxy
  --context-window TOKENS      Served model context window

Options:
  --pack PATH                  Runtime pack. Defaults to newest codex-eu-backend-runtime-*.tar.gz
  --target DIR                 Node-local backend runtime target
  --codex-home DIR             Node-local CODEX_HOME target
  --model SLUG                 Local Codex model slug
  --display-name NAME          Display name in generated catalog
  --provider-id ID             Codex model provider id
  --provider-base-url URL      Local policy proxy base URL
  --wire-api responses|chat    Provider wire API. Default responses.
  --context-window TOKENS      Local served model context window
  --max-context-window TOKENS  Local served model max context window
  --auto-compact-limit TOKENS  Auto compact token limit. Default min(95%, ctx-8192)
  --template-model SLUG        Online catalog entry used as metadata template
  --reasoning-effort EFFORT    Codex reasoning effort in config
  --web-search MODE            disabled|cached|live. Default disabled.
  --tool-output-token-limit N  Tool output token limit in config
  --skills-dir DIR             Optional materialized skills root to expose in CODEX_HOME
  --pack-dir DIR               Shared pack directory
  --force                      Re-extract even if hash marker matches
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pack) PACK=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --codex-home) CODEX_HOME_TARGET=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --display-name) MODEL_DISPLAY_NAME=$2; shift 2 ;;
    --provider-id) MODEL_PROVIDER_ID=$2; shift 2 ;;
    --provider-base-url) MODEL_PROVIDER_BASE_URL=$2; shift 2 ;;
    --wire-api) MODEL_PROVIDER_WIRE_API=$2; shift 2 ;;
    --context-window) MODEL_CONTEXT_WINDOW=$2; shift 2 ;;
    --max-context-window) MODEL_MAX_CONTEXT_WINDOW=$2; shift 2 ;;
    --auto-compact-limit) MODEL_AUTO_COMPACT_TOKEN_LIMIT=$2; shift 2 ;;
    --template-model) MODEL_TEMPLATE=$2; shift 2 ;;
    --reasoning-effort) MODEL_REASONING_EFFORT=$2; shift 2 ;;
    --web-search) WEB_SEARCH=$2; shift 2 ;;
    --tool-output-token-limit) TOOL_OUTPUT_TOKEN_LIMIT=$2; shift 2 ;;
    --skills-dir) SKILLS_DIR=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${PACK}" ]; then
  PACK="$(ls -t "${PACK_DIR}"/codex-eu-backend-runtime-*.tar.gz 2>/dev/null | head -1 || true)"
fi
if [ -z "${PACK}" ] || [ ! -f "${PACK}" ]; then
  echo "Missing Codex-EU backend runtime pack. Build it with pack_codex_eu_online_runtime.sh." >&2
  exit 1
fi
if [ -z "${MODEL_PROVIDER_BASE_URL}" ]; then
  echo "Missing --provider-base-url / HARNESS_CODEX_MODEL_PROVIDER_BASE_URL." >&2
  exit 1
fi
if [ -z "${MODEL_CONTEXT_WINDOW}" ]; then
  echo "Missing --context-window / HARNESS_CODEX_MODEL_CONTEXT_WINDOW." >&2
  exit 1
fi

case "${MODEL_PROVIDER_WIRE_API}" in
  responses|chat) ;;
  *) echo "--wire-api must be responses or chat" >&2; exit 1 ;;
esac
case "${WEB_SEARCH}" in
  disabled|cached|live) ;;
  *) echo "--web-search must be disabled, cached, or live" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "${TARGET}")" "$(dirname "${CODEX_HOME_TARGET}")"
PACK_SHA="$(if [ -f "${PACK}.sha256" ]; then awk '{print $1}' "${PACK}.sha256"; else sha256sum "${PACK}" | awk '{print $1}'; fi)"
STAMP="${TARGET}/.pack.sha256"

if [ "${FORCE}" -eq 0 ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${PACK_SHA}" ]; then
  echo "CODEX_EU_RUNTIME_DIR=${TARGET} (cached)"
else
  tmp="${TARGET}.next"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  tar -xzf "${PACK}" -C "${tmp}"
  test -x "${tmp}/codex-eu/bin/codex.real"
  test -f "${tmp}/codex-eu/runtime/model_catalog_1m.json"
  rm -rf "${TARGET}.old"
  if [ -e "${TARGET}" ]; then
    mv "${TARGET}" "${TARGET}.old"
  fi
  mv "${tmp}/codex-eu" "${TARGET}"
  rm -rf "${tmp}" "${TARGET}.old"
  printf '%s\n' "${PACK_SHA}" > "${STAMP}"
  echo "CODEX_EU_RUNTIME_DIR=${TARGET}"
fi

mkdir -p "${CODEX_HOME_TARGET}" "${CODEX_HOME_TARGET}/tmp" "${CODEX_HOME_TARGET}/.tmp" \
  "${CODEX_HOME_TARGET}/sessions" "${CODEX_HOME_TARGET}/cache" \
  "${CODEX_HOME_TARGET}/shell_snapshots" "${CODEX_HOME_TARGET}/log"

for name in AGENTS.md version.json tmp.md; do
  if [ -f "${TARGET}/runtime/${name}" ]; then
    cp -a "${TARGET}/runtime/${name}" "${CODEX_HOME_TARGET}/${name}"
  fi
done
for dir in plugins python_shims; do
  rm -rf "${CODEX_HOME_TARGET}/${dir}"
  if [ -d "${TARGET}/runtime/${dir}" ]; then
    cp -a "${TARGET}/runtime/${dir}" "${CODEX_HOME_TARGET}/${dir}"
  fi
done
if [ -n "${SKILLS_DIR}" ]; then
  test -d "${SKILLS_DIR}"
  rm -rf "${CODEX_HOME_TARGET}/skills"
  ln -s "${SKILLS_DIR}" "${CODEX_HOME_TARGET}/skills"
fi

CODEX_HOME_TARGET="${CODEX_HOME_TARGET}" \
TARGET="${TARGET}" \
MODEL="${MODEL}" \
MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME}" \
MODEL_PROVIDER_ID="${MODEL_PROVIDER_ID}" \
MODEL_PROVIDER_BASE_URL="${MODEL_PROVIDER_BASE_URL}" \
MODEL_PROVIDER_WIRE_API="${MODEL_PROVIDER_WIRE_API}" \
MODEL_CONTEXT_WINDOW="${MODEL_CONTEXT_WINDOW}" \
MODEL_MAX_CONTEXT_WINDOW="${MODEL_MAX_CONTEXT_WINDOW}" \
MODEL_AUTO_COMPACT_TOKEN_LIMIT="${MODEL_AUTO_COMPACT_TOKEN_LIMIT}" \
MODEL_TEMPLATE="${MODEL_TEMPLATE}" \
MODEL_REASONING_EFFORT="${MODEL_REASONING_EFFORT}" \
WEB_SEARCH="${WEB_SEARCH}" \
TOOL_OUTPUT_TOKEN_LIMIT="${TOOL_OUTPUT_TOKEN_LIMIT}" \
python3 - <<'PY'
import json
import os
import re
from copy import deepcopy
from pathlib import Path

target = Path(os.environ["TARGET"])
home = Path(os.environ["CODEX_HOME_TARGET"])
model = os.environ["MODEL"]
display = os.environ["MODEL_DISPLAY_NAME"]
provider_id = os.environ["MODEL_PROVIDER_ID"]
base_url = os.environ["MODEL_PROVIDER_BASE_URL"]
wire_api = os.environ["MODEL_PROVIDER_WIRE_API"]
ctx = int(os.environ["MODEL_CONTEXT_WINDOW"])
max_ctx = int(os.environ["MODEL_MAX_CONTEXT_WINDOW"] or ctx)
auto_limit_raw = os.environ["MODEL_AUTO_COMPACT_TOKEN_LIMIT"]
auto_limit = int(auto_limit_raw) if auto_limit_raw else min(max(ctx - 8192, 1), int(ctx * 0.95))
template_slug = os.environ["MODEL_TEMPLATE"]
reasoning = os.environ["MODEL_REASONING_EFFORT"]
web_search = os.environ["WEB_SEARCH"]
tool_output_limit = int(os.environ["TOOL_OUTPUT_TOKEN_LIMIT"])

if ctx <= 0 or max_ctx <= 0:
    raise SystemExit("context windows must be positive")
if ctx > max_ctx:
    raise SystemExit("model_context_window cannot exceed model_max_context_window")
if not 0 < auto_limit < ctx:
    raise SystemExit("auto compact limit must be between 0 and context window")
if not re.fullmatch(r"[A-Za-z0-9_.:/-]+", model):
    raise SystemExit("model slug has unsupported characters")
if not re.fullmatch(r"[A-Za-z0-9_-]+", provider_id):
    raise SystemExit("provider id must contain only letters, digits, '_' or '-'")
if not base_url.startswith(("http://", "https://")):
    raise SystemExit("provider base_url must be http(s)")

catalog_path = target / "runtime" / "model_catalog_1m.json"
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
models = catalog.get("models")
if not isinstance(models, list) or not models:
    raise SystemExit("invalid model catalog: missing models list")

template = next((m for m in models if m.get("slug") == template_slug), None)
if template is None:
    template = models[0]

entry = deepcopy(template)
entry["slug"] = model
entry["display_name"] = display
entry["description"] = f"Local policy model served through {provider_id}."
entry["context_window"] = ctx
entry["max_context_window"] = max_ctx
entry["effective_context_window_percent"] = min(100, max(1, int(ctx * 100 / max_ctx)))
entry["supported_in_api"] = True
entry["visibility"] = "list"

catalog["models"] = [entry]
catalog["fetched_at"] = "local-generated"
catalog["etag"] = "local-generated"
derived_catalog = home / "model_catalog.json"
derived_catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

base_text = (target / "runtime" / "config.toml").read_text(encoding="utf-8")
lines = base_text.splitlines()
retained = []
at_top = True
skip_top = {
    "approval_policy",
    "sandbox_mode",
    "model",
    "model_provider",
    "model_context_window",
    "model_auto_compact_token_limit",
    "model_catalog_json",
    "model_reasoning_effort",
    "web_search",
    "tool_output_token_limit",
}
assignment = re.compile(r'^\s*([A-Za-z0-9_-]+)\s*=')
for line in lines:
    if at_top and line.lstrip().startswith("["):
        at_top = False
    if at_top:
        match = assignment.match(line)
        if match and match.group(1) in skip_top:
            continue
    retained.append(line)

prefix = [
    'approval_policy = "never"',
    'sandbox_mode = "danger-full-access"',
    f'model = {json.dumps(model)}',
    f'model_provider = {json.dumps(provider_id)}',
    f'model_reasoning_effort = {json.dumps(reasoning)}',
    f'model_context_window = {ctx}',
    f'model_auto_compact_token_limit = {auto_limit}',
    f'tool_output_token_limit = {tool_output_limit}',
    f'web_search = {json.dumps(web_search)}',
    f'model_catalog_json = {json.dumps(str(derived_catalog))}',
    "",
]

provider_block = [
    "",
    f"[model_providers.{provider_id}]",
    f"name = {json.dumps(provider_id)}",
    f"base_url = {json.dumps(base_url)}",
    f'wire_api = {json.dumps(wire_api)}',
    "",
]

config_text = "\n".join(prefix + retained + provider_block)
if not config_text.endswith("\n"):
    config_text += "\n"
(home / "config.toml").write_text(config_text, encoding="utf-8")
PY

wrapper_dir="${TARGET}/local-bin"
mkdir -p "${wrapper_dir}"
cat > "${wrapper_dir}/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export CODEX_EU_HOME='${TARGET}'
export CODEX_HOME="\${CODEX_HOME:-${CODEX_HOME_TARGET}}"
export CODEX_CONFIG_HOME="\${CODEX_CONFIG_HOME:-\${CODEX_HOME}}"
export CODEX_RUNTIME_HOME="\${CODEX_RUNTIME_HOME:-\${CODEX_HOME}}"
export CODEX_SQLITE_HOME="\${CODEX_SQLITE_HOME:-\${CODEX_HOME}}"
export PATH="${TARGET}/bin:${TARGET}/.cc-connect/data/bin:\${PATH}"
exec '${TARGET}/bin/codex.real' "\$@"
EOF
chmod 755 "${wrapper_dir}/codex"

"${wrapper_dir}/codex" --version

env_file="${TARGET}/codex_eu_runtime.env"
cat > "${env_file}" <<EOF
export CODEX_EU_RUNTIME_DIR='${TARGET}'
export CODEX_HOME='${CODEX_HOME_TARGET}'
export CODEX_CONFIG_HOME='${CODEX_HOME_TARGET}'
export CODEX_RUNTIME_HOME='${CODEX_HOME_TARGET}'
export CODEX_SQLITE_HOME='${CODEX_HOME_TARGET}'
export CODEX_BIN='${wrapper_dir}/codex'
export HARNESS_CODEX_MODEL='${MODEL}'
export HARNESS_CODEX_MODEL_PROVIDER_ID='${MODEL_PROVIDER_ID}'
export HARNESS_CODEX_MODEL_PROVIDER_BASE_URL='${MODEL_PROVIDER_BASE_URL}'
export HARNESS_CODEX_MODEL_CONTEXT_WINDOW='${MODEL_CONTEXT_WINDOW}'
export HARNESS_CODEX_MODEL_MAX_CONTEXT_WINDOW='${MODEL_MAX_CONTEXT_WINDOW}'
export PATH="${wrapper_dir}:${TARGET}/bin:${TARGET}/.cc-connect/data/bin:\${PATH}"
EOF

echo "CODEX_EU_RUNTIME_ENV=${env_file}"
echo "CODEX_HOME=${CODEX_HOME_TARGET}"
echo "CODEX_BIN=${wrapper_dir}/codex"
echo "CODEX_MODEL_CATALOG=${CODEX_HOME_TARGET}/model_catalog.json"
