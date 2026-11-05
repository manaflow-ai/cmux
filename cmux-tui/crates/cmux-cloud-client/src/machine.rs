//! A Cloud machine as a handle, not a bare id (cmuxterm-hq
//! `plans/cloud/ARCHITECTURE-2026-11.lens-review-2026-11-05.md`, finding 2).
//!
//! A `vm_` id names a machine but not the backend that owns it, so an id read
//! from one backend and sent to another answers "not found" for a machine
//! that still exists (the plan's section 1.4, the classic/app-server split).
//! A runtime backend picker would bring that failure back. So, as in a
//! capability system (Cap'n Proto RPC: a reference "both designates an object
//! to call and confers permission to call it"; Miller, *Capability Myths
//! Demolished*, on confused deputies), a [`Machine`] carries the [`Scope`] it
//! was named under: the backend origin and the team its credential acts for.
//!
//! A caller never re-resolves the backend for a machine. It asks the scope it
//! holds for the machine's route ([`Scope::route`]), and a handle from another
//! backend or team is refused before anything is sent ([`Foreign`]). The
//! bearer itself never goes into a handle: a saved handle (a chat pin) holds
//! where the machine lives and for whom, not the secret.

use serde::{Deserialize, Serialize};

/// The authority a credential acts with: one backend origin and, for a
/// person's session, the team it acts for (install and `cmm_` machine
/// credentials already belong to one team, so they carry none).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "ScopeFields", into = "ScopeFields")]
pub struct Scope {
    origin: String,
    team: Option<String>,
}

/// One Cloud machine: its id and the [`Scope`] it was named under.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "MachineFields", into = "MachineFields")]
pub struct Machine {
    scope: Scope,
    id: String,
}

/// Why a scope or a machine handle could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandleError {
    /// The origin is not a bare `https://` origin (or `http://` to this machine).
    Origin,
    /// The team id is empty or not a plain id.
    Team,
    /// The machine id is not a `vm_` id.
    MachineId,
}

impl std::fmt::Display for HandleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            // Never echoes the value: a secret could have been pasted into it.
            Self::Origin => "the Cloud origin must be a bare https origin (http only to this machine)",
            Self::Team => "the team id is not a plain id",
            Self::MachineId => "the machine id is not a Cloud machine id (vm_…)",
        })
    }
}

impl std::error::Error for HandleError {}

/// A machine handle sent to a scope that did not name it: nothing was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Foreign {
    pub machine: Machine,
    pub scope: Scope,
}

impl std::fmt::Display for Foreign {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "machine {} belongs to {}, not {}: nothing was sent",
            self.machine.id, self.machine.scope, self.scope
        )
    }
}

impl std::error::Error for Foreign {}

impl Scope {
    /// The scope of a credential sent to `origin` (as a team member of `team`).
    /// The origin is normalized (`https://Host:443/` is `https://host`), so two
    /// spellings of one backend are one scope.
    pub fn new(origin: &str, team: Option<&str>) -> Result<Self, HandleError> {
        let origin = bare_origin(origin.trim()).ok_or(HandleError::Origin)?;
        let team = match team.map(str::trim) {
            None => None,
            Some(team) if plain_id(team) => Some(team.to_owned()),
            Some(_) => return Err(HandleError::Team),
        };
        Ok(Self { origin, team })
    }

    /// The backend origin, with no trailing slash.
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// The team the credential acts for, if it names one.
    pub fn team(&self) -> Option<&str> {
        self.team.as_deref()
    }

    /// The machine `id` in this scope: a machine this scope's backend answered,
    /// or one a person named for it.
    pub fn machine(&self, id: &str) -> Result<Machine, HandleError> {
        if !machine_id(id) {
            return Err(HandleError::MachineId);
        }
        Ok(Machine { scope: self.clone(), id: id.to_owned() })
    }

    /// `machine`'s id when this scope named it; otherwise [`Foreign`], before
    /// anything is sent.
    pub fn id_of<'m>(&self, machine: &'m Machine) -> Result<&'m str, Foreign> {
        if machine.scope == *self {
            Ok(&machine.id)
        } else {
            Err(Foreign { machine: machine.clone(), scope: self.clone() })
        }
    }

    /// The URL of `machine`'s route `/v1/cloud/machines/{id}{rest}` on this
    /// scope's backend, or [`Foreign`] for a machine another scope named.
    pub fn route(&self, machine: &Machine, rest: &str) -> Result<String, Foreign> {
        let id = self.id_of(machine)?;
        Ok(format!("{}/v1/cloud/machines/{id}{rest}", self.origin))
    }

    /// A generated [`crate::Client`] for this scope with `bearer` (the team
    /// header comes from the scope, so the two cannot disagree).
    pub fn client(&self, bearer: &str, user_agent: &str) -> Result<crate::Client, crate::BuildError> {
        crate::client(&self.origin, bearer, self.team(), user_agent)
    }
}

impl std::fmt::Display for Scope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.team {
            Some(team) => write!(f, "{} (team {team})", self.origin),
            None => f.write_str(&self.origin),
        }
    }
}

impl Machine {
    /// The machine's `vm_` id.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The scope that named this machine.
    pub fn scope(&self) -> &Scope {
        &self.scope
    }
}

impl std::fmt::Display for Machine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} on {}", self.id, self.scope)
    }
}

/// A `vm_` id: `vm_` and up to 64 lowercase letters, digits, `-` or `_`.
pub fn machine_id(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|tail| {
        !tail.is_empty()
            && tail.len() <= 64
            && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
    })
}

fn plain_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// `https://host[:port]`, or `http://` only to this machine; no user, path,
/// query or fragment.
fn bare_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw).ok()?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let scheme_ok = url.scheme() == "https" || (url.scheme() == "http" && local);
    let bare = url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    (scheme_ok && bare).then(|| url.origin().ascii_serialization())
}

// The saved forms go through the same checks as `Scope::new` and
// `Scope::machine`, so a hand-edited pin cannot carry an unchecked origin.

#[derive(Serialize, Deserialize)]
struct ScopeFields {
    origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    team: Option<String>,
}

impl TryFrom<ScopeFields> for Scope {
    type Error = HandleError;
    fn try_from(fields: ScopeFields) -> Result<Self, HandleError> {
        Scope::new(&fields.origin, fields.team.as_deref())
    }
}

impl From<Scope> for ScopeFields {
    fn from(scope: Scope) -> Self {
        ScopeFields { origin: scope.origin, team: scope.team }
    }
}

#[derive(Serialize, Deserialize)]
struct MachineFields {
    id: String,
    origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    team: Option<String>,
}

impl TryFrom<MachineFields> for Machine {
    type Error = HandleError;
    fn try_from(fields: MachineFields) -> Result<Self, HandleError> {
        Scope::new(&fields.origin, fields.team.as_deref())?.machine(&fields.id)
    }
}

impl From<Machine> for MachineFields {
    fn from(machine: Machine) -> Self {
        MachineFields { id: machine.id, origin: machine.scope.origin, team: machine.scope.team }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::Backend;

    const VM: &str = "vm_abcdefghij0123456789";

    fn prod(team: Option<&str>) -> Scope {
        Scope::new(Backend::Production.owner_api(), team).expect("prod scope")
    }

    #[test]
    fn a_machine_named_on_one_backend_is_refused_by_another_before_sending() {
        let machine = prod(Some("team_a")).machine(VM).expect("handle");
        let dev = Scope::new(Backend::Development.owner_api(), Some("team_a")).expect("dev scope");
        let refused = dev.route(&machine, "/exec").expect_err("another backend");
        assert_eq!(refused.machine, machine);
        assert!(refused.to_string().contains("nothing was sent"));
    }

    #[test]
    fn a_machine_named_for_one_team_is_refused_for_another() {
        let machine = prod(Some("team_a")).machine(VM).expect("handle");
        assert!(prod(Some("team_b")).id_of(&machine).is_err());
        assert!(prod(None).id_of(&machine).is_err());
    }

    #[test]
    fn its_own_scope_routes_it_on_its_backend() {
        let scope = prod(Some("team_a"));
        let machine = scope.machine(VM).expect("handle");
        assert_eq!(
            scope.route(&machine, "/client-session").expect("own scope"),
            format!("{}/v1/cloud/machines/{VM}/client-session", Backend::Production.owner_api())
        );
    }

    #[test]
    fn two_spellings_of_one_origin_are_one_scope() {
        let a = Scope::new("https://Cloud-API.cmux.dev:443/", None).expect("a");
        let b = Scope::new("https://cloud-api.cmux.dev", None).expect("b");
        assert_eq!(a, b);
        assert_eq!(a.origin(), "https://cloud-api.cmux.dev");
    }

    #[test]
    fn only_bare_secure_origins_make_a_scope() {
        for bad in [
            "http://cloud-api.cmux.dev",
            "https://user:pw@cloud-api.cmux.dev",
            "https://cloud-api.cmux.dev/v1",
            "https://cloud-api.cmux.dev?x=1",
            "cloud-api.cmux.dev",
            "",
        ] {
            assert_eq!(Scope::new(bad, None), Err(HandleError::Origin), "{bad}");
        }
        assert!(Scope::new("http://127.0.0.1:8787", None).is_ok());
        assert_eq!(Scope::new("https://x.example", Some("a b")), Err(HandleError::Team));
        assert_eq!(prod(None).machine("vm_ABC"), Err(HandleError::MachineId));
        assert_eq!(prod(None).machine("../x"), Err(HandleError::MachineId));
    }

    #[test]
    fn a_saved_handle_reads_back_as_the_same_machine_and_is_checked_on_read() {
        let machine = prod(Some("team_a")).machine(VM).expect("handle");
        let saved = serde_json::to_value(&machine).expect("save");
        assert_eq!(
            saved,
            serde_json::json!({ "id": VM, "origin": Backend::Production.owner_api(), "team": "team_a" })
        );
        let back: Machine = serde_json::from_value(saved).expect("read");
        assert_eq!(back, machine);
        let tampered = serde_json::json!({ "id": VM, "origin": "http://evil.example" });
        assert!(serde_json::from_value::<Machine>(tampered).is_err());
    }
}
