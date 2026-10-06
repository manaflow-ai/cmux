//! The tokenizer's flag grammar.

/// Metadata for flags which consume no following token.
///
/// Keeping this as data makes the tokenizer's grammar auditable and leaves a
/// single place to extend when a command adds a boolean option. This is the
/// same distinction Clap models with `ArgAction::SetTrue`, while retaining
/// cmux's custom forwarding and error text.
pub(super) const BOOLEAN_FLAGS: &[&str] = &[
    "collapse",
    "patch",
    "candidates",
    "expand",
    "clear",
    "reply",
    "empty",
    "ephemeral",
    "left",
    "right",
    "up",
    "down",
    "force",
    "end-terminals",
    // `server ensure`: private app contract, the install key comes on stdin.
    "install-key-stdin",
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
    let name = words.pop().expect("length checked above");
    if flags.values.insert("name".into(), Some(name)).is_some() {
        return Err(super::UsageError::new(
            "give the new name once: rename <name> or rename --name <name>",
        ));
    }
    Ok(())
}
