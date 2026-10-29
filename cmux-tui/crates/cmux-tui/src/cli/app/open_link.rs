//! `cmux open --link`: one `browser.open_link` request, and the `command:`
//! hook of `terminal.linkOpener`.
//!
//! The app decides the target from the setting (TerminalLinkOpener) and opens
//! the URL itself for every target but `command`. A `command` target answers
//! `{"target": "command", "command": "<shell command>"}`: the command runs here,
//! in the caller's shell environment (its PATH, its cwd), with the URL in
//! `CMUX_LINK_URL` and on stdin and the caller names in `CMUX_LINK_CALLERS`.
//! The URL is never put in argv, where other local processes can read it. The
//! command opens the URL itself (exit 0, nothing on stdout) or prints a target
//! on its first line (`cmux`, `system`, `chrome@Work`), which this sends back
//! as the request's `target`. A command that fails fails the open, so the
//! bundled `cmux-open-url` falls back to the default browser.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

use super::open::OpenRequest;
use super::{GlobalArgs, failure, wait};
use cmux_json::JsonSet as _;

pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, request: OpenRequest) -> i32 {
    let timeout = Some(request.timeout());
    let mut params = request.params;
    let result = match send(global, stream, &params, timeout) {
        Ok(result) => result,
        Err(code) => return code,
    };
    if result.get("target").and_then(Value::as_str) != Some("command") {
        return super::super::wire::print_local_success(&result, global.output);
    }
    let Some(command) = result.get("command").and_then(Value::as_str) else {
        return failure("app.transport", "browser.open_link named no command", global.output, 3);
    };
    let url = params["url"].as_str().unwrap_or_default().to_owned();
    let callers = params["callers"]
        .as_array()
        .map(|names| names.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","))
        .unwrap_or_default();
    match run_hook(command, &url, &callers) {
        Ok(None) => super::super::wire::print_local_success(
            &json!({"target": "command", "handled": true}),
            global.output,
        ),
        Ok(Some(target)) => {
            params.set("target", json!(target));
            match send(global, stream, &params, timeout) {
                Ok(result) => super::super::wire::print_local_success(&result, global.output),
                Err(code) => code,
            }
        }
        Err(message) => failure("open.link_command", &message, global.output, 1),
    }
}

fn send(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    params: &Value,
    timeout: Option<std::time::Duration>,
) -> Result<Value, i32> {
    match wait::request(global, stream, "browser.open_link", params, timeout) {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(error)) => Err(super::super::wire::print_operation_error(&error, global.output)),
        Err(error) => Err(super::super::wire::print_local_error(&error, global.output, 3)),
    }
}

/// Runs the `command:` hook; `Some(target)` when it printed one, `None` when
/// it opened the URL itself. Never echoes the URL in an error.
pub(super) fn run_hook(command: &str, url: &str, callers: &str) -> Result<Option<String>, String> {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .env("CMUX_LINK_URL", url)
        .env("CMUX_LINK_CALLERS", callers)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("terminal.linkOpener command could not start: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        // A command that never reads stdin closes it early; that is fine.
        let _ = writeln!(stdin, "{url}");
    }
    let output = child
        .wait_with_output()
        .map_err(|error| format!("terminal.linkOpener command failed: {error}"))?;
    if !output.status.success() {
        return Err(format!("terminal.linkOpener command exited with {}", output.status));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let target = stdout.lines().map(str::trim).find(|line| !line.is_empty());
    match target {
        None => Ok(None),
        Some(target) if target.to_ascii_lowercase().starts_with("command:") => {
            Err("terminal.linkOpener command printed another command: target".to_owned())
        }
        Some(target) => Ok(Some(target.to_owned())),
    }
}

#[cfg(test)]
mod tests {
    use super::run_hook;

    #[test]
    fn hook_gets_the_url_and_callers_and_may_print_a_target() {
        let printed = run_hook(
            r#"read -r line; [ "$line" = "$CMUX_LINK_URL" ] || exit 9; case "$CMUX_LINK_CALLERS" in *aws*) echo "chrome@Work" ;; *) echo system ;; esac"#,
            "https://signin.aws.amazon.com/?state=x",
            "python3,aws,zsh",
        );
        assert_eq!(printed, Ok(Some("chrome@Work".to_owned())));
        assert_eq!(
            run_hook("echo system", "https://a.example/", "gh"),
            Ok(Some("system".to_owned()))
        );
    }

    #[test]
    fn hook_that_opens_the_url_itself_prints_nothing() {
        assert_eq!(run_hook("true", "https://a.example/", ""), Ok(None));
        assert_eq!(run_hook("printf '\\n  \\n'", "https://a.example/", ""), Ok(None));
    }

    #[test]
    fn failing_or_looping_hooks_fail_without_echoing_the_url() {
        let failed = run_hook("exit 3", "https://a.example/?token=SECRET", "").unwrap_err();
        assert!(!failed.contains("SECRET"), "{failed}");
        assert!(run_hook("echo command:other", "https://a.example/", "").is_err());
    }
}
