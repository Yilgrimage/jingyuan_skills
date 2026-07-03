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
SOURCE_DIR="${AGENT_WORKSPACE_SOURCE_DIR:-}"
SKILLS_PACK="${SKILLS_PACK:-${PACK_DIR}/agent-business-skills.tar.gz}"
PERSONA_PACK="${PERSONA_PACK:-${PACK_DIR}/agent-persona.tar.gz}"

usage() {
  cat <<'EOF'
Usage: pack_agent_workspace_layers.sh --source DIR [options]

Build split agent workspace packs:
  - agent-business-skills.tar.gz: business skills only
  - agent-persona.tar.gz: AGENTS/SOUL/IDENTITY only

Data stays on NAS and is referenced by run configs. This script is
whitelist-based and excludes runtime outputs, logs, secrets, session archives,
eval scratch, caches, and train data.

Options:
  --source DIR           Source workspace containing skills/ and persona files
  --pack-dir DIR         Output pack directory
  --skills-pack PATH     Output skills pack
  --persona-pack PATH    Output persona pack
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR=$2; shift 2 ;;
    --pack-dir) PACK_DIR=$2; shift 2 ;;
    --skills-pack) SKILLS_PACK=$2; shift 2 ;;
    --persona-pack) PERSONA_PACK=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${SOURCE_DIR}" ]; then
  echo "Missing --source DIR" >&2
  exit 1
fi

SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -P)"
mkdir -p "${PACK_DIR}"
test -d "${SOURCE_DIR}/skills"

tmp="$(mktemp -d /tmp/agent-workspace-pack.XXXXXX)"
cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

copy_persona_file() {
  local dst="$1"; shift
  local name
  for name in "$@"; do
    if [ -f "${SOURCE_DIR}/${name}" ]; then
      cp "${SOURCE_DIR}/${name}" "${tmp}/persona/${dst}"
      return 0
    fi
  done
  echo "Missing persona file for ${dst} under ${SOURCE_DIR}" >&2
  return 1
}

write_sha_revision() {
  local pack="$1"
  local kind="$2"
  sha256sum "${pack}" > "${pack}.sha256"
  {
    echo "kind=${kind}"
    echo "source=${SOURCE_DIR}"
    echo "created_utc=$(date -u +%Y%m%dT%H%M%SZ)"
    echo "pack_sha256=$(awk '{print $1}' "${pack}.sha256")"
  } > "${pack%.tar.gz}.revision"
}

mkdir -p "${tmp}/skills" "${tmp}/persona"

rsync -a --delete \
  --exclude '.git/' \
  --exclude '.env' \
  --exclude '*.env' \
  --exclude 'outputs/' \
  --exclude 'log/' \
  --exclude 'logs/' \
  --exclude 'sessions/' \
  --exclude 'sessions_*.zip' \
  --exclude 'session_*.zip' \
  --exclude '*.zip' \
  --exclude '*.tar' \
  --exclude '*.tar.gz' \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude '.DS_Store' \
  "${SOURCE_DIR}/skills/" "${tmp}/skills/"

copy_persona_file AGENTS.md AGENTS.md agents.md
copy_persona_file SOUL.md SOUL.md soul.md
copy_persona_file IDENTITY.md IDENTITY.md identity.md

TARGET="${tmp}" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["TARGET"])
skills = root / "skills"
skill_count = len(list(skills.rglob("SKILL.md")))
if skill_count == 0:
    print("No SKILL.md found in skills pack", file=sys.stderr)
    sys.exit(1)

caller = skills / "mcp_tools_usage" / "scripts" / "mcp_tool_call.py"
if not caller.is_file():
    print(f"Missing shared MCP caller: {caller}", file=sys.stderr)
    sys.exit(1)

stdio = skills / "mcp_tools_usage" / "scripts" / "stdio_server_configs.json"
if not stdio.is_file():
    print(f"Missing stdio server config: {stdio}", file=sys.stderr)
    sys.exit(1)
configured = json.loads(stdio.read_text(encoding="utf-8"))
if not isinstance(configured, dict):
    print(f"Invalid stdio server config: {stdio}", file=sys.stderr)
    sys.exit(1)

for rel in ("AGENTS.md", "SOUL.md", "IDENTITY.md"):
    path = root / "persona" / rel
    if not path.is_file():
        print(f"Missing persona file: {path}", file=sys.stderr)
        sys.exit(1)

print(f"SKILL_COUNT={skill_count}")
print(f"MCP_STDIO_CONFIGS={len(configured)}")
print(f"AGENTS_CHARS={len((root / 'persona' / 'AGENTS.md').read_text(encoding='utf-8'))}")
PY

tar -C "${tmp}" -czf "${SKILLS_PACK}" skills
tar -C "${tmp}" -czf "${PERSONA_PACK}" persona

write_sha_revision "${SKILLS_PACK}" agent-business-skills
write_sha_revision "${PERSONA_PACK}" agent-persona

echo "AGENT_SKILLS_PACK=${SKILLS_PACK}"
echo "AGENT_PERSONA_PACK=${PERSONA_PACK}"
