//! `pane-browser-kind-v1`: the optional `kind` and `url` fields of raw
//! `split` and `new-pane-right`. `kind: "browser"` with a `url` makes the new
//! pane hold a browser; `kind: "pty"` or no kind keeps the terminal pane.

use anyhow::Context;

/// The browser URL for a new pane, or `None` for a terminal pane. Unknown
/// kinds, a browser without a URL and a URL on a terminal are refused before
/// anything is created.
pub(super) fn browser_pane_url(
    command: &str,
    kind: Option<String>,
    url: Option<String>,
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
            Ok(Some(url))
        }
        Some(other) => {
            anyhow::bail!("bad request: {command} kind {other:?} (want \"pty\" or \"browser\")")
        }
    }
}
