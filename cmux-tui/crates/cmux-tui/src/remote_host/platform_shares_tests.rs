//! Cloud machine shares against a stand-in platform: create, list and revoke, the refusal of an
//! "every chat" share, the one-time move of local shares (a crash between a create and the config
//! write included), and what each platform refusal says.

use std::cell::RefCell;

use serde_json::{Value, json};

use super::*;
use crate::remote_host::Flags;
use crate::remote_host::grant::{Grant, Scope};
use crate::remote_host::shares::{self, Role, Share};

const VM: &str = "vm_0123456789abcdefghij";
const ANA: &str = "user_00000000000000000a0a";
const BO: &str = "user_00000000000000000b0b";

/// What the stand-in platform holds and was asked.
#[derive(Default)]
struct Platform {
    shares: RefCell<Vec<PlatformShare>>,
    members: Vec<Member>,
    /// Every create's body, as the live client would send it.
    creates: RefCell<Vec<Value>>,
    revokes: RefCell<Vec<String>>,
    next: RefCell<u32>,
    /// Answers every call with this, when set.
    down: Option<Failure>,
    /// Refuses a create for this person.
    refuse_create_for: Option<(String, Failure)>,
}

impl Platform {
    fn with_members(members: &[(&str, &str)]) -> Self {
        Self {
            members: members
                .iter()
                .map(|(user, name)| Member { user: (*user).into(), name: (*name).into() })
                .collect(),
            ..Self::default()
        }
    }

    fn live(&self, person: &str, sessions: &[&str]) -> &Self {
        let id = format!("csh_{:0>20}", self.shares.borrow().len());
        self.shares.borrow_mut().push(PlatformShare {
            id,
            machine: VM.into(),
            person: person.into(),
            sessions: Some(sessions.iter().map(|s| (*s).to_owned()).collect()),
            created_at: Some(1),
            revoked_at: None,
            created_by: Some("user_ffffffffffffffffffff".into()),
        });
        self
    }

    fn live_sessions(&self, person: &str) -> Option<Vec<String>> {
        self.shares
            .borrow()
            .iter()
            .find(|s| s.person == person && s.revoked_at.is_none())
            .and_then(|s| s.sessions.clone())
    }
}

impl Api for Platform {
    fn list(&self, machine: &str) -> Result<Vec<PlatformShare>, Failure> {
        if let Some(down) = &self.down {
            return Err(down.clone());
        }
        assert_eq!(machine, VM);
        Ok(self.shares.borrow().iter().filter(|s| s.revoked_at.is_none()).cloned().collect())
    }

    fn create(
        &self,
        machine: &str,
        person: &str,
        sessions: &Sessions,
        replaces: Option<&str>,
    ) -> Result<PlatformShare, Failure> {
        if let Some(down) = &self.down {
            return Err(down.clone());
        }
        if let Some((who, failure)) = &self.refuse_create_for
            && who == person
        {
            return Err(failure.clone());
        }
        let body = sessions.body(person, replaces);
        assert!(body["sessions"].as_array().is_some_and(|s| !s.is_empty()), "{body}");
        assert!(body.get("replaces").is_some(), "every write names what it replaces: {body}");
        self.creates.borrow_mut().push(body);
        // The platform writes only while `replaces` is still the person's live share.
        let current = self
            .shares
            .borrow()
            .iter()
            .find(|s| s.person == person && s.revoked_at.is_none())
            .map(|s| s.id.clone());
        if current.as_deref() != replaces {
            return Err(refused(409, "cloud.carrier_share.conflict"));
        }
        // A create for the same person replaces their live share.
        for share in self.shares.borrow_mut().iter_mut() {
            if share.person == person && share.revoked_at.is_none() {
                share.revoked_at = Some(2);
            }
        }
        *self.next.borrow_mut() += 1;
        let share = PlatformShare {
            id: format!("csh_new{:0>17}", self.next.borrow()),
            machine: machine.into(),
            person: person.into(),
            sessions: Some(sessions.ids().to_vec()),
            created_at: Some(3),
            revoked_at: None,
            created_by: Some("user_ffffffffffffffffffff".into()),
        };
        self.shares.borrow_mut().push(share.clone());
        Ok(share)
    }

    fn revoke(&self, _: &str, share: &str) -> Result<PlatformShare, Failure> {
        if let Some(down) = &self.down {
            return Err(down.clone());
        }
        self.revokes.borrow_mut().push(share.into());
        let mut shares = self.shares.borrow_mut();
        let Some(found) = shares.iter_mut().find(|s| s.id == share && s.revoked_at.is_none())
        else {
            return Err(refused(404, "cloud.carrier_share.not_found"));
        };
        found.revoked_at = Some(4);
        Ok(found.clone())
    }

    fn members(&self) -> Result<Vec<Member>, Failure> {
        if let Some(down) = &self.down {
            return Err(down.clone());
        }
        Ok(self.members.clone())
    }
}

fn refused(status: u16, code: &str) -> Failure {
    Failure::Refused { status, code: code.into(), message: "refused".into() }
}

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

/// The tests run one change at a time; the lock's own exclusion is `flock`'s.
fn no_lock(_: &str, _: &str) -> anyhow::Result<Guard> {
    Ok(Box::new(()))
}

fn here() -> Target {
    Target { machine: VM.into(), here: true }
}

fn elsewhere() -> Target {
    Target { machine: VM.into(), here: false }
}

/// Runs `act` with a person who says yes, surfaces 3 and 4 showing `s-three` and `s-four`, and
/// acpmux resolving a name to `s-<name>`. The asked prompts and the audit lines come back too.
fn run(
    verb: &str,
    args: &[&str],
    all: bool,
    target: &Target,
    api: &dyn Api,
) -> (anyhow::Result<Value>, Vec<String>, Vec<Value>) {
    let mut asked = Vec::new();
    let mut audited = Vec::new();
    let result = {
        let mut confirm = |prompt: &str| -> anyhow::Result<()> {
            asked.push(prompt.to_owned());
            Ok(())
        };
        let surface_session = |surface: u64| -> anyhow::Result<String> {
            match surface {
                3 => Ok("s-three".into()),
                4 => Ok("s-four".into()),
                _ => anyhow::bail!("not a chat"),
            }
        };
        let resolve_session = |key: &str| -> anyhow::Result<String> { Ok(format!("s-{key}")) };
        let local_sessions = || vec![("s-one".to_owned(), "one".to_owned())];
        let mut audit = |entry: Value| audited.push(entry);
        let mut hooks = Hooks {
            confirm: &mut confirm,
            surface_session: &surface_session,
            resolve_session: &resolve_session,
            local_sessions: &local_sessions,
            audit: &mut audit,
            lock: &no_lock,
        };
        act(verb, &words(args), all, None, target, api, &mut hooks)
    };
    (result, asked, audited)
}

#[test]
fn a_share_creates_one_with_the_named_chats_and_asks_first() {
    let api = Platform::default();
    let (answer, asked, audited) = run("share", &["3", "review", ANA], false, &here(), &api);
    let answer = answer.unwrap();
    assert_eq!(answer["share"]["sessions"], json!(["s-three", "s-review"]));
    assert_eq!(
        *api.creates.borrow(),
        vec![json!({"person": ANA, "sessions": ["s-three", "s-review"], "replaces": null})]
    );
    assert_eq!(asked.len(), 1);
    assert!(asked[0].contains(ANA) && asked[0].contains("s-three"), "{}", asked[0]);
    assert_eq!(audited[0]["decision"], "share");
}

#[test]
fn a_share_adds_to_the_persons_live_share_instead_of_replacing_it() {
    let api = Platform::default();
    api.live(ANA, &["s-old"]);
    let (answer, ..) = run("share", &["s-new", ANA], false, &elsewhere(), &api);
    answer.unwrap();
    assert_eq!(api.live_sessions(ANA).unwrap(), ["s-old", "s-new"]);
}

#[test]
fn a_share_already_covered_changes_nothing_and_asks_nothing() {
    let api = Platform::default();
    api.live(ANA, &["s-three"]);
    let (answer, asked, _) = run("share", &["3", ANA], false, &here(), &api);
    assert_eq!(answer.unwrap()["unchanged"], true);
    assert!(api.creates.borrow().is_empty());
    assert!(asked.is_empty());
}

#[test]
fn every_chat_is_refused_with_this_machines_chats_and_nothing_is_sent() {
    let api = Platform::default();
    for (args, all) in [(&[ANA][..], true), (&["3", ANA][..], true), (&[ANA][..], false)] {
        let (answer, asked, _) = run("share", args, all, &here(), &api);
        let message = answer.unwrap_err().to_string();
        assert!(message.contains("isn't supported yet"), "{message}");
        assert!(message.contains("s-one"), "lists the chats: {message}");
        assert!(asked.is_empty());
    }
    // Another machine's chats are not listed from here.
    let (answer, ..) = run("share", &[ANA], true, &elsewhere(), &api);
    assert!(!answer.unwrap_err().to_string().contains("s-one"));
    assert!(api.creates.borrow().is_empty(), "never a create with null sessions");
}

#[test]
fn a_share_never_sends_null_or_empty_sessions() {
    assert_eq!(Sessions::new(Vec::new()), None);
    assert_eq!(Sessions::new(vec!["bad id".to_owned()]), None);
    let sessions = Sessions::new(words(&["a", "b", "a"])).unwrap();
    assert_eq!(
        sessions.body(ANA, None),
        json!({"person": ANA, "sessions": ["a", "b"], "replaces": null})
    );
    assert_eq!(sessions.body(ANA, Some("csh_x"))["replaces"], "csh_x");
}

#[test]
fn a_guest_role_is_refused_on_a_cloud_machine() {
    let api = Platform::default();
    let mut asked = Vec::new();
    let mut confirm = |p: &str| -> anyhow::Result<()> {
        asked.push(p.to_owned());
        Ok(())
    };
    let none = |_: u64| -> anyhow::Result<String> { anyhow::bail!("no") };
    let same = |k: &str| -> anyhow::Result<String> { Ok(k.to_owned()) };
    let listed: fn() -> Vec<(String, String)> = Vec::new;
    let mut audit = |_: Value| {};
    let mut hooks = Hooks {
        confirm: &mut confirm,
        surface_session: &none,
        resolve_session: &same,
        local_sessions: &listed,
        audit: &mut audit,
        lock: &no_lock,
    };
    let error = act("share", &words(&["s", ANA]), false, Some("guest"), &here(), &api, &mut hooks)
        .unwrap_err();
    assert!(error.to_string().contains("guest"), "{error}");
    assert!(api.creates.borrow().is_empty());
}

#[test]
fn a_surface_number_names_a_chat_of_this_machine_only() {
    let api = Platform::default();
    let (answer, ..) = run("share", &["3", ANA], false, &elsewhere(), &api);
    assert!(answer.unwrap_err().to_string().contains("this machine only"));
    // Another machine's chats go by id, as given.
    let (answer, ..) = run("share", &["chat-9", ANA], false, &elsewhere(), &api);
    assert_eq!(answer.unwrap()["share"]["sessions"], json!(["chat-9"]));
}

#[test]
fn shares_lists_the_machines_live_shares() {
    let api = Platform::default();
    api.live(ANA, &["a"]).live(BO, &["b"]);
    let (answer, ..) = run("shares", &[], false, &elsewhere(), &api);
    let answer = answer.unwrap();
    assert_eq!(answer["machine"], VM);
    assert_eq!(answer["shares"].as_array().unwrap().len(), 2);
}

#[test]
fn unshare_revokes_narrows_or_says_there_is_nothing() {
    let api = Platform::default();
    api.live(ANA, &["a", "b"]);
    // One chat out of two: the person keeps the other.
    let (answer, ..) = run("unshare", &["a", ANA], false, &elsewhere(), &api);
    answer.unwrap();
    assert_eq!(api.live_sessions(ANA).unwrap(), ["b"]);
    // The last chat: the share is revoked.
    let (answer, ..) = run("unshare", &["b", ANA], false, &elsewhere(), &api);
    assert!(answer.unwrap()["revoked"]["revoked_at"].is_number());
    assert_eq!(api.live_sessions(ANA), None);
    // Nothing left to unshare.
    let (answer, ..) = run("unshare", &[ANA], false, &elsewhere(), &api);
    assert!(answer.unwrap_err().to_string().contains("no live share"));
}

#[test]
fn unshare_with_no_chats_or_a_share_id_revokes_the_whole_share() {
    let api = Platform::default();
    api.live(ANA, &["a", "b"]).live(BO, &["c"]);
    let (answer, ..) = run("unshare", &[ANA], false, &elsewhere(), &api);
    answer.unwrap();
    let bo = api.shares.borrow().iter().find(|s| s.person == BO).unwrap().id.clone();
    let (answer, ..) = run("unshare", &[bo.as_str()], false, &elsewhere(), &api);
    answer.unwrap();
    assert_eq!(api.revokes.borrow().len(), 2);
    assert!(api.shares.borrow().iter().all(|s| s.revoked_at.is_some()));
}

#[test]
fn a_person_is_a_user_id_or_one_teammates_name() {
    let api = Platform::with_members(&[(ANA, "Ana"), (BO, "Bo"), (BO, "bo")]);
    assert_eq!(person(&api, ANA).unwrap(), ANA);
    assert_eq!(person(&api, "ana").unwrap(), ANA);
    assert!(person(&api, "Bo").unwrap_err().to_string().contains("more than one"));
    assert!(person(&api, "ana@example.com").unwrap_err().to_string().contains("not emails"));
    assert!(person(&api, "Cy").unwrap_err().to_string().contains("no teammate"));
}

#[test]
fn each_platform_refusal_says_what_it_means() {
    let cases = [
        (refused(409, "cloud.carrier.team_unsupported"), "image does not accept teammate"),
        (refused(409, "acpmux.team_without_chats"), "names no chats"),
        (refused(403, "cloud.carrier_share.not_teammate"), "may not use this team's machines"),
        (refused(404, "cloud.machine.not_found"), "no such machine"),
        (refused(403, "auth.forbidden"), "only the machine's creator"),
        (refused(401, "auth.unauthenticated"), "did not accept your sign-in"),
        (refused(503, "owner.unreachable"), "could not be reached"),
        (Failure::Unreachable("dns".into()), "could not be reached"),
        (refused(400, "validation.invalid"), "400 validation.invalid: refused"),
    ];
    for (failure, says) in cases {
        let message = explain(&failure);
        assert!(message.contains(says), "{failure:?}: {message}");
    }
}

#[test]
fn a_share_route_answer_is_its_value_or_its_refusal() {
    let share = json!({"share": {"id": "csh_aaaaaaaaaaaaaaaaaaaa", "machine": VM, "person": ANA,
        "sessions": ["a"], "created_at": 1, "revoked_at": null, "created_by": BO}});
    let ok = serde_json::to_vec(&json!({"ok": true, "value": share})).unwrap();
    let value = value_of(200, &ok).unwrap();
    assert_eq!(share_of(&value).unwrap().sessions.unwrap(), ["a"]);
    let refusal =
        br#"{"ok":false,"error":{"code":"cloud.carrier_share.not_teammate","message":"no"}}"#;
    assert_eq!(
        value_of(403, refusal),
        Err(Failure::Refused {
            status: 403,
            code: "cloud.carrier_share.not_teammate".into(),
            message: "no".into()
        })
    );
    assert!(matches!(value_of(200, b"<html>"), Err(Failure::Unreadable(_))));
    assert!(matches!(value_of(200, br#"{"ok":false}"#), Err(Failure::Unreadable(_))));
    // An "every chat" share reads as one (`sessions: null`).
    let all = json!({"shares": [{"id": "csh_bbbbbbbbbbbbbbbbbbbb", "machine": VM, "person": ANA,
        "sessions": null, "created_at": 1, "revoked_at": null, "created_by": BO}]});
    assert_eq!(shares_of(&all).unwrap()[0].sessions, None);
}

#[test]
fn the_target_is_the_named_machine_or_this_cloud_machine() {
    let own = || Some(VM.to_owned());
    assert_eq!(target(None, own()).unwrap(), Some(here()));
    assert_eq!(target(None, None).unwrap(), None, "a tailnet host keeps its own shares");
    let other = "vm_bbbbbbbbbbbbbbbbbbbb";
    assert_eq!(
        target(Some(other), own()).unwrap(),
        Some(Target { machine: other.into(), here: false })
    );
    assert_eq!(target(Some(format!("machine:{VM}").as_str()), own()).unwrap(), Some(here()));
    assert!(target(Some("i-provider"), own()).is_err());
}

/// The one login on the teammate allowlist, which a consented grant can admit.
const TEAMMATE: &str = "lawrence@manaflow.ai";
const BOOT: &str = "boot-1";

/// A member share of `session` by the allowlisted teammate, verified as `person`.
fn local(person: &str, session: &str) -> Share {
    Share {
        surface: 3,
        login: TEAMMATE.into(),
        role: Role::Member,
        shared_at: "2026-11-01T00:00:00Z".into(),
        generation: BOOT.into(),
        session: session.into(),
        person: (!person.is_empty()).then(|| person.to_owned()),
    }
}

fn grant(revoked: bool, consented: bool, scopes: &[Scope]) -> Grant {
    Grant {
        login: TEAMMATE.into(),
        scopes: scopes.to_vec(),
        consented_at: consented.then(|| "2026-11-01T00:00:00Z".to_owned()),
        consented_via: Some("cli-tty".into()),
        revoked_at: revoked.then(|| "2026-11-02T00:00:00Z".to_owned()),
    }
}

/// A host with teammate access on and the teammate's consented `agents` grant.
fn with_shares(shares: Vec<Share>) -> config::Config {
    config::Config {
        enabled: true,
        teammate_access: true,
        grants: vec![grant(false, true, &[Scope::Agents])],
        shares,
        ..config::Config::default()
    }
}

fn moved(config: config::Config, api: &Platform) -> MoveOutcome {
    move_local(config, api, VM, "now", Some(BOOT)).unwrap()
}

#[test]
fn local_shares_move_once_and_what_cannot_move_stays() {
    let api = Platform::default();
    api.live(BO, &["s-bo-old"]);
    let guest = Share { role: Role::Guest, ..local(ANA, "s-4") };
    let config = with_shares(vec![
        local(ANA, "s-1"),
        local(ANA, "s-2"),
        local(BO, "s-3"),
        guest,
        local("", "s-5"),
        local(BO, ""),
    ]);
    let outcome = moved(config, &api);
    assert!(outcome.failed.is_none());
    // One create per person, added to what they already had.
    assert_eq!(api.creates.borrow().len(), 2);
    assert_eq!(api.live_sessions(ANA).unwrap(), ["s-1", "s-2"]);
    assert_eq!(api.live_sessions(BO).unwrap(), ["s-bo-old", "s-3"]);
    let moved_ids: Vec<_> = outcome.moved.iter().map(|m| m.session.as_str()).collect();
    assert_eq!(moved_ids, ["s-1", "s-2", "s-3"]);
    assert_eq!(outcome.config.moved_shares, outcome.moved);
    let left: Vec<_> = outcome.config.shares.iter().map(|s| s.session.as_str()).collect();
    assert_eq!(left, ["s-4", "s-5", ""]);
    let reasons: Vec<_> = outcome.kept.iter().map(|k| k.reason).collect();
    assert_eq!(reasons, ["guest", "no verified identity", "no chat"]);
    // A second run finds nothing to move.
    let again = moved(outcome.config, &api);
    assert!(again.moved.is_empty());
    assert_eq!(api.creates.borrow().len(), 2);
}

#[test]
fn a_display_name_that_matches_never_moves_a_share_without_a_verified_id() {
    // The teammate's display name equals the share's tailnet login, but that is no identity.
    let api = Platform::with_members(&[(ANA, TEAMMATE)]);
    let outcome = moved(with_shares(vec![local("", "s-1")]), &api);
    assert!(outcome.moved.is_empty());
    assert!(api.creates.borrow().is_empty());
    assert_eq!(outcome.kept[0].reason, "no verified identity");
    assert_eq!(outcome.config.shares.len(), 1, "it stays local");
}

#[test]
fn a_revoked_or_unconsented_share_is_never_recreated_on_the_platform() {
    let api = Platform::default();
    let cases = [
        vec![grant(true, true, &[Scope::Agents])],
        vec![grant(false, false, &[Scope::Agents])],
        vec![grant(false, true, &[Scope::Status])],
        Vec::new(),
    ];
    for grants in cases {
        let config = config::Config { grants, ..with_shares(vec![local(ANA, "s-1")]) };
        let outcome = moved(config, &api);
        assert!(outcome.moved.is_empty());
        assert_eq!(outcome.kept[0].reason, "revoked");
        assert_eq!(outcome.config.shares.len(), 1);
    }
    let off = config::Config { teammate_access: false, ..with_shares(vec![local(ANA, "s-1")]) };
    assert_eq!(moved(off, &api).kept[0].reason, "revoked");
    assert!(api.creates.borrow().is_empty(), "never a create for a share without access");
}

#[test]
fn an_expired_share_is_never_recreated_on_the_platform() {
    let api = Platform::default();
    let old = Share { generation: "boot-0".into(), ..local(ANA, "s-1") };
    let outcome = moved(with_shares(vec![old]), &api);
    assert_eq!(outcome.kept[0].reason, "expired");
    // A boot that cannot be read moves nothing either.
    let unknown = move_local(with_shares(vec![local(ANA, "s-1")]), &api, VM, "now", None).unwrap();
    assert_eq!(unknown.kept[0].reason, "expired");
    assert!(api.creates.borrow().is_empty());
}

#[test]
fn a_crash_between_the_create_and_the_config_write_moves_without_a_second_create() {
    let api = Platform::default();
    let config = with_shares(vec![local(ANA, "s-1")]);
    // The first run's creates reach the platform, then the process dies before its write.
    let lost = moved(config.clone(), &api);
    assert_eq!(lost.moved.len(), 1);
    drop(lost);
    assert_eq!(api.creates.borrow().len(), 1);
    // The re-run reads the same config: the share is covered, so it only leaves the config.
    let rerun = moved(config, &api);
    assert_eq!(api.creates.borrow().len(), 1, "no second create");
    assert!(rerun.config.shares.is_empty());
    assert_eq!(rerun.config.moved_shares.len(), 1);
    assert_eq!(rerun.moved[0].share, api.shares.borrow()[0].id);
}

#[test]
fn an_unreachable_platform_moves_nothing_and_keeps_every_local_share() {
    let api =
        Platform { down: Some(Failure::Unreachable("offline".into())), ..Platform::default() };
    let config = with_shares(vec![local(ANA, "s-1"), local(BO, "s-2")]);
    assert_eq!(
        move_local(config, &api, VM, "now", Some(BOOT)).unwrap_err(),
        Failure::Unreachable("offline".into())
    );
}

#[test]
fn a_create_that_fails_keeps_that_person_and_the_rest_local() {
    let api = Platform {
        refuse_create_for: Some((BO.into(), Failure::Unreachable("reset".into()))),
        ..Platform::default()
    };
    let config = with_shares(vec![
        local(ANA, "s-1"),
        local(BO, "s-2"),
        local("user_00000000000000000c0c", "s-3"),
    ]);
    let outcome = moved(config, &api);
    assert_eq!(outcome.failed, Some(Failure::Unreachable("reset".into())));
    let moved_ids: Vec<_> = outcome.moved.iter().map(|m| m.session.as_str()).collect();
    assert_eq!(moved_ids, ["s-1"]);
    let left: Vec<_> = outcome.config.shares.iter().map(|s| s.session.as_str()).collect();
    assert_eq!(left, ["s-2", "s-3"]);
}

fn every_chat_share(api: &Platform) {
    api.shares.borrow_mut().push(PlatformShare {
        id: "csh_cccccccccccccccccccc".into(),
        machine: VM.into(),
        person: ANA.into(),
        sessions: None,
        created_at: None,
        revoked_at: None,
        created_by: None,
    });
}

#[test]
fn an_every_chat_platform_share_never_takes_the_place_of_a_local_share() {
    // A machine refuses a grant with no chats, so Ana's every-chat share admits her to none: her
    // local share is her only way in, and it stays, with its grant.
    let api = Platform::default();
    every_chat_share(&api);
    let config = config::Config {
        grants: vec![grant(false, true, &[Scope::Agents, Scope::Shell])],
        ..with_shares(vec![local(ANA, "s-1")])
    };
    let outcome = moved(config, &api);
    assert!(outcome.moved.is_empty());
    assert!(outcome.failed.is_none());
    assert_eq!(outcome.kept.iter().map(|k| k.reason).collect::<Vec<_>>(), ["every-chat share"]);
    assert!(api.creates.borrow().is_empty(), "the owner's share is left as it is");
    assert_eq!(outcome.config.shares, vec![local(ANA, "s-1")]);
    assert!(outcome.config.moved_shares.is_empty());
    // Still admitted to the chat, on the filtered proxy.
    assert!(outcome.config.grants.iter().all(|g| g.revoked_at.is_none()), "the grant stays");
    assert_eq!(next_connection(&outcome.config), Some(true));
    // The proxy still lets her prompt the shared chat.
    let frame = json!({"cmd": "agent-session-prompt", "surface": 3, "text": "hi"});
    let author = json!({"login": TEAMMATE});
    let filtered = crate::remote_host::agent_proxy::filter(&outcome.config, &author, BOOT, frame);
    assert!(filtered.is_ok(), "{filtered:?}");
}

#[test]
fn sharing_a_chat_with_an_every_chat_share_names_it_and_unshare_by_name_is_refused() {
    let api = Platform::default();
    every_chat_share(&api);
    let text = &crate::localization::catalog().host_share;
    let (answer, ..) = run("unshare", &["s-1", ANA], false, &elsewhere(), &api);
    assert!(answer.unwrap_err().to_string().contains(text.all_share_narrow));
    // `share` is not "already covered": it writes the chat by name in place of the share.
    let (answer, ..) = run("share", &["s-1", ANA], false, &elsewhere(), &api);
    answer.unwrap();
    assert_eq!(api.live_sessions(ANA).unwrap(), ["s-1"]);
    assert_eq!(api.creates.borrow()[0]["replaces"], "csh_cccccccccccccccccccc");
}

#[test]
fn shares_says_an_every_chat_share_admits_to_no_chat() {
    let api = Platform::default();
    every_chat_share(&api);
    api.live(BO, &["a"]);
    let (answer, ..) = run("shares", &[], false, &elsewhere(), &api);
    let answer = answer.unwrap();
    assert_eq!(answer["shares"][0]["admits_chats"], false);
    assert!(answer["shares"][1].get("admits_chats").is_none());
    let both = listing(&[], Ok(api.list(VM).unwrap()));
    let every: Vec<_> =
        both["shares"].as_array().unwrap().iter().map(|s| s["admits_chats"].clone()).collect();
    assert_eq!(every, [json!(false), Value::Null]);
}

/// Runs `unshare` whose confirmation waits while `meanwhile` runs, as a second person's change
/// that lands while the first one's prompt is open.
fn unshare_while(api: &Platform, args: &[&str], meanwhile: &dyn Fn()) -> anyhow::Result<Value> {
    let mut confirm = |_: &str| -> anyhow::Result<()> {
        meanwhile();
        Ok(())
    };
    let none = |_: u64| -> anyhow::Result<String> { anyhow::bail!("no") };
    let same = |k: &str| -> anyhow::Result<String> { Ok(k.to_owned()) };
    let listed: fn() -> Vec<(String, String)> = Vec::new;
    let mut audit = |_: Value| {};
    let mut hooks = Hooks {
        confirm: &mut confirm,
        surface_session: &none,
        resolve_session: &same,
        local_sessions: &listed,
        audit: &mut audit,
        lock: &no_lock,
    };
    act("unshare", &words(args), false, None, &elsewhere(), api, &mut hooks)
}

#[test]
fn two_concurrent_removals_end_with_neither_chat_shared() {
    let api = Platform::default();
    api.live(ANA, &["a", "b"]);
    // A takes out `a`; while A's prompt is open, B takes out `b`.
    let answer = unshare_while(&api, &["a", ANA], &|| {
        let (answer, ..) = run("unshare", &["b", ANA], false, &elsewhere(), &api);
        answer.unwrap();
    });
    answer.unwrap();
    assert_eq!(api.live_sessions(ANA), None, "neither chat is shared");
    assert!(api.shares.borrow().iter().all(|s| s.revoked_at.is_some()));
}

#[test]
fn a_share_made_while_the_prompt_waits_is_not_overwritten_by_an_older_list() {
    let api = Platform::default();
    api.live(ANA, &["a", "b"]);
    // A takes out `a`; meanwhile `c` is added. A keeps `c`.
    let answer = unshare_while(&api, &["a", ANA], &|| {
        let (answer, ..) = run("share", &["c", ANA], false, &elsewhere(), &api);
        answer.unwrap();
    });
    answer.unwrap();
    assert_eq!(api.live_sessions(ANA).unwrap(), ["b", "c"]);
}

fn flags(words: &[&str]) -> Flags {
    let args: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
    Flags::parse(&args, &["role", "machine"], &["json", "all"]).unwrap()
}

#[test]
fn an_unmigrated_local_share_keeps_the_tailnet_hosts_unshare_and_share_paths() {
    // A local share with no verified person stays local, so its unshare stays local too.
    let config = with_shares(vec![local("", "s-1")]);
    assert!(stays_local("unshare", &flags(&["3", TEAMMATE]), &config, &here()));
    assert!(stays_local("unshare", &flags(&["3", "Lawrence@Manaflow.ai"]), &config, &here()));
    // ... and the local removal itself is the base one.
    let after = shares::applied(
        "unshare",
        config.clone(),
        3,
        TEAMMATE,
        Role::Member,
        &shares::Chat::default(),
        &shares::Chat::default(),
    )
    .unwrap();
    assert!(after.shares.is_empty());
    // A guest share is made where it is enforced: the platform has no read-only teammate.
    assert!(stays_local("share", &flags(&["3", TEAMMATE, "--role", "guest"]), &config, &here()));
    // Everything else goes to the platform.
    assert!(!stays_local("unshare", &flags(&["4", TEAMMATE]), &config, &here()));
    assert!(!stays_local("unshare", &flags(&["3", ANA]), &config, &here()));
    assert!(!stays_local("unshare", &flags(&["3", TEAMMATE]), &config, &elsewhere()));
    assert!(!stays_local("unshare", &flags(&["3", TEAMMATE, "--machine", VM]), &config, &here()));
    assert!(!stays_local("share", &flags(&["3", ANA]), &config, &here()));
    assert!(!stays_local("shares", &flags(&[]), &config, &here()));
}

#[test]
fn shares_lists_local_and_cloud_shares_marked_by_where_they_live() {
    let api = Platform::default();
    api.live(ANA, &["a"]);
    let local_shares = vec![local("", "s-1")];
    let both = listing(&local_shares, api.list(VM).map_err(|f| explain(&f)));
    let wheres: Vec<_> =
        both["shares"].as_array().unwrap().iter().map(|s| s["where"].clone()).collect();
    assert_eq!(wheres, [json!("local"), json!("cloud")]);
    assert_eq!(both["shares"][0]["session"], "s-1");
    // Without the platform, the local shares still list, with the reason.
    let offline = listing(&local_shares, Err("offline".into()));
    assert_eq!(offline["shares"].as_array().unwrap().len(), 1);
    assert_eq!(offline["cloud_error"], "offline");
}

/// Where `TEAMMATE`'s next tailnet connection lands: `None` refused, `Some(true)` the filtered
/// agent proxy, `Some(false)` the raw daemon.
fn next_connection(config: &config::Config) -> Option<bool> {
    let identity = crate::remote_host::tailnet::Identity {
        login: Some(TEAMMATE.to_owned()),
        node: "teammate-laptop".to_owned(),
        tags: vec![],
        shared: false,
    };
    let peer: std::net::IpAddr = "100.80.2.2".parse().unwrap();
    let self_ip: std::net::IpAddr = "100.70.1.1".parse().unwrap();
    match crate::remote_host::admit::decide(config, &[self_ip], peer, Ok(identity)) {
        crate::remote_host::admit::Decision::Guest(_, scopes) => {
            Some(crate::remote_host::serve::proxied(config, Some(TEAMMATE), Some(&scopes)))
        }
        crate::remote_host::admit::Decision::Refused(_) => None,
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_teammate_with_agents_and_shell_never_reaches_the_raw_daemon_after_the_move() {
    let api = Platform::default();
    let config = config::Config {
        grants: vec![grant(false, true, &[Scope::Agents, Scope::Shell])],
        ..with_shares(vec![local(ANA, "s-1")])
    };
    assert_eq!(next_connection(&config), Some(true), "the local share keeps them proxied");
    let outcome = moved(config, &api);
    assert_eq!(outcome.moved.len(), 1);
    assert!(outcome.config.shares.is_empty());
    assert_eq!(next_connection(&outcome.config), None, "the grant ends with its last share");
    assert!(outcome.config.grants.iter().all(|g| g.revoked_at.is_some()));
}

#[test]
fn a_grant_with_a_share_left_here_stays_and_stays_proxied() {
    let api = Platform::default();
    let guest = Share { role: Role::Guest, ..local(ANA, "s-2") };
    let config = config::Config {
        grants: vec![grant(false, true, &[Scope::Agents, Scope::Shell])],
        ..with_shares(vec![local(ANA, "s-1"), guest])
    };
    let outcome = moved(config, &api);
    assert_eq!(outcome.moved.len(), 1);
    assert_eq!(outcome.config.shares.len(), 1, "the guest share stays here");
    assert!(outcome.config.grants.iter().all(|g| g.revoked_at.is_none()));
    assert_eq!(next_connection(&outcome.config), Some(true));
}

/// A change another host makes to the stand-in platform.
type Meanwhile<'a> = Box<dyn Fn(&Platform) + 'a>;

/// The stand-in platform, with `before` run right before each of this run's first `times` writes:
/// a writer on another host whose change lands between this run's read and its write.
struct Interleaved<'a> {
    platform: &'a Platform,
    before: Meanwhile<'a>,
    times: RefCell<u32>,
}

impl Interleaved<'_> {
    fn meanwhile(&self) {
        let mut times = self.times.borrow_mut();
        if *times > 0 {
            *times -= 1;
            drop(times);
            (self.before)(self.platform);
        }
    }
}

impl Api for Interleaved<'_> {
    fn list(&self, machine: &str) -> Result<Vec<PlatformShare>, Failure> {
        self.platform.list(machine)
    }
    fn create(
        &self,
        m: &str,
        p: &str,
        s: &Sessions,
        replaces: Option<&str>,
    ) -> Result<PlatformShare, Failure> {
        self.meanwhile();
        self.platform.create(m, p, s, replaces)
    }
    fn revoke(&self, m: &str, share: &str) -> Result<PlatformShare, Failure> {
        self.meanwhile();
        self.platform.revoke(m, share)
    }
    fn members(&self) -> Result<Vec<Member>, Failure> {
        self.platform.members()
    }
}

fn interleaved<'a>(platform: &'a Platform, times: u32, before: Meanwhile<'a>) -> Interleaved<'a> {
    Interleaved { platform, before, times: RefCell::new(times) }
}

/// Another host's `unshare CHAT ANA`, run to the end.
fn other_host_unshares(chat: &'static str) -> Meanwhile<'static> {
    Box::new(move |p: &Platform| {
        let (answer, ..) = run("unshare", &[chat, ANA], false, &elsewhere(), p);
        answer.unwrap();
    })
}

#[test]
fn a_stale_write_from_another_host_is_refused_and_redone_from_the_live_share() {
    let platform = Platform::default();
    platform.live(ANA, &["a", "b", "c"]);
    // A reads [a, b, c] to drop `a`; before A writes, B drops `b` and sees [a, c]. A's write of
    // [b, c] names the share B replaced, so the platform refuses it; A reads [a, c] and writes [c].
    let api = interleaved(&platform, 1, other_host_unshares("b"));
    unshare_while_on(&api, &["a", ANA]).unwrap();
    assert_eq!(platform.live_sessions(ANA).unwrap(), ["c"], "b stays removed");
    let creates = platform.creates.borrow();
    let tried: Vec<_> = creates.iter().map(|c| c["sessions"].clone()).collect();
    assert_eq!(tried, [json!(["a", "c"]), json!(["b", "c"]), json!(["c"])]);
}

#[test]
fn a_revoke_of_a_share_another_host_replaced_is_redone_from_the_live_share() {
    let platform = Platform::default();
    platform.live(ANA, &["a", "b"]);
    // A revokes the whole share; before that lands, B narrows it to [a]. A then revokes [a].
    let api = interleaved(&platform, 1, other_host_unshares("b"));
    unshare_while_on(&api, &[ANA]).unwrap();
    assert_eq!(platform.live_sessions(ANA), None);
    assert_eq!(platform.revokes.borrow().len(), 2);
}

#[test]
fn a_share_that_keeps_conflicting_stops_after_three_writes_with_an_error() {
    let platform = Platform::default();
    platform.live(ANA, &["a", "b"]);
    let api = interleaved(
        &platform,
        u32::MAX,
        Box::new(|p: &Platform| {
            let live = p.live_sessions(ANA).unwrap_or_default();
            let now = live.iter().map(String::as_str).chain(["z"]).collect::<Vec<_>>();
            let current = p.list(VM).unwrap().into_iter().find(|s| s.person == ANA).map(|s| s.id);
            p.create(VM, ANA, &sessions(&now), current.as_deref()).unwrap();
        }),
    );
    let error = unshare_while_on(&api, &["a", ANA]).unwrap_err();
    let text = &crate::localization::catalog().host_share;
    assert!(error.to_string().contains(text.narrow_raced), "{error}");
    let ours = platform
        .creates
        .borrow()
        .iter()
        .filter(|c| c["sessions"].get(0) != Some(&json!("a")))
        .count();
    assert_eq!(ours, 3, "three writes of its own, each refused");
}

#[test]
fn a_first_share_sends_replaces_null_and_a_share_made_meanwhile_is_merged_not_overwritten() {
    let platform = Platform::default();
    // Before this share's write, another host shares `x` with Ana: the write that said "Ana has
    // no live share" (replaces: null) is refused, and the next one adds to `x`.
    let api = interleaved(
        &platform,
        1,
        Box::new(|p: &Platform| {
            p.create(VM, ANA, &sessions(&["x"]), None).unwrap();
        }),
    );
    let (answer, ..) = run("share", &["a", ANA], false, &elsewhere(), &api);
    answer.unwrap();
    assert_eq!(platform.live_sessions(ANA).unwrap(), ["x", "a"]);
    let creates = platform.creates.borrow();
    assert_eq!(creates[0]["replaces"], Value::Null);
    assert_eq!(creates[1]["replaces"], Value::Null, "the other host's first share");
    assert!(creates[2]["replaces"].as_str().is_some_and(|id| id.starts_with("csh_")));
}

#[test]
fn every_write_names_the_share_it_replaces() {
    let platform = Platform::default();
    platform.live(BO, &["s-bo-old"]);
    // move_local: one person with a live share, one without.
    let config = with_shares(vec![local(ANA, "s-1"), local(BO, "s-3")]);
    let outcome = move_local(config, &platform, VM, "now", Some(BOOT)).unwrap();
    assert_eq!(outcome.moved.len(), 2);
    // share, then narrow.
    run("share", &["s-2", ANA], false, &elsewhere(), &platform).0.unwrap();
    run("unshare", &["s-1", ANA], false, &elsewhere(), &platform).0.unwrap();
    let creates = platform.creates.borrow();
    assert_eq!(creates.len(), 4);
    assert_eq!(creates[0]["replaces"], Value::Null, "Ana had no live share");
    assert_eq!(creates[1]["replaces"], json!("csh_00000000000000000000"), "Bo's live share");
    for later in &creates[2..] {
        assert!(later["replaces"].as_str().is_some_and(|id| id.starts_with("csh_new")), "{later}");
    }
}

#[test]
fn a_move_that_conflicts_merges_with_the_share_made_meanwhile() {
    let platform = Platform::default();
    let api = interleaved(
        &platform,
        1,
        Box::new(|p: &Platform| {
            p.create(VM, ANA, &sessions(&["x"]), None).unwrap();
        }),
    );
    let outcome = move_local(with_shares(vec![local(ANA, "s-1")]), &api, VM, "now", Some(BOOT));
    let outcome = outcome.unwrap();
    assert!(outcome.failed.is_none());
    assert_eq!(platform.live_sessions(ANA).unwrap(), ["x", "s-1"]);
    assert!(outcome.config.shares.is_empty());
}

#[test]
fn a_conflict_answer_reads_as_a_conflict() {
    let body = br#"{"ok":false,"error":{"code":"cloud.carrier_share.conflict","message":"m","current":null}}"#;
    let failure = value_of(409, body).unwrap_err();
    assert!(conflict(&failure), "{failure:?}");
}

fn sessions(ids: &[&str]) -> Sessions {
    Sessions::new(ids.iter().map(|s| (*s).to_owned())).unwrap()
}

fn unshare_while_on(api: &dyn Api, args: &[&str]) -> anyhow::Result<Value> {
    let mut confirm = |_: &str| -> anyhow::Result<()> { Ok(()) };
    let none = |_: u64| -> anyhow::Result<String> { anyhow::bail!("no") };
    let same = |k: &str| -> anyhow::Result<String> { Ok(k.to_owned()) };
    let listed: fn() -> Vec<(String, String)> = Vec::new;
    let mut audit = |_: Value| {};
    let mut hooks = Hooks {
        confirm: &mut confirm,
        surface_session: &none,
        resolve_session: &same,
        local_sessions: &listed,
        audit: &mut audit,
        lock: &no_lock,
    };
    act("unshare", &words(args), false, None, &elsewhere(), api, &mut hooks)
}
