use super::*;

fn turn(status: &str, kind: Option<&str>, text: &str, at: u64) -> Value {
    json!({"status": status, "errorKind": kind, "errorText": text, "endedAt": at})
}

fn facts(probe: Option<&str>, last: Option<Value>, check: Option<Result<Auth, &str>>) -> Facts {
    Facts {
        harness: "claude".into(),
        route_id: probe.map(|_| "proxy".into()),
        probe: probe.map(|s| (5, json!({"status": s, "message": format!("HTTP: {s}")}))),
        turn: last.as_ref().and_then(turn_evidence).map(|t| ("chat-1".into(), t)),
        check: check.map(|c| (9, c.map(|a| (a, "`check` ran".into())).map_err(str::to_owned))),
        login: Some("claude auth login".into()),
    }
}

/// Each state from the evidence that gives it, with its source and when it was seen.
#[test]
fn each_state_comes_from_its_evidence() {
    let signed_out = turn("failed", Some("auth.signed_out"), "Not logged in", 7);
    let expired = turn("failed", Some("auth.expired"), "OAuth token has expired", 7);
    for (f, state, source, at) in [
        (
            facts(None, Some(turn("completed", None, "", 7)), None),
            State::Ready,
            Source::Turn,
            Some(7),
        ),
        (facts(None, Some(signed_out), None), State::SignedOut, Source::Turn, Some(7)),
        (facts(None, Some(expired), None), State::Expired, Source::Turn, Some(7)),
        (
            facts(Some("auth_needed"), None, None),
            State::RouteAuthNeeded,
            Source::RouteProbe,
            Some(5),
        ),
        (
            facts(Some("unreachable"), None, None),
            State::RouteUnreachable,
            Source::RouteProbe,
            Some(5),
        ),
        (facts(None, None, Some(Ok(Auth::Expired))), State::Expired, Source::AuthCheck, Some(9)),
        (facts(None, None, Some(Ok(Auth::SignedIn))), State::Ready, Source::AuthCheck, Some(9)),
        (
            facts(None, None, Some(Ok(Auth::SignedOut))),
            State::SignedOut,
            Source::AuthCheck,
            Some(9),
        ),
        (facts(None, None, None), State::Unknown, Source::None, None),
        (facts(None, None, Some(Ok(Auth::Unknown))), State::Unknown, Source::AuthCheck, Some(9)),
    ] {
        let out = f.decide();
        assert_eq!((out.state, out.source, out.evidence_at), (state, source, at), "{out:?}");
        let blocks = matches!(state, State::SignedOut | State::Expired | State::RouteAuthNeeded);
        assert_eq!(out.login.is_some(), blocks, "{out:?}");
    }
}

#[test]
fn a_new_refusal_supersedes_an_old_success_but_presence_does_not_clear_a_failure() {
    for auth in [Auth::Expired, Auth::SignedOut] {
        let f = facts(None, Some(turn("completed", None, "", 7)), Some(Ok(auth)));
        assert!(!f.settled(), "an old success permits an explicit fresh check");
        let out = f.decide();
        assert_eq!(out.source, Source::AuthCheck);
        assert!(matches!(out.state, State::Expired | State::SignedOut));
    }
    for check in [Ok(Auth::SignedIn), Ok(Auth::Unknown), Err("network error")] {
        let out =
            facts(None, Some(turn("failed", Some("auth.expired"), "expired", 7)), Some(check))
                .decide();
        assert_eq!((out.state, out.source), (State::Expired, Source::Turn));
    }
    let out =
        facts(None, Some(turn("completed", None, "", 7)), Some(Err("network error"))).decide();
    assert_eq!((out.state, out.source), (State::Ready, Source::Turn));
}

#[test]
fn credential_change_survives_metadata_reload_without_changing_turn_history() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    assert!(meta.auth_change.is_none(), "older metadata remains readable");
    let history = turn("failed", Some("auth.expired"), "expired", 7);
    meta.last_turn = Some(history.clone());
    mark_credentials_changed(&mut meta, 9);
    let encoded = serde_json::to_value(&meta).unwrap();
    let mut restored: SessionMeta = serde_json::from_value(encoded).unwrap();
    assert_eq!(restored.last_turn, Some(history));
    assert_eq!(session_evidence(&restored).unwrap().state, State::Unknown);
    restored.last_turn = Some(turn("failed", Some("auth.expired"), "still expired", 10));
    assert_eq!(session_evidence(&restored).unwrap().state, State::Expired);
}

/// No evidence, a check that could not answer, a connection error or a cancel: unknown,
/// never signed out.
#[test]
fn no_evidence_and_transport_errors_are_unknown() {
    for last in [
        turn("failed", None, "API Error: Connection error.", 7),
        turn("failed", Some("agent.exited"), "agent process closed", 7),
        turn("cancelled", None, "", 7),
    ] {
        assert_eq!(turn_evidence(&last), None, "{last}");
        assert_eq!(facts(None, Some(last), None).decide().state, State::Unknown);
    }
    let out =
        facts(None, None, Some(Err("Claude Code may keep its login in its keychain"))).decide();
    assert_eq!((out.state, out.source, out.evidence_at), (State::Unknown, Source::None, None));
    assert!(out.detail.contains("keychain"), "{out:?}");
    // A turn recorded before the auth kinds is read by its text.
    let old = turn("failed", None, "Not logged in · Please run /login", 7);
    assert_eq!(turn_evidence(&old).map(|t| t.state), Some(State::SignedOut));
}

/// An agent's error of many lines and sentences is one sentence in `detail`.
#[test]
fn a_detail_is_one_sentence() {
    let text = "API Error: 401 OAuth token has expired. Please run /login\n\nat step 2";
    let out = facts(None, Some(turn("failed", Some("auth.expired"), text, 7)), None).decide();
    assert_eq!(out.detail, "its last turn failed: API Error: 401 OAuth token has expired.");
    assert_eq!(
        one_sentence("not logged in\nrun claude auth login"),
        "not logged in run claude auth login"
    );
    assert_eq!(one_sentence("see e.g. the docs"), "see e.g. the docs");
    assert_eq!(one_sentence("not logged in. run /login"), "not logged in.");
    assert_eq!(
        one_sentence("Claude said: \"OAuth token expired.\" Please run /login"),
        "Claude said: \"OAuth token expired.\""
    );
    assert_eq!(one_sentence("Error! try again"), "Error!");
    assert_eq!(one_sentence("use v2.1 i.e. the new one"), "use v2.1 i.e. the new one");
    let long = one_sentence(&"word ".repeat(100));
    assert!(long.chars().count() <= DETAIL_CHARS && long.ends_with('…'), "{long}");
}

/// A rate-limited or unknown probe says nothing of the sign-in: the turn answers.
#[test]
fn a_rate_limited_probe_falls_through() {
    for status in ["rate_limited", "unknown", "ok"] {
        let out = facts(Some(status), Some(turn("completed", None, "", 7)), None).decide();
        assert_eq!((out.state, out.source), (State::Ready, Source::Turn), "{status}");
        assert_eq!(out.route_id.as_deref(), Some("proxy"));
        let out = facts(Some(status), None, None).decide();
        assert_eq!(out.state, State::Unknown, "{status}");
    }
}

/// A target's account home is the one its spawn would use: a home the profile pins beats
/// a family or global route's, not one picked for the chat or the profile.
#[test]
fn a_target_keeps_the_home_its_profile_pins() {
    let route = |home: &str| routes::Route {
        id: "r".into(),
        file: serde_json::from_value(json!({"kind": "direct-subscription", "account_home": home}))
            .unwrap(),
        path: PathBuf::new(),
    };
    let at = |home: &str| BTreeMap::from([("CODEX_HOME".to_owned(), home.to_owned())]);
    let pinned = at("/accounts/A");
    let plain = BTreeMap::new();
    let b = route("/accounts/B");
    let home = |env: &BTreeMap<_, _>, scope| target_home(env, "codex", Some((&b, scope)), None);
    assert_eq!(home(&pinned, "global"), Some(PathBuf::from("/accounts/A")));
    assert_eq!(home(&pinned, "family"), Some(PathBuf::from("/accounts/A")));
    assert_eq!(home(&pinned, "chat"), Some(PathBuf::from("/accounts/B")));
    assert_eq!(home(&plain, "global"), Some(PathBuf::from("/accounts/B")));
    assert_eq!(target_home(&pinned, "codex", None, None), Some(PathBuf::from("/accounts/A")));
    let templated = BTreeMap::from([("CODEX_HOME".into(), "${cwd}/.codex".into())]);
    assert_eq!(target_home(&templated, "codex", None, None), None);
    assert_eq!(
        target_home(&templated, "codex", None, Some(Path::new("/project"))),
        Some(PathBuf::from("/project/.codex"))
    );
    // A home the defaults pin holds as the profile's does, and the profile's wins over it.
    let defaulted = with_defaults(&at("/accounts/A"), BTreeMap::new());
    assert_eq!(home(&defaulted, "global"), Some(PathBuf::from("/accounts/A")));
    let both = with_defaults(&at("/accounts/A"), at("/accounts/C"));
    assert_eq!(home(&both, "global"), Some(PathBuf::from("/accounts/C")));
}

/// A route a spawn refuses (gone, or named for the chat but not serving the harness) is an
/// error; a family or global one that does not serve it is none.
#[test]
fn a_route_is_taken_as_a_spawn_takes_it() {
    let chosen = |id: &str, scope: &'static str| Some((id.to_owned(), scope));
    assert!(spawn_route_for(None, chosen("gone", "family"), "claude").is_err());
    assert!(spawn_route_for(None, chosen("cmux", "chat"), "codex").is_err());
    assert!(spawn_route_for(None, chosen("cmux", "profile"), "codex").is_err());
    assert!(matches!(spawn_route_for(None, chosen("cmux", "global"), "codex"), Ok(None)));
    let served = spawn_route_for(None, chosen("cmux", "global"), "claude").unwrap();
    assert_eq!(served.map(|(r, scope)| (r.id, scope)), Some(("cmux".into(), "global")));
    assert!(matches!(spawn_route_for(None, None, "claude"), Ok(None)));
}

#[test]
fn a_chat_in_its_own_account_home_signs_in_there() {
    let home = Path::new("/Users/me/claude two");
    assert_eq!(
        route_account::login_command(
            Some("claude auth login".into()),
            Some(("CLAUDE_CONFIG_DIR", home))
        ),
        Some("CLAUDE_CONFIG_DIR='/Users/me/claude two' claude auth login".into())
    );
    assert_eq!(
        route_account::login_command(Some("codex login".into()), None),
        Some("codex login".into())
    );
}
