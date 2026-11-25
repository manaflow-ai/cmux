//! A hybrid start's tool calls while its Cloud machine boots: held, then run on the machine
//! (Leo, 2026-11-23: "you're not even interrupting them. You're just giving them a sort of
//! extended wait ... It's like an extended tool call. It's like you don't even add an additional
//! tool call almost. It's like boom, you just instantly resume").
//!
//! The chat answers here at once ([`crate::hybrid`]); until this change its tool calls ran here
//! too, in the start's fresh empty folder, until the move. Now acpmux's PreToolUse gate asks
//! [`route`] for each call of a chat whose driver tagged it ([`STAGE_TAG`], [`MACHINE_TAG`]):
//!
//! | stage | read, edit, search, execute, other | fetch, think |
//! | --- | --- | --- |
//! | no tag, `none` | here (not a hybrid start) | here |
//! | `booting`, held < [`HOLD_DEADLINE_MS`] | hold | here |
//! | `booting`, held >= [`HOLD_DEADLINE_MS`] | here, `machine-not-ready` | here |
//! | `ready`, `moving` | execute: on the machine; else here, `no-file-route` | here |
//! | `live` | here (the chat already runs there) | here |
//! | `failed` | here, `machine-failed` | here |
//!
//! A held call is the same call, longer: the gate answers it once, when the hold ends, so the
//! agent sees no extra call and none run twice. The hold ends on the tag's change (the driver's
//! machine-ready event), never on a sleep; the deadline is the existing path, the call running
//! here as before, with its reason. Pure: the caller reads the tags and the clock.

use serde::{Deserialize, Serialize};

use crate::hybrid::Cloud;

/// The acpmux session tag the hybrid driver keeps at its [`Cloud`] stage (kebab-case).
pub const STAGE_TAG: &str = "cmux.hybridStart";
/// The acpmux session tag with the machine's id, once it is known.
pub const MACHINE_TAG: &str = "cmux.hybridMachine";
/// How long one call is held at most: under Claude Code's gate timeout (600 s), past which the
/// call would not run at all.
pub const HOLD_DEADLINE_MS: u64 = 5 * 60 * 1000;

/// The reason of a call that runs here because the chat is not a hybrid start.
pub const NOT_HYBRID: &str = "not-hybrid";
pub const MACHINE_NOT_READY: &str = "machine-not-ready";
pub const NO_FILE_ROUTE: &str = "no-file-route";
pub const NO_MACHINE_ID: &str = "no-machine-id";
pub const RUNS_ANYWHERE: &str = "runs-anywhere";
pub const MACHINE_FAILED: &str = "machine-failed";
pub const CHAT_ON_MACHINE: &str = "chat-on-machine";

/// What the gate does with one tool call.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "route", rename_all = "kebab-case", rename_all_fields = "camelCase")]
pub enum Route {
    /// Keep the call waiting; ask again when the stage changes.
    Hold,
    /// Run it on `machine` (`execute` only: [`on_machine_command`]).
    OnMachine { machine: String },
    /// Run it here, as before this change, for `reason`.
    Here { reason: String },
}

/// The boot facts the driver's tags carry.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Boot<'a> {
    /// [`STAGE_TAG`]'s stage; None: no tag (not a hybrid start).
    pub stage: Option<Cloud>,
    /// [`MACHINE_TAG`]'s id.
    pub machine: Option<&'a str>,
}

/// The pending call: its ACP kind and how long it has been held.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Call<'a> {
    pub kind: &'a str,
    pub held_ms: u64,
}

fn here(reason: &str) -> Route {
    Route::Here { reason: reason.to_owned() }
}

/// What the gate does with `call` under `boot` (module table).
pub fn route(boot: &Boot<'_>, call: &Call<'_>) -> Route {
    let acts_on_machine = !matches!(call.kind, "fetch" | "think");
    match boot.stage {
        None | Some(Cloud::None) => here(NOT_HYBRID),
        Some(_) if !acts_on_machine => here(RUNS_ANYWHERE),
        Some(Cloud::Booting) if call.held_ms < HOLD_DEADLINE_MS => Route::Hold,
        Some(Cloud::Booting) => here(MACHINE_NOT_READY),
        Some(Cloud::Ready | Cloud::Moving) => match (call.kind, boot.machine) {
            ("execute", Some(machine)) if !machine.is_empty() => {
                Route::OnMachine { machine: machine.to_owned() }
            }
            ("execute", _) => here(NO_MACHINE_ID),
            _ => here(NO_FILE_ROUTE),
        },
        Some(Cloud::Live) => here(CHAT_ON_MACHINE),
        Some(Cloud::Failed) => here(MACHINE_FAILED),
    }
}

/// The stage a [`STAGE_TAG`] value names; None for no tag or a value it does not know.
pub fn stage_of(tag: Option<&str>) -> Option<Cloud> {
    serde_json::from_value(serde_json::Value::String(tag?.to_owned())).ok()
}

/// The [`STAGE_TAG`] value of `cloud`.
pub fn stage_tag(cloud: Cloud) -> String {
    serde_json::to_value(cloud)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// A shell command that runs `command` on `machine` through `cmux vm exec`, its output and exit
/// status the call's own.
pub fn on_machine_command(machine: &str, command: &str) -> String {
    format!("cmux vm exec {} -- bash -lc {}", quote(machine), quote(command))
}

fn quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// The boot marks a start reports, in order, with their share of readiness: the names
/// `cmux vm new --wait` marks (`start_stages.rs` `MARKS`). Ready itself is 100.
pub const MARKS: &[(&str, u8)] =
    &[("created", 20), ("running", 50), ("connect", 65), ("machine_config", 80), ("secrets", 90)];

/// The least readiness of a start that is booting.
pub const BOOTING: u8 = 5;

/// How ready the machine is, 0 to 100, from its stage and the boot marks reached: None when no
/// start runs or it failed. Monotonic as marks are reached and stages advance; 100 only once the
/// machine is ready (and after: moving, live).
pub fn readiness(cloud: Cloud, reached: &[&str]) -> Option<u8> {
    match cloud {
        Cloud::None | Cloud::Failed => None,
        Cloud::Ready | Cloud::Moving | Cloud::Live => Some(100),
        Cloud::Booting => Some(
            MARKS
                .iter()
                .filter(|(name, _)| reached.contains(name))
                .map(|(_, share)| *share)
                .fold(BOOTING, u8::max),
        ),
    }
}

#[cfg(test)]
#[path = "hybrid_tools_tests.rs"]
mod tests;
