//! The connect handshake's verdicts on a daemon's `identify`.

use crate::identity::Identity;

/// The protocol the app speaks (cmux-tui-core `PROTOCOL_VERSION`).
pub const PROTOCOL_VERSION: i64 = 12;
/// The app name a cmux-tui daemon reports.
pub const DAEMON_APP: &str = "cmux-tui";
/// Owner machine metadata on `identify` (`identify {machine_metadata: true}`).
pub const MACHINE_IDENTITY: &str = "machine-identity-v1";
/// The page relay's origin claim.
pub const ORIGIN_CLAIM: &str = "origin-claim-v1";
/// Page ids on page relays.
pub const PAGE_ROUTER: &str = "page-router-v1";
pub const SIDEBAR_DOC: &str = "sidebar-doc-v1";
pub const PLACEMENT_SHIFT: &str = "placement-shift-v1";
pub const TERMINAL_FRONTEND_SHELL_INTEGRATION: &str = "terminal-frontend-shell-integration-v1";

/// Why the handshake refuses a daemon, or that it accepts it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Accept,
    /// Another program serves the socket: close at once, no handoff.
    WrongApp(String),
    /// Another protocol: the app's local owner may be handed off first.
    UnsupportedProtocol(i64),
    /// Required capabilities missing, in the order asked.
    MissingCapabilities(Vec<String>),
}

/// The main connection's verdict: the app, then the protocol, then the
/// required capabilities.
pub fn verdict(identity: &Identity, required: &[String]) -> Verdict {
    if identity.app != DAEMON_APP {
        return Verdict::WrongApp(identity.app.clone());
    }
    if identity.protocol != PROTOCOL_VERSION {
        return Verdict::UnsupportedProtocol(identity.protocol);
    }
    let have = identity.capability_set();
    let missing: Vec<String> =
        required.iter().filter(|c| !have.contains(c.as_str())).cloned().collect();
    if missing.is_empty() { Verdict::Accept } else { Verdict::MissingCapabilities(missing) }
}

/// The page relay's verdict: app and protocol as the main connection, then
/// `origin-claim-v1`; on accept, the page to name in `client-hello` (only to
/// a daemon that knows page ids).
pub fn page_relay_verdict(
    identity: &Identity,
    page: Option<&str>,
) -> Result<Option<String>, Verdict> {
    if identity.app != DAEMON_APP {
        return Err(Verdict::WrongApp(identity.app.clone()));
    }
    if identity.protocol != PROTOCOL_VERSION {
        return Err(Verdict::UnsupportedProtocol(identity.protocol));
    }
    if !identity.supports(ORIGIN_CLAIM) {
        return Err(Verdict::MissingCapabilities(vec![ORIGIN_CLAIM.to_string()]));
    }
    Ok(if identity.supports(PAGE_ROUTER) { page.map(str::to_string) } else { None })
}

/// The daemon serves owner machine metadata: ask `identify` again with it.
pub fn serves_machine_metadata(identity: &Identity) -> bool {
    identity.app == DAEMON_APP
        && identity.protocol == PROTOCOL_VERSION
        && identity.supports(MACHINE_IDENTITY)
}

/// The metadata reply belongs to the daemon that answered first: same app,
/// protocol, generation and session.
pub fn metadata_fenced(first: &Identity, enriched: &Identity) -> bool {
    enriched.app == first.app
        && enriched.protocol == first.protocol
        && enriched.generation == first.generation
        && enriched.session_id() == first.session_id()
}

/// What a connection echoes in `set-client-info`: what it advertises, then
/// `terminal-frontend-shell-integration-v1` when it resolves the shell
/// integration itself, then `placement-shift-v1` when this build orders rows
/// from the sidebar document and advertises it.
pub fn handshake_capabilities(
    advertised: &[String],
    resolves_shell_integration: bool,
    echoes_placement_shift: bool,
) -> Vec<String> {
    let mut echoed = advertised.to_vec();
    if resolves_shell_integration {
        echoed.push(TERMINAL_FRONTEND_SHELL_INTEGRATION.to_string());
    }
    if echoes_placement_shift && advertised.iter().any(|c| c == SIDEBAR_DOC) {
        echoed.push(PLACEMENT_SHIFT.to_string());
    }
    echoed
}
