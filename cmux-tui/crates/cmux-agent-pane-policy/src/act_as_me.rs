//! "Computer use can act as me": an explicit, revocable grant on the person
//! gate (Swift `AgentPaneActAsMe`, `AgentPanePersonInput`). Off by default.
//! While it is on, input another process posts (cua-driver, CGEventPost)
//! counts as the person's for Send and Retry (`session/prompt`) and Approve
//! (`_acpmux/queue_approve`), `policy.json` `act_as_me_covers`, and for
//! nothing wider: a permission answer, a mode, a trust grant, a folder, a new
//! chat on another machine still need the person's own key press or click.
//!
//! Who may turn it on ([`GrantSource`]):
//! - the person's own click on Allow in the app's consent card, read by the
//!   app's strict check (HID input: source pid 0 or the WindowServer, the
//!   HID source state), never the button's action, so no posted click, key,
//!   Accessibility press or DEBUG automation reaches it;
//! - a forced (MDM) `ComputerUseActsAsPerson` in `com.manaflow.cmux`, which
//!   only an administrator's profile installs.
//!
//! Nothing an agent can reach turns it on: an RPC, the CLI, MCP, a page
//! frame, `defaults write` (a value that is not forced) or a config file.
//! Turning it off needs no proof, so revoking is always one click away; it
//! also holds a managed grant off until the app starts again.
//!
//! The host keeps the state (its own Keychain item for the person's grant)
//! and logs every let-through with [`let_through_record`].

use crate::data::policy;
use crate::frame::contains;
use serde_json::{Value, json};

/// Where a request to turn the grant on came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrantSource {
    /// The person's own click on the consent card's Allow (the strict check).
    PersonClick,
    /// A forced managed preference (an administrator's profile).
    ManagedProfile,
    /// A click or key another process posted on the card.
    PostedInput,
    /// A daemon or control-socket RPC.
    Rpc,
    /// A `cmux` command line.
    Cli,
    /// An MCP tool.
    Mcp,
    /// A frame from a page (the agent pane, Settings).
    Page,
    /// A value in the app's defaults that is not forced (`defaults write`).
    Defaults,
    /// A config file (`cmux.json`, a settings key).
    ConfigFile,
}

impl GrantSource {
    /// The sources that may turn the grant on: the person's click and an
    /// administrator's profile, and no other.
    pub fn may_grant(self) -> bool {
        matches!(self, GrantSource::PersonClick | GrantSource::ManagedProfile)
    }

    pub fn name(self) -> &'static str {
        match self {
            GrantSource::PersonClick => "person_click",
            GrantSource::ManagedProfile => "managed_profile",
            GrantSource::PostedInput => "posted_input",
            GrantSource::Rpc => "rpc",
            GrantSource::Cli => "cli",
            GrantSource::Mcp => "mcp",
            GrantSource::Page => "page",
            GrantSource::Defaults => "defaults",
            GrantSource::ConfigFile => "config_file",
        }
    }
}

/// Who holds the grant while it is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Holder {
    Person,
    Managed,
}

impl Holder {
    pub fn name(self) -> &'static str {
        match self {
            Holder::Person => "person",
            Holder::Managed => "managed",
        }
    }
}

/// A refused turn-on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GrantRefused {
    pub source: GrantSource,
}

impl GrantRefused {
    pub fn message(self) -> String {
        format!(
            "only your own click in cmux's consent card turns on Computer use can act as me (refused: {})",
            self.source.name()
        )
    }
}

/// The grant's state. [`Default`] is off.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ActAsMe {
    person: bool,
    managed: bool,
    /// The person turned a managed grant off for this run of the app.
    managed_held_off: bool,
}

impl ActAsMe {
    /// Turns the grant on for `source`; refused for every source but the
    /// person's click and a managed profile, and the state is unchanged.
    pub fn turn_on(&mut self, source: GrantSource) -> Result<Holder, GrantRefused> {
        match source {
            GrantSource::PersonClick => {
                self.person = true;
                self.managed_held_off = false;
                Ok(Holder::Person)
            }
            GrantSource::ManagedProfile => {
                self.managed = true;
                Ok(Holder::Managed)
            }
            other => Err(GrantRefused { source: other }),
        }
    }

    /// The managed profile was removed (or its value is no longer forced).
    pub fn managed_removed(&mut self) {
        self.managed = false;
    }

    /// Turns the grant off, from any source: no proof is needed to revoke.
    /// A managed grant stays off until the app starts again.
    pub fn turn_off(&mut self) {
        self.person = false;
        if self.managed {
            self.managed_held_off = true;
        }
    }

    pub fn holder(self) -> Option<Holder> {
        if self.person {
            Some(Holder::Person)
        } else if self.managed && !self.managed_held_off {
            Some(Holder::Managed)
        } else {
            None
        }
    }

    pub fn is_on(self) -> bool {
        self.holder().is_some()
    }
}

/// Whether the grant covers a frame of `method` (Send, Retry, Approve).
pub fn covers(method: &str) -> bool {
    contains(&policy().act_as_me_covers, method)
}

/// How a gesture-needing frame is judged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// The person's own input: the gesture rules as always.
    Person,
    /// Posted input that the grant lets through as the person's: log it.
    ActsAsPerson(Holder),
    /// Posted input that grants nothing.
    Refused,
}

/// The verdict for a frame of `method` backed by input that is the person's
/// (`person`) or another process's.
pub fn decide(state: ActAsMe, method: &str, person: bool) -> Verdict {
    if person {
        return Verdict::Person;
    }
    match state.holder() {
        Some(holder) if covers(method) => Verdict::ActsAsPerson(holder),
        _ => Verdict::Refused,
    }
}

/// The process that posted the input a let-through used.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Driver {
    pub pid: Option<i64>,
    pub path: Option<String>,
    pub bundle_id: Option<String>,
    pub cua_session: Option<String>,
}

/// The log record of one let-through: the action, who holds the grant, and
/// the driver's identity (unknown fields are `null`, never left out).
pub fn let_through_record(method: &str, holder: Holder, driver: &Driver) -> Value {
    json!({
        "event": "act_as_me.let_through",
        "method": method,
        "holder": holder.name(),
        "driver": {
            "pid": driver.pid,
            "path": driver.path,
            "bundleId": driver.bundle_id,
            "cuaSession": driver.cua_session,
        },
    })
}
