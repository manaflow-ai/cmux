// Shared local and peer topology grammar for the in-VM CLI.
export const GUEST_CMUX_TOPOLOGY_SHELL = `# Verb-first topology commands share the current local/peer target. The daemon
# validates selectors and destination flags before its authoritative mutation.
guest_topology_command() {
  cmux_tp_noun="\$1"; shift
  cmux_tp_verb="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_tp_verb" in
    help|--help|-h) cmux_message topologyHelp; return ;;
    rename)
      [ "\$#" -ge 2 ] || die_message 2 topologyUsage
      cmux_tp_id="\$1"; cmux_tp_name="\$2"; shift 2
      # The empty name is an intentional value, never a missing argument.
      for cmux_tp_arg in "\$@"; do
        [ "\$cmux_tp_arg" = --json ] || die_message 2 topologyUsage
      done
      if [ "\$cmux_tp_noun" = terminal ]; then
        guest_terminal_rename "\$cmux_tp_id" "\$cmux_tp_name" "\$@"
      else
        exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$@" "\$cmux_tp_noun" "\$cmux_tp_id" rename --name "\$cmux_tp_name"
      fi
      ;;
    new|rm|delete)
      [ "\$cmux_tp_noun" = workspace ] || die_message 2 topologyUsage
      workspace_verb "\$cmux_tp_verb" "\$@"
      ;;
    list|ls)
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$cmux_tp_noun" list "\$@"
      ;;
    show|focus|close|move|split|swap|zoom|resize)
      [ "\$#" -ge 1 ] && [ -n "\$1" ] || die_message 2 topologyUsage
      cmux_tp_id="\$1"; shift
      case "\$cmux_tp_noun:\$cmux_tp_verb" in
        pane:split)
          case "\${1:-}" in
            left|right|up|down) cmux_tp_direction="\$1"; shift ;;
            *) die_message 2 topologyUsage ;;
          esac
          exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" pane "\$cmux_tp_id" split "--\$cmux_tp_direction" "\$@"
          ;;
        pane:resize)
          exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" pane "\$cmux_tp_id" split ratio set "\$@"
          ;;
        *) exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$cmux_tp_noun" "\$cmux_tp_id" "\$cmux_tp_verb" "\$@" ;;
      esac
      ;;
    *)
      # Preserve the daemon's selector-first grammar and creation verbs.
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$cmux_tp_noun" "\$cmux_tp_verb" "\$@"
      ;;
  esac
}

# A terminal label is implemented by renaming its exact tab placements, like
# the Mac provider. Use a fresh graph and revision fences; never choose an
# arbitrary view, retry a partial rename, or launch a process to change a name.
guest_terminal_rename() {
  cmux_tr_id="\$1"; cmux_tr_name="\$2"; shift 2
  cmux_tr_json=0
  [ "\${1:-}" != --json ] || cmux_tr_json=1
  if [ "\$cmux_tr_id" = current ] && [ "\$TARGET_LABEL" = local ]; then
    cmux_tr_id="\$(caller_terminal)"
  fi
  cmux_tr_snapshot="\$(tui --json session current snapshot)" || return \$?
  cmux_tr_plan="\$(printf '%s\\n' "\$cmux_tr_snapshot" | jq -ce --arg id "\$cmux_tr_id" '
    (.value // .) as \$s
    | [\$s.terminals[] | select(.id == \$id)] as \$terminals
    | [\$s.tabs[] | select(.content_kind == "terminal" and .content_id == \$id) | .id] | unique
    | select(length > 0 and (\$terminals | length) == 1) as \$tabs
    | select(all(\$tabs[]; type == "string" and test("^tab_[A-Za-z0-9]+\$")))
    | select((\$s.session.generation | type) == "string" and (\$s.session.generation | length) > 0)
    | select((\$s.session.revision | type) == "string" and (\$s.session.revision | test("^[0-9]+\$")))
    | {tabs: \$tabs, generation: \$s.session.generation, revision: \$s.session.revision}
  ')" || die_message 1 topologyRenameTarget "\$cmux_tr_id"
  cmux_tr_revision="\$(printf '%s\\n' "\$cmux_tr_plan" | jq -r .revision)"
  cmux_tr_generation="\$(printf '%s\\n' "\$cmux_tr_plan" | jq -r .generation)"
  cmux_tr_tabs="\$(printf '%s\\n' "\$cmux_tr_plan" | jq -r '.tabs[]')"
  cmux_tr_count=0
  for cmux_tr_tab in \$cmux_tr_tabs; do
    cmux_tr_receipt="\$(tui --json --expected-revision "\$cmux_tr_revision" tab "\$cmux_tr_tab" rename --name "\$cmux_tr_name")" ||
      die_message 1 topologyRenamePartial "\$cmux_tr_id" "\$cmux_tr_count"
    # Compare decimal revisions as strings so UInt64 cursors retain precision.
    cmux_tr_revision="\$(printf '%s\\n' "\$cmux_tr_receipt" | jq -er --arg gen "\$cmux_tr_generation" --arg prev "\$cmux_tr_revision" --arg tab "\$cmux_tr_tab" '
      select(.generation == \$gen and .value.id == \$tab)
      | .revision | select(type == "string" and test("^[0-9]+\$"))
      | select(length > (\$prev | length) or (length == (\$prev | length) and . > \$prev))
    ')" || die_message 1 topologyRenameReceipt "\$cmux_tr_id"
    cmux_tr_count=\$((cmux_tr_count + 1))
  done
  if [ "\$cmux_tr_json" -eq 1 ]; then
    printf '%s\\n' "\$cmux_tr_plan" | jq --arg id "\$cmux_tr_id" --arg name "\$cmux_tr_name" --arg revision "\$cmux_tr_revision" \\
      '{terminal_id: \$id, tab_ids: .tabs, name: \$name, generation: .generation, revision: \$revision}'
  else
    cmux_message topologyRenamed "\$cmux_tr_id" "\$cmux_tr_count"
  fi
}
`;
