//! Who an unnamed prompt is from, judged by what the daemon checked or the CLI declared, never
//! by its text: the proven person (`person_admitted`), the owner's terminal (`owner_terminal`),
//! the app's own pane before it proved the person (`app_pane_unproven`), else no one for sure.

use super::super::Conn;
use super::super::conn_auth::ConnAuth;
use super::super::remote_guard;
use serde_json::Value;

/// Whether a prompt naming no sender is the person's, by a proof and never by a label: the
/// connection proved the person (`hub/person.rs`: the app's own pane), a paired phone sent it (a
/// Web connection with the device's `client` credential, `pairing.rs` `origin_of`), or a peer link
/// forwarded one its own daemon's connection proved (`remote_guard::PERSON_PROVEN`, that peer's
/// word, recorded as come over `peer`). A local process of the user (a shell, a script, an agent
/// outside acpmux, the Cloud mobile carrier's unix connection) proves nothing: socket access,
/// the listener token and environment tags are not the person. An unnamed prompt from the owner's
/// own terminal is still recorded as the person's ([`owner_terminal`]), which proves nothing to
/// a peer or a protected hold.
pub(in crate::server) fn person_admitted(conn: &Conn, params: &Value) -> bool {
    if conn.is_person() {
        return true;
    }
    if !conn.auth.authenticated() {
        return false;
    }
    match conn.origin {
        // The listener token a dashboard or browser socket holds proves no person; a paired
        // read-only device sends no prompt.
        super::super::Origin::Web => conn.auth == ConnAuth::Device,
        // Only the forwarding daemon's own proof (`remote_guard::attest_person`, by this same
        // rule there), on a peer daemon's own link (`PeerToken`). A paired machine's `client`
        // credential is served as Peer too (`pairing.rs` `origin_of`, `Device`): it is a client,
        // and its own `personVerified` proves nothing. Its `via` is no proof either: it labels
        // any client but the owner's, a unix one too.
        super::super::Origin::Peer => {
            conn.auth.peer_daemon()
                && params
                    .pointer("/_meta/acpmux")
                    .and_then(|m| m.get(remote_guard::PERSON_PROVEN))
                    .and_then(Value::as_bool)
                    == Some(true)
        }
        super::super::Origin::Local | super::super::Origin::LocalApp => false,
    }
}

/// Whether an unnamed prompt is the owner's own terminal send (`acpmux send` at
/// a plain shell of this machine's user), recorded as the person's prompt as it was before #37497,
/// so every client draws the owner's bubble.
///
/// The trust boundary: the unix socket is reachable only by this machine's user, and among that
/// user's processes the daemon tells an agent from the person by what it can check or what the
/// CLI declares, never by the text. An agent in an acpmux session holds a caller token
/// (`hub/person.rs` (a)), proven or not, and its send is that session's. An agent harness's own
/// shell outside acpmux (Claude Code, Codex, an `AI_AGENT` tool) names itself and its harness
/// (`cli/sender.rs` `implicit`, `harness_of`: `fromAgent`, `fromHarness`), and a send whose
/// environment or process chain shows a harness, an MCP client or an app that is no terminal
/// says so (`sender_harness.rs`: `senderHarness`; a shell under a terminal or cmux claims none). A relay names what it
/// carries (`fromRelay`, `via`: the lane-gh broker, the Cloud mobile carrier). A trigger, the
/// app's own transport (`LocalApp`, whose pane proves the person instead) and every non-unix
/// transport are no terminal. Any of those stays `unverified`. A send the daemon keeps and delivers
/// later (`_acpmux/send_queue`) replays on the outbox's own unix connection with its request's
/// claims and the caller its sender named, proven or not (`Delivery::unproven_caller`), so it is
/// judged here as the send itself was (#38260 F1). An acpmux CLI says at `initialize` whether
/// it runs in an acpmux session's environment (`cli_caller.rs`): one that says `agent` (its token
/// proved nothing to this daemon, or it had none), and an old acpmux CLI that says nothing (it
/// checked nothing: bench round 4 recorded an agent's send through `acpmux` 0.1.0 as the person),
/// are no terminal either; the outbox replays that too (`Delivery::not_terminal`). What is left
/// is a plain unix connection of the user that claims nothing: the person at their terminal. A script of the
/// same user that strips every label is let through, as it was before #37497; it still never
/// releases a protected hold (`PromptOptions::unproven_owner`), never counts as an authenticated
/// person (`human_authenticated` needs the proven person) and is never forwarded to a peer as
/// the person's (`attest_person` reads `person_admitted` only).
pub(super) fn owner_terminal(conn: &Conn, params: &Value) -> bool {
    conn.origin == super::super::Origin::Local
        && !conn.is_trigger()
        && conn.caller().is_none()
        && conn.unproven_caller.get().is_none()
        && conn.may_be_owner_terminal()
        && !claims_a_sender(params)
}

/// Whether an unnamed prompt is the app's own agent pane's (`Origin::LocalApp`, proven by this
/// launch's LocalApp token) on a connection that has not proved the person: recorded as the
/// person's prompt, as [`owner_terminal`]'s is.
///
/// The pane proves the person with `_acpmux/person_prove`, but only once the daemon holds the
/// app's person key, and a daemon that just restarted, is still loading, or refused the app's
/// enroll does not hold it yet. The composer's prompts in that window were recorded as
/// `unverified` and drawn as "Unverified sender" in the inbox, with the agent told they came
/// "From a program that did not say who it is, not the person" (Leo, 2026-11-12: "STOP CALLING
/// ME F***ING UNVERIFIED F***ING SENDER"). The LocalApp token proves more than the unix socket
/// an owner's terminal send comes over, so the pane gets the same record. As with
/// `owner_terminal`, it lifts no protected hold (`PromptOptions::unproven_owner`), is never
/// an authenticated person and is never forwarded to a peer as the person's; a pane prompt
/// that names a sender (an agent's `cmux agent message` through the app) stays that sender's.
pub(super) fn app_pane_unproven(conn: &Conn, params: &Value) -> bool {
    conn.origin == super::super::Origin::LocalApp
        && conn.auth == ConnAuth::LocalApp
        && !conn.is_person()
        && !conn.is_trigger()
        && conn.caller().is_none()
        && conn.unproven_caller.get().is_none()
        && !claims_a_sender(params)
}

/// Whether a prompt names a sender, a harness or a relay of its own (`_meta.acpmux`): an agent's
/// or a relay's then, never the person's.
fn claims_a_sender(params: &Value) -> bool {
    params.pointer("/_meta/acpmux").and_then(Value::as_object).is_some_and(|mux| {
        [
            "fromAgent",
            crate::prompt_provenance::FROM_HARNESS,
            crate::sender_harness::META_KEY,
            "fromRelay",
            "via",
        ]
        .iter()
        .any(|key| mux.get(*key).is_some_and(|v| !v.is_null()))
    })
}
