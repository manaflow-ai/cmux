//! The server pairing catalog's local CLI entrypoints. Approval stays remote.

use std::io::Write;

use serde_json::{Value, json};

use super::{Args, Context, Output, lifecycle};
use crate::error::{Error, Result};
use crate::pairing::{self, Network, messages};

fn path(ctx: &Context<'_>, mutating: bool) -> Result<std::path::PathBuf> {
    let layout = if mutating {
        lifecycle::mutating_layout(ctx, false)?
    } else {
        lifecycle::layout(ctx, false)?
    };
    Ok(crate::fsx::local(&layout.state).join("pairing/identity.json"))
}

fn output(value: Value, invited_as: Option<&str>) -> Output {
    let messages = messages::current();
    let human = match value.get("state").and_then(Value::as_str) {
        Some("paired") if invited_as.is_some() => {
            format!("{} {}\n", messages.paired_as, invited_as.unwrap_or_default())
        }
        Some("paired") => {
            format!(
                "{} {}\n",
                messages.paired,
                value.get("host").and_then(Value::as_str).unwrap_or_default()
            )
        }
        Some("pending") => format!("{}\n", messages.pending),
        Some("network_pending") => format!("{}\n", messages.network_pending),
        Some("indeterminate") => format!("{}\n", messages.indeterminate),
        _ => format!("{}\n", messages.unpaired),
    };
    Output::new(value, human)
}

pub(super) fn status(ctx: &Context<'_>) -> Result<Output> {
    pairing::status(&path(ctx, false)?).map(|value| output(value, None))
}

pub(super) fn begin(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    // Validate before creating a directory, key, HTTP client or socket.
    let api = pairing::api_origin(args.value("api-origin").unwrap_or(pairing::DEFAULT_API))?;
    let invite = args.value("invite").map(pairing::invite::normalize).transpose()?;
    let name = args.value("name").map(str::to_owned).unwrap_or_else(pairing::info::name);
    if name.trim().is_empty()
        || name.encode_utf16().count() > 80
        || name.chars().any(char::is_control)
    {
        return Err(Error::usage("server.pair.invalid_name"));
    }
    let path = path(ctx, true)?;
    let info = json!({"name":name,"platform":std::env::consts::OS,
        "os_version":pairing::info::os_version(),"arch":std::env::consts::ARCH,"cmux_version":ctx.running_cmux});
    let network = Network::with_client_version(&ctx.running_cmux)?;
    let messages = messages::current();
    let value = pairing::enroll_with_invite(
        &path,
        &api,
        info,
        args.idempotency_key.as_deref(),
        invite.as_deref(),
        &network,
        ctx.now_ms,
        |progress| {
            let mut stderr = std::io::stderr().lock();
            if args.json {
                writeln!(stderr, "{progress}")
            } else {
                let words = progress
                    .get("words")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")
                    })
                    .unwrap_or_default();
                progress_text(&messages, progress, &words, &mut stderr)
            }
            .map_err(|_| Error::unreachable("server.pair.progress_unavailable"))?;
            stderr.flush().map_err(|_| Error::unreachable("server.pair.progress_unavailable"))
        },
    )?;
    Ok(output(value, invite.is_some().then_some(name.as_str())))
}

/// `cmux server unpair [--local]` (`cmux unpair`): sign this machine out of
/// cmux Cloud, then forget its pairing here, and say what was done.
pub(super) fn unpair(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let path = path(ctx, true)?;
    let local_only = args.has("local");
    let value = if local_only {
        pairing::unpair(&path, &NoBackend, true)?
    } else {
        pairing::unpair(&path, &Network::with_client_version(&ctx.running_cmux)?, false)?
    };
    let human = unpair_text(&messages::current(), &value);
    Ok(Output::new(value, human))
}

/// `--local` never reaches the backend.
struct NoBackend;

impl pairing::Transport for NoBackend {
    fn health(&self, _api: &str) -> Result<Value> {
        Err(Error::unreachable(pairing::unpair::UNREACHABLE))
    }
    fn begin(&self, _api: &str, _body: &Value) -> Result<Value> {
        Err(Error::unreachable(pairing::unpair::UNREACHABLE))
    }
    fn wait(
        &self,
        _api: &str,
        _begun: &cmux_server_core::pairing::enrollment::Begun,
    ) -> Result<cmux_server_core::pairing::enrollment::Waited> {
        Err(Error::unreachable(pairing::unpair::UNREACHABLE))
    }
}

/// One line per thing done: Cloud first, then the local record.
fn unpair_text(messages: &messages::Messages, value: &Value) -> String {
    let host = value.get("host").and_then(Value::as_str).unwrap_or_default();
    let mut out = String::new();
    match value.get("cloud").and_then(Value::as_str) {
        Some("signed_out") => out.push_str(&messages.unpair_signed_out.replace("{host}", host)),
        Some("already_revoked") => out.push_str(messages.unpair_already_revoked),
        Some("skipped") => out.push_str(messages.unpair_skipped),
        _ => {}
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(if value.get("removed").and_then(Value::as_bool) == Some(true) {
        messages.unpair_removed
    } else {
        messages.unpair_nothing
    });
    out.push('\n');
    out
}

/// What a person reads while the machine waits: the code to type into Add
/// Server, or after an invite, who confirms this machine and the words to
/// compare with theirs.
fn progress_text(
    messages: &messages::Messages,
    progress: &Value,
    words: &str,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if progress.get("invited").and_then(Value::as_bool) == Some(true) {
        let who = match progress.get("inviter").and_then(Value::as_str) {
            Some(inviter) => messages.invite_confirm.replace("{inviter}", inviter),
            None => messages.invite_confirm_anyone.to_owned(),
        };
        return writeln!(out, "{who}\n{} {words}", messages.words);
    }
    writeln!(
        out,
        "{} {}\n{} {}\n{}",
        messages.code,
        progress.get("code").and_then(Value::as_str).unwrap_or_default(),
        messages.words,
        words,
        messages.approve
    )
}
