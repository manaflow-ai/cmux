//! A harness's readiness as one typed answer (competitor-teardown row 3, ledger 06211836fd;
//! version sides, row 9, ae222726fd): what it is, whether a chat can start on it, where the
//! sign-in verdict came from, which operations are blocked and why, the one repair to offer, and
//! the installed, running and target versions with the side that needs the repair.
//!
//! Leo: "even if you don't trust something, like you should still be able to use it"; "if your
//! sort of codex or cloud are out of date, you know, you should still be able to use it".
//! So an unknown or stale sign-in is `unverified` and usable, never `ready` (it never claims a
//! verified sign-in) and never `signIn` (missing credential files are not a sign-out). An update
//! on offer is only a repair, never a gate: `usable` never reads `outdated`.
//!
//! Computed when `_acpmux/harness/health` answers (`hub/health_view.rs`), never saved: staleness
//! depends on the time it is read.

use super::{Auth, Channel, HarnessHealth, REFRESH_EVERY};
use serde::{Deserialize, Serialize};

/// Where a row's sign-in verdict came from. Saved with the row; a copy saved before this field
/// reads `none`, so it is never shown as checked.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AuthSource {
    /// Nothing answered: the sign-in is unknown.
    #[default]
    None,
    /// The profile's `auth.check` command ran.
    Check,
    /// The agent's own files or status command (`builtin_auth`).
    Files,
    /// The hub's probe error named signing in (it can be older than a login since).
    ProbeError,
    /// An ACP `session/new` or `session/load` succeeded.
    Session,
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Installed, and a fresh check proved the sign-in.
    Ready,
    /// Installed; the sign-in is unknown or its proof is stale. Usable, labelled as unverified.
    Unverified,
    /// A check or probe said signed out or expired.
    SignIn,
    /// The program is not where the profile says.
    Missing,
}

/// An operation this row cannot do, and why. Never the launch itself for an outdated CLI.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Blocker {
    /// The operation: `update` (a one-click update here).
    pub capability: &'static str,
    /// `elevated` (needs sudo: run it in Terminal), `manual` (only the way it was installed can
    /// update it), `managed` (a launcher picks the version).
    pub kind: &'static str,
    pub reason: String,
}

/// The one repair a row offers.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Repair {
    Install,
    SignIn {
        #[serde(skip_serializing_if = "Option::is_none")]
        command: Option<String>,
    },
    /// Check this harness again (`_acpmux/harness/health {refresh}`): it changes no model or
    /// default.
    Recheck,
    Update {
        command: String,
    },
    /// The installed version is newer than the one the newest chat started on: restart the chat.
    Restart,
}

/// Which side a repair applies to. Only the provider (the agent CLI) is judged here; the app and
/// the daemon report their own versions elsewhere.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    Provider,
}

/// The provider's versions.
#[derive(Serialize, Clone, Debug, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Versions {
    /// On disk now, as the last check read it.
    pub installed: Option<String>,
    /// The version on disk when the newest chat on this harness started (since the daemon
    /// started); None: no chat started on it yet.
    pub running: Option<String>,
    /// The newest version its install channel offers.
    pub target: Option<String>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Readiness {
    pub state: State,
    /// A chat can start on it: ready or unverified.
    pub usable: bool,
    pub provenance: AuthSource,
    pub checked_at: u64,
    /// The check is older than two refresh periods: its sign-in proof no longer counts.
    pub stale: bool,
    pub blockers: Vec<Blocker>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repair: Option<Repair>,
    pub versions: Versions,
    /// The side `repair` applies to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub side: Option<Side>,
    /// The newest chat started on an older version than is installed: an update that has not
    /// reached a running chat yet (or did not apply). None: nothing to compare.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_applied: Option<bool>,
}

/// How old a check may be before its sign-in proof stops counting.
pub const STALE_AFTER_MS: u64 = 2 * REFRESH_EVERY.as_millis() as u64;

/// `row`'s readiness at `now` (ms since the epoch; None: never stale, a capture fixture's rows),
/// with `running` the version the newest chat on it started on.
pub fn of(row: &HarnessHealth, running: Option<&str>, now: Option<u64>) -> Readiness {
    let stale = now.is_some_and(|now| now.saturating_sub(row.checked_at) > STALE_AFTER_MS);
    let missing = row.path.is_none() && row.channel != Channel::Launcher;
    let state = if missing {
        State::Missing
    } else {
        match row.auth {
            Auth::SignedOut | Auth::Expired => State::SignIn,
            Auth::SignedIn if !stale => State::Ready,
            Auth::SignedIn | Auth::Unknown => State::Unverified,
        }
    };
    let blockers = update_blockers(row);
    let applied = match (running, row.version.as_deref()) {
        (Some(running), Some(installed)) => Some(!super::probe::is_newer(installed, running)),
        _ => None,
    };
    let update = row
        .update
        .as_ref()
        .filter(|plan| row.outdated && !plan.elevated)
        .map(|plan| Repair::Update { command: plan.command.clone() });
    let repair = match state {
        State::Missing => Some(Repair::Install),
        State::SignIn => Some(Repair::SignIn { command: row.login.clone() }),
        State::Unverified => Some(Repair::Recheck),
        State::Ready if applied == Some(false) => Some(Repair::Restart),
        State::Ready => update,
    };
    Readiness {
        state,
        usable: matches!(state, State::Ready | State::Unverified),
        provenance: row.auth_source,
        checked_at: row.checked_at,
        stale,
        blockers,
        side: repair.as_ref().map(|_| Side::Provider),
        repair,
        versions: Versions {
            installed: row.version.clone(),
            running: running.map(str::to_owned),
            target: row.latest.clone(),
        },
        update_applied: applied,
    }
}

/// Why a one-click update is not on offer for an outdated row, so the page explains the action
/// that is available instead of a broken Update button.
fn update_blockers(row: &HarnessHealth) -> Vec<Blocker> {
    if !row.outdated {
        return vec![];
    }
    let blocker = match (&row.update, row.channel) {
        (Some(plan), _) if plan.elevated => Blocker {
            capability: "update",
            kind: "elevated",
            reason: format!(
                "updating needs administrator rights: run `{}` in Terminal",
                plan.command
            ),
        },
        (Some(_), _) => return vec![],
        (None, Channel::Launcher) => Blocker {
            capability: "update",
            kind: "managed",
            reason: format!("`{}` runs through a launcher that picks its own version", row.program),
        },
        (None, _) => Blocker {
            capability: "update",
            kind: "manual",
            reason: format!("update `{}` the way it was installed", row.program),
        },
    };
    vec![blocker]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness_health::channel::UpdatePlan;

    fn row(auth: Auth, source: AuthSource) -> HarnessHealth {
        HarnessHealth {
            id: "codex".into(),
            program: "codex".into(),
            path: Some("/usr/local/bin/codex".into()),
            channel: Channel::Npm,
            package: Some("@openai/codex".into()),
            version: Some("0.40.0".into()),
            latest: Some("0.40.0".into()),
            latest_checked_at: Some(1_000),
            outdated: false,
            auth,
            auth_source: source,
            auth_detail: None,
            login: Some("codex login".into()),
            update: None,
            problem: None,
            checked_at: 1_000,
            auto_update: false,
            last_auto_update: None,
        }
    }

    const FRESH: Option<u64> = Some(2_000);

    #[test]
    fn unknown_absent_and_stale_sign_ins_are_usable_but_never_verified() {
        let unknown = of(&row(Auth::Unknown, AuthSource::None), None, FRESH);
        assert_eq!(unknown.state, State::Unverified);
        assert!(unknown.usable);
        assert_eq!(unknown.provenance, AuthSource::None);
        assert_eq!(unknown.repair, Some(Repair::Recheck));

        // A signed-in proof older than two refresh periods no longer counts.
        let stale =
            of(&row(Auth::SignedIn, AuthSource::Check), None, Some(1_000 + STALE_AFTER_MS + 1));
        assert!(stale.stale);
        assert_eq!(stale.state, State::Unverified);
        assert!(stale.usable);

        let fresh = of(&row(Auth::SignedIn, AuthSource::Check), None, FRESH);
        assert_eq!(fresh.state, State::Ready);
        assert_eq!(fresh.provenance, AuthSource::Check);
        assert_eq!(fresh.repair, None);
        // A capture fixture's rows are never stale.
        assert_eq!(of(&row(Auth::SignedIn, AuthSource::Files), None, None).state, State::Ready);
    }

    #[test]
    fn missing_program_missing_login_and_unknown_get_different_repairs() {
        let mut missing = row(Auth::Unknown, AuthSource::None);
        missing.path = None;
        let missing = of(&missing, None, FRESH);
        assert_eq!((missing.state, missing.usable), (State::Missing, false));
        assert_eq!(missing.repair, Some(Repair::Install));

        let signed_out = of(&row(Auth::SignedOut, AuthSource::Check), None, FRESH);
        assert_eq!((signed_out.state, signed_out.usable), (State::SignIn, false));
        assert_eq!(signed_out.repair, Some(Repair::SignIn { command: Some("codex login".into()) }));
        assert_eq!(
            of(&row(Auth::Expired, AuthSource::ProbeError), None, FRESH).state,
            State::SignIn
        );

        // A launcher has no path of its own and is not missing.
        let mut launcher = row(Auth::Unknown, AuthSource::None);
        launcher.path = None;
        launcher.channel = Channel::Launcher;
        assert_eq!(of(&launcher, None, FRESH).state, State::Unverified);
    }

    #[test]
    fn an_outdated_cli_stays_usable_and_its_update_is_only_a_repair() {
        let mut old = row(Auth::SignedIn, AuthSource::Files);
        old.latest = Some("0.41.0".into());
        old.outdated = true;
        old.update = Some(UpdatePlan {
            argv: vec!["npm".into(), "install".into(), "-g".into(), "@openai/codex@latest".into()],
            command: "npm install -g @openai/codex@latest".into(),
            elevated: false,
        });
        let ready = of(&old, None, FRESH);
        assert_eq!((ready.state, ready.usable), (State::Ready, true));
        assert_eq!(
            ready.repair,
            Some(Repair::Update { command: "npm install -g @openai/codex@latest".into() })
        );
        assert_eq!(ready.side, Some(Side::Provider));
        assert!(ready.blockers.is_empty());
        assert_eq!(ready.versions.installed.as_deref(), Some("0.40.0"));
        assert_eq!(ready.versions.target.as_deref(), Some("0.41.0"));

        // Elevated: no one-click update, the blocker names Terminal; the chat still starts.
        old.update.as_mut().unwrap().elevated = true;
        let elevated = of(&old, None, FRESH);
        assert!(elevated.usable);
        assert_eq!(elevated.repair, None);
        assert_eq!(elevated.blockers[0].capability, "update");
        assert_eq!(elevated.blockers[0].kind, "elevated");

        // No plan: only the way it was installed can update it.
        old.update = None;
        assert_eq!(of(&old, None, FRESH).blockers[0].kind, "manual");
        old.channel = Channel::Launcher;
        assert_eq!(of(&old, None, FRESH).blockers[0].kind, "managed");
    }

    #[test]
    fn a_chat_on_an_older_version_than_installed_says_the_update_has_not_applied() {
        let current = row(Auth::SignedIn, AuthSource::Session);
        let behind = of(&current, Some("0.39.0"), FRESH);
        assert_eq!(behind.update_applied, Some(false));
        assert_eq!(behind.repair, Some(Repair::Restart));
        assert_eq!(behind.versions.running.as_deref(), Some("0.39.0"));
        assert!(behind.usable, "an old running chat is still usable");

        let applied = of(&current, Some("0.40.0"), FRESH);
        assert_eq!(applied.update_applied, Some(true));
        assert_eq!(applied.repair, None);
        assert_eq!(of(&current, None, FRESH).update_applied, None);
    }

    #[test]
    fn readiness_serializes_in_the_page_shape() {
        let value = serde_json::to_value(of(&row(Auth::SignedOut, AuthSource::Check), None, FRESH))
            .unwrap();
        assert_eq!(value["state"], "signIn");
        assert_eq!(value["provenance"], "check");
        assert_eq!(
            value["repair"],
            serde_json::json!({"kind": "signIn", "command": "codex login"})
        );
        assert_eq!(value["side"], "provider");
        assert_eq!(value["versions"]["installed"], "0.40.0");
    }
}
