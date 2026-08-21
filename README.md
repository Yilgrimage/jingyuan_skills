# Jingyuan Skills

Canonical, reusable skills for agent workflows. This repository is the source
of truth for skill handoff and installation. Copies under an application
repository's `.claude/skills/` are vendored snapshots for repo-local discovery;
update this repository whenever those snapshots change.

- `agentic-slime-discipline`: engineering discipline for the agentic Slime RL
  training stack.
- `server-ops-discipline`: server, runtime-pack, node, and GPU keepalive
  discipline.

Install into Codex with:

```bash
for skill in agentic-slime-discipline server-ops-discipline; do
  rm -rf "${HOME}/.codex/skills/${skill}"
  cp -a "${skill}" "${HOME}/.codex/skills/${skill}"
done
```

For a new cluster with no existing packs, start with
`server-ops-discipline/references/runtime_pack_build.md`.
