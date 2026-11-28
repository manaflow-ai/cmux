use super::*;

fn profile(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
    serde_json::from_value(json!({
        "argv": argv,
        "kind": "claude-stdio",
        "env": env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<std::collections::BTreeMap<_, _>>(),
    }))
    .unwrap()
}

const GATEWAY: &str = "http://sr2-gateway.example.ts.net:4016";

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

/// 2026-11-28: a remote chain's `sr2 claude2` slept forever before its main in the
/// sandbox (or exited on the claude.json.lock EPERM). It now runs Claude Code itself on the sr2
/// gateway, even when acpmux's own `claude` profile is that same launcher.
#[test]
fn sr2_runs_claude_on_the_gateway_never_the_launcher() {
    let sr2 = profile(&["/Users/l/bin/sr2", "claude2"], &[]);
    assert!(is_sr2(&sr2.argv));
    let args = strings(&["claude2", "--autocompact", "149745", "-p"]);
    for claude in [None, Some("/Users/l/bin/sr2".to_string()), Some("claude-sr2".to_string())] {
        let (program, out, routed) =
            sr2_plan(&sr2, args.clone(), claude, Some(GATEWAY.into())).unwrap();
        assert_eq!(program, "claude");
        assert_eq!(out, strings(&["--autocompact", "149745", "-p"]));
        assert_eq!(routed.argv, vec!["claude".to_string()]);
        assert_eq!(routed.env["ANTHROPIC_BASE_URL"], GATEWAY);
        assert_eq!(routed.env["ANTHROPIC_AUTH_TOKEN"], "subrouter2");
    }
    let (program, _, _) =
        sr2_plan(&sr2, args.clone(), Some("/u/.local/bin/claude".into()), Some(GATEWAY.into()))
            .unwrap();
    assert_eq!(program, "/u/.local/bin/claude");
    // The plain `claude` agent word and the `claude-sr2` wrapper run the same way.
    let plain = profile(&["sr2", "claude"], &[]);
    assert!(sr2_plan(&plain, strings(&["claude", "-p"]), None, Some(GATEWAY.into())).is_ok());
    let wrapper = profile(&["/u/.local/bin/claude-sr2"], &[]);
    let (_, out, _) = sr2_plan(&wrapper, strings(&["-p"]), None, Some(GATEWAY.into())).unwrap();
    assert_eq!(out, strings(&["-p"]));
}

/// A shape acpmux cannot run as Claude Code, or no gateway, is refused before any spawn: a
/// reason, never a launch that hangs.
#[test]
fn sr2_without_gateway_or_with_other_words_is_refused() {
    let sr2 = profile(&["sr2", "claude2"], &[]);
    let args = strings(&["claude2", "-p"]);
    let why = sr2_plan(&sr2, args.clone(), None, None).unwrap_err();
    assert!(why.contains(ROUTE_ENV), "{why}");
    for argv in [&["sr2", "codex"][..], &["sr2", "claude2", "--account", "a"], &["sr2", "claudex"]]
    {
        let p = profile(argv, &[]);
        let args: Vec<String> = argv[1..].iter().map(|s| s.to_string()).collect();
        assert!(sr2_plan(&p, args, None, Some(GATEWAY.into())).is_err(), "{argv:?}");
    }
    // Args that do not carry the launcher's words are not this profile's plan.
    assert!(sr2_plan(&sr2, strings(&["-p"]), None, Some(GATEWAY.into())).is_err());
    assert!(!is_sr2(&strings(&["/u/.local/bin/claude"])));
}

/// The route: the profile's own `SUBROUTER2_BASE_URL` first; only an http(s) URL.
#[test]
fn sr2_route_reads_the_profile_first() {
    let p = profile(&["sr2", "claude2"], &[(ROUTE_ENV, " http://g:4016 ")]);
    assert_eq!(route(&p).as_deref(), Some("http://g:4016"));
    let (_, _, routed) = sr2_plan(&p, strings(&["claude2"]), None, route(&p)).unwrap();
    assert!(!routed.env.contains_key(ROUTE_ENV));
    let bad = profile(&["sr2", "claude2"], &[(ROUTE_ENV, "g:4016")]);
    if std::env::var(ROUTE_ENV).is_err() {
        assert_eq!(route(&bad), None);
    }
}
