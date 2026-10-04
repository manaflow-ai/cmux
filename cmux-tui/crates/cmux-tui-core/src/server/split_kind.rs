//! `pane-browser-kind-v1`: the optional `kind` and `url` fields of raw
//! `split` and `new-pane-right`. `kind: "browser"` with a `url` makes the new
//! pane hold a browser; `kind: "pty"` or no kind keeps the terminal pane.

use anyhow::Context;

/// The terminal-only fields a request carried, for refusal messages.
pub(super) struct TerminalFields {
    pub cwd: bool,
    pub env: bool,
    pub keep: bool,
    pub terminal_id: bool,
    pub shell_args: bool,
}

impl TerminalFields {
    fn first_present(&self) -> Option<&'static str> {
        [
            (self.cwd, "cwd"),
            (self.env, "env"),
            (self.keep, "keep"),
            (self.terminal_id, "terminal_id"),
            (self.shell_args, "shell_args"),
        ]
        .into_iter()
        .find_map(|(present, name)| present.then_some(name))
    }
}

/// The browser URL for a new pane, or `None` for a terminal pane. Unknown
/// kinds, a browser without a URL, a URL on a terminal and terminal fields on
/// a browser are refused before anything is created.
pub(super) fn browser_pane_url(
    command: &str,
    kind: Option<String>,
    url: Option<String>,
    terminal: &TerminalFields,
) -> anyhow::Result<Option<String>> {
    match kind.as_deref() {
        None | Some("pty") => {
            anyhow::ensure!(url.is_none(), "bad request: {command} url requires kind \"browser\"");
            Ok(None)
        }
        Some("browser") => {
            let url = url.filter(|url| !url.is_empty()).with_context(|| {
                format!("bad request: {command} kind \"browser\" requires a url")
            })?;
            if let Some(field) = terminal.first_present() {
                anyhow::bail!("bad request: {command} {field} applies only to kind \"pty\"");
            }
            Ok(Some(url))
        }
        Some(other) => {
            anyhow::bail!("bad request: {command} kind {other:?} (want \"pty\" or \"browser\")")
        }
    }
}
