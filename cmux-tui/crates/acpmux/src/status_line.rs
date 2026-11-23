//! The person's own status line under a chat's prompt (`agentPane.statusLine.command`, Settings >
//! Agent Chat > Composer), as Claude Code's `statusLine` command: a shell command acpmux runs with
//! the chat's session JSON on stdin, whose first line of stdout the composer shows under the prompt.
//! The page never names the command: acpmux reads it from the settings file at each ask
//! (`user_settings`), so only what the person wrote there runs. Bounded: [`TIMEOUT`] to answer,
//! [`MAX_READ`] bytes read, the first line only, cut to [`MAX_CHARS`], escapes and control
//! characters dropped. Empty (the default) runs nothing and shows nothing.

use crate::user_settings::{self, Settings};
use serde_json::Value;
use std::path::Path;
use std::time::Duration;

/// The setting that names the command (schemas/settings/source/agent-pane-composer.json).
pub const KEY: &str = "agentPane.statusLine.command";
/// The longest the command has to print its first line.
pub const TIMEOUT: Duration = Duration::from_secs(2);
/// The most of its stdout read.
pub const MAX_READ: usize = 16 * 1024;
/// The longest line shown, in characters (an ellipsis ends a longer one).
pub const MAX_CHARS: usize = 200;

/// The command the settings file names, or None when it names none (unset, empty, not text, no
/// file or one that does not parse).
pub fn command(settings: &Settings) -> Option<String> {
    let Settings::Parsed(doc) = settings else { return None };
    let value = user_settings::value(doc, KEY)?;
    let text = value.as_str()?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// The line to show from the command's stdout: its first line, with terminal escapes (CSI, OSC)
/// and other control characters dropped, trimmed, cut to [`MAX_CHARS`]. Empty when it printed
/// nothing to show.
pub fn first_line(out: &[u8]) -> String {
    let text = String::from_utf8_lossy(out);
    let line = text.split(['\n', '\r']).next().unwrap_or("");
    let mut shown = String::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            match chars.peek() {
                // CSI: parameters up to a final byte in @..~.
                Some('[') => {
                    chars.next();
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC: up to BEL or ST (ESC \).
                Some(']') => {
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            }
            continue;
        }
        if c == '\t' {
            shown.push(' ');
        } else if !c.is_control() {
            shown.push(c);
        }
    }
    let shown = shown.trim();
    if shown.chars().count() <= MAX_CHARS {
        return shown.to_owned();
    }
    let mut cut: String = shown.chars().take(MAX_CHARS - 1).collect();
    cut.truncate(cut.trim_end().len());
    cut.push('…');
    cut
}

/// Runs `command` with `sh -c` in `cwd` (when it is a folder), `input` as JSON on its stdin, and
/// answers [`first_line`] of what it printed by its first newline, its end or [`TIMEOUT`],
/// whichever comes first. Its process group is killed then, so nothing it started outlives the
/// ask. Err says why nothing came (it could not start, it printed nothing in time).
#[cfg(unix)]
pub async fn run(command: &str, cwd: &Path, input: &Value) -> Result<String, String> {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let mut cmd = tokio::process::Command::new("/bin/sh");
    cmd.arg("-c")
        .arg(command)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .kill_on_drop(true);
    if cwd.is_dir() {
        cmd.current_dir(cwd);
    }
    let mut child =
        cmd.spawn().map_err(|e| format!("could not start the status line command: {e}"))?;
    let group = child.id();
    let mut stdin = child.stdin.take();
    let mut stdout = child.stdout.take().ok_or("the status line command has no stdout")?;
    let body = serde_json::to_vec(input).unwrap_or_default();
    let read = async move {
        // A command that never reads its stdin must not hold the read up: the write runs beside it.
        let write = async move {
            if let Some(mut stdin) = stdin.take() {
                let _ = stdin.write_all(&body).await;
                let _ = stdin.shutdown().await;
            }
        };
        let mut out = Vec::new();
        let read = async {
            let mut buf = [0u8; 4096];
            while out.len() < MAX_READ {
                let n = stdout.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                out.extend_from_slice(&buf[..n.min(MAX_READ - out.len())]);
                // The first line is all that shows: stop at its end, unless it is still blank.
                if let Some(at) = out.iter().position(|b| *b == b'\n')
                    && !String::from_utf8_lossy(&out[..at]).trim().is_empty()
                {
                    break;
                }
            }
        };
        tokio::join!(write, read);
        out
    };
    let out = tokio::time::timeout(TIMEOUT, read).await;
    if let Some(group) = group {
        // SAFETY: killpg signals only the group this function started (process_group(0)).
        unsafe { libc::killpg(group as i32, libc::SIGKILL) };
    }
    let _ = child.wait().await;
    let out = out.map_err(|_| {
        format!("the status line command printed no line in {} s", TIMEOUT.as_secs())
    })?;
    Ok(first_line(&out))
}

#[cfg(not(unix))]
pub async fn run(_command: &str, _cwd: &Path, _input: &Value) -> Result<String, String> {
    Err("the status line command runs on macOS and Linux".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn no_command_unless_the_settings_name_one() {
        assert_eq!(command(&Settings::Missing), None);
        assert_eq!(command(&Settings::Unreadable("x".into())), None);
        assert_eq!(command(&Settings::Parsed(json!({}))), None);
        assert_eq!(command(&Settings::Parsed(json!({ KEY: "  " }))), None);
        assert_eq!(command(&Settings::Parsed(json!({ KEY: 3 }))), None);
        assert_eq!(
            command(&Settings::Parsed(json!({ KEY: " ~/bin/line " }))).as_deref(),
            Some("~/bin/line")
        );
        let nested = json!({"agentPane": {"statusLine": {"command": "echo hi"}}});
        assert_eq!(command(&Settings::Parsed(nested)).as_deref(), Some("echo hi"));
    }

    #[test]
    fn the_first_line_only_without_escapes_and_cut() {
        assert_eq!(first_line(b"main  +2 -1\nsecond line\n"), "main  +2 -1");
        assert_eq!(
            first_line(b"\x1b[1;32mgreen\x1b[0m \x1b]8;;https://x\x07link\x1b]8;;\x07\tdone\r\n"),
            "green link done"
        );
        assert_eq!(first_line(b""), "");
        assert_eq!(first_line(b"   \n"), "");
        let long = "x".repeat(MAX_CHARS + 50);
        let cut = first_line(long.as_bytes());
        assert_eq!(cut.chars().count(), MAX_CHARS);
        assert!(cut.ends_with('…'));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn the_command_reads_the_session_on_stdin() {
        let input = json!({"session_id": "chat-1", "model": {"display_name": "Opus"}});
        let line = run(
            r#"read -r body; case "$body" in *'"session_id":"chat-1"'*) echo "seen $PWD";; *) echo missing;; esac"#,
            Path::new("/"),
            &input,
        )
        .await
        .unwrap();
        assert_eq!(line, "seen /");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_slow_or_endless_command_is_cut_off() {
        let started = std::time::Instant::now();
        let line =
            run("echo first; echo second; sleep 30", Path::new("/"), &json!({})).await.unwrap();
        assert_eq!(line, "first");
        assert!(started.elapsed() < TIMEOUT, "the first line answers at once");

        let started = std::time::Instant::now();
        let err = run("sleep 30", Path::new("/"), &json!({})).await.unwrap_err();
        assert!(err.contains("no line"), "{err}");
        assert!(started.elapsed() < TIMEOUT + Duration::from_secs(1));

        // Stdout that never ends is read only up to MAX_READ.
        let line = run("yes abc | tr -d '\\n'", Path::new("/"), &json!({})).await.unwrap();
        assert_eq!(line.chars().count(), MAX_CHARS);
    }
}
