#!/usr/bin/env bash
# Verify skill discovery wiring. Every skill directory (a directory containing
# SKILL.md, either at skills/<name>/ or grouped at skills/<group>/<name>/) must
# be mirrored by a same-named symlink in .claude/skills/ and .agents/skills/,
# skill names must be unique across groups, and the mirrors must contain no
# extra or dangling entries. Agent skill discovery is flat, so these mirrors
# are what Claude Code and cross-agent tools actually read.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
err() {
  printf 'lint-skills-wiring: %s\n' "$*" >&2
  fail=1
}

skill_dirs="$(
  find skills -mindepth 2 -maxdepth 3 -name SKILL.md | sort | while IFS= read -r f; do
    dir="${f%/SKILL.md}"
    parent="$(dirname "$dir")"
    if [[ "$parent" != "skills" && -f "$parent/SKILL.md" ]]; then
      continue
    fi
    printf '%s\n' "$dir"
  done
)"
[[ -n "$skill_dirs" ]] || { err "no skills found under skills/"; exit 1; }

names="$(printf '%s\n' "$skill_dirs" | while IFS= read -r d; do basename "$d"; done | sort)"
dups="$(printf '%s\n' "$names" | uniq -d)"
[[ -z "$dups" ]] || err "duplicate skill names across groups: $(printf '%s ' $dups)"

while IFS= read -r dir; do
  name="$(basename "$dir")"
  for mirror in .claude/skills .agents/skills; do
    link="$mirror/$name"
    if [[ ! -L "$link" ]]; then
      err "missing symlink: $link (expected -> ../../$dir)"
      continue
    fi
    resolved="$(cd "$mirror" 2>/dev/null && cd "$(readlink "$name")" 2>/dev/null && pwd)" ||
      { err "dangling symlink: $link -> $(readlink "$link")"; continue; }
    expected="$(cd "$dir" && pwd)"
    if [[ "$resolved" != "$expected" ]]; then
      err "wrong target: $link -> $(readlink "$link") (expected ../../$dir)"
    fi
  done
done <<<"$skill_dirs"

for mirror in .claude/skills .agents/skills; do
  for entry in "$mirror"/* "$mirror"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    if ! printf '%s\n' "$names" | grep -qx "$name"; then
      err "extra entry in $mirror: $name (no matching skills/**/SKILL.md)"
    fi
  done
done

if [[ "$fail" -eq 0 ]]; then
  printf 'skills wiring OK (%s skills)\n' "$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
fi
exit "$fail"
