//! Who may open a remote desktop session on a host (remote-desktop.md
//! section 11). Default deny: hosting must be on, the principal must come
//! from an authenticated `hello`, agents never get control, and anyone other
//! than the owner from their own interactive client needs a grant. Live
//! consent at the host is required unless an unattended grant covers the
//! viewer.

/// The class of a principal (identity-and-permissions.md section 4a).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PrincipalClass {
    /// A person from one of their clients.
    User,
    /// A user's orchestrator agent.
    Mux,
    /// An ordinary agent (terminal agent, ACP subagent, MCP client).
    Agent,
    /// An automation run.
    Run,
}

/// The authenticated caller, taken from the link's `hello`, never from the request.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Principal {
    pub user: String,
    pub install: String,
    pub class: PrincipalClass,
    /// The request comes from the user's own interactive client (not a script).
    pub interactive: bool,
}

/// What a session may do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Mode {
    View,
    Control,
}

/// A standing permission the host's owner created on the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub id: String,
    pub user: String,
    /// The most the grant allows; a control grant also allows view.
    pub mode: Mode,
    /// Sessions under this grant need no live consent.
    pub unattended: bool,
    /// Milliseconds since the epoch; `None` never expires (owner only).
    pub expires_at_ms: Option<u64>,
}

/// When the host asks the person at the console.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsentRule {
    /// Ask when someone other than the viewer is logged in at the console.
    AskOthers,
    /// Ask for every session.
    AskAlways,
}

/// The host's desktop policy (owned by the host engine).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostPolicy {
    pub enabled: bool,
    pub owner_user: String,
    pub grants: Vec<Grant>,
    pub consent: ConsentRule,
    /// Team policy may forbid unattended grants.
    pub unattended_allowed: bool,
}

/// Why a session is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Deny {
    /// No authenticated principal (no valid `hello`).
    NoPrincipal,
    HostingDisabled,
    /// Agents and automation runs never use remote desktop.
    AgentClass,
    /// A mux principal may only open a view-only pane for its own user.
    AgentControl,
    /// The principal is not the host's owner and has no grant.
    NoGrant,
    /// The only matching grant expired.
    GrantExpired,
    /// Consent is required but nobody is at the console to give it.
    ConsentUnavailable,
    /// The caller is not the viewer of that session.
    NotYourSession,
    /// The session does not exist or has ended.
    NoSession,
    /// The person at the host refused.
    ConsentDenied,
    /// A mux opened the pane but named no interactive client of its user to
    /// receive the stream (a mux never receives frames itself).
    NoViewerClient,
    /// An idempotency key was replayed with different parameters.
    KeyReused,
    /// The session skipped consent under an unattended grant that no longer applies.
    UnattendedRevoked,
}

/// The policy decision for a session request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admission {
    Allow {
        needs_consent: bool,
        /// The grant that allowed it, when the viewer is not the owner.
        via_grant: Option<String>,
        /// Consent was waived by an unattended grant.
        unattended: bool,
    },
    Deny(Deny),
}

/// The checks that do not depend on the console: hosting, class and grant.
/// Returns the grant that allows `mode` (`None` for the owner's own access)
/// and whether that grant waives consent.
fn standing<'a>(
    policy: &'a HostPolicy,
    principal: &Principal,
    mode: Mode,
    now_ms: u64,
) -> Result<(Option<&'a Grant>, bool), Deny> {
    if !policy.enabled {
        return Err(Deny::HostingDisabled);
    }
    let is_owner = principal.user == policy.owner_user;
    match principal.class {
        PrincipalClass::Agent | PrincipalClass::Run => return Err(Deny::AgentClass),
        PrincipalClass::Mux => {
            if mode == Mode::Control {
                return Err(Deny::AgentControl);
            }
            if !is_owner {
                return Err(Deny::NoGrant);
            }
        }
        PrincipalClass::User => {}
    }
    let owner_direct =
        is_owner && (principal.interactive || principal.class == PrincipalClass::Mux);
    let grant = match live_grant(policy, &principal.user, mode, now_ms) {
        Ok(g) => Some(g),
        // The owner needs no grant; an unattended grant only removes the consent step.
        Err(_) if owner_direct => None,
        Err(deny) => return Err(deny),
    };
    let unattended = grant.is_some_and(|g| g.unattended && policy.unattended_allowed);
    Ok((if owner_direct { grant.filter(|g| g.unattended) } else { grant }, unattended))
}

/// Decides a session request. `console_user` is the user logged in at the
/// host's console (`None` on a headless host).
pub fn admit(
    policy: &HostPolicy,
    principal: Option<&Principal>,
    mode: Mode,
    console_user: Option<&str>,
    now_ms: u64,
) -> Admission {
    let Some(principal) = principal else { return Admission::Deny(Deny::NoPrincipal) };
    let (grant, unattended) = match standing(policy, principal, mode, now_ms) {
        Ok(v) => v,
        Err(deny) => return Admission::Deny(deny),
    };
    let someone_else_at_console = console_user.is_some_and(|u| u != principal.user);
    let wants_consent = someone_else_at_console || policy.consent == ConsentRule::AskAlways;
    let needs_consent = wants_consent && !unattended;
    if needs_consent && console_user.is_none() {
        return Admission::Deny(Deny::ConsentUnavailable);
    }
    Admission::Allow {
        needs_consent,
        via_grant: grant.map(|g| g.id.clone()),
        unattended: wants_consent && unattended,
    }
}

/// Re-checks a live session after a policy change or at a grant expiry.
/// Consent already given stays valid; a session that skipped consent under
/// an unattended grant ends when that grant no longer waives it.
pub fn still_allowed(
    policy: &HostPolicy,
    principal: &Principal,
    mode: Mode,
    used_unattended: bool,
    now_ms: u64,
) -> Result<Option<String>, Deny> {
    let (grant, unattended) = standing(policy, principal, mode, now_ms)?;
    if used_unattended && !unattended {
        return Err(Deny::UnattendedRevoked);
    }
    Ok(grant.map(|g| g.id.clone()))
}

/// The earliest future grant expiry, for the engine's one-shot timer.
pub fn next_expiry_ms(policy: &HostPolicy, now_ms: u64) -> Option<u64> {
    policy.grants.iter().filter_map(|g| g.expires_at_ms).filter(|&t| t > now_ms).min()
}

fn live_grant<'a>(
    policy: &'a HostPolicy,
    user: &str,
    mode: Mode,
    now_ms: u64,
) -> Result<&'a Grant, Deny> {
    let mut expired = false;
    for g in policy.grants.iter().filter(|g| g.user == user && g.mode >= mode) {
        let is_owner = g.user == policy.owner_user;
        match g.expires_at_ms {
            Some(t) if t <= now_ms => expired = true,
            // Grants to other people must expire (remote-desktop.md section 11).
            None if !is_owner => expired = true,
            _ => return Ok(g),
        }
    }
    Err(if expired { Deny::GrantExpired } else { Deny::NoGrant })
}
