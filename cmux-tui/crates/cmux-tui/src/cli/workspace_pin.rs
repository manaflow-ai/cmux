//! `cmux workspace <ws> pin|unpin` (cmux#25586): the app's Pin/Unpin Workspace action (CLI name
//! `workspace pin-unpin`, MCP `app_workspace_pin_unpin`) with its `pinned` argument set, so the
//! pin goes through the one pin path the sidebar row, the palette and drags use (PinCommands):
//! the sidebar document, and the workspace's own daemon flag. `workspace list` reports the result
//! in each row's `extra.pinned`. The workspace is the action's `--target`, a `ws_…` id.

const ACTION: &str = "workspace pin-unpin";

/// The app action and its arguments for `workspace <ws> pin|unpin [flags]`, or None for other
/// words.
pub(super) fn action(command_args: &[String]) -> Option<(String, Vec<String>)> {
    let [scope, workspace, verb, rest @ ..] = command_args else { return None };
    // The app's action target is an id; a name or `current` stays a usage error.
    if scope != "workspace" || !workspace.starts_with("ws_") {
        return None;
    }
    let pinned = match verb.as_str() {
        "pin" => "true",
        "unpin" => "false",
        _ => return None,
    };
    let mut args =
        vec!["--target".to_owned(), workspace.clone(), "--pinned".to_owned(), pinned.to_owned()];
    args.extend(rest.iter().cloned());
    Some((ACTION.to_owned(), args))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    #[test]
    fn pin_and_unpin_name_the_pin_action_with_its_state() {
        let workspace = "ws_0123456789abcdef0123456789abcdef";
        let (name, args) = action(&words(&["workspace", workspace, "pin"])).unwrap();
        assert_eq!(name, "workspace pin-unpin");
        assert_eq!(args, words(&["--target", workspace, "--pinned", "true"]));
        let (_, args) = action(&words(&["workspace", workspace, "unpin", "--no-wait"])).unwrap();
        assert_eq!(args, words(&["--target", workspace, "--pinned", "false", "--no-wait"]));
        for other in [
            &["workspace", workspace, "rename"][..],
            &["workspace", "pin-unpin", "--target", workspace][..],
            &["workspace", "--target", "pin"][..],
            &["workspace", "current", "pin"][..],
            &["screen", workspace, "pin"][..],
        ] {
            assert_eq!(action(&words(other)), None, "{other:?}");
        }
    }
}
