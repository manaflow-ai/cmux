use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

fn proc(pid: u32, ppid: u32, exe: &str) -> Proc {
    Proc { pid, ppid, exe: exe.to_owned() }
}

fn of(table: &[Proc]) -> impl Fn(u32) -> Option<Proc> + '_ {
    move |pid| table.iter().find(|p| p.pid == pid).cloned()
}

fn no_walk() -> Chain {
    panic!("the environment was enough")
}

/// Claude Code in Claude desktop, as its shell's environment reads.
const DESKTOP: &[(&str, &str)] = &[
    ("CLAUDECODE", "1"),
    ("CLAUDE_CODE_ENTRYPOINT", "claude-desktop"),
    ("CLAUDE_CODE_SESSION_ID", "8f0c2b7e-session"),
    ("CLAUDE_CODE_HOST_SESSION_ID", "local_01HZYX"),
    ("CLAUDE_CODE_DESKTOP_APP_VERSION", "1.0.734"),
    ("CLAUDE_PID", "4242"),
];

#[test]
fn claude_desktop_is_read_from_claude_codes_environment() {
    let claim = detect(&env(DESKTOP), no_walk).unwrap();
    assert_eq!(
        claim,
        json!({"harness": "claude-code", "source": "env", "entrypoint": "claude-desktop",
               "sessionId": "8f0c2b7e-session", "hostSessionId": "local_01HZYX",
               "appVersion": "1.0.734", "pid": 4242})
    );
}

#[test]
fn claude_code_in_a_terminal_names_its_cli_entrypoint() {
    let claim =
        claude_code(&env(&[("CLAUDECODE", "1"), ("CLAUDE_CODE_ENTRYPOINT", "cli")])).unwrap();
    assert_eq!(claim["entrypoint"], "cli");
    assert!(claim.get("hostSessionId").is_none());
    assert!(claude_code(&env(&[("CLAUDE_CODE_ENTRYPOINT", "sdk-ts")])).is_some(), "the SDK");
    assert!(claude_code(&env(&[("CLAUDECODE", "0")])).is_none());
    assert!(
        claude_code(&env(&[("CLAUDE_PID", "notapid"), ("CLAUDECODE", "1")]))
            .unwrap()
            .get("pid")
            .is_none()
    );
}

#[test]
fn codex_is_read_from_its_thread() {
    let claim =
        codex(&env(&[("CODEX_THREAD_ID", "01a1b838-thread"), ("CODEX_VERSION", "0.164.0")]))
            .unwrap();
    assert_eq!(
        claim,
        json!({"harness": "codex", "source": "env", "sessionId": "01a1b838-thread", "version": "0.164.0"})
    );
    assert_eq!(codex(&env(&[("CODEX_SESSION_ID", "s")])).unwrap()["sessionId"], "s");
    assert!(codex(&env(&[("CODEX_HOME", "/x")])).is_none(), "a config dir names no running Codex");
}

#[test]
fn a_codex_run_under_a_claude_shell_is_codex_by_its_chain_or_by_default() {
    let both = [("CLAUDECODE", "1"), ("CODEX_THREAD_ID", "t")];
    let codex_nearer = || Chain { harness: Some(("codex".into(), 10)), app: None };
    assert_eq!(detect(&env(&both), codex_nearer).unwrap()["harness"], "codex");
    let claude_nearer = || Chain { harness: Some(("claude-code".into(), 10)), app: None };
    assert_eq!(detect(&env(&both), claude_nearer).unwrap()["harness"], "claude-code");
    assert_eq!(detect(&env(&both), Chain::default).unwrap()["harness"], "codex");
}

#[test]
fn ai_agent_names_another_harness() {
    let claim = ai_agent(&env(&[("AI_AGENT", "claude-code_2-1-310_agent")])).unwrap();
    assert_eq!(claim, json!({"harness": "claude-code", "source": "env", "version": "2.1.310"}));
    assert!(ai_agent(&env(&[("AI_AGENT", "")])).is_none());
}

#[test]
fn in_an_acpmux_session_the_token_proves_it_and_nothing_is_claimed() {
    let inside: Vec<_> = DESKTOP
        .iter()
        .copied()
        .chain([("ACPMUX_SESSION_ID", "s1"), (crate::hub::person::CALLER_TOKEN_ENV, "t")])
        .collect();
    assert_eq!(detect(&env(&inside), no_walk), None);
}

#[test]
fn with_no_markers_the_process_chain_finds_the_harness_and_its_app() {
    let table = [
        proc(50, 40, "/usr/local/bin/acpmux"),
        proc(40, 30, "/bin/zsh"),
        proc(30, 20, "/Users/l/Library/Application Support/Claude/claude-code/2.1.3/claude"),
        proc(20, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    ];
    let walked = chain(of(&table), 50);
    assert_eq!(walked.harness, Some(("claude-code".into(), 30)));
    assert_eq!(walked.app, Some(("Claude.app".into(), "/Applications/Claude.app".into())));
    let claim = detect(&env(&[]), || walked.clone()).unwrap();
    assert_eq!(
        claim,
        json!({"harness": "claude-code", "pid": 30, "source": "process", "app": "Claude.app"})
    );
}

#[test]
fn linux_command_names_find_the_harness() {
    let table = [proc(9, 8, "acpmux"), proc(8, 7, "bash"), proc(7, 6, "claude"), proc(6, 1, "exe")];
    assert_eq!(chain(of(&table), 9).harness, Some(("claude-code".into(), 7)));
}

#[test]
fn an_assistant_app_is_claimed_but_a_terminal_is_the_persons() {
    let duet =
        Chain { harness: None, app: Some(("Duet.app".into(), "/Applications/Duet.app".into())) };
    assert_eq!(
        from_chain(&duet).unwrap(),
        json!({"harness": "Duet", "source": "process", "app": "Duet.app"})
    );
    for app in ["Terminal.app", "iTerm.app", "Ghostty.app", "cmux.app", "cmux DEV next.app"] {
        let terminal =
            Chain { harness: None, app: Some((app.into(), format!("/Applications/{app}"))) };
        assert_eq!(from_chain(&terminal), None, "{app}");
    }
    assert_eq!(detect(&env(&[]), Chain::default), None, "the person's plain shell");
}

#[test]
fn the_chain_stops_at_the_first_app_and_on_a_loop() {
    let table = [
        proc(5, 4, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        proc(4, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    ];
    assert_eq!(chain(of(&table), 5).app.unwrap().0, "Ghostty.app");
    let looped = [proc(3, 2, "sh"), proc(2, 3, "sh")];
    assert_eq!(chain(of(&looped), 3), Chain::default());
}

#[test]
fn an_mcp_client_is_read_from_its_initialize() {
    let claim = from_mcp_client(&json!({"name": "claude-ai", "version": "0.1.0"})).unwrap();
    assert_eq!(claim, json!({"harness": "claude-ai", "source": "mcp", "version": "0.1.0"}));
    assert_eq!(from_mcp_client(&json!({"name": " "})), None);
    assert_eq!(from_mcp_client(&json!({})), None);
}

#[test]
fn the_daemon_keeps_known_one_line_fields_marked_self_reported() {
    let sent = json!({"harness": "claude-code", "entrypoint": "claude-desktop", "pid": 7,
                      "sessionId": "x".repeat(MAX_FIELD_CHARS + 1), "app": "a\nb",
                      "source": "trust-me", "verified": true, "fromSessionId": "forged"});
    let kept = sanitized(&sent).unwrap();
    assert_eq!(
        kept,
        json!({"harness": "claude-code", "entrypoint": "claude-desktop", "pid": 7, "selfReported": true})
    );
    assert_eq!(sanitized(&json!({"entrypoint": "cli"})), None, "no harness, no claim");
    assert_eq!(sanitized(&json!("claude")), None);
}

#[test]
fn the_daemon_records_what_the_peer_pids_chain_shows_beside_the_claim() {
    let walked = Chain {
        harness: Some(("claude-code".into(), 30)),
        app: Some(("Claude.app".into(), "/Applications/Claude.app".into())),
    };
    let signer = |path: &str| {
        (path == "/Applications/Claude.app")
            .then(|| "Developer ID Application: Anthropic".to_owned())
    };
    let found = checked(&walked, 50, signer).unwrap();
    assert_eq!(
        found,
        json!({"peerPid": 50, "harness": "claude-code", "harnessPid": 30, "app": "Claude.app",
               "signedBy": "Developer ID Application: Anthropic"})
    );
    assert_eq!(checked(&Chain::default(), 50, |_| None), None);
    let claimed = sanitized(&json!({"harness": "claude-code"}));
    let rec = record("p1", claimed, Some(found)).unwrap();
    assert_eq!(rec["promptId"], "p1");
    assert_eq!(rec["claimed"]["selfReported"], true);
    assert_eq!(rec["checked"]["app"], "Claude.app");
    assert_eq!(record("p1", None, None), None);
}

#[tokio::test]
async fn a_client_cannot_name_what_the_daemon_checked() {
    let forged = json!({"_meta": {"acpmux": {"promptId": "p",
        "senderHarness": {"harness": "claude-code"},
        "senderHarnessChecked": {"app": "Claude.app", "signedBy": "Anthropic"}}}});
    let mut from_web = forged.clone();
    stamp_checked(&mut from_web, None, false).await;
    assert!(from_web.pointer("/_meta/acpmux/senderHarnessChecked").is_none());
    let rec = recorded(&from_web, Some("p")).unwrap();
    assert_eq!(rec["claimed"]["selfReported"], true);
    assert!(rec.get("checked").is_none(), "only the claim, self-reported");
    // The outbox's own connection and a proven peer carry the daemon's check on.
    let mut carried = forged.clone();
    stamp_checked(&mut carried, None, true).await;
    assert_eq!(recorded(&carried, Some("p")).unwrap()["checked"]["app"], "Claude.app");
}

#[tokio::test]
async fn a_send_with_no_claim_walks_nothing_and_records_nothing() {
    let mut plain = json!({"_meta": {"acpmux": {"promptId": "p"}}});
    stamp_checked(&mut plain, Some(std::process::id()), false).await;
    assert!(plain.pointer("/_meta/acpmux/senderHarnessChecked").is_none());
    assert_eq!(recorded(&plain, Some("p")), None);
    let claimed = json!({"_meta": {"acpmux": {"senderHarness": {"harness": "codex"}}}});
    assert_eq!(recorded(&claimed, None), None, "no prompt id to key it by");
}

#[test]
fn proc_stat_and_codesign_output_parse() {
    let stat = "812 (claude (2)) S 811 812 812 0 -1 4194560";
    assert_eq!(stat_proc(812, stat), Some(proc(812, 811, "claude (2)")));
    assert_eq!(stat_proc(1, "garbage"), None);
    let codesign = "Executable=/Applications/Claude.app/Contents/MacOS/Claude\nAuthority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)\nAuthority=Developer ID Certification Authority\n";
    assert_eq!(
        parse_signer(codesign).unwrap(),
        "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)"
    );
    assert_eq!(parse_signer("code object is not signed at all"), None);
}

#[test]
fn this_process_reads_by_its_own_pid() {
    let own = std::process::id();
    if cfg!(any(target_os = "linux", target_os = "macos")) {
        assert_eq!(lookup(own).map(|p| p.pid), Some(own));
    }
}

#[test]
fn only_the_outbox_and_a_proven_peer_carry_the_daemons_check() {
    // The unix socket's peer: walked, and what it sent of a check dropped.
    assert_eq!(check_trust(SocketPeer::Pid(50), true, false), (Some(50), false));
    // The daemon's own outbox delivering a send it checked at enqueue.
    assert_eq!(check_trust(SocketPeer::Outbox, true, false), (None, true));
    // A peer daemon proven by its peer token.
    assert_eq!(check_trust(SocketPeer::Unknown, false, true), (None, true));
    // A local connection with no peer pid (a Windows pipe, an in-process bridge) is no outbox:
    // its forged check is dropped and nothing is walked.
    assert_eq!(check_trust(SocketPeer::Unknown, true, false), (None, false));
    assert_eq!(check_trust(SocketPeer::Unknown, true, true), (None, false));
    // A paired device or Web client.
    assert_eq!(check_trust(SocketPeer::Unknown, false, false), (None, false));
    // A pid never comes from off the unix socket; if one did, it is not walked.
    assert_eq!(check_trust(SocketPeer::Pid(50), false, false), (None, false));
}

#[test]
fn a_harness_shell_that_names_its_sender_still_says_where_it_came_from() {
    // Base names a Claude desktop shell's sender itself (`cli::sender::implicit`); the claim rides
    // along, so the receiver draws the chip.
    let (from, claim) = of_send(None, &env(DESKTOP), || "mac".into(), no_walk);
    assert_eq!(from.as_deref(), Some("Claude Code desktop on mac · 8f0c2b7e"));
    assert_eq!(claim.unwrap()["entrypoint"], "claude-desktop");
    // A sender named on purpose (--from, ACPMUX_FROM) speaks for itself: no claim.
    let (from, claim) = of_send(Some("lane-a".into()), &env(DESKTOP), || "mac".into(), no_walk);
    assert_eq!((from.as_deref(), claim), (Some("lane-a"), None));
    let named = [DESKTOP, &[("ACPMUX_FROM", "lane-b")]].concat();
    let (from, claim) = of_send(None, &env(&named), || "mac".into(), no_walk);
    assert_eq!((from.as_deref(), claim), (Some("lane-b"), None));
    // The person's own shell names nothing and claims nothing.
    let (from, claim) = of_send(None, &env(&[]), || "mac".into(), Chain::default);
    assert_eq!((from, claim), (None, None));
}

#[test]
fn acpmuxs_own_app_bundle_is_not_where_a_send_came_from() {
    // The acpmux that cmux.app ships, run from Claude desktop's shell: the walk goes past cmux.app
    // to the harness and the app above it.
    let table = [
        proc(50, 40, "/Applications/cmux.app/Contents/Resources/bin/acpmux"),
        proc(40, 30, "/bin/zsh"),
        proc(30, 20, "/Users/l/Library/Application Support/Claude/claude-code/2.1.3/claude"),
        proc(20, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    ];
    let walked = chain(of(&table), 50);
    assert_eq!(walked.harness, Some(("claude-code".into(), 30)));
    assert_eq!(walked.app, Some(("Claude.app".into(), "/Applications/Claude.app".into())));
    // In cmux's own terminal the shell's app is cmux.app, a terminal: the person's.
    let in_cmux = [
        proc(50, 40, "/Applications/cmux.app/Contents/Resources/bin/acpmux"),
        proc(40, 30, "/bin/zsh"),
        proc(30, 1, "/Applications/cmux.app/Contents/MacOS/cmux"),
    ];
    let walked = chain(of(&in_cmux), 50);
    assert_eq!(walked.app, Some(("cmux.app".into(), "/Applications/cmux.app".into())));
    assert_eq!(from_chain(&walked), None);
}

#[test]
fn an_mcp_send_from_codex_under_a_claude_shell_is_codex_by_its_chain_or_by_default() {
    let both = [("CLAUDECODE", "1"), ("CODEX_THREAD_ID", "t-1")];
    let client = json!({"name": "claude-ai"});
    let under = |harness: &str| Chain { harness: Some((harness.into(), 7)), app: None };
    let claim = of_mcp(&env(&both), || under("codex"), Some(&client)).unwrap();
    assert_eq!(claim["harness"], "codex");
    let claim = of_mcp(&env(&both), Chain::default, Some(&client)).unwrap();
    assert_eq!(claim["harness"], "codex");
    let claim = of_mcp(&env(&both), || under("claude-code"), Some(&client)).unwrap();
    assert_eq!(claim["harness"], "claude-code");
    // With no harness markers, the MCP client names itself.
    let claim = of_mcp(&env(&[]), no_walk, Some(&client)).unwrap();
    assert_eq!(claim["harness"], "claude-ai");
}
