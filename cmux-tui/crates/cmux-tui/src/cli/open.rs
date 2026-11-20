//! Guest-side remote file preview requests.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const CLAIM_DEADLINE: Duration = Duration::from_secs(5);
const DELIVERY_DEADLINE: Duration = Duration::from_secs(45);

pub(super) struct Plan {
    location: String,
}

pub(super) fn parse(words: &[String]) -> Result<Plan, super::UsageError> {
    match words {
        [location] => Ok(Plan { location: location.clone() }),
        _ => Err(super::UsageError::new(crate::localization::catalog().open.arguments)),
    }
}

pub(super) fn run(global: GlobalArgs, plan: Plan) -> i32 {
    let (socket, socket_is_derived) = match super::wire::resolve_socket_with_origin(&global) {
        Ok(socket) => socket,
        Err(_) => {
            return usage_error(
                crate::localization::catalog().open.outside_terminal,
                global.output,
            );
        }
    };
    let terminal = match std::env::var("CMUX_TUI_TERMINAL_ID") {
        Ok(terminal) if !terminal.is_empty() => terminal,
        _ => {
            return usage_error(
                crate::localization::catalog().open.outside_terminal,
                global.output,
            );
        }
    };
    let cwd = match std::env::current_dir() {
        Ok(cwd) => cwd,
        Err(error) => {
            return usage_error(
                &crate::localization::catalog()
                    .open
                    .read_current_directory
                    .replace("{error}", &error.to_string()),
                global.output,
            );
        }
    };
    let (path, line) = match resolve_location(&plan.location, &cwd) {
        Ok(location) => location,
        Err(message) => return usage_error(&message, global.output),
    };
    let stream = match cmux_tui_core::server::connect_session_socket(&socket, socket_is_derived) {
        Ok(stream) => stream,
        Err(error) => {
            return transport_error(
                &crate::localization::catalog()
                    .open
                    .connect_failed
                    .replace("{socket}", &socket.display().to_string())
                    .replace("{error}", &error.to_string()),
                global.output,
            );
        }
    };
    let _ =
        stream.set_read_timeout(Some(CLAIM_DEADLINE + DELIVERY_DEADLINE + Duration::from_secs(1)));
    let request = json!({
        "id": "guest-file-preview-open",
        "cmd": "file-preview-open",
        "terminal_id": terminal,
        "path": path,
        "line": line,
    });
    let encoded = match serde_json::to_vec(&request) {
        Ok(encoded) => encoded,
        Err(error) => {
            return transport_error(
                &crate::localization::catalog()
                    .open
                    .encode_failed
                    .replace("{error}", &error.to_string()),
                global.output,
            );
        }
    };
    let mut reader = BufReader::new(stream);
    if let Err(error) = reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().write_all(b"\n"))
        .and_then(|()| reader.get_mut().flush())
    {
        return transport_error(
            &crate::localization::catalog().open.send_failed.replace("{error}", &error.to_string()),
            global.output,
        );
    }
    let mut response = String::new();
    match reader.read_line(&mut response) {
        Ok(0) => transport_error(
            crate::localization::catalog().open.closed_before_delivery,
            global.output,
        ),
        Ok(_) => match serde_json::from_str::<Value>(&response) {
            Ok(response) if response["ok"] == true && response["data"]["opened"] == true => {
                success(&path, line, global.output)
            }
            Ok(response) if response["ok"] == true => {
                delivery_error(crate::localization::catalog().open.no_frontend, global.output)
            }
            Ok(response) => delivery_error(
                response["error"]
                    .as_str()
                    .unwrap_or(crate::localization::catalog().open.request_failed),
                global.output,
            ),
            Err(error) => transport_error(
                &crate::localization::catalog()
                    .open
                    .invalid_response
                    .replace("{error}", &error.to_string()),
                global.output,
            ),
        },
        Err(error) => transport_error(
            &crate::localization::catalog().open.timed_out.replace("{error}", &error.to_string()),
            global.output,
        ),
    }
}

fn success(path: &str, line: Option<u64>, output: OutputMode) -> i32 {
    super::wire::print_local_success(&success_result(path, line), output)
}

fn success_result(path: &str, line: Option<u64>) -> Value {
    json!({"opened": true, "path": path, "line": line})
}

fn resolve_location(raw: &str, cwd: &Path) -> Result<(String, Option<u64>), String> {
    if raw.is_empty() || raw.chars().any(char::is_control) || looks_like_url(raw) {
        return Err(crate::localization::catalog().open.expects_local_path.into());
    }
    let (path, line) = split_line(raw)?;
    let path = PathBuf::from(path);
    let path = if path.is_absolute() { path } else { cwd.join(path) };
    let metadata = std::fs::metadata(&path).map_err(|error| {
        crate::localization::catalog()
            .open
            .cannot_open
            .replace("{path}", &path.display().to_string())
            .replace("{error}", &error.to_string())
    })?;
    if !metadata.is_file() {
        return Err(crate::localization::catalog()
            .open
            .not_regular_file
            .replace("{path}", &path.display().to_string()));
    }
    Ok((utf8_path(&path)?, line))
}

fn utf8_path(path: &Path) -> Result<String, String> {
    path.to_str().map(ToOwned::to_owned).ok_or_else(|| {
        crate::localization::catalog()
            .open
            .path_not_utf8
            .replace("{path}", &path.display().to_string())
    })
}

fn split_line(raw: &str) -> Result<(&str, Option<u64>), String> {
    let Some((path, suffix)) = raw.rsplit_once(':') else { return Ok((raw, None)) };
    if suffix.is_empty() || !suffix.bytes().all(|byte| byte.is_ascii_digit()) {
        return Ok((raw, None));
    }
    let line = suffix
        .parse::<u64>()
        .map_err(|_| crate::localization::catalog().open.line_too_large.to_owned())?;
    if line == 0 {
        return Err(crate::localization::catalog().open.line_must_be_positive.into());
    }
    if line > u64::from(u32::MAX) {
        return Err(crate::localization::catalog().open.line_too_large_for_preview.into());
    }
    Ok((path, Some(line)))
}

fn looks_like_url(raw: &str) -> bool {
    raw.contains("://") || raw.get(..5).is_some_and(|prefix| prefix.eq_ignore_ascii_case("file:"))
}

fn usage_error(message: &str, output: OutputMode) -> i32 {
    print_error("usage.invalid", message, output, 2, false)
}

fn transport_error(message: &str, output: OutputMode) -> i32 {
    print_error("transport.failed", message, output, 3, true)
}

fn delivery_error(message: &str, output: OutputMode) -> i32 {
    print_error("file-preview.unavailable", message, output, 1, true)
}

fn print_error(code: &str, message: &str, output: OutputMode, status: i32, retryable: bool) -> i32 {
    super::wire::print_local_error(
        &json!({"code": code, "message": message, "details": {}, "retryable": retryable}),
        output,
        status,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_line_parser_only_treats_a_trailing_decimal_as_a_line() {
        assert_eq!(split_line("notes.md:12").unwrap(), ("notes.md", Some(12)));
        assert_eq!(split_line("a:b.md").unwrap(), ("a:b.md", None));
        assert_eq!(split_line("notes.md:0").unwrap_err(), "line number must be at least 1");
        assert_eq!(
            split_line("notes.md:4294967296").unwrap_err(),
            "line number must not exceed 4294967295"
        );
    }

    #[test]
    fn explicit_socket_wins_over_the_environment() {
        let global =
            GlobalArgs { socket: Some(PathBuf::from("/explicit.sock")), ..Default::default() };
        let (socket, derived) = super::super::wire::resolve_socket_with_env(&global, |_| {
            Some(std::ffi::OsString::from("/environment.sock"))
        })
        .unwrap();
        assert_eq!(socket, PathBuf::from("/explicit.sock"));
        assert!(!derived);
    }

    #[test]
    fn json_success_includes_the_opened_location() {
        assert_eq!(
            success_result("/srv/notes.md", Some(12)),
            json!({"opened": true, "path": "/srv/notes.md", "line": 12})
        );
        assert_eq!(
            success_result("/srv/notes.md", None),
            json!({"opened": true, "path": "/srv/notes.md", "line": null})
        );
    }

    #[test]
    fn relative_paths_resolve_against_the_callers_current_directory() {
        let root = std::env::temp_dir().join(format!("cmux-open-regular-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("notes.md");
        std::fs::write(&file, "notes").unwrap();
        assert_eq!(
            resolve_location("notes.md:7", &root).unwrap(),
            (file.to_str().unwrap().to_owned(), Some(7))
        );
        let _ = std::fs::remove_file(&file);
        let _ = std::fs::remove_dir(&root);
    }

    #[test]
    fn resolve_location_requires_a_regular_utf8_file() {
        let root = std::env::temp_dir().join(format!("cmux-open-invalid-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        assert_eq!(
            resolve_location(root.to_str().unwrap(), &root).unwrap_err(),
            format!("cannot open {}: it is not a regular file", root.display())
        );

        let _ = std::fs::remove_dir(&root);
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_paths_are_rejected() {
        use std::os::unix::ffi::OsStringExt;

        let path = PathBuf::from(std::ffi::OsString::from_vec(vec![b'f', 0x80]));
        assert_eq!(
            utf8_path(&path).unwrap_err(),
            format!("cannot open {}: its path is not valid UTF-8", path.display())
        );
    }
}
