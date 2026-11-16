//! `cmux share prepare [--json] [--on MACHINE]`: whether screen sharing to a machine is ready,
//! as `cmux.screen-share.status/1` (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md):
//! `granted`, `needs_grant` with `missing`, `not_installed`, `unsupported`. It installs or
//! updates the Screen Sharing helper beside the daemon from a cmux app there, then reads the
//! helper's grants from a fresh helper process. It grants nothing and asks nobody. Exit 0 with a
//! status every time: a machine it cannot reach reads `not_installed` with the reason.

use super::*;

const USAGE: &str = "usage: cmux share prepare [--json] [--on MACHINE]";

/// The words after `share prepare` when `raw_args` is that verb (output flags may come first).
pub(crate) fn requested(raw_args: &[String]) -> Option<Vec<String>> {
    let lead = raw_args.iter().take_while(|w| *w == "--json").count();
    let (flags, rest) = (raw_args.get(..lead)?, raw_args.get(lead..)?);
    match rest {
        [share, prepare, after @ ..] if share == "share" && prepare == "prepare" => {
            Some(flags.iter().chain(after).cloned().collect())
        }
        _ => None,
    }
}

/// Runs `cmux share prepare <args>`: 0 with a status, 2 on a usage error.
pub(crate) fn run(args: &[String]) -> i32 {
    let flags = match super::super::Flags::parse(args, &["on", "network"], &["json"]) {
        Ok(flags) if flags.positional.is_empty() => flags,
        Ok(_) | Err(_) => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let status = match flags.value("on") {
        None => acpmux::screen_share::read(
            &acpmux::config::home(),
            acpmux::screen_share::Options { install: true },
        ),
        Some(machine) => match Here::read(&flags) {
            Ok(here) => on(&here, machine),
            Err(e) => unreachable_status(&format!("cannot read your machines: {e:#}")),
        },
    };
    if flags.has("json") {
        println!("{}", serde_json::to_string(&status).unwrap_or_default());
    } else {
        let state = serde_json::to_value(status.state).unwrap_or_default();
        println!("{}: {}", state.as_str().unwrap_or_default(), status.detail);
    }
    0
}

/// The status of `machine`, read there over its route ([`SHARE_PREPARE`]).
pub(crate) fn on(world: &dyn World, machine: &str) -> Status {
    let (name, route) = match world.lookup(machine) {
        Ok(found) => found,
        Err(why) => return unreachable_status(&format!("{machine}: {why}")),
    };
    let remote = world.remote(&route);
    let out = exec(remote.as_ref(), SHARE_PREPARE, None);
    match serde_json::from_str::<Status>(out.stdout.trim()) {
        Ok(status) if out.ok && status.schema == acpmux::screen_share::SCHEMA => status,
        _ if !out.ok => unreachable_status(&format!("cannot reach {name}: {}", said(&out))),
        _ => unreachable_status(&format!(
            "{name} has no cmux that reads screen sharing yet: cmux device setup {name}"
        )),
    }
}

/// A status for a machine that gave none: nothing there was read, so nothing is claimed.
fn unreachable_status(why: &str) -> Status {
    let mut status = acpmux::screen_share::classify(acpmux::screen_share::Facts {
        mac: true,
        install_error: Some(why.to_owned()),
        now_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or_default(),
        ..Default::default()
    });
    status.detail = why.to_owned();
    status
}
