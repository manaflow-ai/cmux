use super::*;

#[cfg(target_os = "linux")]
const LOADER_KEYS: &str = "GCONV_PATH GETCONF_DIR GLIBC_TUNABLES HOSTALIASES LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_DYNAMIC_WEAK LD_HWCAP_MASK LD_LIBRARY_PATH LD_ORIGIN_PATH LD_PRELOAD LD_PROFILE LD_SHOW_AUXV LD_USE_LOAD_BIAS LD_UNKNOWN LOCALDOMAIN LOCPATH MALLOC_ARENA_MAX MALLOC_ARENA_TEST MALLOC_CHECK_ MALLOC_MMAP_MAX_ MALLOC_MMAP_THRESHOLD_ MALLOC_PERTURB_ MALLOC_TCACHE_COUNT MALLOC_TCACHE_MAX MALLOC_TCACHE_UNSORTED_LIMIT MALLOC_TOP_PAD_ MALLOC_TRACE MALLOC_TRIM_THRESHOLD_ NIS_PATH NLSPATH RESOLV_HOST_CONF RES_OPTIONS TMPDIR TZDIR";

#[test]
fn macos_profile_identity_stays_at_base() {
    assert_eq!(
        platform_profile_id(false),
        "c1bc6b9ad4bfc49398fb0d7427fef225ed3490688ba6de654ab69a73e3b22954"
    );
}

/// Claude Code's scrub starts its own bwrap, which cannot start inside the remote sandbox:
/// a sandboxed chain turns it off over whatever the profile set; a `vmBoundary` keeps it.
#[test]
fn only_a_vm_boundary_chain_scrubs_claudes_children_env() {
    for (sandboxed, inherited, want) in
        [(true, Some("1"), "0"), (true, None, "0"), (false, Some("0"), "1"), (false, None, "1")]
    {
        let mut p = profile(&["claude"], &[]);
        if let Some(v) = inherited {
            p.env.insert("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB".into(), v.into());
        }
        scrub_env(&mut p, sandboxed);
        let got = p.env.get("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB").map(String::as_str);
        assert_eq!(got, Some(want), "sandboxed={sandboxed} inherited={inherited:?}");
    }
}

#[test]
fn macos_canary_report_format_is_unchanged() {
    let fields = parse_canary_report("acpmux-canary outside=1 loopback=1 tmp=0\n").unwrap();
    assert!(canary_verdict(true, fields, false, true));
}

#[test]
fn canary_requires_success_and_every_field() {
    let fields = (Some(1), Some(1), Some(0), Some(1));
    assert!(canary_report_held(true, fields, true));
    assert!(!canary_report_held(false, fields, true));
    for fields in [
        (None, Some(1), Some(0), Some(1)),
        (Some(1), None, Some(0), Some(1)),
        (Some(1), Some(1), None, Some(1)),
        (Some(1), Some(1), Some(0), None),
    ] {
        assert!(!canary_report_held(true, fields, true));
    }
}

#[test]
fn acpmuxs_own_disallowed_tools_pass_and_other_tool_args_do_not() {
    let ok = |argv: &[&str]| {
        claude_args(bound(None).endpoint.as_ref(), &profile(argv, &[]), vec![]).is_ok()
    };
    // `acpmux new --prompt-file` / `--report-to` from a peer, and a chat with a server off.
    assert!(ok(&["claude", "--disallowedTools", "AskUserQuestion"]));
    assert!(ok(&[
        "claude",
        "--disallowedTools",
        "AskUserQuestion",
        "--disallowedTools",
        "mcp__claude_ai_Gmail"
    ]));
    for argv in [
        &["claude", "--disallowedTools"][..],
        &["claude", "--disallowedTools", "Bash(rm:*)"],
        &["claude", "--disallowedTools", "--settings"],
        &["claude", "--disallowedTools=AskUserQuestion"],
        &["claude", "--disallowed-tools", "AskUserQuestion"],
        &["claude", "--disallowedTools", "AskUserQuestion", "--allowedTools", "Bash"],
        &["claude", "--disallowedTools", "AskUserQuestion", "--dangerously-skip-permissions"],
    ] {
        assert!(!ok(argv), "{argv:?}");
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_refuses_loader_profile_env() {
    for key in LOADER_KEYS.split_whitespace() {
        let p = profile(&["claude"], &[(key, "injected")]);
        assert_eq!(
            claude_args(bound(None).endpoint.as_ref(), &p, vec![]).is_err(),
            key != "TMPDIR",
            "{key}"
        );
        assert!(loader_env_key(key), "{key} must be scrubbed");
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_profile_tmpdir_is_replaced_inside_the_sandbox() {
    let bound = bound(None);
    let p = profile(&["claude"], &[("TMPDIR", "/injected")]);
    let (_, args) = linux_wrap(&bound, &p, "claude".into(), vec![]).unwrap();
    assert!(args.contains(&format!("TMPDIR={}", bound.tmp.display())));
    assert!(!args.iter().any(|a| a.contains("/injected")));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_canary_attempts_both_persistence_renames() {
    let root = std::env::temp_dir().join(format!("canary-renames-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let probe = canary_persistence_probe(&root, true).unwrap().unwrap();
    let log = root.join("renames");
    let mv = root.join("bin/mv");
    crate::test_exec::write_executable(
        &mv,
        "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$RENAME_LOG\"\nexit 1\n",
    );
    let helper = root.join("bin/helper");
    crate::test_exec::write_executable(
        &helper,
        "#!/bin/sh\ncase \"$1\" in __remote-sandbox-canary-rename) echo rename=0;; *) echo unix=unknown;; esac\n",
    );
    let out = std::process::Command::new("/bin/bash")
        .args(["-c", CANARY, "canary", "/nonexistent/outside", "0"])
        .arg(&root)
        .arg("0")
        .arg(&probe.path)
        .args(["/nonexistent/socket", helper.to_str().unwrap()])
        .env("PATH", format!("{}:/usr/bin:/bin", root.join("bin").display()))
        .env("RENAME_LOG", &log)
        .output()
        .unwrap();
    let attempts = std::fs::read_to_string(log).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&root);
    assert!(out.status.success());
    assert!(attempts.is_empty(), "canary used project-controlled mv: {attempts}");
    let report = String::from_utf8_lossy(&out.stdout);
    assert!(report.contains("rename_git=0") && report.contains("rename_claude=0"), "{report}");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_canary_checks_write_open_persistence_paths() {
    assert!(CANARY.contains(".git/hooks/pre-commit"));
    assert!(CANARY.contains("CLAUDE.md"));
    assert!(CANARY.contains("printf"));
}

#[cfg(target_os = "linux")]
#[test]
fn canary_missing_unix_helper_is_unknown() {
    let out = std::process::Command::new("/bin/bash")
        .args([
            "-c",
            CANARY,
            "canary",
            "/nonexistent/outside",
            "0",
            "/nonexistent/tmp",
            "0",
            "/nonexistent/socket",
            "/nonexistent/acpmux",
        ])
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("unix=unknown"));
}

#[test]
fn mac_canary_setup_does_not_touch_a_worktree_git_file() {
    let root = std::env::temp_dir().join(format!("acpmux-canary-setup-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join(".git"), b"gitdir: elsewhere").unwrap();
    let result = canary_persistence_probe(&root, false).unwrap();
    assert!(result.is_none());
    assert!(root.join(".git").is_file());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn canary_rejects_a_denied_report_when_probe_file_landed() {
    let fields = [Some(1), Some(1), Some(0), Some(1), Some(1), Some(1), Some(1), Some(1), Some(0)];
    assert!(!canary_verdict(true, fields, true, false));
}

#[test]
fn linux_canary_requires_rename_results_and_ordinary_writes() {
    let fields = [Some(1), Some(1), Some(0), Some(1), Some(1), Some(1), Some(1), Some(1), Some(0)];
    assert!(canary_verdict(true, fields, true, true));
    for index in [6, 7, 8] {
        let mut missing = fields;
        missing[index] = None;
        assert!(!canary_verdict(true, missing, true, true));
        missing[index] = Some(if index == 8 { 1 } else { 0 });
        assert!(!canary_verdict(true, missing, true, true));
    }
    assert!(parse_canary_report("acpmux-canary outside=1 outside=0").is_err());
}

#[cfg(target_os = "linux")]
#[test]
fn canary_renames_are_helper_pinned_not_path_commands() {
    assert!(!CANARY.contains("mv -T"));
    assert!(CANARY.contains("__remote-sandbox-canary-rename"));
}

#[cfg(target_os = "linux")]
#[test]
fn probe_source_symlink_is_rejected_without_reading_target() {
    let root = std::env::temp_dir().join(format!("probe-fd-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let probe = canary_persistence_probe(&root, true).unwrap().unwrap();
    std::os::unix::fs::symlink("/dev/zero", probe.path.join("source-git")).unwrap();
    std::fs::write(probe.path.join("source-claude"), b"x").unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(probe_sources_intact(&probe));
    });
    let result = rx.recv_timeout(std::time::Duration::from_millis(100));
    assert_eq!(result.ok(), Some(false), "probe check did not reject quickly");
    let root2 = std::env::temp_dir().join(format!("probe-fifo-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root2).unwrap();
    let probe = canary_persistence_probe(&root2, true).unwrap().unwrap();
    let fifo = probe.path.join("source-git");
    let _ = std::fs::remove_file(&fifo);
    unsafe {
        libc::mkfifo(
            std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap().as_ptr(),
            0o600 as _,
        )
    };
    std::fs::write(probe.path.join("source-claude"), b"x").unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(probe_sources_intact(&probe));
    });
    let result = rx.recv_timeout(std::time::Duration::from_millis(100));
    let _ = std::fs::remove_dir_all(root);
    let _ = std::fs::remove_dir_all(root2);
    assert_eq!(result.ok(), Some(false), "probe check did not reject quickly");
}

#[test]
fn canary_rejects_duplicate_report_lines() {
    let report = "acpmux-canary outside=1 loopback=1 tmp=0 unix=1\nacpmux-canary outside=1 loopback=1 tmp=0 unix=1\n";
    assert!(parse_canary_report(report).is_err());
}

#[cfg(target_os = "linux")]
#[test]
fn linux_identity_covers_every_enforcement_source() {
    let names: Vec<_> = linux_identity_sources().into_iter().map(|(name, _)| name).collect();
    for name in [
        "supervisor.rs",
        "supervisor/locking.rs",
        "lookup.rs",
        "rules.rs",
        "bwrap/home.rs",
        "bwrap/aliases.rs",
        "supervisor/mutations.rs",
    ] {
        assert!(names.contains(&name), "missing {name} from Linux profile identity");
    }
}

fn profile(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
    serde_json::from_value(json!({
            "argv": argv,
            "kind": "claude-stdio",
            "env": env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<std::collections::BTreeMap<_, _>>(),
        }))
        .unwrap()
}

fn bound(endpoint: Option<Endpoint>) -> Bound {
    Bound {
        cwd: "/Users/p/proj".into(),
        tmp: "/private/tmp/acpmux-remote-x".into(),
        home: "/Users/p".into(),
        claude_tmp_project: "/private/tmp/claude-501/x".into(),
        claude_project: "/Users/p/.claude/projects/x".into(),
        api_port: endpoint.as_ref().and_then(|e| api_port(&e.url)),
        endpoint,
    }
}

/// Claude's own order: the profile (or its route) wins, then the user's
/// Claude settings env (it replaces the process env), then the login env.
#[test]
fn the_endpoint_is_the_one_claude_uses() {
    let relay = "http://127.0.0.1:41234";
    let sub = "http://100.89.225.106:31415";
    assert_eq!(
        endpoint(Some(relay), Some(sub), Some("http://x:1")),
        Some(Endpoint { url: relay.into(), own: true })
    );
    assert_eq!(
        endpoint(None, Some(sub), Some("http://x:1")),
        Some(Endpoint { url: sub.into(), own: false })
    );
    assert_eq!(
        endpoint(Some(" "), None, Some("http://x:1")),
        Some(Endpoint { url: "http://x:1".into(), own: false })
    );
    assert_eq!(endpoint(None, None, None), None);
}

#[test]
fn the_user_settings_endpoint_is_read_from_claudes_settings_file() {
    let home = std::env::temp_dir().join(format!("acpmux-ep-{}", std::process::id()));
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    assert_eq!(user_settings_endpoint(&home), None);
    std::fs::write(
        home.join(".claude/settings.json"),
        r#"{"env": {"ANTHROPIC_BASE_URL": "http://h:31415", "ANTHROPIC_AUTH_TOKEN": "t"}}"#,
    )
    .unwrap();
    assert_eq!(user_settings_endpoint(&home).as_deref(), Some("http://h:31415"));
    let _ = std::fs::remove_dir_all(&home);
}

/// A profile's own loopback route (the `cmux` harness through the local
/// relay): exactly that loopback port opens, the inline settings pin it,
/// and the user settings source (whose env would replace the route's
/// endpoint and key) is skipped.
#[test]
fn a_profiles_loopback_route_opens_only_its_port_and_wins_over_user_settings() {
    let b = bound(Some(Endpoint { url: "http://127.0.0.1:41234".into(), own: true }));
    let args = b.sandbox_args();
    let sb = &args[1];
    assert!(sb.contains("(allow network-outbound (remote ip \"localhost:41234\"))"), "{sb}");
    let deny = sb.find("(deny network-outbound (remote ip \"localhost:*\"))").unwrap();
    let allow = sb.find("(remote ip \"localhost:41234\")").unwrap();
    assert!(allow > deny, "the loopback port must open after the loopback deny");
    assert_eq!(sb.matches("localhost:4").count(), 1, "one loopback port only");
    let p = profile(&["/bin/claude"], &[]);
    let (_, out) =
        wrap(Path::new("/usr/bin/sandbox-exec"), &b, &p, "/bin/claude".into(), vec![]).unwrap();
    let at = out.iter().position(|a| a == "--settings").unwrap();
    let settings: Value = serde_json::from_str(&out[at + 1]).unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "http://127.0.0.1:41234");
    let sources = out.iter().position(|a| a == "--setting-sources").expect("--setting-sources");
    assert_eq!(out[sources + 1], "project,local");
}

/// The user's own route (their Claude settings): pinned, opened, and the
/// user settings stay (they hold its credential).
#[test]
fn the_users_own_route_keeps_the_user_settings() {
    let b = bound(Some(Endpoint { url: "http://100.89.225.106:31415".into(), own: false }));
    let sb = &b.sandbox_args()[1];
    assert!(sb.contains("(allow network-outbound (remote ip \"*:31415\"))"), "{sb}");
    let p = profile(&["/bin/claude"], &[]);
    let (_, out) =
        wrap(Path::new("/usr/bin/sandbox-exec"), &b, &p, "/bin/claude".into(), vec![]).unwrap();
    assert!(!out.iter().any(|a| a == "--setting-sources"), "{out:?}");
    let at = out.iter().position(|a| a == "--settings").unwrap();
    let settings: Value = serde_json::from_str(&out[at + 1]).unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "http://100.89.225.106:31415");
    // No route at all: no env pin, no port.
    let none = bound(None);
    assert!(!none.sandbox_args()[1].contains("Claude Code's own API route"));
    assert_eq!(serde_json::from_str::<Value>(&claude_settings(None)).unwrap().get("env"), None);
}

/// Claude Code's own temporary files go to this spawn's temporary folder,
/// the one the profile lets it write, never the shared /tmp.
#[test]
fn claude_codes_temporary_folder_is_the_spawns_own() {
    let (_, out) = wrap(
        Path::new("/usr/bin/sandbox-exec"),
        &bound(None),
        &profile(&["claude"], &[]),
        "claude".into(),
        vec![],
    )
    .unwrap();
    let env_at = out.iter().position(|a| a == "/usr/bin/env").unwrap();
    let program_at = out.iter().position(|a| a == "claude").unwrap();
    let env = &out[env_at..program_at];
    assert!(env.contains(&"TMPDIR=/private/tmp/acpmux-remote-x".to_string()), "{env:?}");
    assert!(
        env.contains(&"CLAUDE_CODE_TMPDIR=/private/tmp/acpmux-remote-x".to_string()),
        "{env:?}"
    );
}

/// `sr claude proxy` cannot start its proxy in the sandbox: Claude Code
/// runs straight to the subrouter server instead, or the chain is refused.
#[test]
fn sr_claude_proxy_runs_claude_on_the_subrouter_server() {
    let sr = profile(&["/u/.local/bin/sr", "claude", "proxy"], &[]);
    let args = vec!["claude".into(), "proxy".into(), "-p".into(), "--verbose".into()];
    let (program, out, routed) = subrouter_plan(
        &sr,
        args.clone(),
        Some("/u/.local/bin/claude".into()),
        Some("http://100.89.225.106:31415".into()),
    )
    .unwrap();
    assert_eq!(program, "/u/.local/bin/claude");
    assert_eq!(out, vec!["-p".to_string(), "--verbose".into()]);
    assert_eq!(routed.argv, vec!["/u/.local/bin/claude".to_string()]);
    assert_eq!(routed.env["ANTHROPIC_BASE_URL"], "http://100.89.225.106:31415");
    assert_eq!(routed.env["ANTHROPIC_AUTH_TOKEN"], "subrouter");
    assert!(subrouter_plan(&sr, args.clone(), Some("c".into()), None).is_err());
    assert!(subrouter_plan(&sr, args.clone(), None, Some("http://r:1".into())).is_err());
    let extra = profile(&["/u/sr", "claude", "proxy", "--account"], &[]);
    assert!(subrouter_plan(&extra, args, Some("c".into()), Some("http://r:1".into())).is_err());
}

#[cfg(target_os = "linux")]
#[test]
fn linux_wrap_uses_keeper_and_fixed_proxy_shape() {
    let bound = bound(Some(Endpoint { url: "http://127.0.0.1:41234".into(), own: true }));
    let (_, args) =
        linux_wrap(&bound, &profile(&["claude"], &[]), "/bin/claude".into(), vec![]).unwrap();
    let text = args.join(" ");
    assert!(text.contains("__remote-sandbox-keeper"));
    assert!(text.contains("--proxy-port 8118"));
    assert!(text.contains("--api-port 41234 --api-loopback-v4"));
    assert!(text.contains("-- /usr/bin/env -u CLAUDE_CONFIG_DIR"));
}

/// A cloud VM's Claude reaches its router on another tailnet host and a
/// port other than 80/443 (sr2 :4016). macOS opens that port in Seatbelt;
/// the Linux keeper must open it too, or every request 403s inside the
/// sandbox ("destination denied by network policy").
#[cfg(target_os = "linux")]
#[test]
fn linux_wrap_opens_a_remote_api_port() {
    let bound = bound(Some(Endpoint { url: "http://100.120.48.119:4016".into(), own: false }));
    let (_, args) =
        linux_wrap(&bound, &profile(&["claude"], &[]), "/bin/claude".into(), vec![]).unwrap();
    let text = args.join(" ");
    assert!(text.contains("--api-remote-port 4016"), "{text}");
    assert!(!text.contains("--api-loopback-v4"), "{text}");
    let https = bound_https();
    let (_, args) =
        linux_wrap(&https, &profile(&["claude"], &[]), "/bin/claude".into(), vec![]).unwrap();
    assert!(!args.join(" ").contains("--api-remote-port"), "443 is open already");
}

#[cfg(target_os = "linux")]
fn bound_https() -> Bound {
    bound(Some(Endpoint { url: "https://api.anthropic.com".into(), own: false }))
}

#[cfg(target_os = "linux")]
#[test]
fn linux_credentials_are_bounded_and_parsed_from_home() {
    let home = std::env::temp_dir().join(format!("acpmux-linux-cred-{}", std::process::id()));
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::write(
        home.join(".claude/.credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"linux-token","expiresAt":4102444800000}}"#,
    )
    .unwrap();
    assert_eq!(linux_credential_file(&home).unwrap().as_deref(), Some("linux-token"));
    let _ = std::fs::remove_dir_all(home);
}

#[cfg(target_os = "linux")]
#[test]
fn linux_default_checks_the_real_sandbox_preconditions() {
    let error = Bound::for_session(Path::new("/"), "wire-default", None).unwrap_err();
    assert!(!error.contains("platform has none"), "{error}");
}

/// A fresh `root/project` tree with `root` at `mode`, removed on drop.
#[cfg(target_os = "linux")]
struct ModeTree {
    root: PathBuf,
    child: PathBuf,
    gid: u32,
}

#[cfg(target_os = "linux")]
impl ModeTree {
    fn new(tag: &str, mode: u32) -> Self {
        use std::os::unix::fs::PermissionsExt;
        let root =
            std::env::temp_dir().join(format!("acpmux-linux-safe-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let child = root.join("project");
        std::fs::create_dir_all(&child).unwrap();
        std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(mode)).unwrap();
        let gid = std::fs::metadata(&root).unwrap().gid();
        ModeTree { root, child, gid }
    }
    fn check(&self, accounts: &dyn accounts::Accounts) -> Result<(), String> {
        // SAFETY: getuid has no preconditions and cannot fail.
        let uid = unsafe { libc::getuid() };
        linux_secure_path_with(&self.child, &self.root, uid, false, accounts)
    }
    fn private(&self) -> accounts::tests::Fake {
        // SAFETY: getuid has no preconditions and cannot fail.
        accounts::tests::Fake::private(unsafe { libc::getuid() }, self.gid)
    }
}

#[cfg(target_os = "linux")]
impl Drop for ModeTree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_group_writable_ancestor_in_a_private_group_is_allowed() {
    let tree = ModeTree::new("private", 0o775);
    assert_eq!(tree.check(&tree.private()), Ok(()));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_group_writable_ancestor_in_a_shared_group_is_refused() {
    let tree = ModeTree::new("shared", 0o775);
    let mut shared = tree.private();
    shared.group.as_mut().unwrap().members = vec!["bob".into()];
    let error = tree.check(&shared).unwrap_err();
    assert!(error.contains("is group-writable and its group leo"), "{error}");
    assert!(error.contains("bob"), "{error}");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_group_writable_ancestor_in_a_non_primary_group_is_refused() {
    let tree = ModeTree::new("other", 0o775);
    let mut other = tree.private();
    other.user.as_mut().unwrap().gid = tree.gid.wrapping_add(1);
    other.group.as_mut().unwrap().name = "developers".into();
    let error = tree.check(&other).unwrap_err();
    assert!(error.contains("its group developers"), "{error}");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_world_writable_ancestor_is_refused_even_in_a_private_group() {
    let tree = ModeTree::new("world", 0o777);
    let error = tree.check(&tree.private()).unwrap_err();
    assert!(error.ends_with("is world-writable"), "{error}");
    let tree = ModeTree::new("world-only", 0o757);
    assert!(tree.check(&tree.private()).unwrap_err().ends_with("is world-writable"));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_group_writable_ancestor_with_an_acl_is_refused() {
    // A named user (nobody, 65534) and then a named group with write: the
    // mode still reads 0775, but the ACL lets them write.
    for named in [2u16, 8] {
        let tree = ModeTree::new(&format!("acl-{named}"), 0o775);
        let Some(()) = accounts::tests::set_acl(&tree.root, named, 65534) else {
            eprintln!("skipped: this filesystem has no POSIX ACLs");
            return;
        };
        assert_eq!(std::fs::metadata(&tree.root).unwrap().mode() & 0o777, 0o775);
        let error = tree.check(&tree.private()).unwrap_err();
        assert!(error.contains("has an access control list"), "{error}");
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_group_writable_ancestor_whose_group_lookup_fails_is_refused() {
    let tree = ModeTree::new("lookup", 0o775);
    let mut failing = tree.private();
    failing.group = None;
    let error = tree.check(&failing).unwrap_err();
    assert!(error.contains("cannot be checked"), "{error}");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_probe_failure_has_a_sandbox_refusal_reason() {
    let error = crate::linux_sandbox::bwrap::probe(Path::new("/definitely/missing/bwrap"))
        .unwrap_err()
        .to_string();
    assert!(
        error.contains("bwrap not installed") || error.contains("probe did not start"),
        "{error}"
    );
}
