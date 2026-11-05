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
    let human = match value["state"].as_str() {
        Some("paired") if invited_as.is_some() => {
            format!("{} {}\n", messages.paired_as, invited_as.unwrap_or_default())
        }
        Some("paired") => {
            format!("{} {}\n", messages.paired, value["host"].as_str().unwrap_or_default())
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
                let words = progress["words"]
                    .as_array()
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

/// What a person reads while the machine waits: the code to type into Add
/// Server, or after an invite, who confirms this machine and the words to
/// compare with theirs.
fn progress_text(
    messages: &messages::Messages,
    progress: &Value,
    words: &str,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if progress["invited"] == true {
        let who = match progress["inviter"].as_str() {
            Some(inviter) => messages.invite_confirm.replace("{inviter}", inviter),
            None => messages.invite_confirm_anyone.to_owned(),
        };
        return writeln!(out, "{who}\n{} {words}", messages.words);
    }
    writeln!(
        out,
        "{} {}\n{} {}\n{}",
        messages.code,
        progress["code"].as_str().unwrap_or_default(),
        messages.words,
        words,
        messages.approve
    )
}
