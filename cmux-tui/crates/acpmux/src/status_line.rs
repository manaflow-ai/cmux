//! The person's own status line under a chat's prompt (`agentPane.statusLine.command`, Settings >
//! Agent Chat > Composer), as Claude Code's `statusLine` command: a shell command acpmux runs with
//! the chat's session JSON on stdin, whose first line of stdout the composer shows under the prompt.
//! The page never names the command: acpmux reads it from the settings file at each ask
//! (`user_settings`), so only what the person wrote there runs. Bounded: [`TIMEOUT`] to answer,
//! [`MAX_READ`] bytes read, the first line with text only, cut to [`MAX_CHARS`], escapes and control
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

/// The line to show from the command's stdout: its first line with something to show, with
/// terminal escapes (CSI, OSC) and other control characters dropped, trimmed, cut to
/// [`MAX_CHARS`]. Empty when it printed nothing to show.
pub fn first_line(out: &[u8]) -> String {
    let text = String::from_utf8_lossy(out);
    let shown =
        text.split(['\n', '\r']).map(clean).find(|line| !line.is_empty()).unwrap_or_default();
    if shown.chars().count() <= MAX_CHARS {
        return shown;
    }
    let mut cut: String = shown.chars().take(MAX_CHARS - 1).collect();
    cut.truncate(cut.trim_end().len());
    cut.push('…');
    cut
}

/// One line without its terminal escapes and control characters, trimmed.
fn clean(line: &str) -> String {
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
    shown.trim().to_owned()
}

/// Runs `command` with `sh -c` in `cwd` (when it is a folder), `input` as JSON on its stdin, and
/// answers [`first_line`] of what it printed by its first newline, its end or [`TIMEOUT`],
/// whichever comes first. It runs in a process group of its own, ended with all it started when
/// the answer is in (`cmux_process::Child`'s drop), so nothing outlives the ask. Off the async
/// threads. Err says why nothing came (it could not start, it printed nothing in time).
#[cfg(unix)]
pub async fn run(command: &str, cwd: &Path, input: &Value) -> Result<String, String> {
    let (command, cwd) = (command.to_owned(), cwd.to_owned());
    let mut body = serde_json::to_vec(input).unwrap_or_default();
    if body.len() > MAX_INPUT {
        // Written before the first read, it must fit the pipe: drop the bulky part.
        let mut slim = input.clone();
        if let Some(map) = slim.as_object_mut() {
            map.remove("usage");
        }
        body = serde_json::to_vec(&slim).unwrap_or_default();
        body.truncate(MAX_INPUT);
    }
    tokio::task::spawn_blocking(move || run_blocking(&command, &cwd, &body))
        .await
        .map_err(|e| format!("the status line command did not run: {e}"))?
}

/// The most of the session JSON written to the command's stdin: under a pipe's buffer, so the
/// write never waits on a command that does not read it.
#[cfg(unix)]
const MAX_INPUT: usize = 32 * 1024;

#[cfg(unix)]
fn run_blocking(command: &str, cwd: &Path, body: &[u8]) -> Result<String, String> {
    use std::io::{Read as _, Write as _};
    use std::os::fd::AsRawFd as _;
    let started = std::time::Instant::now();
    let mut cmd = cmux_process::Command::new("/bin/sh");
    cmd.arg("-c")
        .arg(command)
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .process_group(0);
    if cwd.is_dir() {
        cmd.current_dir(cwd);
    }
    // Dropped at the end of this function, it ends the command's group (`cmux_process::Child`).
    let mut child =
        cmd.spawn().map_err(|e| format!("could not start the status line command: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        // A command that exits without reading closes the pipe: that is no failure.
        let _ = stdin.write_all(body);
    }
    let mut stdout = child.stdout.take().ok_or("the status line command has no stdout")?;
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    while out.len() < MAX_READ {
        let left = TIMEOUT.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Err(format!(
                "the status line command printed no line in {} s",
                TIMEOUT.as_secs()
            ));
        }
        let mut fd = libc::pollfd { fd: stdout.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one pollfd for a descriptor this function owns, for at most `left`.
        let ready =
            unsafe { libc::poll(&mut fd, 1, left.as_millis().clamp(1, i32::MAX as u128) as i32) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if ready == 0 {
            continue;
        }
        let n = match stdout.read(&mut buf) {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => 0,
        };
        if n == 0 {
            break;
        }
        let room = n.min(MAX_READ.saturating_sub(out.len()));
        out.extend_from_slice(buf.get(..room).unwrap_or_default());
        // The first line with text is all that shows: stop once a whole one is in.
        if let Some(at) = out.iter().rposition(|b| *b == b'\n')
            && !first_line(out.get(..at).unwrap_or_default()).is_empty()
        {
            break;
        }
    }
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
        assert_eq!(first_line(b"\n\x1b[0m\nlater\n"), "later");
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
