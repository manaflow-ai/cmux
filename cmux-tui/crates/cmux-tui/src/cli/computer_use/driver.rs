//! `cmux computer-use` on a machine with the daemon: status and approvals
//! through `mcp/computer_use_tools.rs` (the MCP tools' own functions), the
//! driver's tools through acpmux's bridge, and the macOS mode through the app.

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::mcp::computer_use_tools::{self as tools, Revoke};
use super::super::mcp::{CallFailure, agent_failure_value, cli_backend};
use super::super::{GlobalArgs, OutputMode, wire};
use super::{Command, fail};

pub(super) fn run(global: &GlobalArgs, command: Command) -> i32 {
    let backend = cli_backend(global.clone());
    let output = global.output;
    let answer = match command {
        Command::Status => tools::status(&backend),
        Command::List => tools::approvals_list(&backend),
        Command::Pending => tools::approvals_pending(&backend),
        Command::Revoke { app } => tools::revoke(
            &backend,
            match app.as_deref() {
                Some(app) => Revoke::App(app),
                None => Revoke::All,
            },
        ),
        Command::Deny { id } => tools::deny(&backend, &id),
        Command::Approve { id } => tools::prompt(&backend, &id).map(|value| {
            json!({"shown": true, "id": id, "collector": value,
                   "note": "The question is on cmux's card again; answer it there."})
        }),
        Command::Tools => {
            return match tools::mcp_request(&backend, "tools/list", json!({})).and_then(mcp_result)
            {
                Ok(result) => print_tools(&result, output),
                Err(failure) => print_failure(failure, output),
            };
        }
        Command::Call { tool, arguments } => {
            let params = json!({"name": tool, "arguments": arguments});
            return match tools::mcp_request(&backend, "tools/call", params).and_then(mcp_result) {
                Ok(result) => print_call(&result, output),
                Err(failure) => print_failure(failure, output),
            };
        }
        Command::Screenshot { out, arguments } => {
            let params = json!({"name": "screenshot", "arguments": arguments});
            return match tools::mcp_request(&backend, "tools/call", params).and_then(mcp_result) {
                Ok(result) => save_screenshot(&result, &out, output),
                Err(failure) => print_failure(failure, output),
            };
        }
        Command::Help | Command::Setup(_) => return 2,
    };
    match answer {
        Ok(value) => wire::print_local_success(&value, output),
        Err(failure) => print_failure(failure, output),
    }
}

fn print_failure(failure: CallFailure, output: OutputMode) -> i32 {
    wire::print_local_error(&agent_failure_value(failure), output, 1)
}

/// The `result` of the bridge's MCP response, or its error as a failure.
fn mcp_result(response: Value) -> Result<Value, CallFailure> {
    if let Some(error) = response.get("error") {
        let message = error["message"].as_str().unwrap_or("Computer Use refused the request");
        return Err(CallFailure {
            kind: super::super::mcp::FailureKind::Rejected,
            error: json!({"code": "computer_use.refused", "message": message,
                          "details": {"rpc": error.get("code")}, "retryable": false}),
            idempotency_key: None,
        });
    }
    Ok(response.get("result").cloned().unwrap_or(Value::Null))
}

/// The text of a tool result's `content`, images named by type and size.
pub(super) fn result_text(result: &Value) -> String {
    let mut lines = Vec::new();
    for item in result["content"].as_array().into_iter().flatten() {
        match item["type"].as_str() {
            Some("text") => lines.push(item["text"].as_str().unwrap_or_default().to_owned()),
            Some("image") => lines.push(format!(
                "[{} image, {} base64 characters; save one with `cmux computer-use screenshot --out FILE`]",
                item["mimeType"].as_str().unwrap_or("an"),
                item["data"].as_str().map_or(0, str::len)
            )),
            Some(other) => lines.push(format!("[{other} content]")),
            None => {}
        }
    }
    lines.join("\n")
}

fn print_call(result: &Value, output: OutputMode) -> i32 {
    let failed = result["isError"] == json!(true);
    match output {
        OutputMode::Human | OutputMode::Quiet if failed => {
            eprintln!("{}", result_text(result));
            1
        }
        OutputMode::Human => {
            println!("{}", result_text(result));
            0
        }
        OutputMode::Quiet => 0,
        OutputMode::Json | OutputMode::JsonLines if failed => {
            wire::print_local_error(result, output, 1)
        }
        OutputMode::Json | OutputMode::JsonLines => wire::print_local_success(result, output),
    }
}

fn print_tools(result: &Value, output: OutputMode) -> i32 {
    let tools = result["tools"].as_array().cloned().unwrap_or_default();
    if output != OutputMode::Human {
        return wire::print_local_success(&Value::Array(tools), output);
    }
    for tool in &tools {
        let description = tool["description"].as_str().unwrap_or_default();
        let first = description.lines().next().unwrap_or_default();
        println!("{:<28} {first}", tool["name"].as_str().unwrap_or("?"));
    }
    0
}

/// The first image of a `screenshot` result, decoded.
pub(super) fn screenshot_image(result: &Value) -> Result<(Vec<u8>, String), String> {
    if result["isError"] == json!(true) {
        return Err(result_text(result));
    }
    let image = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["type"] == "image")
        .ok_or("the screenshot tool returned no image")?;
    let data = image["data"].as_str().ok_or("the image has no data")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| format!("the image data is not base64: {e}"))?;
    Ok((bytes, image["mimeType"].as_str().unwrap_or("image/png").to_owned()))
}

fn save_screenshot(result: &Value, out: &std::path::Path, output: OutputMode) -> i32 {
    let (bytes, mime) = match screenshot_image(result) {
        Ok(image) => image,
        Err(message) => return fail(output, "computer_use.screenshot_failed", &message),
    };
    if let Err(error) = write_private(out, &bytes) {
        return fail(
            output,
            "computer_use.write_failed",
            &format!("cannot write {}: {error}", out.display()),
        );
    }
    let receipt =
        json!({"path": out.display().to_string(), "bytes": bytes.len(), "mimeType": mime});
    wire::print_local_success(&receipt, output)
}

/// A screenshot shows the person's screen: 0600, never through a symlink.
fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    file.write_all(bytes)
}

/// How long `setup` waits for the person's answer in the app.
#[cfg(target_os = "macos")]
const CONFIRM_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// macOS: the app's setting `computerUse.mode`. The key is the person's; a
/// raise waits for their confirmation in the app.
#[cfg(target_os = "macos")]
pub(super) fn set_app_mode(global: &GlobalArgs, setup: &super::Setup) -> i32 {
    if setup.manifest.is_some() || setup.elevated {
        return fail(
            global.output,
            "usage.invalid",
            "on macOS the cmux app keeps the mode and the approved apps: run setup with --mode only",
        );
    }
    let params = json!({"path": "computerUse.mode", "value": setup.mode.name(), "confirm": true});
    match super::super::mcp::agent_app(global, "settings.set", params, CONFIRM_TIMEOUT, None) {
        Ok(value) => wire::print_local_success(&value, global.output),
        Err(error) => wire::print_local_error(&error, global.output, 1),
    }
}
