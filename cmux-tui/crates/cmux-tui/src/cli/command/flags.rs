//! The tokenizer's flag grammar.

/// Metadata for flags which consume no following token.
///
/// Keeping this as data makes the tokenizer's grammar auditable and leaves a
/// single place to extend when a command adds a boolean option. This is the
/// same distinction Clap models with `ArgAction::SetTrue`, while retaining
/// cmux's custom forwarding and error text.
/// Flags that are a switch for one command and take a value for another:
/// `pane <p> split --right --fit` (a column that shares the window) and
/// `tab <t> emulate --fit 16:9`. Such a flag takes the next word as its value
/// only when one follows that is not itself a flag, so `split --right --fit`
/// and `split --right --fit --json` read it as a switch.
pub(super) const SWITCH_OR_VALUE_FLAGS: &[&str] = &["fit"];

pub(super) const BOOLEAN_FLAGS: &[&str] = &[
    "ack",
    // `terminal <t> screen read --details`: the screen record's fields, not its text alone.
    "details",
    // `cloud kill-machine --confirm`: without this it would swallow a following `--json`.
    "confirm",
    // `settings reset PATH --yes` (`--confirm`'s new spelling): it must not swallow a `--json`.
    "yes",
    // `setup trust --dry-run`: plan only; without this it would swallow a following `--json`.
    "dry-run",
    // `workspace create --no-focus`: accepted and ignored (creation does not
    // move focus without `--focus`); agents pass it out of habit.
    "no-focus",
    // `agent list`: only the agents waiting on the person.
    "needs-me",
    // `terminal list --agents`: without this it would swallow a following `--json`.
    "agents",
    // `pane <p> move --new-screen|--new-tab`: without this it would swallow a
    // following `--help` or `--json`.
    "new-screen",
    "new-tab",
    // `agent list --json`: the agents and their counts by state.
    "counts",
    // `agent message release`: the person's decision on a held message.
    "approve",
    "decline",
    "collapse",
    // `workspace group create --reuse`: the room's group of that name when it has one.
    "reuse",
    "patch",
    "candidates",
    "catalog",
    "expand",
    "clear",
    "reply",
    "empty",
    "ephemeral",
    // `workspace create --top`: first in the sidebar, whatever workspaces.newPlacement says.
    "top",
    "left",
    "right",
    "up",
    "down",
    // `pane split --focus`: the new pane takes the focus.
    "focus",
    "force",
    "end-terminals",
    // `server ensure`: private app contract, the install key comes on stdin.
    "install-key-stdin",
    // `server ensure`: private app contract, restore progress lines on stdout.
    "restore-progress",
    // `server ensure`: private app contract, the owner's loopback WebSocket.
    "ws-loopback",
    // `server ensure`: private app contract, replace an unresponsive owner.
    "replace-unresponsive",
    "confirm-close",
    "complete",
    "clear-name",
    "clear-kind",
    "clear-foreground",
    "clear-background",
    "clear-cursor",
    "clear-selection-background",
    "clear-selection-foreground",
    "clear-cursor-style",
    "clear-cursor-blink",
    "clear-palette",
    "read-only",
    "relaunch",
    "styled",
    "builtin",
    "mutation",
    "stream",
    "ignore-case",
    "all",
    "indeterminate",
    "clear-title",
    "clear-color",
    "clear-icon",
    "clear-theme",
    "clear-browser-profile",
    "clear-default-session",
    "clear-zoom",
    "clear-top-index",
    "clear-description",
    "clear-task-status",
    "report-closed-ids",
    "include-untracked",
    "amend",
    "no-verify",
    "set-upstream",
    "no-set-upstream",
    "discard",
    // `<scope> <selector> close`: one bulk close (layout.bulk).
    "others",
    "to-right",
    "to-left",
    "include-pinned",
    // `workspace rename`: hand the name back to the automatic namer.
    "release-to-auto",
    // `run --sandboxed <task>` (cli/sandbox_run.rs): without it a following `--json` would be eaten.
    "sandboxed",
    // `terminal screen read|copy --unwrap`: soft wraps joined into logical lines.
    "unwrap",
    // `terminal screen wait --new`: only output printed from now on matches.
    "new",
    // `terminal <t> close --if-unplaced`: end it only when nothing shows it.
    "if-unplaced",
];

/// `--name` ends the command without a value: it needs one, or it is no
/// option of this action (the tokenizer cannot tell which).
pub(super) fn missing_value(name: &str) -> super::UsageError {
    super::UsageError::new(format!(
        "--{name} needs a value, or is not an option of this action; see --help"
    ))
}

/// The words after a scope name no action; the scope's help lists them.
pub(super) fn usage<T>(what: &str) -> Result<T, super::UsageError> {
    let scope = what.split(' ').next().unwrap_or(what);
    Err(super::UsageError::new(format!(
        "unknown or incomplete {what}; run `cmux {scope} --help` for its actions"
    )))
}

/// `<selector> rename NAME` is `<selector> rename --name NAME` in every scope.
/// `rename` is a reserved selector word, so the word after it is a name.
pub(super) fn positional_rename(
    words: &mut Vec<String>,
    flags: &mut super::Flags,
) -> Result<(), super::UsageError> {
    let count = words.len();
    if count < 3 || words[count - 2] != "rename" {
        return Ok(());
    }
    let Some(name) = words.pop() else { return Ok(()) };
    if flags.values.insert("name".into(), Some(name)).is_some() {
        return Err(super::UsageError::new(
            "give the new name once: rename <name> or rename --name <name>",
        ));
    }
    Ok(())
}

/// A flag whose value must be one of `allowed`.
pub(super) fn validate_one_of(
    flag: &str,
    value: &str,
    allowed: &[&str],
) -> Result<(), super::UsageError> {
    if allowed.contains(&value) {
        Ok(())
    } else {
        Err(super::UsageError::new(format!("{flag} must be one of {}", allowed.join(", "))))
    }
}
