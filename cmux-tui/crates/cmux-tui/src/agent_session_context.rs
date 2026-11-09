//! `cmux-tui agent session-context`: the `SessionStart` hook the `claude`
//! shim adds to every Claude Code it starts in a cmux terminal, and the
//! pane's Claude Code plugin to every other one (claude_plugin.rs). It prints
//! the session context (cmux-tui-hook session_context.rs) as the hook's
//! `additionalContext`, so the model knows it runs in cmux, its ids and
//! where the guide is. It runs this binary, the build that spawned the pane,
//! never an older installed helper.

use std::ffi::OsString;
use std::io::Read as _;
use std::path::{Path, PathBuf};

const VERB: &str = "session-context";
/// Claude Code's hook payload is small; anything past this is not read.
const MAX_PAYLOAD_BYTES: u64 = 1 << 20;

/// Whether argv (without the program name) is `agent session-context`.
pub(crate) fn invocation(args: &[OsString]) -> bool {
    matches!(args, [scope, verb] if scope == "agent" && verb == VERB)
}

/// The hook command that runs [`run`] through `executable`; `None` when the
/// path is not UTF-8 (the launch then gets no context hook, and keeps the
/// others).
pub(crate) fn hook_command(executable: &Path) -> Option<String> {
    let executable = executable.to_str()?;
    Some(format!("{} agent {VERB}", crate::agent_hook_install::shell_quote(executable)))
}

/// Prints the hook's one JSON object; always exits 0, so a failure never
/// stops Claude Code from starting.
pub(crate) fn run() -> i32 {
    // Drain the payload so Claude Code's write never fails on a closed pipe.
    let _ = std::io::stdin().lock().take(MAX_PAYLOAD_BYTES).read_to_end(&mut Vec::new());
    let env = |key: &str| std::env::var(key).ok().filter(|value| !value.trim().is_empty());
    // The plugin's copy of this hook (claude_plugin.rs) runs without the
    // wrapper, which is what otherwise honors the switch.
    if env("CMUX_TUI_CLAUDE_HOOKS_DISABLED").as_deref() == Some("1") {
        println!("{{}}");
        return 0;
    }
    let cli = std::env::current_exe().ok().map(|path| path.canonicalize().unwrap_or(path));
    match env("CMUX_TUI_SOCKET").or_else(|| env("CMUX_MUX_SOCKET")) {
        Some(socket) => crate::hook_helper::session_context::print(
            Some(&PathBuf::from(socket)),
            env("CMUX_TUI_TERMINAL_ID").as_deref(),
            cli.as_deref(),
        ),
        None => crate::hook_helper::session_context::print(None, None, cli.as_deref()),
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_context_the_verb_and_its_hook_command_agree() {
        let args = |words: &[&str]| words.iter().map(OsString::from).collect::<Vec<_>>();
        assert!(invocation(&args(&["agent", "session-context"])));
        assert!(!invocation(&args(&["agent", "session-context", "x"])));
        assert!(!invocation(&args(&["agent", "list"])));
        let command = hook_command(Path::new("/opt/cmux tui/cmux-tui")).unwrap();
        assert_eq!(command, "'/opt/cmux tui/cmux-tui' agent session-context");
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt as _;
            let invalid = Path::new(std::ffi::OsStr::from_bytes(b"/opt/\xff/cmux-tui"));
            assert_eq!(hook_command(invalid), None);
        }
    }
}
