//! The app's Cloud send as a hybrid start (the GUI half of [`crate::hybrid`]): the composer's
//! Send with Cloud picked runs the chat's first turn on this Mac while its Cloud machine boots,
//! then the chat moves there with the app's own Move (fenced since cmux#55785, so a prompt the
//! Mac already ran gets no second model call). Until now only `cmux chat --on cloud` did this
//! (cmux-tui `cli/chat_start/hybrid_start.rs`); the app's Send only started the agent on the VM
//! (Leo, 2026-11-25: "the agent that starts up is just the cloud vm that we did right?").
//!
//! [`decide`] is the whole decision; the app reads the account, the send's shape and this Mac's
//! acpmux harness catalog, asks here, and on `here` answers the page `run_on_this_mac` (the page
//! sends the prompt to a chat on this Mac in the same tab) and, once that chat has a session,
//! runs `cmux cloud hybrid-begin SESSION new` (the CLI's own driver: machine, then Move).
//!
//! On by default for every account [`hybrid::enabled`] takes. Kill switches: `CMUX_HYBRID_START=0`
//! (every hybrid start) or `CMUX_GUI_HYBRID_START=0` (the app's only), read by the FFI. Probe: the
//! app logs [`Decision::probe`], one line per Cloud send, `cloud hybrid gui start: here` or
//! `... off <reason>`.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::hybrid::{self, Account, Off};

/// The probe line's prefix, one per Cloud send.
pub const PROBE: &str = "cloud hybrid gui start: ";
/// The app-only kill switch's env name (`0`, `false`, `off`, `no` turn it off).
pub const GUI_ENV: &str = "CMUX_GUI_HYBRID_START";
/// Every hybrid start's kill switch (the CLI's too).
pub const ENV: &str = "CMUX_HYBRID_START";

/// What the app knows of its Cloud send.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Send {
    pub account: Account,
    /// The send's folder is one a Move can carry (not home, not too broad, present).
    pub folder: bool,
    /// The send clones a repository on the machine.
    pub repository: bool,
    /// The send switches team first.
    pub team: bool,
    /// The send repicks Cloud for a chat that already ran.
    pub replaces_chat: bool,
    /// The send names a Cloud environment.
    pub environment: bool,
    /// The harness the send names, else this Mac's default.
    pub harness: Option<String>,
    /// This Mac's acpmux `_acpmux/harnesses` answer; None: it could not be asked.
    pub catalog: Option<Value>,
    /// A kill switch said off (the FFI reads [`ENV`] and [`GUI_ENV`]).
    pub killed: bool,
}

/// Why the app's Cloud send is not hybrid, beyond [`Off`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Skip {
    KillSwitch,
    /// No folder a Move carries: the chat would start in an odd place here.
    NoFolder,
    Repository,
    Team,
    Repick,
    Environment,
    NoCloud,
    Flag,
    Plan,
    NoLocalHarness,
}

impl From<Off> for Skip {
    fn from(off: Off) -> Self {
        match off {
            Off::NoCloud => Self::NoCloud,
            Off::Flag => Self::Flag,
            Off::Plan => Self::Plan,
            Off::NoLocalHarness => Self::NoLocalHarness,
        }
    }
}

/// The answer: run here first (`here`), else why not; `probe` is the line the app logs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub here: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub off: Option<Skip>,
    pub probe: String,
}

/// Whether a kill switch's value says off.
pub fn says_off(value: Option<&str>) -> bool {
    value.is_some_and(|value| {
        matches!(value.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off" | "no")
    })
}

/// The app's Cloud send: here first, or the Cloud start as before.
pub fn decide(send: &Send) -> Decision {
    let skip = if send.killed {
        Some(Skip::KillSwitch)
    } else if send.replaces_chat {
        Some(Skip::Repick)
    } else if send.team {
        Some(Skip::Team)
    } else if send.repository {
        Some(Skip::Repository)
    } else if send.environment {
        Some(Skip::Environment)
    } else if !send.folder {
        Some(Skip::NoFolder)
    } else {
        hybrid::enabled(&send.account)
            .and(local_harness(send.catalog.as_ref(), send.harness.as_deref()))
            .err()
            .map(Skip::from)
    };
    let probe = match skip {
        None => format!("{PROBE}here"),
        Some(skip) => {
            let reason = serde_json::to_value(skip)
                .ok()
                .and_then(|value| value.as_str().map(str::to_owned))
                .unwrap_or_default();
            format!("{PROBE}off {reason}")
        }
    };
    Decision { here: skip.is_none(), off: skip, probe }
}

/// Whether this machine's acpmux can start the chat's agent, from its `_acpmux/harnesses`
/// answer (`catalog`; None: it could not be asked): the harness the start names, else its
/// `defaultHarness`, resolved as acpmux's `session/new` resolves it (a profile, else a family's
/// `prefer`, its only profile or the profile named like it), and not `unavailable`.
/// `Err(NoLocalHarness)`: the chat could not run here, so the Cloud start runs as before.
pub fn local_harness(catalog: Option<&Value>, named: Option<&str>) -> Result<(), Off> {
    let catalog = catalog.ok_or(Off::NoLocalHarness)?;
    let head = named
        .or_else(|| catalog.get("defaultHarness").and_then(Value::as_str))
        .ok_or(Off::NoLocalHarness)?;
    let harnesses = catalog.get("harnesses").and_then(Value::as_object);
    let usable = |name: &str| {
        harnesses
            .and_then(|rows| rows.get(name))
            .is_some_and(|row| row.get("unavailable").is_none_or(Value::is_null))
    };
    let names = |value: Option<&Value>| -> Vec<String> {
        value
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default()
    };
    let members = names(catalog.pointer(&format!("/families/{}", escape(head))));
    let resolved = if members.is_empty() {
        usable(head)
    } else {
        let prefer = names(catalog.pointer(&format!("/defaults/{}/prefer", escape(head))));
        prefer.iter().any(|name| members.contains(name) && usable(name))
            || (members.len() == 1 && members.first().is_some_and(|only| usable(only)))
            || (members.iter().any(|name| name == head) && usable(head))
    };
    if resolved { Ok(()) } else { Err(Off::NoLocalHarness) }
}

/// `name` as one JSON pointer token.
fn escape(name: &str) -> String {
    name.replace('~', "~0").replace('/', "~1")
}

/// The header the Worker's InferenceGateway dedupes on (cmux-platform#2074): one upstream call
/// per key, so the Mac, the agent VM and the gateway can race a turn's model call and it is
/// billed once.
pub const CALL_KEY_HEADER: &str = "x-cmux-call-key";

/// The key of one model call: `hash(chat_id, turn_id, call_seq)` (RFD agent-vm-work-vm-trilink),
/// SHA-256 over the three fields each length-prefixed, lowercase hex (64 characters, under the
/// gateway's 256). Every path that runs the call computes the same key from the same three.
pub fn call_key(chat_id: &str, turn_id: &str, call_seq: u64) -> String {
    let mut hash = Sha256::new();
    for field in [chat_id.as_bytes(), turn_id.as_bytes(), &call_seq.to_be_bytes()] {
        hash.update((field.len() as u64).to_be_bytes());
        hash.update(field);
    }
    hex::encode(hash.finalize())
}

#[cfg(test)]
#[path = "hybrid_gui_tests.rs"]
mod tests;
