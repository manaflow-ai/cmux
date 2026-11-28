use super::*;

fn step(name: &str, status: Status, ms: u64, detail: &str) -> Step {
    Step { step: name.to_owned(), status, ms, detail: detail.to_owned() }
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_reads_every_flag() {
    let args = parse(&words(
        "--backend staging --team t1 --model-stub /s.py --chat-timeout 5 --out /tmp/x",
    ))
    .unwrap();
    assert_eq!(args.backend, "staging");
    assert_eq!(args.team.as_deref(), Some("t1"));
    assert_eq!(args.model_stub, Some(PathBuf::from("/s.py")));
    // Clamped to at least 10 s.
    assert_eq!(args.chat_budget, Duration::from_secs(10));
    assert_eq!(args.out, Some(PathBuf::from("/tmp/x")));
    assert_eq!(args.prompt, DEFAULT_PROMPT);
    assert!(parse(&words("--bogus")).is_err());
    assert!(parse(&words("--backend")).is_err());
    assert!(parse(&words("--chat-timeout soon")).is_err());
}

#[test]
fn backends_resolve_like_the_ts_journey() {
    assert_eq!(resolve_backend("staging").unwrap().0, cmux_cloud_environment::STAGING_API);
    assert_eq!(resolve_backend("prod").unwrap().0, cmux_cloud_environment::PRODUCTION_API);
    assert_eq!(
        resolve_backend("prod").unwrap().1,
        cmux_cloud_environment::PRODUCTION_STACK_PROJECT
    );
    assert_eq!(
        resolve_backend("preview-42").unwrap().0,
        "https://cmux-api-preview-42.debussy.workers.dev"
    );
    assert!(resolve_backend("preview-").is_err());
    assert!(resolve_backend("preview-A/b").is_err());
    assert!(resolve_backend("elsewhere").is_err());
}

#[test]
fn summary_matches_the_ts_format() {
    let steps = vec![
        step("create machine", Status::Pass, 1000, "m1 status provisioning"),
        step("running (status)", Status::Pass, 2000, "host h"),
        step("first exec", Status::Pass, 300, "journey-ok"),
        step("pass Claude login", Status::Pass, 100, "none"),
        step("start agent (claude)", Status::Pass, 600, "a|b\nc"),
        step("delete", Status::Pass, 0, "m1"),
    ];
    let meta = [("tag", "jr-1".to_owned()), ("agent", "claude".to_owned())];
    let md = summary_markdown("staging", "https://api", &meta, &steps);
    let lines: Vec<&str> = md.lines().collect();
    assert_eq!(
        lines[0],
        "PASS: Cloud journey on `staging` (https://api), 4.0 s; create machine to agent running 4.0 s"
    );
    assert_eq!(lines[1], "");
    assert_eq!(lines[2], "tag: jr-1, agent: claude");
    assert_eq!(lines[4], "| result | step | ms | detail |");
    assert_eq!(lines[5], "|---|---|---:|---|");
    assert_eq!(lines[10], "| pass | start agent (claude) | 600 | a\\|b c |");
    assert!(md.ends_with('\n'));
}

#[test]
fn a_failed_step_fails_the_summary_and_drops_ready_time() {
    let steps = vec![
        step("create machine", Status::Pass, 1000, ""),
        step("running (status)", Status::Fail, 2000, "timeout"),
        step("delete", Status::Skip, 0, ""),
    ];
    let md = summary_markdown("dev", "https://api", &[], &steps);
    assert!(md.starts_with("FAIL: Cloud journey on `dev` (https://api), 3.0 s\n"));
    assert!(md.contains("| **FAIL** | running (status) | 2000 | timeout |"));
    assert!(md.contains("| skip | delete | 0 |  |"));
    assert_eq!(ready_ms(&steps), None);
}

#[test]
fn the_launch_credential_rides_the_heredoc_not_argv() {
    let program = launch_credential_program(
        "journey-jr-1",
        "claude",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "sk-ant-oat01-x'y\"z",
    );
    let first = program.lines().next().unwrap();
    assert_eq!(first, "python3 -I - <<'CMUX_JOURNEY_START'");
    assert!(!first.contains("sk-ant"));
    assert!(program.ends_with("CMUX_JOURNEY_START"));
    // The params are one Python string literal that json.loads reads back.
    let literal = program.lines().find(|l| l.starts_with("params = json.loads(")).unwrap();
    let inner = literal.trim_start_matches("params = json.loads(").trim_end_matches(')');
    let text: String = serde_json::from_str(inner).unwrap();
    let params: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(params["_meta"]["acpmux"]["name"], "journey-jr-1");
    assert_eq!(
        params["_meta"]["acpmux"]["credentials"]["env"]["CLAUDE_CODE_OAUTH_TOKEN"],
        "sk-ant-oat01-x'y\"z"
    );
}

/// The start reaches acpmux on the socket of whichever home the machine's acpmux uses:
/// `ACPMUX_SOCKET`, the cmux daemon's acpmux home, then acpmux's own (where a machine's
/// `acpmux.service` listens), the order cloud-journey.ts `launchCredentialStartProgram` tries.
#[test]
fn the_start_program_looks_for_acpmux_in_its_own_home_too() {
    let program =
        launch_credential_program("journey-jr-1", "claude", "CLAUDE_CODE_OAUTH_TOKEN", "x");
    let paths = program.lines().find(|l| l.starts_with("paths = ")).expect("the socket list");
    let at = |needle: &str| paths.find(needle).unwrap_or_else(|| panic!("{needle} in {paths}"));
    let env = at("os.environ.get('ACPMUX_SOCKET')");
    let cmux = at("home + '/.cmux/acpmux/acpmux.sock'");
    let own = at("home + '/.acpmux/acpmux.sock'");
    assert!(env < cmux && cmux < own, "{paths}");
}

#[test]
fn stub_reply_needs_the_nonce_and_the_tool_output() {
    assert!(stub_reply_ok("Stub reply ab12. The tool printed ab12-tool.", "ab12"));
    assert!(!stub_reply_ok("Stub reply ab12.", "ab12"));
    assert!(!stub_reply_ok("Stub reply zz. The tool printed zz-tool.", "ab12"));
}

#[test]
fn shell_quoting_survives_single_quotes() {
    assert_eq!(shq("it's"), "'it'\\''s'");
}

#[test]
fn run_tags_look_like_the_ts_tags() {
    let tag = run_tag();
    assert!(tag.starts_with("jr-"));
    assert!(tag[3..].bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()));
}

#[test]
fn start_size_is_the_spare_shape_unless_killed() {
    // The platform's CHAT_START_SHAPE (2 vCPU, 4 GiB, 20 GiB): the only size its Scaler claims a warm spare for.
    assert_eq!(start_size(None), (2, 4_096, 20_480));
    assert_eq!(start_size(Some("1")), (2, 4_096, 20_480));
    for kill in ["0", "false", " OFF "] {
        assert_eq!(start_size(Some(kill)), NO_SPARE_SIZE, "{kill}");
    }
}

fn machine(
    id: &str,
    name: &str,
    status: &str,
    last_active_at: Option<i64>,
) -> cmux_cloud_wire::CloudMachine {
    serde_json::from_value(json!({
        "id": id,
        "team": "team_a",
        "creator": "user_a",
        "name": name,
        "size": {"cpu": null, "memory_mb": null, "disk_mb": null},
        "status": status,
        "image": {"id": "img", "daemon_version": null},
        "host": null,
        "classic": false,
        "created_at": 0,
        "last_active_at": last_active_at,
        "idle_policy": {"idle_seconds": 0},
        "error": null,
        "revision": "r1"
    }))
    .expect("CloudMachine record")
}

fn b36(mut n: i64) -> String {
    let mut out = Vec::new();
    while n > 0 {
        out.push(char::from_digit(u32::try_from(n % 36).unwrap(), 36).unwrap());
        n /= 36;
    }
    out.iter().rev().collect()
}

#[test]
fn sweep_owns_only_names_a_deleting_run_gives() {
    let t = 1_795_560_000_000_i64;
    let tag = b36(t);
    for name in [
        format!("cloud journey auto jr-{tag}"),
        format!("cloud journey auto jr-{tag} gateway"),
        format!("cloud journey auto jr-{tag} cold"),
        format!("cloud start bench jr-{tag} source"),
        format!("cloud start bench jr-{tag} spare 3"),
        format!("repro capsule nightly-next-pkg jr-{tag}"),
    ] {
        assert_eq!(sweep::owned_tag_ms(&name), Some(t), "{name}");
    }
    for name in [
        format!("cloud journey jr-{tag}"),
        format!("cloud journey kept jr-{tag}"),
        format!("cloud journey auto jr-{tag} other"),
        format!("cloud start bench jr-{tag} spare"),
        format!("repro capsule jr-{tag}"),
        "my machine".to_owned(),
        "cloud journey auto jr-".to_owned(),
        "cloud journey auto jr-UPPER".to_owned(),
    ] {
        assert_eq!(sweep::owned_tag_ms(&name), None, "{name}");
    }
}

#[test]
fn sweep_picks_stale_idle_journey_machines_only() {
    let now = 1_795_600_000_000_i64;
    let old = format!("jr-{}", b36(now - sweep::STALE_MS - 60_000));
    let young = format!("jr-{}", b36(now - sweep::STALE_MS + 60_000));
    let future = format!("jr-{}", b36(now + 60_000));
    let rows = vec![
        machine("vm_old", &format!("cloud journey auto {old}"), "paused", None),
        machine(
            "vm_capsule",
            &format!("repro capsule c1 {old}"),
            "running",
            Some(now - 2 * sweep::IDLE_MS),
        ),
        machine("vm_young", &format!("cloud journey auto {young}"), "paused", None),
        machine("vm_busy", &format!("cloud journey auto {old}"), "running", Some(now - 60_000)),
        machine("vm_kept", &format!("cloud journey {old}"), "paused", None),
        machine("vm_deleting", &format!("cloud journey auto {old}"), "deleting", None),
        machine("vm_future", &format!("cloud journey auto {future}"), "paused", None),
        machine("vm_person", "dev box", "paused", None),
    ];
    let ids: Vec<&str> = sweep::stale(&rows, now).iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["vm_old", "vm_capsule"]);
    let many: Vec<_> = (0..40)
        .map(|i| machine(&format!("vm_{i}"), &format!("cloud journey auto {old}"), "paused", None))
        .collect();
    assert_eq!(sweep::stale(&many, now).len(), sweep::MAX_PER_RUN);
}

/// Seeded secrets on the wire (cmux_egress::capture): the journey's file write and its exec's session
/// mint send the credential only in `Authorization` and the team only in its team header; the file's
/// bytes ride only in the write body. tests/egress_seeded.json names this test for
/// `cmux_tui::cli::cloud_journey`.
#[test]
fn seeded_secrets_ride_only_in_authorization_the_team_header_and_the_write_body() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "SEEDjourneyBearer-d93a";
    let team = "SEEDjourneyTeam-17be";
    let data = "SEEDjourneyFileBytes-5af2";
    let vm = "vm_journeyseeded0123456789";
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let client = exec_client("cmux/test cloud-journey").unwrap();
    let scope = Scope::new("https://cloud-api.cmux.dev", Some(team)).unwrap();
    let mut exec = Exec {
        client: &client,
        scope: &scope,
        credential,
        machine: scope.machine(vm).unwrap(),
        session: None,
        direct: false,
    };
    runtime.block_on(async {
        let _ = exec.write("/tmp/seeded", data.as_bytes(), 0o600).await;
        let _ = exec.run("true", 1_000).await;
    });
    let sent: Vec<_> = cmux_egress::capture::requests_to("cloud-api.cmux.dev")
        .into_iter()
        .filter(|r| r.target.contains(vm))
        .collect();
    assert!(sent.iter().any(|r| r.target.ends_with("/fs/write")), "{sent:?}");
    assert!(sent.iter().any(|r| r.target.ends_with("/client-session")), "{sent:?}");
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(
        places.iter().all(|p| p.ends_with(&format!(": header {}", cmux_cloud_client::TEAM_HEADER))),
        "{places:?}"
    );
    // `leaks` finds the base64 form the write body carries.
    let places = cmux_egress::capture::leaks(data);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].contains("/fs/write") && places[0].ends_with(": body"), "{places:?}");
}
