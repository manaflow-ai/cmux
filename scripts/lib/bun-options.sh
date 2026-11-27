# shellcheck shell=sh
# Sourced (sh or bash) by scripts that run bun's package manager: bun install, bun pm, bun x, bunx.
# It rewrites an inherited BUN_OPTIONS so each path-taking preload flag is joined to its path:
# `--preload PATH` becomes `--preload=PATH` (and `-r PATH` becomes `--preload=PATH`). Bun reads the
# spaced form in BUN_OPTIONS as a script name, so every subcommand but `bun run` fails with
# 'Script not found "install"' (bun 1.4.5; a login-file block that adds a Claude Code preload,
# 2026-11-06 and 2026-11-22, when it broke `cmux app try .`). The joined
# form means the same to bun, so the person's preload still loads. scripts/web_lint_prepush.py's
# bun_options_joined does the same in Python; keep the two flag lists alike.
bun_options_join() {
  [ -n "${BUN_OPTIONS:-}" ] || return 0
  case $- in *f*) _boj_noglob=1 ;; *) _boj_noglob= ; set -f ;; esac
  _boj_out= _boj_flag= _boj_word=
  for _boj_w in $BUN_OPTIONS; do
    if [ -n "$_boj_flag" ]; then
      case $_boj_w in
        -*) _boj_out="$_boj_out $_boj_word" _boj_flag= ;;
        *) _boj_out="$_boj_out $_boj_flag=$_boj_w" _boj_flag=; continue ;;
      esac
    fi
    case $_boj_w in
      --preload | -r) _boj_flag=--preload _boj_word=$_boj_w ;;
      --require) _boj_flag=--require _boj_word=$_boj_w ;;
      --import) _boj_flag=--import _boj_word=$_boj_w ;;
      *) _boj_out="$_boj_out $_boj_w" ;;
    esac
  done
  [ -z "$_boj_flag" ] || _boj_out="$_boj_out $_boj_word"
  [ -n "$_boj_noglob" ] || set +f
  BUN_OPTIONS=${_boj_out# }
  export BUN_OPTIONS
  unset _boj_noglob _boj_out _boj_flag _boj_word _boj_w
}
bun_options_join
