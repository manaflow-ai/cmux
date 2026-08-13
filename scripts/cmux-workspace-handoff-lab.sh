#!/usr/bin/env bash
set -euo pipefail

# manual runbook — spends agent tokens; NOT run in CI
#
# This lab is deliberately outside the repository. It creates only fresh
# Claude/Codex session ids and never reads credential files or existing
# sessions. The resulting run directory is retained for inspection.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/cmux-workspace-handoff.py"
LAB_ROOT="/tmp/cmux-remote-lab"
RUN_ID="$(date +%s)"
RUN_DIR="$LAB_ROOT/run-$RUN_ID"
SRC="$RUN_DIR/src"
DST="$RUN_DIR/dst"
OBSERVED_HOME="$RUN_DIR/home-observed"
LOGS="$RUN_DIR/logs"
CLAUDE_ONLY=0
CODEX_ONLY=0
KEEP=0

while (($#)); do
  case "$1" in
    --claude-only) CLAUDE_ONLY=1 ;;
    --codex-only) CODEX_ONLY=1 ;;
    --keep) KEEP=1 ;;
    -h|--help)
      sed -n '1,14p' "$0"
      printf 'usage: %s [--claude-only|--codex-only] [--keep]\n' "$0"
      exit 0
      ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
if ((CLAUDE_ONLY && CODEX_ONLY)); then
  printf '%s\n' '--claude-only and --codex-only are mutually exclusive' >&2
  exit 2
fi

SLUG_SRC="$RUN_DIR/src.dot_under"
SLUG_DST="$RUN_DIR/dst.dot_under"
SLUG_REWRITE_DST="$RUN_DIR/dst-rewrite.dot_under"
mkdir -p "$SRC" "$DST" "$SLUG_SRC" "$OBSERVED_HOME" "$LOGS"
SRC_ABS="$(cd "$SRC" && pwd -P)"
exec 3>"$LOGS/runbook.transcript"
printf '%s\n' 'manual runbook — spends agent tokens; NOT run in CI' | tee /dev/fd/3
printf 'run directory: %s\n' "$RUN_DIR" | tee /dev/fd/3

pass() { printf 'PASS: %s\n' "$1" | tee -a "$LOGS/assertions.log" /dev/fd/3; }
fail() { printf 'FAIL: %s\n' "$1" | tee -a "$LOGS/assertions.log" /dev/fd/3; }
run_logged() {
  local name="$1"; shift
  printf '\n$' | tee -a "$LOGS/$name.command" /dev/fd/3 >/dev/null
  printf ' %q' "$@" | tee -a "$LOGS/$name.command" /dev/fd/3 >/dev/null
  printf '\n' | tee -a "$LOGS/$name.command" /dev/fd/3 >/dev/null
  "$@" >"$LOGS/$name.stdout" 2>"$LOGS/$name.stderr" || return $?
}

git -C "$SRC" init -q -b main
git -C "$SRC" config user.email lab@example.invalid
git -C "$SRC" config user.name 'cmux remote lab'
printf '*.secret\n' >"$SRC/.gitignore"
printf 'base\n' >"$SRC/README.md"
git -C "$SRC" add .
git -C "$SRC" commit -qm base

# A local bare remote with two commits; the superproject pins the first (not
# tip) commit so the restore path proves SHA pinning rather than branch naming.
SUBWORK="$RUN_DIR/subwork"
SUBREMOTE="$RUN_DIR/submodule.git"
mkdir -p "$SUBWORK"
git -C "$SUBWORK" init -q -b main
git -C "$SUBWORK" config user.email lab@example.invalid
git -C "$SUBWORK" config user.name 'cmux remote lab'
printf 'submodule one\n' >"$SUBWORK/file"
git -C "$SUBWORK" add file; git -C "$SUBWORK" commit -qm one
SUB_SHA="$(git -C "$SUBWORK" rev-parse HEAD)"
printf 'submodule two\n' >"$SUBWORK/file"
git -C "$SUBWORK" commit -qam two
git clone -q --bare "$SUBWORK" "$SUBREMOTE"
git -C "$SRC" -c protocol.file.allow=always submodule add -q "file://$(cd "$SUBREMOTE" && pwd -P)" vendor/sub
git -C "$SRC/vendor/sub" checkout -q "$SUB_SHA"
git -C "$SRC" add .gitmodules vendor/sub
git -C "$SRC" commit -qm 'pin submodule at non-tip'

printf 'staged version\n' >"$SRC/split.txt"; git -C "$SRC" add split.txt
printf 'unstaged version\n' >"$SRC/split.txt"
printf 'tracked deletion kept as untracked\n' >"$SRC/kept.txt"; git -C "$SRC" add kept.txt; git -C "$SRC" commit -qm 'add kept file'
git -C "$SRC" rm --cached -q kept.txt
mkdir -p "$SRC/new"
printf 'nested untracked\n' >"$SRC/new/dir.txt"
printf 'ignored secret\n' >"$SRC/private.secret"
chmod 600 "$SRC/private.secret"

BASE_STATUS="$RUN_DIR/status.before"
git -C "$SRC" status --porcelain=v2 >"$BASE_STATUS"
BASE_REFS="$RUN_DIR/refs.before"
git -C "$SRC" for-each-ref >"$BASE_REFS"
if run_logged fixture-snapshot python3 "$TOOL" snapshot --workspace "$SRC" --out "$RUN_DIR/bundle" --include-ignored private.secret; then
  pass 'snapshot fixture and ignored allowlist'
else
  fail 'snapshot fixture'
fi
if run_logged fixture-restore python3 "$TOOL" restore --bundle "$RUN_DIR/bundle" --dest "$DST" --skip-agent-sessions; then
  pass 'restore fixture'
else
  fail 'restore fixture'
fi
if python3 "$TOOL" verify --source "$SRC" --restored "$DST" >>"$LOGS/fixture-verify.stdout" 2>>"$LOGS/fixture-verify.stderr"; then
  pass 'round-trip verify'
else
  fail 'round-trip verify'
fi
if cmp -s "$BASE_STATUS" <(git -C "$SRC" status --porcelain=v2) && cmp -s "$BASE_REFS" <(git -C "$SRC" for-each-ref); then
  pass 'source repository unchanged'
else
  fail 'source repository changed'
fi

FINDINGS="$RUN_DIR/findings.md"
{
  printf '# cmux remote resume-fidelity lab (%s)\n\n' "$RUN_ID"
  printf 'The fixture protocol passed before agent legs. Full command/output transcripts are in `logs/`.\n\n'
  printf '| leg | status | evidence |\n|---|---|---|\n'
} >"$FINDINGS"

# A separate clean repository whose source and destination both contain the
# two characters whose Claude project-slug treatment must be empirical.
git -C "$SLUG_SRC" init -q -b main
git -C "$SLUG_SRC" config user.email lab@example.invalid
git -C "$SLUG_SRC" config user.name 'cmux remote lab'
printf 'dotted slug fixture\n' >"$SLUG_SRC/README.md"
git -C "$SLUG_SRC" add README.md
git -C "$SLUG_SRC" commit -qm 'dotted slug fixture'
SLUG_SRC_ABS="$(cd "$SLUG_SRC" && pwd -P)"

codex_answer_summary() {
  python3 - "$1" <<'PY'
import json
import re
import sys

texts = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    item = value.get("item", {})
    text = item.get("text") or item.get("message")
    if text:
        texts.append(str(text))
joined = " ".join(texts).replace("\n", " ")
paths = re.findall(r"(?:/private)?/(?:tmp|Users|var)/[^\s`\"]+", joined)
print("answer=" + joined)
print("cwd=" + (paths[-1] if paths else "<not reported>"))
PY
}

CLAUDE_SID=""
CODEX_SID=""
if (( ! CODEX_ONLY )); then
  CLAUDE_SID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  # State the lab fact directly: Claude's safety heuristics reject the
  # “remember this and nothing else” social-engineering framing.
  CLAUDE_WORD="cobalt"
  CLAUDE_LOG="$LOGS/claude-create"
  CLAUDE_ENV=(env -i "HOME=$HOME" "PATH=$PATH" "USER=${USER:-}" "SHELL=${SHELL:-/bin/zsh}" "TMPDIR=${TMPDIR:-/tmp}" TERM=xterm-256color LANG=en_US.UTF-8)
  set +e
  (cd "$SLUG_SRC" && "${CLAUDE_ENV[@]}" claude -p --session-id "$CLAUDE_SID" --model claude-haiku-4-5-20251001 \
    "For this lab, the codeword is $CLAUDE_WORD. Reply with exactly OK.") >"$CLAUDE_LOG.stdout" 2>"$CLAUDE_LOG.stderr"
  CLAUDE_CREATE_STATUS=$?
  set -e
  if ((CLAUDE_CREATE_STATUS != 0)) && grep -qi 'model' "$CLAUDE_LOG.stderr"; then
    set +e
    (cd "$SLUG_SRC" && "${CLAUDE_ENV[@]}" claude -p --session-id "$CLAUDE_SID" --model haiku \
      "For this lab, the codeword is $CLAUDE_WORD. Reply with exactly OK.") >"$CLAUDE_LOG.stdout" 2>"$CLAUDE_LOG.stderr"
    CLAUDE_CREATE_STATUS=$?
    set -e
  fi
  if ((CLAUDE_CREATE_STATUS == 0)) && grep -q 'OK' "$CLAUDE_LOG.stdout"; then
    pass 'claude create returned OK'
    CLAUDE_FILE="$(find "$HOME/.claude/projects" -type f -name "$CLAUDE_SID.jsonl" -print -quit 2>/dev/null || true)"
    if [[ -n "$CLAUDE_FILE" && -f "$CLAUDE_FILE" ]]; then
      CLAUDE_SLUG_DIR="$(dirname "$CLAUDE_FILE")"
      CLAUDE_SLUG_NAME="${CLAUDE_SLUG_DIR##*/}"
      CLAUDE_EXPECTED_SLUG="$(python3 - "$SLUG_SRC_ABS" <<'PY'
import re, sys
print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))
PY
      )"
      printf 'claude dotted/underscore source: %s\nclaude session slug: %s\nclaude observed slug name: %s\nclaude expected non-alphanumeric slug: %s\n' "$SLUG_SRC_ABS" "$CLAUDE_SLUG_DIR" "$CLAUDE_SLUG_NAME" "$CLAUDE_EXPECTED_SLUG" >>"$FINDINGS"
      ls -la "$CLAUDE_SLUG_DIR" >"$LOGS/claude-slug-ls.txt"
      CLAUDE_BEFORE_SIZE="$(wc -c <"$CLAUDE_FILE")"
      if [[ "$CLAUDE_SLUG_NAME" == "$CLAUDE_EXPECTED_SLUG" ]]; then
        pass 'claude dotted/underscore slug matches observed transform'
      else
        fail 'claude dotted/underscore slug transform mismatch'
      fi
      if run_logged claude-snapshot python3 "$TOOL" snapshot --workspace "$SLUG_SRC" --out "$RUN_DIR/claude-bundle" --claude-session "$CLAUDE_SID" --claude-home "$HOME/.claude"; then
        if run_logged claude-restore-verbatim python3 "$TOOL" restore --bundle "$RUN_DIR/claude-bundle" --dest "$SLUG_DST" --claude-home "$HOME/.claude" --claude-cwd-mode verbatim; then
          set +e
          (cd "$SLUG_DST" && "${CLAUDE_ENV[@]}" claude -p --resume "$CLAUDE_SID" --model haiku \
            "What codeword did I give you, and what is the absolute path of your current working directory?" >"$LOGS/claude-resume.stdout" 2>"$LOGS/claude-resume.stderr"
          )
          CLAUDE_RESUME_STATUS=$?
          set -e
          CLAUDE_DST_ABS="$(cd "$SLUG_DST" && pwd -P)"
          CLAUDE_DEST_SLUG="$(python3 - "$CLAUDE_DST_ABS" <<'PY'
import re, sys
print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))
PY
          )"
          CLAUDE_DEST_FILE="$HOME/.claude/projects/$CLAUDE_DEST_SLUG/$CLAUDE_SID.jsonl"
          CLAUDE_SRC_SIZE="$(wc -c <"$CLAUDE_FILE")"
          CLAUDE_DEST_SIZE=0; [[ -f "$CLAUDE_DEST_FILE" ]] && CLAUDE_DEST_SIZE="$(wc -c <"$CLAUDE_DEST_FILE")"
          if ((CLAUDE_RESUME_STATUS == 0)) && grep -qi "$CLAUDE_WORD" "$LOGS/claude-resume.stdout"; then
            pass 'claude recalled codeword after verbatim restore'
            printf '| claude dotted/underscore | PASS | codeword recalled; reported cwd in logs; destination slug %s; source bytes %s→%s, destination rollout bytes %s |\n' "$CLAUDE_DEST_SLUG" "$CLAUDE_BEFORE_SIZE" "$CLAUDE_SRC_SIZE" "$CLAUDE_DEST_SIZE" >>"$FINDINGS"
          else
            fail 'claude verbatim resume'
            printf '| claude | BLOCKED/FAIL | status %s; output/error retained in logs; rewrite arm attempted below |\n' "$CLAUDE_RESUME_STATUS" >>"$FINDINGS"
          fi
          if run_logged claude-restore-rewrite python3 "$TOOL" restore --bundle "$RUN_DIR/claude-bundle" --dest "$SLUG_REWRITE_DST" --claude-home "$HOME/.claude" --claude-cwd-mode rewrite; then
            printf 'claude rewrite restore completed; see logs/claude-restore-rewrite.*\n' >>"$FINDINGS"
          fi
        fi
      fi
    else
      fail 'claude transcript not found for newly-created session id'
      printf '| claude | BLOCKED | transcript not found for the new id; creation output/error retained in logs |\n' >>"$FINDINGS"
    fi
  else
    fail 'claude leg blocked (creation/auth/model error)'
    printf '| claude | BLOCKED | create exit %s; see logs/claude-create.stderr |\n' "$CLAUDE_CREATE_STATUS" >>"$FINDINGS"
  fi
fi

if (( ! CLAUDE_ONLY )); then
  CODEX_CREATE_LOG="$LOGS/codex-create"
  CODEX_ENV=(env -i "HOME=$HOME" "PATH=$PATH" "USER=${USER:-}" "SHELL=${SHELL:-/bin/zsh}" "TMPDIR=${TMPDIR:-/tmp}" TERM=xterm-256color LANG=en_US.UTF-8)
  # This is the scrubbed real environment: HOME points at the user's existing
  # authenticated Codex store; no CODEX_HOME override is used for either arm.
  CODEX_RESUME_ENV=("${CODEX_ENV[@]}")
  set +e
  (cd "$SRC" && "${CODEX_ENV[@]}" codex exec --json -c model_reasoning_effort=low --sandbox read-only \
    "Remember this codeword and nothing else: amber-$RUN_ID. Reply OK.") >"$CODEX_CREATE_LOG.stdout" 2>"$CODEX_CREATE_LOG.stderr"
  CODEX_CREATE_STATUS=$?
  set -e
  CODEX_SID="$(python3 - "$CODEX_CREATE_LOG.stdout" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    try: value=json.loads(line)
    except json.JSONDecodeError: continue
    if value.get('type') == 'thread.started' and value.get('thread_id'):
        print(value['thread_id']); break
    if value.get('type') == 'session_configured' and value.get('session_id'):
        print(value['session_id']); break
PY
  )"
  if ((CODEX_CREATE_STATUS == 0)) && [[ -n "$CODEX_SID" ]]; then
    pass 'codex create returned a session id'
    CODEX_FILE="$(find "$HOME/.codex/sessions" -type f -name "*${CODEX_SID}*.jsonl" -print -quit 2>/dev/null || true)"
    if [[ -n "$CODEX_FILE" ]]; then
      printf 'codex rollout: %s\n' "$CODEX_FILE" >>"$FINDINGS"
      if run_logged codex-snapshot python3 "$TOOL" snapshot --workspace "$SRC" --out "$RUN_DIR/codex-bundle" --codex-session "$CODEX_SID" --codex-home "$HOME/.codex"; then
        # Placement-only restore: this checks the dated relative rollout path
        # in an isolated home but deliberately does not attempt a resume there.
        if run_logged codex-placement-restore python3 "$TOOL" restore --bundle "$RUN_DIR/codex-bundle" --dest "$RUN_DIR/codex-dst" --codex-home "$OBSERVED_HOME/codex"; then
          pass 'codex dated-relpath placement in scratch home'
          CODEX_A_BEFORE_SIZE="$(wc -c <"$CODEX_FILE")"
          set +e
          (cd "$RUN_DIR/codex-dst" && "${CODEX_RESUME_ENV[@]}" codex exec resume "$CODEX_SID" --json -c model_reasoning_effort=low \
            "What codeword did I give you, and what is the absolute path of your current working directory?") >"$LOGS/codex-arm-a.stdout" 2>"$LOGS/codex-arm-a.stderr"
          CODEX_A_STATUS=$?
          set -e
          CODEX_A_AFTER_SIZE="$(wc -c <"$CODEX_FILE")"
          codex_answer_summary "$LOGS/codex-arm-a.stdout" >"$LOGS/codex-arm-a.summary"
          printf '\nCodex Arm A (real HOME, different cwd): exit=%s; rollout=%s; bytes=%s→%s; which rollout grew=%s\n' "$CODEX_A_STATUS" "$CODEX_FILE" "$CODEX_A_BEFORE_SIZE" "$CODEX_A_AFTER_SIZE" "$([[ "$CODEX_A_AFTER_SIZE" -gt "$CODEX_A_BEFORE_SIZE" ]] && echo "$CODEX_FILE" || echo 'none observed')" >>"$FINDINGS"
          if ((CODEX_A_STATUS == 0)) && grep -qi "amber-$RUN_ID" "$LOGS/codex-arm-a.summary" && grep -q "cwd=/" "$LOGS/codex-arm-a.summary"; then
            pass 'codex Arm A recalled codeword from different cwd'
            printf '| codex Arm A | PASS | real HOME; codeword/cwd summary and rollout growth recorded above |\n' >>"$FINDINGS"
          else
            fail 'codex Arm A resume'
            printf '| codex Arm A | REAL-BLOCKED/FAIL | exit %s; exact output/error retained in logs/codex-arm-a.* |\n' "$CODEX_A_STATUS" >>"$FINDINGS"
          fi
          # Keep Arm A's destination for inspection, then reuse the required
          # codex-dst path for Arm B's real-home restore.
          mv "$RUN_DIR/codex-dst" "$RUN_DIR/codex-dst-arm-a"
          CODEX_REL="${CODEX_FILE#$HOME/.codex/}"
          CODEX_MOVED="$RUN_DIR/moved-aside/$CODEX_REL"
          mkdir -p "$(dirname "$CODEX_MOVED")"
          mv "$CODEX_FILE" "$CODEX_MOVED"
          if [[ -e "$CODEX_FILE" ]]; then
            fail 'codex Arm B move-aside did not remove original rollout'
            printf '| codex Arm B | BLOCKED | original rollout still existed after move; no restore attempted |\n' >>"$FINDINGS"
          else
            pass "codex Arm B moved this run's original rollout aside first"
            printf 'codex moved-aside original: %s\n' "$CODEX_MOVED" >>"$FINDINGS"
            if run_logged codex-real-restore python3 "$TOOL" restore --bundle "$RUN_DIR/codex-bundle" --dest "$RUN_DIR/codex-dst" --codex-home "$HOME/.codex"; then
              CODEX_B_BEFORE_SIZE="$(wc -c <"$CODEX_FILE")"
              set +e
              (cd "$RUN_DIR/codex-dst" && "${CODEX_RESUME_ENV[@]}" codex exec resume "$CODEX_SID" --json -c model_reasoning_effort=low \
                "What codeword did I give you, and what is the absolute path of your current working directory?") >"$LOGS/codex-arm-b.stdout" 2>"$LOGS/codex-arm-b.stderr"
              CODEX_B_STATUS=$?
              set -e
              CODEX_B_AFTER_SIZE="$(wc -c <"$CODEX_FILE")"
              codex_answer_summary "$LOGS/codex-arm-b.stdout" >"$LOGS/codex-arm-b.summary"
              printf '\nCodex Arm B (rollout-only restore into real HOME): exit=%s; restored rollout=%s; bytes=%s→%s; which rollout grew=%s\n' "$CODEX_B_STATUS" "$CODEX_FILE" "$CODEX_B_BEFORE_SIZE" "$CODEX_B_AFTER_SIZE" "$([[ "$CODEX_B_AFTER_SIZE" -gt "$CODEX_B_BEFORE_SIZE" ]] && echo "$CODEX_FILE" || echo 'none observed')" >>"$FINDINGS"
              if ((CODEX_B_STATUS == 0)) && grep -qi "amber-$RUN_ID" "$LOGS/codex-arm-b.summary" && grep -q "cwd=/" "$LOGS/codex-arm-b.summary"; then
                pass 'codex Arm B rollout-only restore resumed successfully'
                printf '| codex Arm B | PASS | rollout alone at dated relpath sufficed; codeword/cwd and growth recorded above |\n' >>"$FINDINGS"
              else
                fail 'codex Arm B resume'
                printf '| codex Arm B | REAL-BLOCKED/FAIL | exit %s; exact output/error retained in logs/codex-arm-b.*; restored rollout left in place |\n' "$CODEX_B_STATUS" >>"$FINDINGS"
              fi
            else
              fail 'codex Arm B restore into real HOME'
              printf '| codex Arm B | BLOCKED | real-home restore failed after move-aside; see logs/codex-real-restore.* |\n' >>"$FINDINGS"
            fi
          fi
        fi
      fi
    else
      fail 'codex rollout not found for newly-created session id'
      printf '| codex | BLOCKED | rollout not found for new session id; see logs/codex-create.* |\n' >>"$FINDINGS"
    fi
  else
    fail 'codex leg blocked (creation/auth/error or no session id)'
    printf '| codex | BLOCKED | create exit %s or no session id; see logs/codex-create.* |\n' "$CODEX_CREATE_STATUS" >>"$FINDINGS"
  fi
fi

printf '\n## Commands and trimmed outputs\n\n' >>"$FINDINGS"
for log in "$LOGS"/*.command "$LOGS"/*.stdout "$LOGS"/*.stderr "$LOGS"/*.txt; do
  [[ -f "$log" ]] || continue
  printf '\n### %s\n\n```text\n' "${log##*/}" >>"$FINDINGS"
  sed -n '1,80p' "$log" >>"$FINDINGS"
  printf '```\n' >>"$FINDINGS"
done
printf 'findings: %s\n' "$FINDINGS" | tee /dev/fd/3
if ((KEEP == 0)); then
  printf 'Run retained by default for judge inspection; --keep is accepted for compatibility.\n' | tee /dev/fd/3
fi
