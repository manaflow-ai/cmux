//! CALLER-LOCALITY (a9, 2026-10-04): where a caller is, from the transport
//! only, never from a request field or claim. A call on the host's local
//! 0600 Unix socket or the in-process provider link is `Local`; a call
//! forwarded by the daemon's remote relay (cmux link) carries the
//! authenticated principal from the link hello and is `Remote`. Today the
//! browser.* remote relay is off, so every caller is `Local`.
//!
//! `RequestOrigin` (cmux-tui-core) is a trust level, not a place; the
//! `origin` field of `Caller` is neither.

/// The principal class of a remote link (cmux-rd-core policy.rs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrincipalClass {
    User,
    Mux,
    Agent,
    Run,
}

/// The authenticated principal of a remote link's hello.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePrincipal {
    pub user: String,
    pub install: String,
    pub class: PrincipalClass,
    pub interactive: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum CallerLocality {
    /// The host's own socket or the in-process provider link.
    #[default]
    Local,
    /// Forwarded by the remote relay, as this principal.
    Remote { principal: RemotePrincipal },
}

impl CallerLocality {
    /// FETCH-PRIVATE-RANGES: whether loopback and private ranges are refused
    /// to this caller (link-local and metadata are refused to everyone).
    pub fn refuses_private_ranges(&self) -> bool {
        match self {
            CallerLocality::Local => false,
            CallerLocality::Remote { principal } => !remote_may_reach_private(principal),
        }
    }
}

/// The single hook for D20: a later owner policy may let a remote caller of
/// class Mux of the same user reach private ranges. Today none may.
fn remote_may_reach_private(principal: &RemotePrincipal) -> bool {
    let _ = principal;
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_remote_callers_are_refused_private_ranges() {
        assert!(!CallerLocality::Local.refuses_private_ranges());
        for class in
            [PrincipalClass::User, PrincipalClass::Mux, PrincipalClass::Agent, PrincipalClass::Run]
        {
            let remote = CallerLocality::Remote {
                principal: RemotePrincipal {
                    user: "u".into(),
                    install: "i".into(),
                    class,
                    interactive: true,
                },
            };
            assert!(remote.refuses_private_ranges(), "{class:?}");
        }
    }
}
