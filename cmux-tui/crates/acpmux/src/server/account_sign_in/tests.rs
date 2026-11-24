use super::*;
use crate::agent_login::{Machine, github::GhAccount};

fn dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let d =
        std::env::temp_dir().join(format!("account-sign-in-{tag}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn row(id: &str, family: &str, name: &str) -> Value {
    json!({"id": id, "family": family, "name": name, "home": null, "builtin": false})
}

#[test]
fn only_this_machine_and_its_app_may_ask() {
    let none = json!({});
    assert!(allowed(Origin::Local, ConnAuth::LocalSocket, &none));
    assert!(allowed(Origin::LocalApp, ConnAuth::LocalApp, &none));
    assert!(!allowed(Origin::Web, ConnAuth::ListenerToken, &none));
    assert!(!allowed(Origin::Web, ConnAuth::WebDevice, &none));
    assert!(!allowed(Origin::Local, ConnAuth::None, &none));
    let e = refused();
    assert_eq!(e.data.as_ref().and_then(|d| d.get("reason")), Some(&json!(REMOTE_REFUSED)));
}

#[test]
fn the_machines_owner_may_ask_over_the_peer_route() {
    // The person's Mac forwarding its card for a chat here, by the peer token or the Cloud
    // carrier's owner header: the same owner rule `agent_login` runs.
    let forwarded = json!({"family": "github", "sessionId": "s-1"});
    for auth in [ConnAuth::PeerToken, ConnAuth::CarrierOwner] {
        assert!(allowed(Origin::Peer, auth, &forwarded), "{auth:?}");
        assert_eq!(
            allowed(Origin::Peer, auth, &forwarded),
            super::super::agent_login::allowed(Origin::Peer, auth, &forwarded)
        );
    }
}

#[test]
fn anyone_but_the_owner_is_refused_over_the_peer_route() {
    let plain = json!({"family": "codex"});
    // A paired machine, an unproven link.
    for auth in
        [ConnAuth::Device, ConnAuth::ReadOnlyDevice, ConnAuth::ListenerToken, ConnAuth::None]
    {
        assert!(!allowed(Origin::Peer, auth, &plain), "{auth:?}");
    }
    // The owner's daemon forwarding for its own Web client or a paired device.
    for via in ["web", "device"] {
        let p = json!({"family": "claude", "_meta": {"acpmux": {"via": via}}});
        assert!(!allowed(Origin::Peer, ConnAuth::PeerToken, &p), "{via}");
        assert!(!allowed(Origin::Peer, ConnAuth::CarrierOwner, &p), "{via}");
    }
}

#[test]
fn a_teammate_on_a_shared_machine_is_refused() {
    // A team machine's other members reach it through the Cloud carrier as `CarrierTeam`, served
    // as Web: never an account sign-in, whatever the request says.
    let p = json!({"family": "github"});
    assert!(!allowed(Origin::Web, ConnAuth::CarrierTeam, &p));
    assert!(!allowed(Origin::Peer, ConnAuth::CarrierTeam, &p));
}

#[tokio::test]
async fn a_shared_machine_refuses_the_owners_sign_in_too() {
    // The owner passes `allowed`, and a team machine still runs no own sign-in: every member runs
    // as the same user there, so it would be everyone's.
    assert!(allowed(Origin::Peer, ConnAuth::PeerToken, &json!({"family": "github"})));
    let root = dir("shared");
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "team\n").unwrap();
    let m = Machine { root: root.clone(), home: root.join("home") };
    let cli = Cli { program: root.join("no-such-gh").display().to_string(), ..Cli::default() };
    for agent in [Agent::Github, Agent::Codex, Agent::Claude] {
        let e = login::start_in(&m, &cli, agent, None).await.unwrap_err();
        assert_eq!(e.reason, reason::SHARED_MACHINE, "{agent:?}");
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn an_unknown_account_is_refused() {
    let accounts = vec![
        json!({"id": "codex-login", "family": "codex", "name": "ChatGPT", "home": null, "builtin": true}),
        json!({"id": "claude-2", "family": "claude", "name": "Claude 2", "home": "/h/claude-2", "builtin": false}),
        json!({"id": "work-key", "family": "claude", "name": "Key", "home": null, "builtin": false, "key": true}),
    ];
    for id in ["nope", "github:", "github:bad login", "github:-x", "../codex-login"] {
        let e = resolve(id, &accounts).unwrap_err();
        assert_eq!(e.reason, reason::UNKNOWN_ACCOUNT, "{id}");
    }
    assert_eq!(resolve("work-key", &accounts).unwrap_err().reason, reason::UNSUPPORTED);
    assert_eq!(
        resolve("claude-2", &accounts).unwrap(),
        Target::Listed {
            id: "claude-2".into(),
            family: "claude".into(),
            home: Some(PathBuf::from("/h/claude-2")),
            builtin: false
        }
    );
    assert!(matches!(
        resolve("codex-login", &accounts).unwrap(),
        Target::Listed { builtin: true, home: None, .. }
    ));
    assert_eq!(
        resolve("github:octo-cat", &accounts).unwrap(),
        Target::Github { login: "octo-cat".into() }
    );
}

#[test]
fn a_new_account_takes_the_macs_id_and_name() {
    let accounts = vec![
        row("codex-login", "codex", "ChatGPT"),
        row("claude-login", "claude", "Claude Code login"),
    ];
    assert_eq!(
        new_account("codex", &accounts, None, |_| false),
        ("codex-2".into(), "ChatGPT 2".into())
    );
    assert_eq!(
        new_account("claude", &accounts, None, |_| false),
        ("claude-2".into(), "Claude 2".into())
    );
    // A name or id in use, or a folder already there, moves to the next number.
    let mut more = accounts.clone();
    more.push(row("codex-2", "codex", "Work"));
    more.push(row("other", "claude", "ChatGPT 3"));
    assert_eq!(new_account("codex", &more, None, |_| false).0, "codex-4");
    assert_eq!(new_account("codex", &accounts, None, |id| id == "codex-2").0, "codex-3");
    // A typed name, trimmed and kept to 128 characters; a blank one is the picked name.
    let long = "x".repeat(200);
    assert_eq!(new_account("claude", &accounts, Some(&long), |_| false).1.len(), NAME_MAX);
    assert_eq!(new_account("claude", &accounts, Some("  Work  "), |_| false).1, "Work");
    assert_eq!(new_account("claude", &accounts, Some("   "), |_| false).1, "Claude 2");
    assert_eq!(
        account_home(Path::new("/u"), "claude-2"),
        PathBuf::from("/u/.cmux/accounts/claude-2")
    );
}

#[test]
fn github_rows_never_carry_a_token() {
    let got = rows(&[
        GhAccount { login: "alice".into(), active: true, signed_in: true },
        GhAccount { login: "bob".into(), active: false, signed_in: false },
    ]);
    assert_eq!(
        got,
        vec![
            json!({"id": "github:alice", "family": "github", "name": "alice", "signedIn": true, "default": true, "builtin": false}),
            json!({"id": "github:bob", "family": "github", "name": "bob", "signedIn": false, "default": false, "builtin": false}),
        ]
    );
}

/// A cancelled add lists nothing and removes only the home it made: a stand-in Claude that
/// never gets its code, a routes folder with nothing in it, and a folder beside the new home
/// that is not the add's.
#[cfg(unix)]
#[tokio::test]
async fn a_cancelled_add_lists_nothing_and_removes_only_its_home() {
    use std::os::unix::fs::PermissionsExt;
    let root = dir("cancel");
    let routes_dir = root.join("routes");
    std::fs::create_dir_all(&routes_dir).unwrap();
    let accounts_dir = root.join(".cmux/accounts");
    let neighbour = accounts_dir.join("claude-9");
    std::fs::create_dir_all(&neighbour).unwrap();
    std::fs::write(neighbour.join("keep"), "x").unwrap();
    let program = root.join("claude");
    std::fs::write(
        &program,
        "#!/bin/sh\necho 'visit: https://claude.com/cai/oauth/authorize?code=true&state=s1 '\nread code\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();

    let before = super::super::accounts::list(
        Some(&routes_dir),
        &root.join("state"),
        &routes::Bindings::default(),
    );
    let (id, name) = new_account("claude", &before, None, |id| account_home(&root, id).exists());
    let home = account_home(&root, &id);
    let file = add_file("claude", &name, &home).expect("a route file");
    let made = make_home(&file).expect("home");
    assert!(made && home.is_dir());

    let m = Machine { root: root.clone(), home: root.clone() };
    let mut cli = Cli { program: program.display().to_string(), ..Cli::default() };
    cli.env.insert("HOME".into(), root.display().to_string());
    let started = login::start_in(&m, &cli, Agent::Claude, Some(&home)).await.expect("started");
    assert!(started.needs_code);
    lock_pending().insert(
        started.login_id.clone(),
        Pending {
            agent: Agent::Claude,
            account: Some(id.clone()),
            route: Some(id.clone()),
            add: Some(Add { id: id.clone(), file, home: home.clone(), made }),
            busy: false,
        },
    );
    assert!(adding(&id));
    assert!(cancel(&started.login_id));
    assert!(!login::running(&started.login_id) && !adding(&id));
    assert!(!home.exists(), "the add's home stayed");
    assert!(neighbour.join("keep").is_file(), "a folder the add did not make went");
    let after = super::super::accounts::list(
        Some(&routes_dir),
        &root.join("state"),
        &routes::Bindings::default(),
    );
    assert_eq!(after.len(), before.len(), "the cancelled add was listed");
    assert!(!after.iter().any(|a| a["id"] == id.as_str()));
    // A home that was there before the add is never removed.
    drop_home(Agent::Claude, &neighbour, false);
    assert!(neighbour.is_dir());
    assert!(!cancel(&started.login_id));
    let _ = std::fs::remove_dir_all(&root);
}

fn signed(id: &str, family: &str, email: Option<&str>, default: bool) -> Value {
    json!({"id": id, "family": family, "name": format!("{id} name"), "email": email,
        "signedIn": true, "default": default, "enabled": true, "builtin": false})
}

#[test]
fn readiness_names_every_family_in_order() {
    let families: Vec<&str> = READINESS_FAMILIES.iter().map(|(f, _)| *f).collect();
    assert_eq!(families, ["github", "codex", "claude"]);
    assert!(METHODS.contains(&method::MUX_ACCOUNT_READINESS));
}

#[test]
fn a_family_without_its_cli_is_not_installed_whatever_it_lists() {
    let rows = [signed("codex-2", "codex", Some("a@example.com"), true)];
    assert_eq!(
        provider("codex", false, &rows),
        json!({"family": "codex", "state": "notInstalled"})
    );
}

#[test]
fn a_family_with_no_signed_in_account_needs_a_sign_in() {
    let mut out = signed("claude-2", "claude", None, true);
    out["signedIn"] = json!(false);
    let mut off = signed("claude-3", "claude", None, false);
    off["enabled"] = json!(false);
    let other = signed("codex-2", "codex", None, true);
    let want = json!({"family": "claude", "state": "signInRequired"});
    assert_eq!(provider("claude", true, &[out, off, other]), want);
    assert_eq!(provider("claude", true, &[]), want);
}

#[test]
fn ready_names_the_default_signed_in_account_else_the_first() {
    let rows = [
        signed("codex", "codex", Some("own@example.com"), false),
        signed("codex-2", "codex", Some("work@example.com"), true),
    ];
    assert_eq!(
        provider("codex", true, &rows),
        json!({"family": "codex", "state": "ready", "account": "codex-2",
            "label": "work@example.com"})
    );
    let first = [signed("codex", "codex", None, false), signed("codex-2", "codex", None, false)];
    assert_eq!(
        provider("codex", true, &first),
        json!({"family": "codex", "state": "ready", "account": "codex", "label": "codex name"})
    );
}

#[test]
fn a_github_row_is_ready_by_its_login_and_says_nothing_else() {
    let gh = rows(&[
        GhAccount { login: "alice".into(), active: false, signed_in: true },
        GhAccount { login: "bob".into(), active: true, signed_in: true },
    ]);
    let got = provider("github", true, &gh);
    assert_eq!(
        got,
        json!({"family": "github", "state": "ready", "account": "github:bob", "label": "bob"})
    );
    let text = got.to_string().to_ascii_lowercase();
    assert!(!text.contains("token") && !text.contains("code"));
}
