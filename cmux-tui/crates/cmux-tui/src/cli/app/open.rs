//! `cmux open <path|url>...` and `cmux open -`: paths, folders and URLs the
//! app opens (`file.open`, `workspace.create`, `browser.open_split`).

use std::io::{IsTerminal, Read};
use std::time::Duration;

use serde_json::{Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT, action_origin};

#[derive(Debug, PartialEq)]
pub(in crate::cli) struct OpenRequest {
    pub(super) method: &'static str,
    pub(super) params: Value,
}

impl OpenRequest {
    /// How long the app may take: `browser.open_split` runs `openBrowser`
    /// and waits for the tab, like a waiting `action.run`.
    pub(super) fn timeout(&self) -> Duration {
        if self.method == "browser.open_split" { WAITING_RUN_TIMEOUT } else { READ_TIMEOUT }
    }
}

/// `cmux open` opens paths and URLs through the app control socket.
pub(super) fn parse_open(args: &[String]) -> Result<AppCommand, UsageError> {
    let environment = std::env::vars().collect::<std::collections::HashMap<_, _>>();
    parse_open_with(
        args,
        std::io::stdin().is_terminal() && std::io::stdout().is_terminal(),
        &environment,
        &mut std::io::stdin().lock(),
    )
}

/// `cmux open <path|url>...`, or `cmux open -`: one URL per stdin line, so a
/// URL that carries a token never sits in argv, where other local processes
/// can read it. `stdin` is read only for `-`.
pub(super) fn parse_open_with(
    args: &[String],
    interactive: bool,
    environment: &std::collections::HashMap<String, String>,
    stdin: &mut dyn Read,
) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut explicit_focus = None;
    let mut workspace = None;
    let mut from_stdin = false;
    let mut targets = Vec::new();
    let mut index = 0;
    let mut literal = false;
    while index < args.len() {
        let arg = &args[index];
        if literal {
            targets.push(arg.clone());
            index += 1;
            continue;
        }
        if arg == "--" {
            literal = true;
            index += 1;
            continue;
        }
        let (name, inline) =
            arg.split_once('=').map_or((arg.as_str(), None), |(name, value)| (name, Some(value)));
        match name {
            "--focus" => {
                let value = inline.map(str::to_owned).or_else(|| {
                    args.get(index + 1)
                        .filter(|value| matches!(value.as_str(), "true" | "false"))
                        .cloned()
                });
                if inline.is_none() && value.is_some() {
                    index += 1;
                }
                explicit_focus = Some(
                    value
                        .as_deref()
                        .unwrap_or("true")
                        .parse::<bool>()
                        .map_err(|_| UsageError::new("--focus must be true|false"))?,
                );
            }
            "--no-focus" => {
                if inline.is_some() {
                    return Err(UsageError::new("--no-focus does not take a value"));
                }
                explicit_focus = Some(false);
            }
            "--workspace" => {
                let value = match inline {
                    Some(value) => value.to_owned(),
                    None => {
                        index += 1;
                        args.get(index).cloned().ok_or_else(|| {
                            UsageError::new("--workspace needs a workspace id (ws_…)")
                        })?
                    }
                };
                if value.is_empty() {
                    return Err(UsageError::new("--workspace needs a workspace id (ws_…)"));
                }
                workspace = Some(value);
            }
            "-" => from_stdin = true,
            _ if name.starts_with('-') => {
                return Err(UsageError::new(messages.unexpected_argument.replace("{value}", arg)));
            }
            _ => targets.push(arg.clone()),
        }
        index += 1;
    }
    if from_stdin {
        if !targets.is_empty() {
            return Err(UsageError::new(
                "open - reads every URL from stdin; give no other path or URL",
            ));
        }
        targets = stdin_urls(stdin)?;
    }
    if targets.is_empty() {
        return Err(UsageError::new("open requires at least one path or URL"));
    }
    // A named workspace is a placement, often a background one: the view
    // stays unless --focus asks for it.
    let focus = explicit_focus.unwrap_or_else(|| {
        workspace.is_none() && default_focus_for_user_open(environment, interactive)
    });
    // The caller's own terminal names the pane the tab goes to.
    let terminal = environment.get("CMUX_TUI_TERMINAL_ID").filter(|id| !id.is_empty()).cloned();
    let url_params = |url: &str| {
        let mut params = json!({"url": url, "focus": focus, "origin": action_origin()});
        if let Some(workspace) = &workspace {
            params["workspace_id"] = json!(workspace);
        }
        if let Some(terminal) = &terminal {
            params["terminal_id"] = json!(terminal);
        }
        params
    };
    if from_stdin {
        let requests = targets
            .iter()
            .map(|url| OpenRequest { method: "browser.open_split", params: url_params(url) })
            .collect();
        return Ok(AppCommand::Open { requests, stop_on_failure: true });
    }
    let mut requests = Vec::new();
    let mut pending_files = Vec::new();
    let flush_files = |requests: &mut Vec<OpenRequest>, pending: &mut Vec<String>| {
        if pending.is_empty() {
            return;
        }
        let paths = std::mem::take(pending);
        requests.push(OpenRequest {
            method: "file.open",
            params: json!({"paths": paths, "focus": focus}),
        });
    };
    for target in targets {
        if target.starts_with("http://")
            || target.starts_with("https://")
            || target.starts_with("mailto:")
        {
            flush_files(&mut requests, &mut pending_files);
            requests
                .push(OpenRequest { method: "browser.open_split", params: url_params(&target) });
        } else if workspace.is_some() {
            return Err(UsageError::new("--workspace applies only to http and https URLs"));
        } else if std::fs::metadata(&target).map(|metadata| metadata.is_dir()).unwrap_or(false) {
            flush_files(&mut requests, &mut pending_files);
            requests.push(OpenRequest {
                method: "workspace.create",
                params: json!({"cwd": target, "focus": focus, "activate": focus}),
            });
        } else {
            pending_files.push(target);
        }
    }
    flush_files(&mut requests, &mut pending_files);
    Ok(AppCommand::Open { requests, stop_on_failure: false })
}

/// The URLs of `cmux open -`: one per line, blank lines skipped, every line
/// checked before any opens. An error names the line, never its text (it
/// may carry a token).
fn stdin_urls(stdin: &mut dyn Read) -> Result<Vec<String>, UsageError> {
    let mut text = String::new();
    stdin
        .read_to_string(&mut text)
        .map_err(|error| UsageError::new(format!("open -: cannot read stdin: {error}")))?;
    let mut urls = Vec::new();
    for (index, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if !is_web_url(line) {
            return Err(UsageError::new(format!(
                "open -: line {} of stdin is not an absolute http or https URL; nothing was opened",
                index + 1
            )));
        }
        urls.push(line.to_owned());
    }
    if urls.is_empty() {
        return Err(UsageError::new("open -: stdin has no URL"));
    }
    Ok(urls)
}

/// An absolute `http`/`https` URL with a host and no whitespace or control
/// characters, the URLs the app's `browser.open_split` takes.
pub(super) fn is_web_url(text: &str) -> bool {
    if text.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    let lower = text.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://"))
    else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    let host = host.strip_prefix('[').map_or_else(
        || host.split(':').next().unwrap_or_default(),
        |bracketed| bracketed.split(']').next().unwrap_or_default(),
    );
    !host.is_empty()
}

fn default_focus_for_user_open(
    environment: &std::collections::HashMap<String, String>,
    interactive: bool,
) -> bool {
    match environment.get("CMUX_FOCUS_NEW").map(String::as_str) {
        Some("1") => return true,
        Some("0") => return false,
        _ => {}
    }
    if !interactive {
        return false;
    }
    [
        "CODEX_CI",
        "CODEX_THREAD_ID",
        "CODEX_SESSION_ID",
        "CODEX_SANDBOX",
        "CODEX_MANAGED_BY_BUN",
        "CLAUDECODE",
        "CLAUDE_CODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "OPENCODE",
        "OPENCODE_PORT",
        "OPENCODE_SESSION_ID",
        "AI_AGENT",
    ]
    .iter()
    .all(|key| environment.get(*key).is_none_or(|value| value.trim().is_empty()))
}
