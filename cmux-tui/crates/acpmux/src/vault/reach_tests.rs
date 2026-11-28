use super::*;
use std::fs;

struct Box {
    _dir: tempfile::TempDir,
    roots: Roots,
}

fn scratch() -> Box {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path();
    for sub in ["home", "acpmux", "root"] {
        fs::create_dir_all(base.join(sub)).unwrap();
    }
    let roots = Roots {
        home: base.join("home"),
        acpmux_home: base.join("acpmux"),
        root: base.join("root"),
        claude_config: None,
    };
    Box { _dir: dir, roots }
}

fn put(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

fn proc(pid: u32, role: &'static str, env: &[(&str, &str)]) -> Proc {
    let env = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    Proc { pid, role, env: Some(env) }
}

fn none() -> io::Result<Vec<Proc>> {
    Ok(Vec::new())
}

fn whats(report: &Report, class: Class) -> Vec<String> {
    report.items.iter().filter(|i| i.class == class).map(|i| i.what.clone()).collect()
}

const VALUE: &str = "do-not-print-this-value";

#[test]
fn only_the_owner_login_is_green() {
    let b = scratch();
    let token = format!("sk-ant-oat01-{VALUE}");
    let procs = vec![
        proc(
            10,
            "daemon",
            &[("PATH", "/usr/bin"), ("ACPMUX_LAUNCH_CREDENTIAL", "CLAUDE_CODE_OAUTH_TOKEN")],
        ),
        proc(11, "agent", &[("CLAUDE_CODE_OAUTH_TOKEN", &token), ("TERM", "xterm")]),
    ];
    put(&b.roots.home.join(".claude/.credentials.json"), b"{}");
    put(&b.roots.at(INSTALL_RECEIPTS[0]), b"{}");
    let report = audit(&b.roots, || Ok(procs)).unwrap();
    assert!(report.green(), "{:?}", report.items);
    assert_eq!(report.processes, 2);
    assert!(whats(&report, Class::Login).contains(&"env:CLAUDE_CODE_OAUTH_TOKEN".to_owned()));
}

#[test]
fn every_other_secret_is_a_named_finding_and_no_value_is_kept() {
    let b = scratch();
    let (ghp, cmm) = (format!("ghp_{VALUE}"), format!("cmm_{VALUE}"));
    let procs = vec![proc(
        20,
        "agent",
        &[("GITHUB_TOKEN", VALUE), ("DB_PASSWORD", VALUE), ("INNOCENT", &ghp), ("ALSO", &cmm)],
    )];
    put(&b.roots.at(OLD_LOGIN_SYNC), VALUE.as_bytes());
    put(&b.roots.at(GATEWAY_TOKEN), VALUE.as_bytes());
    put(&b.roots.at(INSTALL_KEYS[0]), VALUE.as_bytes());
    let machine_env = crate::login_env::machine_env_path(&b.roots.home);
    put(&machine_env, format!("export STRIPE_SECRET='{VALUE}'\nexport EDITOR='vi'\n").as_bytes());
    put(
        &machine_env.with_file_name(MACHINE_SECRETS),
        format!("OPENROUTER_KEY={VALUE}\n").as_bytes(),
    );
    put(&machine_env.with_file_name(TEAM_LOGIN), VALUE.as_bytes());
    put(&b.roots.home.join(".ssh/id_ed25519"), VALUE.as_bytes());
    put(&b.roots.home.join(".ssh/id_ed25519.pub"), b"ssh-ed25519 AAAA");
    put(&b.roots.home.join(".git-credentials"), VALUE.as_bytes());
    put(
        &b.roots.acpmux_home.join("vault-state.json"),
        format!(r#"{{"env":{{"NPM_TOKEN":{{"fingerprint":"{VALUE}"}}}}}}"#).as_bytes(),
    );
    let report = audit(&b.roots, || Ok(procs)).unwrap();
    assert!(!report.green());
    let leaks = whats(&report, Class::Leak);
    for want in [
        "env:GITHUB_TOKEN",
        "env:DB_PASSWORD",
        "env:INNOCENT",
        "env:ALSO",
        "env:STRIPE_SECRET",
        "env:OPENROUTER_KEY",
        "vault:NPM_TOKEN",
    ] {
        assert!(leaks.iter().any(|w| w == want), "{want} missing from {leaks:?}");
    }
    for path in [OLD_LOGIN_SYNC, GATEWAY_TOKEN, INSTALL_KEYS[0]] {
        let want = format!("file:{}", b.roots.at(path).display());
        assert!(leaks.contains(&want), "{want} missing from {leaks:?}");
    }
    for tail in [".ssh/id_ed25519", ".git-credentials", TEAM_LOGIN] {
        assert!(leaks.iter().any(|w| w.ends_with(tail)), "{tail} missing from {leaks:?}");
    }
    assert!(!leaks.iter().any(|w| w.ends_with(".pub") || w.contains("EDITOR")));
    let printed = serde_json::to_string(&report).unwrap();
    assert!(!printed.contains(VALUE), "a value reached the report");
}

#[test]
fn the_gateway_token_is_machine_identity_only_when_opted_in() {
    let b = scratch();
    put(&b.roots.at(GATEWAY_TOKEN), VALUE.as_bytes());
    put(&cmux_host::cloud::gateway_token::marker(&b.roots.home), b"");
    put(&b.roots.acpmux_home.join("machine-credential.json"), VALUE.as_bytes());
    let report = audit(&b.roots, none).unwrap();
    assert!(report.green(), "{:?}", report.items);
    assert_eq!(whats(&report, Class::Machine).len(), 2);
}

#[test]
fn an_install_key_the_work_user_cannot_read_is_not_reachable() {
    use std::os::unix::fs::PermissionsExt as _;
    if unsafe { libc::geteuid() } == 0 {
        return; // root reads anything; the live audit runs as the work user.
    }
    let b = scratch();
    let key = b.roots.at(INSTALL_KEYS[0]);
    put(&key, VALUE.as_bytes());
    fs::set_permissions(&key, fs::Permissions::from_mode(0o000)).unwrap();
    assert!(audit(&b.roots, none).unwrap().green());
}

#[test]
fn it_fails_closed_when_it_cannot_list_processes_or_read_state() {
    let b = scratch();
    assert!(audit(&b.roots, || Err(io::Error::other("no daemon"))).is_err());
    put(&b.roots.acpmux_home.join("vault-state.json"), b"not json");
    assert!(audit(&b.roots, none).is_err());
}

#[test]
fn a_process_whose_env_cannot_be_read_is_counted_not_skipped() {
    let b = scratch();
    let procs = vec![Proc { pid: 30, role: "agent", env: None }];
    let report = audit(&b.roots, || Ok(procs)).unwrap();
    assert_eq!(report.unreadable, 1);
}

#[test]
fn shapes() {
    assert!(secret_shaped("AWS_SECRET_ACCESS_KEY", b""));
    assert!(secret_shaped("x", b"sk-abc"));
    assert!(!secret_shaped("ACPMUX_LAUNCH_CREDENTIAL", b"CLAUDE_CODE_OAUTH_TOKEN"));
    assert!(!secret_shaped("PATH", b"/usr/bin"));
}

#[test]
fn the_vault_audit_recognizes_every_launch_credential_name() {
    let b = scratch();
    let env: Vec<_> = crate::agent_credentials::NAMES.iter().map(|name| (*name, VALUE)).collect();
    let report = audit(&b.roots, || Ok(vec![proc(11, "agent", &env)])).unwrap();
    assert!(report.green(), "{:?}", report.items);
    for (name, _) in env {
        assert!(whats(&report, Class::Login).contains(&format!("env:{name}")));
    }
}
