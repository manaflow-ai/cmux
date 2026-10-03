//! Who is calling (plans/cmux-next/identity.md section 3, package P8).
//!
//! A caller never states its actor. A request may carry a launch credential
//! (the CLI copies `CMUX_LAUNCH_CREDENTIAL`); the service verifies it through
//! a `CredentialVerifier` and builds the stamp. The reducer authorizes the
//! principal derived from the stamp:
//!
//! | stamp | principal |
//! | --- | --- |
//! | `user` | that person (`user_local` is the machine's person) |
//! | `terminal` / `acp_session` with `agent` | that agent, working for the local person |
//! | `terminal` / `acp_session` without `agent` | the local person |
//! | `app` | its `on_behalf_of` person |

use cmux_tasks_core::ids::{AgentClass, AgentRef, Principal, is_valid_id, prefix};
use cmux_tasks_core::{Actor, actor::LOCAL_USER};

use crate::protocol::{ErrorBody, ErrorCode};

/// The authenticated caller of one request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    /// Who the reducer authorizes.
    pub principal: Principal,
    /// The P8 stamp recorded with the op.
    pub stamp: Actor,
}

impl Caller {
    /// The machine's person, stamped as the local user.
    pub fn person(principal: Principal) -> Self {
        Self { principal, stamp: Actor::local_user() }
    }
}

/// The result of checking one launch credential.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Valid: the session host built this stamp.
    Valid(Actor),
    /// The key id is unknown (dropped by rotation, or no verifier yet):
    /// the request falls back to the user, as if no credential was sent.
    UnknownKid,
    /// A bad MAC, a foreign host, or a closed terminal or ACP session.
    Invalid(String),
}

/// Verifies launch credentials with the session host (`credential.verify`).
pub trait CredentialVerifier: Send + Sync {
    fn verify(&self, credential: &str) -> Verdict;
}

/// The verifier until P8 ships `credential.verify`: every credential is an
/// unknown key id, so every request is stamped as the local user.
pub struct NoVerifier;

impl CredentialVerifier for NoVerifier {
    fn verify(&self, _credential: &str) -> Verdict {
        Verdict::UnknownKid
    }
}

/// Builds callers for one owner.
pub struct Identity {
    /// The machine's person (`usr_…`), the principal of `user_local`.
    person: Principal,
    verifier: Box<dyn CredentialVerifier>,
}

/// Longest credential accepted on the wire.
const MAX_CREDENTIAL: usize = 4096;

impl Identity {
    pub fn new(person: Principal, verifier: Box<dyn CredentialVerifier>) -> Self {
        Self { person, verifier }
    }

    /// The local person with no verifier (tests, and until P8 slice 3).
    pub fn local(person: Principal) -> Self {
        Self::new(person, Box::new(NoVerifier))
    }

    pub fn person(&self) -> &Principal {
        &self.person
    }

    /// The caller for a request with `credential` (or none).
    pub fn caller(&self, credential: Option<&str>) -> Result<Caller, ErrorBody> {
        let Some(credential) = credential else {
            return Ok(Caller::person(self.person.clone()));
        };
        if credential.is_empty() || credential.len() > MAX_CREDENTIAL {
            return Err(invalid("credential must be 1..=4096 bytes"));
        }
        match self.verifier.verify(credential) {
            // A launch credential names a terminal or an ACP session only.
            // `user` and `app` stamps never come from a caller (P8).
            Verdict::Valid(stamp @ (Actor::Terminal { .. } | Actor::AcpSession { .. })) => {
                self.caller_for(stamp)
            }
            Verdict::Valid(_) => {
                Err(invalid("a launch credential names a terminal or an ACP session"))
            }
            Verdict::UnknownKid => Ok(Caller::person(self.person.clone())),
            Verdict::Invalid(reason) => Err(invalid(reason)),
        }
    }

    /// The caller for a stamp the owner trusts (a verified credential, or
    /// the app supervisor's own connection).
    pub fn caller_for(&self, stamp: Actor) -> Result<Caller, ErrorBody> {
        if !stamp.is_well_formed() {
            return Err(invalid("malformed actor stamp"));
        }
        let principal = match &stamp {
            Actor::User { id } => self.person_for(id)?,
            Actor::Terminal { agent: None, .. } | Actor::AcpSession { agent: None, .. } => {
                self.person.clone()
            }
            Actor::Terminal { agent: Some(agent), .. }
            | Actor::AcpSession { agent: Some(agent), .. } => self.agent_for(agent)?,
            Actor::App { on_behalf_of, .. } => self.person_for(&on_behalf_of.id)?,
        };
        Ok(Caller { principal, stamp })
    }

    /// `user_local` is the machine's person; `usr_…` is itself; any other
    /// account id `x` maps to `usr_x` only when that is a valid id (refused,
    /// never rewritten). `x` and `usr_x` name the same person by design: the
    /// account id is the person.
    fn person_for(&self, user: &str) -> Result<Principal, ErrorBody> {
        if user == LOCAL_USER {
            return Ok(self.person.clone());
        }
        if is_valid_id(user, prefix::USER) {
            return Ok(Principal::user(user));
        }
        let id = format!("{}{user}", prefix::USER);
        if !is_valid_id(&id, prefix::USER) {
            return Err(invalid(format!("cannot map user {user:?} to a Tasks person")));
        }
        Ok(Principal::user(id))
    }

    /// A P8 agent principal (`agent_mux`, `agt_…`) as a Tasks agent working
    /// for the local person. Only the exact `mux` name is a mux (D20); a name
    /// that is not a valid id is refused, never rewritten. `agent_x` (P8) and
    /// `agt_x` (Tasks) are the two spellings of one agent by design.
    fn agent_for(&self, agent: &str) -> Result<Principal, ErrorBody> {
        // Only the prefixed P8 forms; a bare name would be a second spelling
        // of the same principal.
        let Some(name) = agent.strip_prefix(prefix::AGENT).or_else(|| agent.strip_prefix("agent_"))
        else {
            return Err(invalid(format!("agent {agent:?} needs the agent_ or agt_ prefix")));
        };
        let principal = format!("{}{name}", prefix::AGENT);
        if !is_valid_id(&principal, prefix::AGENT) {
            return Err(invalid(format!("cannot map agent {agent:?} to a Tasks agent")));
        }
        let class = if name == "mux" { AgentClass::Mux } else { AgentClass::Ordinary };
        Ok(Principal::Agent(AgentRef {
            principal,
            class,
            harness: "unknown".to_owned(),
            on_behalf_of: self.person.id().to_owned(),
        }))
    }
}

fn invalid(message: impl Into<String>) -> ErrorBody {
    ErrorBody::new(ErrorCode::CredentialInvalid, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tasks_core::UserActor;

    struct Fixed(Verdict);
    impl CredentialVerifier for Fixed {
        fn verify(&self, _credential: &str) -> Verdict {
            self.0.clone()
        }
    }

    fn identity(verdict: Verdict) -> Identity {
        Identity::new(Principal::user("usr_me"), Box::new(Fixed(verdict)))
    }

    #[test]
    fn no_credential_is_the_local_user() {
        let caller = identity(Verdict::UnknownKid).caller(None).unwrap();
        assert_eq!(caller, Caller::person(Principal::user("usr_me")));
    }

    #[test]
    fn an_unknown_kid_falls_back_to_the_user() {
        let caller = identity(Verdict::UnknownKid).caller(Some("cmuxlc1.x.y.z")).unwrap();
        assert_eq!(caller.stamp, Actor::local_user());
        assert_eq!(caller.principal, Principal::user("usr_me"));
    }

    #[test]
    fn an_invalid_credential_is_refused() {
        let err = identity(Verdict::Invalid("closed terminal".into()))
            .caller(Some("cmuxlc1.x.y.z"))
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::CredentialInvalid);
        let err = identity(Verdict::UnknownKid).caller(Some("")).unwrap_err();
        assert_eq!(err.code, ErrorCode::CredentialInvalid);
    }

    #[test]
    fn a_terminal_without_an_agent_acts_as_the_person() {
        let stamp = Actor::Terminal { id: "term_1".into(), host: "sess_h".into(), agent: None };
        let caller = identity(Verdict::Valid(stamp.clone())).caller(Some("c")).unwrap();
        assert_eq!(caller.principal, Principal::user("usr_me"));
        assert_eq!(caller.stamp, stamp);
    }

    #[test]
    fn an_agent_stamp_maps_to_a_tasks_agent() {
        let stamp = Actor::AcpSession {
            id: "acp_1".into(),
            host: "sess_h".into(),
            agent: Some("agent_mux".into()),
        };
        let caller = identity(Verdict::Valid(stamp)).caller(Some("c")).unwrap();
        assert!(caller.principal.is_mux());
        assert_eq!(caller.principal.id(), "agt_mux");
        assert_eq!(caller.principal.human(), "usr_me");
        let ordinary = Actor::Terminal {
            id: "t".into(),
            host: "h".into(),
            agent: Some("agt_claude-me".into()),
        };
        let caller = identity(Verdict::Valid(ordinary)).caller(Some("c")).unwrap();
        assert!(caller.principal.is_ordinary_agent());
        assert_eq!(caller.principal.id(), "agt_claude-me");
    }

    #[test]
    fn an_app_acts_for_its_person() {
        let stamp = Actor::App {
            id: "cmux/tasks".into(),
            host: "sess_h".into(),
            version: "1".into(),
            on_behalf_of: UserActor { id: LOCAL_USER.into() },
        };
        let caller = identity(Verdict::UnknownKid).caller_for(stamp).unwrap();
        assert_eq!(caller.principal, Principal::user("usr_me"));
    }

    #[test]
    fn account_user_ids_map_to_people() {
        let stamp = Actor::User { id: "user_42".into() };
        let caller = identity(Verdict::UnknownKid).caller_for(stamp).unwrap();
        assert_eq!(caller.principal, Principal::user("usr_user_42"));
        for bad in ["!!!", "User_42", "a.b"] {
            let err = identity(Verdict::UnknownKid)
                .caller_for(Actor::User { id: bad.into() })
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::CredentialInvalid, "{bad}");
        }
    }

    /// Review finding: a launch credential names a terminal or an ACP
    /// session; a verifier answer naming a user or an app is refused.
    #[test]
    fn a_credential_never_yields_a_user_or_app_stamp() {
        let app = Actor::App {
            id: "cmux/tasks".into(),
            host: "h".into(),
            version: "1".into(),
            on_behalf_of: UserActor { id: LOCAL_USER.into() },
        };
        for stamp in [app, Actor::User { id: "usr_other".into() }] {
            let err = identity(Verdict::Valid(stamp)).caller(Some("c")).unwrap_err();
            assert_eq!(err.code, ErrorCode::CredentialInvalid);
        }
    }

    /// Review finding: only the exact mux name is a mux, and agent names are
    /// refused instead of rewritten (no two agents share a principal).
    #[test]
    fn only_the_exact_mux_name_is_a_mux() {
        let agent_stamp = |agent: &str| Actor::Terminal {
            id: "t".into(),
            host: "h".into(),
            agent: Some(agent.into()),
        };
        let mapped = |agent: &str| {
            identity(Verdict::UnknownKid).caller_for(agent_stamp(agent)).map(|c| c.principal)
        };
        assert!(mapped("agent_mux").unwrap().is_mux());
        assert!(mapped("agt_mux").unwrap().is_mux());
        assert!(mapped("agent_mux-helper").unwrap().is_ordinary_agent());
        for bad in ["AGT_Mux!", "agt_a.b", "agent_", "mux", "claude"] {
            assert_eq!(mapped(bad).unwrap_err().code, ErrorCode::CredentialInvalid, "{bad}");
        }
    }
}
