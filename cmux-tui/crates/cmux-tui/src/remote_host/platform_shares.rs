//! `cmux host share|unshare|shares` for a cmux Cloud machine: a teammate's share lives on the cmux
//! platform (`/v1/cloud/machines/{machine}/shares`, cmux-platform `CarrierShareRoute.ts`), not in
//! the host config. The platform then gives the teammate a team carrier grant that names the shared
//! acpmux sessions (its `chats`), and the machine admits them by that grant alone.
//!
//! The machine is `--machine vm_...`, else this machine when it is a Cloud machine
//! ([`crate::machine_secrets::this_machine_id`]); with neither, the verbs stay the tailnet host's
//! (`shares.rs`). The caller signs in as a person: `--cloud-token-file`, `--cloud-token-stdin` or
//! `CMUX_CLOUD_ACCESS_TOKEN`, with `--team` (or `CMUX_CLOUD_TEAM`) and `--platform`.
//!
//! - `share CHAT... PERSON`: each chat is a surface number or a session name or id (this machine's,
//!   resolved here), or a session id (another machine's). The platform keeps one live share per
//!   person, and a create replaces it, so the chats are added to the person's live share. A share
//!   always names its chats: the platform reads none (`null`) as every chat, and a machine refuses
//!   such a share (`acpmux.team_without_chats`), so `--all` is refused here and lists the chats.
//! - `unshare [CHAT...] PERSON` takes those chats out of the person's share (all of it with no
//!   chats); `unshare csh_...` revokes one share.
//! - `shares` lists the machine's live shares.
//!
//! On this machine every run first moves the local shares (`config.shares`) to the platform, once
//! ([`move_local`]): only a share that still grants access (a live, consented `agents` grant, this
//! daemon boot) and carries a verified `user_` id moves, and each one the platform confirms leaves
//! `shares` and goes to `moved_shares` in one write; the rest stay local, enforced as before. A platform that cannot be reached changes nothing; a crash between a create and that
//! write leaves the local share, and the next run finds it already covered and only removes it.

use std::collections::BTreeMap;

use anyhow::{anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{Flags, audit, config, shares};

/// One live share, as the platform answers it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PlatformShare {
    pub id: String,
    pub machine: String,
    pub person: String,
    /// The shared acpmux session ids; `None` is the platform's "every session".
    #[serde(default)]
    pub sessions: Option<Vec<String>>,
    #[serde(default)]
    pub created_at: Option<u64>,
    #[serde(default)]
    pub revoked_at: Option<u64>,
    #[serde(default)]
    pub created_by: Option<String>,
}

/// One local share the platform confirmed (`config.moved_shares`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Moved {
    pub login: String,
    pub session: String,
    pub machine: String,
    pub person: String,
    /// The live platform share that covers it.
    pub share: String,
    pub moved_at: String,
}

/// A team member, as the platform lists them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Member {
    pub user: String,
    pub name: String,
}

/// Why a platform call failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Failure {
    Refused { status: u16, code: String, message: String },
    Unreachable(String),
    Unreadable(String),
}

/// The platform's share routes and member list (a live client, or a test's stand-in).
pub(crate) trait Api {
    fn list(&self, machine: &str) -> Result<Vec<PlatformShare>, Failure>;
    /// `sessions` is never empty: a share without chats is refused before it gets here.
    /// `replaces` is always sent: the person's live share as it was read (`None` for none). The
    /// platform writes only while that is still their live share, and answers a 409
    /// `cloud.carrier_share.conflict` otherwise ([`conflict`]), so no write is computed from a
    /// share another writer has since replaced.
    fn create(
        &self,
        machine: &str,
        person: &str,
        sessions: &Sessions,
        replaces: Option<&str>,
    ) -> Result<PlatformShare, Failure>;
    fn revoke(&self, machine: &str, share: &str) -> Result<PlatformShare, Failure>;
    fn members(&self) -> Result<Vec<Member>, Failure>;
}

/// A non-empty list of distinct, valid acpmux session ids: the only `sessions` a create sends,
/// so no create can mean "every chat".
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Sessions(Vec<String>);

impl Sessions {
    pub(crate) fn new(ids: impl IntoIterator<Item = String>) -> Option<Self> {
        let mut out: Vec<String> = Vec::new();
        for id in ids {
            if !valid_session(&id) {
                return None;
            }
            if !out.contains(&id) {
                out.push(id);
            }
        }
        (!out.is_empty()).then_some(Self(out))
    }

    pub(crate) fn ids(&self) -> &[String] {
        &self.0
    }

    /// The create body: `{person, sessions: [...], replaces}`, never `null` sessions, and
    /// `replaces` always present (`null` when the person had no live share).
    pub(crate) fn body(&self, person: &str, replaces: Option<&str>) -> Value {
        json!({"person": person, "sessions": self.0, "replaces": replaces})
    }
}

/// Where the verbs go: a Cloud machine, and whether it is this one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Target {
    pub machine: String,
    pub here: bool,
}

/// `--machine`, else this Cloud machine; `None` keeps the tailnet host's verbs.
pub(crate) fn target(flag: Option<&str>, own: Option<String>) -> anyhow::Result<Option<Target>> {
    let text = &crate::localization::catalog().host_share;
    match flag {
        Some(machine) => {
            let machine = machine.strip_prefix("machine:").unwrap_or(machine);
            if !valid_machine(machine) {
                return Err(super::usage(text.cloud_machine));
            }
            let here = own.as_deref() == Some(machine);
            Ok(Some(Target { machine: machine.to_owned(), here }))
        }
        None => {
            Ok(own.filter(|id| valid_machine(id)).map(|machine| Target { machine, here: true }))
        }
    }
}

/// `vm_` and 20 lowercase letters or digits (the platform's route pattern).
pub(crate) fn valid_machine(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// `user_` and 20 lowercase hex digits.
pub(crate) fn valid_person(id: &str) -> bool {
    id.strip_prefix("user_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// 1 to 128 of `A-Z a-z 0-9 . _ -` (the carrier grant's `chats`).
pub(crate) fn valid_session(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// `csh_` and 20 lowercase letters or digits.
fn valid_share(id: &str) -> bool {
    id.strip_prefix("csh_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// A person for the platform: a `user_` id as given, else the one member whose name is `given`
/// (any case). The member list carries no emails, so an email is refused with that reason.
pub(crate) fn person(api: &dyn Api, given: &str) -> anyhow::Result<String> {
    let text = &crate::localization::catalog().host_share;
    let given = given.trim();
    if valid_person(given) {
        return Ok(given.to_owned());
    }
    let members = api.members().map_err(|f| anyhow!("{}", explain(&f)))?;
    let mut named = members.iter().filter(|m| m.name.trim().eq_ignore_ascii_case(given));
    match (named.next(), named.next()) {
        (Some(member), None) => {
            eprintln!("cmux host: {given} = {}", member.user);
            Ok(member.user.clone())
        }
        (Some(_), Some(_)) => bail!("{}: {given}", text.person_ambiguous),
        (None, _) if given.contains('@') => bail!("{}: {given}", text.person_email),
        (None, _) => bail!("{}: {given}", text.person_unknown),
    }
}

/// What a failure means for the person at the terminal.
pub(crate) fn explain(failure: &Failure) -> String {
    let text = &crate::localization::catalog().host_share;
    match failure {
        Failure::Refused { status, code, message } => match code.as_str() {
            "cloud.carrier.team_unsupported" => text.team_unsupported.to_owned(),
            "acpmux.team_without_chats" => text.team_without_chats.to_owned(),
            "cloud.carrier_share.not_teammate" => text.not_teammate.to_owned(),
            "cloud.carrier_share.not_found" => text.share_not_found.to_owned(),
            "cloud.carrier_share.conflict" => text.narrow_raced.to_owned(),
            "cloud.machine.not_found" => text.machine_not_found.to_owned(),
            "auth.forbidden" => text.forbidden.to_owned(),
            "owner.unreachable" => text.cloud_unreachable.to_owned(),
            _ if *status == 401 => format!("{} ({status} {code})", text.sign_in_refused),
            _ => format!("{status} {code}: {message}"),
        },
        Failure::Unreachable(reason) => format!("{} ({reason})", text.cloud_unreachable),
        Failure::Unreadable(reason) => reason.clone(),
    }
}

/// Whether a create was refused because the person's live share is no longer the one it named
/// in `replaces`: another writer got there first, and the change is computed again from the
/// share as it is now.
pub(crate) fn conflict(failure: &Failure) -> bool {
    matches!(failure, Failure::Refused { status: 409, code, .. }
        if code == "cloud.carrier_share.conflict")
}

/// Whether a revoke found no such live share: it was replaced or revoked since it was read.
fn gone(failure: &Failure) -> bool {
    matches!(failure, Failure::Refused { status: 404, code, .. }
        if code == "cloud.carrier_share.not_found")
}

/// The person's live share of the machine, if any.
fn live_for<'a>(live: &'a [PlatformShare], person: &str) -> Option<&'a PlatformShare> {
    live.iter().find(|s| s.person == person && s.revoked_at.is_none())
}

/// The sessions a create must send to add `add` to `live` (the person's live share), or `None`
/// when it already covers them (an "every chat" share covers all).
pub(crate) fn merged(live: Option<&PlatformShare>, add: &Sessions) -> Option<Sessions> {
    let mut ids = match live.map(|s| s.sessions.as_ref()) {
        Some(None) => return None,
        Some(Some(ids)) => ids.clone(),
        None => Vec::new(),
    };
    let before = ids.len();
    for id in add.ids() {
        if !ids.contains(id) {
            ids.push(id.clone());
        }
    }
    if ids.len() == before {
        return None;
    }
    Sessions::new(ids)
}

/// What taking chats out of a live share leaves.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Narrowed {
    /// Nothing left: revoke the share.
    Revoke,
    /// Create again with these (a create replaces the live share).
    Keep(Sessions),
    /// None of the chats were in it.
    Unchanged,
}

/// `live` without `remove`; an "every chat" share cannot be narrowed by name.
pub(crate) fn narrowed(live: &PlatformShare, remove: &Sessions) -> anyhow::Result<Narrowed> {
    let Some(ids) = &live.sessions else {
        bail!("{}", crate::localization::catalog().host_share.all_share_narrow);
    };
    let left: Vec<String> = ids.iter().filter(|id| !remove.ids().contains(id)).cloned().collect();
    if left.len() == ids.len() {
        return Ok(Narrowed::Unchanged);
    }
    Ok(Sessions::new(left).map_or(Narrowed::Revoke, Narrowed::Keep))
}

/// A local share left in the host config, and why.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Kept {
    pub login: String,
    pub session: String,
    pub reason: &'static str,
}

/// [`move_local`]'s result: the config to write and what moved.
#[derive(Debug)]
pub(crate) struct MoveOutcome {
    pub config: config::Config,
    pub moved: Vec<Moved>,
    pub kept: Vec<Kept>,
    /// The call that stopped the move; the shares not yet confirmed stay local.
    pub failed: Option<Failure>,
}

/// `config` with its local shares moved to `machine` on the platform: each person's chats are
/// added to their live share (one create per person, none when it already covers them), and only
/// what the platform confirmed leaves `shares`. A share moves only while it still grants access
/// here, and only to a verified person; every other one stays local with its reason:
///
/// - `guest`: the platform has no read-only teammate yet, and moving it would raise the access;
/// - `no chat`: no pinned session;
/// - `revoked`: its login's teammate grant is gone, revoked or not consented, or lacks `agents`
///   (`cmux host revoke` leaves the share in the config, and it must not come back as access);
/// - `expired`: it names an older daemon boot than `generation` (local shares end with the boot),
///   or the boot could not be read;
/// - `no verified identity`: the share carries no `user_` id (`Share::person`). A tailnet login is
///   never matched to a teammate by display name.
///
/// A login whose last local share moved also loses its teammate grant here (revoked), so a grant
/// with `shell` never outlives the share that kept it on the filtered proxy.
///
/// A list that fails changes nothing.
pub(crate) fn move_local(
    mut config: config::Config,
    api: &dyn Api,
    machine: &str,
    at: &str,
    generation: Option<&str>,
) -> Result<MoveOutcome, Failure> {
    let mut outcome =
        MoveOutcome { config: config.clone(), moved: Vec::new(), kept: Vec::new(), failed: None };
    if config.shares.is_empty() {
        return Ok(outcome);
    }
    let mut by_person: BTreeMap<String, Vec<&shares::Share>> = BTreeMap::new();
    for share in &config.shares {
        match movable(&config, share, generation) {
            Ok(person) => by_person.entry(person).or_default().push(share),
            Err(reason) => outcome.kept.push(kept(share, reason)),
        }
    }
    if by_person.is_empty() {
        return Ok(outcome);
    }
    let mut live = api.list(machine)?;
    let mut confirmed: Vec<(String, String)> = Vec::new();
    for (person, local) in &by_person {
        if outcome.failed.is_some() {
            outcome.kept.extend(local.iter().map(|s| kept(s, "not reached")));
            continue;
        }
        let Some(add) = Sessions::new(local.iter().map(|s| s.session.clone())) else {
            continue;
        };
        match cover(api, machine, person, &add, &mut live) {
            Ok(Some(share_id)) => {
                for share in local {
                    confirmed.push((share.login.clone(), share.session.clone()));
                    outcome.moved.push(Moved {
                        login: share.login.clone(),
                        session: share.session.clone(),
                        machine: machine.to_owned(),
                        person: person.clone(),
                        share: share_id.clone(),
                        moved_at: at.to_owned(),
                    });
                }
            }
            Ok(None) => {}
            Err(failure) => {
                outcome.failed = Some(failure);
                outcome.kept.extend(local.iter().map(|s| kept(s, "not reached")));
            }
        }
    }
    config.shares.retain(|s| {
        !(s.role == shares::Role::Member
            && confirmed.iter().any(|(login, session)| *login == s.login && *session == s.session))
    });
    // A local share is what kept its login on the filtered agent proxy (`serve::proxied`): a
    // grant with `shell` whose last local share moved would otherwise reach the raw daemon. The
    // grant ends with the last share it was used for; the shared chats are reached through the
    // platform's grant from now on.
    let now = super::grant::now_rfc3339();
    for (login, _) in &confirmed {
        if config.shares.iter().any(|s| config::same_login(&s.login, login)) {
            continue;
        }
        for grant in config.grants.iter_mut() {
            if config::same_login(&grant.login, login) && grant.revoked_at.is_none() {
                grant.revoked_at = Some(now.clone());
            }
        }
    }
    config.moved_shares.extend(outcome.moved.iter().cloned());
    outcome.config = config;
    Ok(outcome)
}

/// The id of `person`'s live share once it covers `add`: as it is, or after a create that names
/// the share it replaces. A conflict (another writer replaced it since `live` was read) reads
/// `live` again and merges from that, up to [`MAX_WRITES`].
fn cover(
    api: &dyn Api,
    machine: &str,
    person: &str,
    add: &Sessions,
    live: &mut Vec<PlatformShare>,
) -> Result<Option<String>, Failure> {
    let mut last = None;
    for _ in 0..MAX_WRITES {
        let existing = live_for(live, person);
        let Some(sessions) = merged(existing, add) else {
            return Ok(existing.map(|s| s.id.clone()));
        };
        let replaces = existing.map(|s| s.id.clone());
        match api.create(machine, person, &sessions, replaces.as_deref()) {
            Ok(share) => return Ok(Some(share.id)),
            Err(failure) if conflict(&failure) => {
                last = Some(failure);
                *live = api.list(machine)?;
            }
            Err(failure) => return Err(failure),
        }
    }
    Err(last.unwrap_or_else(|| Failure::Unreadable("no write was tried".to_owned())))
}

fn kept(share: &shares::Share, reason: &'static str) -> Kept {
    Kept { login: share.login.clone(), session: share.session.clone(), reason }
}

/// The verified person a local share may move to, or why it stays local ([`move_local`]).
fn movable(
    config: &config::Config,
    share: &shares::Share,
    generation: Option<&str>,
) -> Result<String, &'static str> {
    if share.role != shares::Role::Member {
        return Err("guest");
    }
    if !valid_session(&share.session) {
        return Err("no chat");
    }
    let granted = matches!(super::grant::check(config, &share.login),
        super::grant::Check::Granted(scopes) if scopes.contains(&super::grant::Scope::Agents));
    if !granted || config.allow.iter().any(|a| config::same_login(a, &share.login)) {
        return Err("revoked");
    }
    if generation.is_none_or(|now| now.is_empty() || share.generation != now) {
        return Err("expired");
    }
    match share.person.as_deref().map(str::trim) {
        Some(person) if valid_person(person) => Ok(person.to_owned()),
        _ => Err("no verified identity"),
    }
}

/// What the verbs need besides the platform, so tests can stand in for it.
pub(crate) struct Hooks<'a> {
    /// Asks the person at the terminal; an error is a refusal (no terminal, not approved).
    pub confirm: &'a mut dyn FnMut(&str) -> anyhow::Result<()>,
    /// The agent session a surface of this machine shows.
    pub surface_session: &'a dyn Fn(u64) -> anyhow::Result<String>,
    /// The id of this machine's acpmux session a name, id or prefix names.
    pub resolve_session: &'a dyn Fn(&str) -> anyhow::Result<String>,
    /// This machine's acpmux sessions: id and name.
    pub local_sessions: &'a dyn Fn() -> Vec<(String, String)>,
    /// Records a decision in the host's audit log.
    pub audit: &'a mut dyn FnMut(Value),
    /// Holds off every other change to one person's share of one machine on this host until the
    /// guard drops ([`person_lock`]), so a change is computed from the share as it is then.
    pub lock: &'a dyn Fn(&str, &str) -> anyhow::Result<Guard>,
}

/// What [`Hooks::lock`] hands back: the lock is held until it drops.
pub(crate) type Guard = Box<dyn std::any::Any>;

/// How many writes a change tries when each is refused because a concurrent writer (another host)
/// replaced the share between this run's read and its write.
const MAX_WRITES: usize = 3;

/// `share|unshare|shares` on `target` with `positional` words; the JSON answer.
pub(crate) fn act(
    verb: &str,
    positional: &[String],
    all: bool,
    role: Option<&str>,
    target: &Target,
    api: &dyn Api,
    hooks: &mut Hooks<'_>,
) -> anyhow::Result<Value> {
    let text = &crate::localization::catalog().host_share;
    let machine = target.machine.as_str();
    let failed = |f: Failure| anyhow!("{}", explain(&f));
    match verb {
        "shares" => {
            if !positional.is_empty() || all {
                return Err(super::usage(text.no_arguments));
            }
            let live = api.list(machine).map_err(failed)?;
            Ok(json!({"machine": machine, "shares": live}))
        }
        "share" => {
            if role.is_some_and(|r| r != "member") {
                return Err(super::usage(text.cloud_role));
            }
            let Some((who, chats)) = positional.split_last() else {
                return Err(super::usage(text.cloud_arguments));
            };
            if all || chats.is_empty() {
                bail!("{}", all_refusal(target, hooks));
            }
            let add = sessions_of(chats, target, hooks)?;
            let person = person(api, who)?;
            let before = api.list(machine).map_err(failed)?;
            if merged(live_for(&before, &person), &add).is_none() {
                let existing = live_for(&before, &person);
                return Ok(json!({"machine": machine, "share": existing, "unchanged": true}));
            }
            (hooks.confirm)(&format!(
                "share: {machine}, {person}, add {}. {} ",
                add.ids().join(" "),
                text.cloud_confirm
            ))?;
            // What is written is computed from the share as it is now, under the lock: a change
            // that landed while the prompt waited is kept, never overwritten by an older list.
            // A writer on another host is caught by `replaces`: a conflict reads the share again.
            let _guard = (hooks.lock)(machine, &person)?;
            for _ in 0..MAX_WRITES {
                let live = api.list(machine).map_err(failed)?;
                let existing = live_for(&live, &person);
                let Some(sessions) = merged(existing, &add) else {
                    return Ok(json!({"machine": machine, "share": existing, "unchanged": true}));
                };
                let replaces = existing.map(|s| s.id.as_str());
                match api.create(machine, &person, &sessions, replaces) {
                    Ok(share) => {
                        (hooks.audit)(json!({"decision": "share", "machine": machine,
                            "person": person, "sessions": sessions.ids(), "share": share.id}));
                        return Ok(json!({"machine": machine, "share": share}));
                    }
                    Err(failure) if conflict(&failure) => {}
                    Err(failure) => return Err(failed(failure)),
                }
            }
            bail!("{}: {person}", text.narrow_raced)
        }
        "unshare" => {
            if all {
                return Err(super::usage(text.cloud_arguments));
            }
            let Some((who, chats)) = positional.split_last() else {
                return Err(super::usage(text.cloud_arguments));
            };
            if chats.is_empty() && valid_share(who) {
                (hooks.confirm)(&format!(
                    "unshare: {machine}, {who}. {} ",
                    text.cloud_unshare_confirm
                ))?;
                let share = api.revoke(machine, who).map_err(failed)?;
                (hooks.audit)(json!({"decision": "unshare", "machine": machine, "share": who}));
                return Ok(json!({"machine": machine, "revoked": share}));
            }
            let remove =
                if chats.is_empty() { None } else { Some(sessions_of(chats, target, hooks)?) };
            let person = person(api, who)?;
            let before = api.list(machine).map_err(failed)?;
            if live_for(&before, &person).is_none() {
                bail!("{}: {person}", text.not_shared);
            }
            let what = remove.as_ref().map_or_else(
                || "every chat".to_owned(),
                |remove| format!("remove {}", remove.ids().join(" ")),
            );
            (hooks.confirm)(&format!(
                "unshare: {machine}, {person}, {what}. {} ",
                text.cloud_unshare_confirm
            ))?;
            let _guard = (hooks.lock)(machine, &person)?;
            narrow(api, machine, &person, remove.as_ref(), hooks)
        }
        _ => Err(anyhow!("unknown verb")),
    }
}

/// Takes `remove` (every chat for `None`) out of `person`'s live share, holding their lock. Each
/// pass reads the share as it is and writes the narrowed one with `replaces` naming it (or
/// revokes it by id). A write the platform refuses because another writer replaced the share
/// since it was read (a 409 conflict, or a revoke of a share that is gone) writes nothing, and the
/// next pass computes the change again from the live share, up to [`MAX_WRITES`]. A list
/// computed before the lock is never written, and no write is sent without `replaces`.
fn narrow(
    api: &dyn Api,
    machine: &str,
    person: &str,
    remove: Option<&Sessions>,
    hooks: &mut Hooks<'_>,
) -> anyhow::Result<Value> {
    let text = &crate::localization::catalog().host_share;
    let failed = |f: Failure| anyhow!("{}", explain(&f));
    for _ in 0..MAX_WRITES {
        let live = api.list(machine).map_err(failed)?;
        let Some(existing) = live_for(&live, person) else {
            return Ok(json!({"machine": machine, "unchanged": true}));
        };
        let next = match remove {
            None => Narrowed::Revoke,
            Some(remove) => narrowed(existing, remove)?,
        };
        match next {
            Narrowed::Unchanged => {
                return Ok(json!({"machine": machine, "share": existing, "unchanged": true}));
            }
            Narrowed::Revoke => match api.revoke(machine, &existing.id) {
                Ok(share) => {
                    (hooks.audit)(json!({"decision": "unshare", "machine": machine,
                        "person": person, "share": existing.id}));
                    return Ok(json!({"machine": machine, "revoked": share}));
                }
                Err(failure) if gone(&failure) => {}
                Err(failure) => return Err(failed(failure)),
            },
            Narrowed::Keep(sessions) => {
                match api.create(machine, person, &sessions, Some(&existing.id)) {
                    Ok(share) => {
                        (hooks.audit)(json!({"decision": "unshare", "machine": machine,
                            "person": person, "sessions": sessions.ids(), "share": share.id}));
                        return Ok(json!({"machine": machine, "share": share}));
                    }
                    Err(failure) if conflict(&failure) => {}
                    Err(failure) => return Err(failed(failure)),
                }
            }
        }
    }
    bail!("{}: {person}", text.narrow_raced)
}

/// Whether a verb on this Cloud machine stays the tailnet host's, exactly as on a host that is no
/// Cloud machine: a local share the platform does not hold (not moved: a guest, no verified
/// person, a revoked or expired grant) is taken back where it lives (`unshare SURFACE LOGIN`
/// naming one), and a guest share is made there (the platform has no read-only teammate).
/// `shares` lists both ([`listing`]); every other verb goes to the platform.
pub(super) fn stays_local(
    verb: &str,
    flags: &Flags,
    config: &config::Config,
    target: &Target,
) -> bool {
    if !target.here || CLOUD_FLAGS.iter().any(|name| flags.has(name)) {
        return false;
    }
    match (verb, flags.positional.as_slice()) {
        ("unshare", [surface, login]) => surface.parse::<u64>().is_ok_and(|surface| {
            config
                .shares
                .iter()
                .any(|s| s.surface == surface && config::same_login(&s.login, login.trim()))
        }),
        ("share", [_, _]) => flags.value("role") == Some("guest"),
        _ => false,
    }
}

/// `shares` on this Cloud machine: the local shares (`where: local`, enforced by the tailnet
/// host as before) and the platform's (`where: cloud`), or the local ones and why the platform's
/// could not be read.
pub(crate) fn listing(local: &[shares::Share], cloud: Result<Vec<PlatformShare>, String>) -> Value {
    let mut all: Vec<Value> = local
        .iter()
        .map(|share| {
            let mut entry = json!(share);
            if let Some(object) = entry.as_object_mut() {
                object.insert("where".to_owned(), json!("local"));
            }
            entry
        })
        .collect();
    let mut answer = json!({});
    match cloud {
        Ok(cloud) => all.extend(cloud.iter().map(|share| {
            let mut entry = json!(share);
            if let Some(object) = entry.as_object_mut() {
                object.insert("where".to_owned(), json!("cloud"));
            }
            entry
        })),
        Err(error) => {
            if let Some(object) = answer.as_object_mut() {
                object.insert("cloud_error".to_owned(), json!(error));
            }
        }
    }
    if let Some(object) = answer.as_object_mut() {
        object.insert("shares".to_owned(), Value::Array(all));
    }
    answer
}

/// Why `--all` (or no chats) is refused, with this machine's chats to pick from.
fn all_refusal(target: &Target, hooks: &Hooks<'_>) -> String {
    let text = &crate::localization::catalog().host_share;
    let mut message = text.cloud_all.to_owned();
    if target.here {
        let listed = (hooks.local_sessions)();
        if !listed.is_empty() {
            message.push('\n');
            message.push_str(text.cloud_sessions);
            for (id, name) in listed {
                message.push_str(&format!("\n  {id}  {name}"));
            }
        }
    }
    message
}

/// The session ids `chats` name on `target`.
fn sessions_of(chats: &[String], target: &Target, hooks: &Hooks<'_>) -> anyhow::Result<Sessions> {
    let text = &crate::localization::catalog().host_share;
    let mut ids = Vec::new();
    for chat in chats {
        let id = match chat.parse::<u64>() {
            Ok(surface) if target.here => (hooks.surface_session)(surface)?,
            Ok(_) => return Err(super::usage(text.surface_elsewhere)),
            Err(_) if target.here => (hooks.resolve_session)(chat)?,
            Err(_) => chat.clone(),
        };
        if !valid_session(&id) {
            return Err(super::usage(format!("{}: {id}", text.session_invalid)));
        }
        ids.push(id);
    }
    Sessions::new(ids).ok_or_else(|| super::usage(text.cloud_arguments))
}

/// The flags only a Cloud machine's verbs take.
pub(super) const CLOUD_FLAGS: &[&str] =
    &["machine", "platform", "team", "cloud-token-file", "cloud-token-stdin", "all"];

/// Runs `verb` on `target`: signs in, moves this machine's local shares once, then acts.
pub(super) fn run(verb: &str, flags: &Flags, target: &Target) -> anyhow::Result<()> {
    if verb == "shares" && target.here {
        if !flags.positional.is_empty() || flags.has("all") {
            return Err(super::usage(crate::localization::catalog().host_share.no_arguments));
        }
        // The local shares list as on any host, with or without a sign-in or the platform.
        let cloud = live::Live::from_flags(flags).map_err(|e| format!("{e:#}")).and_then(|api| {
            if let Err(error) = move_here(&api, &target.machine) {
                eprintln!("cmux host: {error:#}");
            }
            api.list(&target.machine).map_err(|f| explain(&f))
        });
        println!("{}", listing(&config::load()?.shares, cloud));
        return Ok(());
    }
    let api = live::Live::from_flags(flags)?;
    let moved = if target.here { move_here(&api, &target.machine)? } else { None };
    let config = config::load()?;
    let mut confirm = confirm_at_terminal;
    let surface_session =
        |surface: u64| -> anyhow::Result<String> { Ok(shares::chat(&config, surface)?.session) };
    let resolve_session = live::resolve_session;
    let local_sessions = live::local_sessions;
    let mut hooks = Hooks {
        confirm: &mut confirm,
        surface_session: &surface_session,
        resolve_session: &resolve_session,
        local_sessions: &local_sessions,
        audit: &mut |entry| audit::append(&entry),
        lock: &person_lock,
    };
    let mut answer = act(
        verb,
        &flags.positional,
        flags.has("all"),
        flags.value("role"),
        target,
        &api,
        &mut hooks,
    )?;
    if let (Some(moved), Some(object)) = (moved, answer.as_object_mut()) {
        object.insert("moved".to_owned(), moved);
    }
    println!("{answer}");
    Ok(())
}

/// [`move_local`] on the host config under its lock. `None` when there was nothing to move.
fn move_here(api: &dyn Api, machine: &str) -> anyhow::Result<Option<Value>> {
    let text = &crate::localization::catalog().host_share;
    if config::load()?.shares.is_empty() {
        return Ok(None);
    }
    let lock = config::lock()?;
    let current = config::load()?;
    let generation = shares::generation(&current);
    let outcome =
        move_local(current, api, machine, &super::grant::now_rfc3339(), generation.as_deref())
            .map_err(|f| anyhow!("{}", explain(&f)))?;
    if !outcome.moved.is_empty() {
        // The listener restarts: a tailnet connection a moved share admitted closes with it.
        config::commit(&outcome.config, &lock, config::Listener::Restart)?;
        audit::append(&json!({"decision": "move-shares", "machine": machine,
            "moved": outcome.moved, "kept": outcome.kept}));
        eprintln!("cmux host: {} ({})", text.moved, outcome.moved.len());
    }
    if !outcome.kept.is_empty() {
        eprintln!("cmux host: {} ({})", text.kept, outcome.kept.len());
    }
    if let Some(failure) = &outcome.failed {
        bail!("{}", explain(failure));
    }
    Ok(Some(json!({"moved": outcome.moved, "not_moved": outcome.kept})))
}

/// An exclusive lock on one person's share of one machine, on this host (a 0600 file beside the
/// host config, `flock` on Unix), held until the guard drops.
fn person_lock(machine: &str, person: &str) -> anyhow::Result<Guard> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    // Both are checked ids (`vm_…`, `user_…`), so the name is a plain file name.
    let path = config::ensure_dir()?.join(format!("share-{machine}-{person}.lock"));
    let file = options.open(path)?;
    file.lock()?;
    Ok(Box::new(file))
}

/// A yes from the person at this machine's terminal, as `cmux host share` always asked.
fn confirm_at_terminal(prompt: &str) -> anyhow::Result<()> {
    use std::io::IsTerminal as _;
    let text = &crate::localization::catalog().host_share;
    if super::grant::require_interactive(
        std::io::stdin().is_terminal(),
        std::io::stderr().is_terminal(),
    )
    .is_err()
    {
        bail!("{}", text.terminal);
    }
    eprint!("{prompt}");
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    if !super::grant::confirmed(&answer) {
        bail!("{}", text.not_approved);
    }
    Ok(())
}

/// The answer of a share route: `{ok: true, value}` on a 2xx, else the refusal it carries.
pub(crate) fn value_of(status: u16, body: &[u8]) -> Result<Value, Failure> {
    if !(200..300).contains(&status) {
        let error = cmux_cloud_client::ApiError::from_status(status, body);
        return Err(Failure::Refused {
            status,
            code: error.code.unwrap_or_default(),
            message: error.message,
        });
    }
    let parsed: Value = serde_json::from_slice(body).map_err(|_| {
        Failure::Unreadable(format!("the cmux platform answered {status} with no JSON"))
    })?;
    match (parsed.get("ok"), parsed.get("value")) {
        (Some(Value::Bool(true)), Some(value)) => Ok(value.clone()),
        _ => {
            Err(Failure::Unreadable(format!("the cmux platform answered {status} without a value")))
        }
    }
}

/// `value.share` as a share.
pub(crate) fn share_of(value: &Value) -> Result<PlatformShare, Failure> {
    value
        .get("share")
        .cloned()
        .and_then(|share| serde_json::from_value(share).ok())
        .ok_or_else(|| Failure::Unreadable("the cmux platform answered no share".to_owned()))
}

/// `value.shares` as shares.
pub(crate) fn shares_of(value: &Value) -> Result<Vec<PlatformShare>, Failure> {
    value
        .get("shares")
        .cloned()
        .and_then(|shares| serde_json::from_value(shares).ok())
        .ok_or_else(|| Failure::Unreadable("the cmux platform answered no share list".to_owned()))
}

#[cfg(unix)]
mod live {
    //! The platform over HTTPS, as the person signed in.
    use std::time::Duration;

    use anyhow::anyhow;
    use serde_json::Value;

    use super::{Api, Failure, Flags, Member, PlatformShare, Sessions};

    const TIMEOUT: Duration = Duration::from_secs(20);
    const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";
    /// The most member pages read to find one name.
    const MAX_PAGES: usize = 50;

    pub(super) struct Live {
        base: String,
        http: reqwest::Client,
        runtime: tokio::runtime::Runtime,
    }

    impl Live {
        pub(super) fn from_flags(flags: &Flags) -> anyhow::Result<Self> {
            let text = &crate::localization::catalog().host_share;
            let env = |key: &str| std::env::var(key).ok();
            let origin = crate::cli::platform_origin(flags.value("platform"), &env)
                .map_err(|message| anyhow!("{message}"))?;
            let auth = crate::cli::PlatformAuth {
                platform: None,
                token_file: flags.value("cloud-token-file").map(std::path::PathBuf::from),
                token_stdin: flags.has("cloud-token-stdin"),
            };
            let credential =
                crate::cli::read_platform_credential(&auth, &env, &mut std::io::stdin().lock())
                    .map_err(|message| anyhow!("{message}"))?
                    .ok_or_else(|| anyhow!("{}", text.cloud_sign_in))?;
            let team = flags
                .value("team")
                .map(str::to_owned)
                .or_else(|| env(TEAM_ENV))
                .filter(|team| !team.trim().is_empty());
            let _ = rustls::crypto::ring::default_provider().install_default();
            let (base, http) = cmux_cloud_client::http(
                &origin,
                Some(&credential),
                team.as_deref(),
                concat!("cmux/", env!("CARGO_PKG_VERSION")),
                TIMEOUT,
            )
            .map_err(|e| anyhow!("{e}"))?;
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
            Ok(Self { base, http, runtime })
        }

        fn send(
            &self,
            method: reqwest::Method,
            path: &str,
            body: Option<Value>,
        ) -> Result<Value, Failure> {
            self.runtime.block_on(async {
                let mut request = self
                    .http
                    .request(method, format!("{}{path}", self.base))
                    .header(reqwest::header::ACCEPT, "application/json");
                if let Some(body) = body {
                    request = request.json(&body);
                }
                let unreachable =
                    |e: reqwest::Error| Failure::Unreachable(e.without_url().to_string());
                let response = request.send().await.map_err(unreachable)?;
                let status = response.status().as_u16();
                let bytes = response.bytes().await.map_err(unreachable)?;
                super::value_of(status, &bytes)
            })
        }
    }

    fn path(machine: &str) -> String {
        format!("/v1/cloud/machines/{machine}/shares")
    }

    impl Api for Live {
        fn list(&self, machine: &str) -> Result<Vec<PlatformShare>, Failure> {
            super::shares_of(&self.send(reqwest::Method::GET, &path(machine), None)?)
        }

        fn create(
            &self,
            machine: &str,
            person: &str,
            sessions: &Sessions,
            replaces: Option<&str>,
        ) -> Result<PlatformShare, Failure> {
            let body = sessions.body(person, replaces);
            super::share_of(&self.send(reqwest::Method::POST, &path(machine), Some(body))?)
        }

        fn revoke(&self, machine: &str, share: &str) -> Result<PlatformShare, Failure> {
            let route = format!("{}/{share}", path(machine));
            super::share_of(&self.send(reqwest::Method::DELETE, &route, None)?)
        }

        fn members(&self) -> Result<Vec<Member>, Failure> {
            use cmux_cloud_wire::{TeamMembersListOp, TeamMembersListParams};
            self.runtime.block_on(async {
                let mut members = Vec::new();
                let mut cursor = None;
                for _ in 0..MAX_PAGES {
                    let params =
                        TeamMembersListParams { team: None, cursor, limit: None, role: None };
                    let page = cmux_cloud_client::ops::call::<TeamMembersListOp>(
                        &self.http, &self.base, params, None, None,
                    )
                    .await
                    .and_then(cmux_cloud_client::ops::Answer::into_result)
                    .map_err(failure)?;
                    members.extend(
                        page.members
                            .into_iter()
                            .map(|m| Member { user: m.user, name: m.display_name }),
                    );
                    cursor = page.next_cursor;
                    if cursor.is_none() {
                        break;
                    }
                }
                Ok(members)
            })
        }
    }

    fn failure(error: cmux_cloud_client::ApiError) -> Failure {
        match error.status {
            Some(status) => Failure::Refused {
                status,
                code: error.code.unwrap_or_default(),
                message: error.message,
            },
            None if error.code.as_deref() == Some("cloud.client.unreadable") => {
                Failure::Unreadable(error.message)
            }
            None => Failure::Unreachable(error.message),
        }
    }

    fn runtime() -> anyhow::Result<tokio::runtime::Runtime> {
        crate::acp::configure_home();
        Ok(tokio::runtime::Builder::new_current_thread().enable_all().build()?)
    }

    /// The id of this machine's acpmux session `key` names.
    pub(super) fn resolve_session(key: &str) -> anyhow::Result<String> {
        runtime()?.block_on(async {
            let client = acpmux::deliver::connect().await?;
            Ok(acpmux::deliver::resolve_session(&client, key).await?.0)
        })
    }

    /// This machine's acpmux sessions (none when acpmux is not running).
    pub(super) fn local_sessions() -> Vec<(String, String)> {
        let listed = runtime().and_then(|runtime| {
            runtime.block_on(async {
                let client = acpmux::deliver::connect().await?;
                acpmux::deliver::sessions(&client).await
            })
        });
        listed
            .unwrap_or_default()
            .iter()
            .filter_map(|s| {
                let id = s.get("sessionId").and_then(Value::as_str)?;
                let name = s.get("name").and_then(Value::as_str).unwrap_or_default();
                Some((id.to_owned(), name.to_owned()))
            })
            .collect()
    }
}

#[cfg(not(unix))]
mod live {
    //! Cloud machine shares need the platform client, which this platform does not build.
    use anyhow::bail;

    use super::{Api, Failure, Flags, Member, PlatformShare, Sessions};

    pub(super) struct Live;

    impl Live {
        pub(super) fn from_flags(_: &Flags) -> anyhow::Result<Self> {
            bail!("{}", crate::localization::catalog().host_share.cloud_unsupported)
        }
    }

    impl Api for Live {
        fn list(&self, _: &str) -> Result<Vec<PlatformShare>, Failure> {
            Ok(Vec::new())
        }
        fn create(
            &self,
            _: &str,
            _: &str,
            _: &Sessions,
            _: Option<&str>,
        ) -> Result<PlatformShare, Failure> {
            Err(Failure::Unreachable(String::new()))
        }
        fn revoke(&self, _: &str, _: &str) -> Result<PlatformShare, Failure> {
            Err(Failure::Unreachable(String::new()))
        }
        fn members(&self) -> Result<Vec<Member>, Failure> {
            Ok(Vec::new())
        }
    }

    pub(super) fn resolve_session(key: &str) -> anyhow::Result<String> {
        Ok(key.to_owned())
    }

    pub(super) fn local_sessions() -> Vec<(String, String)> {
        Vec::new()
    }
}

#[cfg(test)]
#[path = "platform_shares_tests.rs"]
mod tests;
