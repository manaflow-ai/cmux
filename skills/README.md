# skills/

Agent skills shipped with cmux. Each skill is a directory containing `SKILL.md`, either directly under `skills/` or grouped one level deeper (for example `skills/apple/swiftui-specialist/`).

Agent discovery is flat. Claude Code reads `.claude/skills/` and cross-agent tools (Codex, OpenCode, and others following the `.agents/skills/` convention) read `.agents/skills/`. Both directories hold one symlink per skill regardless of grouping, so skill names must be unique across all groups. `skills.sh` resolves skills by name and installs them flat into the Codex skills directory.

Adding a skill:

1. Create `skills/<name>/SKILL.md` (or `skills/<group>/<name>/SKILL.md`).
2. Add symlinks `.claude/skills/<name>` and `.agents/skills/<name>` pointing at the skill directory.
3. `scripts/lint-skills-wiring.sh` runs in CI and fails on missing, dangling, mistargeted, extra, or duplicate-name entries.

`skills/apple/` holds Apple-authored skills exported from the Xcode 27 developer beta (`xcrun agent skills export`), copied verbatim from https://github.com/mariusfanu/xcode-skills. To refresh on a new beta, re-export and diff against this directory.
