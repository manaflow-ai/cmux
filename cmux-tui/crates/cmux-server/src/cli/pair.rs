//! `cmux server pair [--wait] [--timeout S] [--json]` (server.md 6.2).
//! The code is printed before the wait starts: one human block, or with
//! `--json` one `{code, expires_at, words, qr_payload}` line; with `--wait`
//! the last line is `{host, team}`. Refused exits 4, timeout or expiry 5.

use std::io::Write;
use std::time::Duration;

use serde_json::json;

use super::{Args, Context, Output};
use crate::error::{Error, Result};
use crate::pair::{self, ApiTarget, PairOutcome, PairRequest, Started};

pub(super) fn pair(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let timeout = match args.number("timeout")? {
        Some(0) => return Err(Error::usage("--timeout takes a positive number of seconds")),
        Some(s) => Some(Duration::from_secs(s)),
        None => None,
    };
    if timeout.is_some() && !args.has("wait") {
        return Err(Error::usage("--timeout needs --wait"));
    }
    if crate::host::resolve_mode(false) == cmux_server_core::InstallMode::System {
        // The keys would be made by root (or by whoever runs this) in the
        // service user's state folder; the service could not read them.
        return Err(Error::rejected(
            "pairing a system-mode server is not supported yet: the keys must belong to the service user `cmux`. Pair a user-mode server, without sudo",
        ));
    }
    let layout = super::lifecycle::layout(ctx, false)?;
    let api = ApiTarget::from_env();
    let request = PairRequest {
        layout: &layout,
        api: &api,
        info: pair::info::host_info(&ctx.running_cmux),
        wait: args.has("wait"),
        timeout,
        now_ms: ctx.now_ms,
    };
    let json_mode = args.json;
    let now_ms = ctx.now_ms;
    let waiting = request.wait;
    let mut show = |started: &Started| {
        // Without --wait the final output carries the code.
        if !waiting {
            return;
        }
        let mut out = std::io::stdout().lock();
        let _ = if json_mode {
            writeln!(out, "{}", json!(started))
        } else {
            write!(out, "{}", human_code(started, now_ms))
        };
        let _ = out.flush();
    };
    Ok(match pair::run(&request, &mut show)? {
        PairOutcome::Pending(started) => Output::new(
            json!(started),
            format!(
                "{}\nRun `cmux server pair --wait` to finish pairing after approval.\n",
                human_code(&started, ctx.now_ms)
            ),
        ),
        PairOutcome::Paired(p) => Output::new(
            json!({"host": p.host, "team": p.team}),
            format!("Paired: this server is host {} in team {}.\n", p.host, p.team),
        ),
        PairOutcome::AlreadyPaired(p) => Output::new(
            json!({"host": p.host, "team": p.team, "already_paired": true}),
            format!("Already paired: host {} in team {}.\n", p.host, p.team),
        ),
    })
}

/// The block a person reads: code, link, words.
pub fn human_code(s: &Started, now_ms: u64) -> String {
    let words = s.words.join(" ");
    let minutes = s.expires_at.saturating_sub(now_ms).div_ceil(60_000);
    format!(
        "Pairing code: {}\n\nApprove it in cmux (Add Server…) or open:\n  {}\n\nCheck that the approving screen shows these words:\n  {words}\n\nThe code expires in {minutes} min.\n",
        s.code, s.qr_payload
    )
}
