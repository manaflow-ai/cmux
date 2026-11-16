//! `cmux device add HOST --yes`'s second half: this Mac on the hub mesh, so a chat starts on the
//! machine it just added (cmuxterm-hq docs/design/remote-spin-up.md, section 2.1: "A Door A join
//! writes the same-person grant for the Mac that ran it ... the check in section 6 starts a chat
//! right after the join to prove it").
//!
//! The far machine's join already grants the person's own machines (`controlFrom: sameUser`,
//! acpmux `cli/cloud_join.rs`). A grant reaches only a machine on the mesh: a Mac that never
//! joined the hub has no mesh, and `cmux chat --on NAME` answered "mesh enqueue key ...; error
//! runtime" (Door A timing run, huge-blue/doora-timing, 2026-11-16). So the add makes sure this
//! Mac is on the mesh as the same person, with what signing in to the app already does:
//! `acpmux machine enroll-self` (`cli/cloud_join/enroll.rs`), with the person's access token on
//! stdin and the person it names. A Mac signing in already enrolled answers `alreadyJoined` and
//! changes nothing; one joined by another person, to another hub or with a relay of the
//! person's own is left alone and said so, with its next step. A new join here restarts this
//! Mac's acpmux daemon (sessions kept: `acpmux daemon restart`), whose mesh relay starts only at
//! its start; then the add waits a little for the hub to list the new machine, so the line it
//! prints works when it is printed.

use std::time::{Duration, Instant};

use serde_json::Value;

/// `cmux acp WORDS` with `stdin`: its JSON answer, or the failure.
pub(crate) type Acp<'a> = dyn FnMut(&[&str], Option<&str>) -> Result<Value, Value> + 'a;

/// What the add did for this Mac.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ThisMac {
    /// Already on the mesh as this person: nothing changed.
    Ready,
    /// Joined now (and its daemon restarted onto the join).
    Joined,
    /// Not on the mesh as this person: what is in the way and the next step.
    Blocked { message: String, next: String },
}

impl ThisMac {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Joined => "joined",
            Self::Blocked { .. } => "blocked",
        }
    }
}

/// Makes sure this Mac is on `hub`'s mesh as the person whose access token is `access`.
pub(crate) fn ensure(hub: &str, access: &str, acp: &mut Acp<'_>) -> ThisMac {
    let Some(user) = acpmux::cli::cloud_join::access_token_user(access) else {
        return blocked(
            "this sign-in names no person, so this Mac was not joined to the cmux hub",
            "sign in to cmux on this Mac (`cmux login`), then add the machine again",
        );
    };
    let stdin = format!("{}\n", access.trim());
    let words =
        ["machine", "enroll-self", "--access-token-stdin", "--hub", hub, "--user-id", &user];
    let mut with_json: Vec<&str> = words.to_vec();
    with_json.push("--json");
    let answer = match acp(&with_json, Some(&stdin)) {
        Ok(answer) => answer,
        Err(error) => {
            let why = error.get("message").and_then(Value::as_str).unwrap_or("no answer");
            return blocked(
                &format!("this Mac's acpmux did not join the cmux hub ({why})"),
                "run `cmux acp machine join --status` to see this Mac's join, then add the machine again",
            );
        }
    };
    match answer.get("outcome").and_then(Value::as_str).unwrap_or_default() {
        "alreadyJoined" => ThisMac::Ready,
        "joined" => {
            // The relay starts with the daemon; a daemon that is not running starts on it.
            if acp(&["daemon", "restart", "--json"], None).is_err()
                && acp(&["daemon", "start", "--json"], None).is_err()
            {
                return blocked(
                    "this Mac joined the cmux hub, but its acpmux daemon did not restart onto the join",
                    "run `cmux acp daemon restart`, then start the chat",
                );
            }
            ThisMac::Joined
        }
        "otherUser" => blocked(
            "this Mac is joined to cmux as another person, so its chats cannot reach machines you add",
            "sign in to cmux on this Mac as the person adding machines, then start the chat",
        ),
        "otherHub" => blocked(
            &format!("this Mac is joined to another cmux hub than {hub}"),
            "add the machine through that hub (--platform), or leave it here (`cmux acp machine leave`) and add it again",
        ),
        "ownRelay" => blocked(
            "this Mac's mesh relay is one set up by hand, so the add did not replace it",
            "point that relay at this hub, or remove it from acpmux's config.json, then add the machine again",
        ),
        "revoked" => blocked(
            "this Mac's join to the cmux hub was revoked",
            "join it again (`cmux machine add` prints a line; run it here with CMUX_JOIN_REPLACE=1), then start the chat",
        ),
        "ownerUnknown" => blocked(
            "this Mac is joined to the cmux hub with no person recorded",
            "run `cmux acp machine join --status` (it records the person), then start the chat",
        ),
        _ => blocked(
            "the cmux hub did not answer this Mac's own join",
            "add the machine again in a minute; it joins this Mac then",
        ),
    }
}

fn blocked(message: &str, next: &str) -> ThisMac {
    ThisMac::Blocked { message: message.to_owned(), next: next.to_owned() }
}

/// How long the add waits for the hub to list the new machine on this Mac's mesh.
pub(crate) const LISTED_WITHIN: Duration = Duration::from_secs(20);
const LISTED_EVERY: Duration = Duration::from_millis(1000);

/// Whether this Mac's acpmux lists `name` through the hub (`acp host ls`, a `via: "hub"` row),
/// read until `within` passes.
pub(crate) fn listed(name: &str, within: Duration, acp: &mut Acp<'_>) -> bool {
    let deadline = Instant::now() + within;
    loop {
        let rows = acp(&["host", "ls", "--json"], None).ok();
        let found = rows
            .as_ref()
            .and_then(|answer| answer.get("peers"))
            .and_then(Value::as_array)
            .is_some_and(|peers| {
                peers.iter().any(|peer| {
                    peer.get("via").and_then(Value::as_str) == Some("hub")
                        && peer
                            .get("name")
                            .and_then(Value::as_str)
                            .is_some_and(|listed| listed.eq_ignore_ascii_case(name))
                })
            });
        if found {
            return true;
        }
        if Instant::now() + LISTED_EVERY > deadline {
            return false;
        }
        // timeout: short-gate: one local acpmux read a second, bounded by `within`.
        std::thread::sleep(LISTED_EVERY);
    }
}

#[cfg(test)]
#[path = "this_mac_tests.rs"]
mod tests;
