use super::*;
use std::fs;

struct Box {
    _dir: tempfile::TempDir,
    roots: Roots,
}

fn scratch() -> Box {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path();
    for sub in ["proc", "home", "acpmux", "root"] {
        fs::create_dir_all(base.join(sub)).unwrap();
    }
    let roots = Roots {
        proc: base.join("proc"),
        home: base.join("home"),
        acpmux_home: base.join("acpmux"),
        root: base.join("root"),
        uid: unsafe { libc::geteuid() },
        claude_config: None,
    };
    Box { _dir: dir, roots }
}

fn put(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

fn process(b: &Box, pid: u32, comm: &str, env: &[&str]) {
    let dir = b.roots.proc.join(pid.to_string());
    put(&dir.join("comm"), format!("{comm}\n").as_bytes());
    let mut bytes = Vec::new();
    for pair in env {
        bytes.extend_from_slice(pair.as_bytes());
        bytes.push(0);
    }
    put(&dir.join("environ"), &bytes);
}

fn whats(report: &Report, class: Class) -> Vec<String> {
    report.items.iter().filter(|i| i.class == class).map(|i| i.what.clone()).collect()
}

const VALUE: &str = "do-not-print-this-value";

#[test]
fn only_the_owner_login_is_green() {
    let b = scratch();
    process(
        &b,
        10,
        "acpmux",
        &["HOME=/home/cmux", "PATH=/usr/bin", "ACPMUX_LAUNCH_CREDENTIAL=CLAUDE_CODE_OAUTH_TOKEN"],
    );
    process(
        &b,
        11,
        "claude",
        &[&format!("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-{VALUE}"), "TERM=xterm"],
    );
    put(&b.roots.home.join(".claude/.credentials.json"), b"{}");
    put(&b.roots.at(INSTALL_RECEIPTS[0]), b"{}");
    let report = audit(&b.roots).unwrap();
    assert!(report.green(), "{:?}", report.items);
    assert_eq!(report.processes, 2);
    assert!(whats(&report, Class::Login).contains(&"env:CLAUDE_CODE_OAUTH_TOKEN".to_owned()));
}

#[test]
fn every_other_secret_is_a_named_finding_and_no_value_is_kept() {
    let b = scratch();
    process(
        &b,
        20,
        "claude",
        &[
            &format!("GITHUB_TOKEN={VALUE}"),
            &format!("DB_PASSWORD={VALUE}"),
            &format!("INNOCENT=ghp_{VALUE}"),
            &format!("ALSO=cmm_{VALUE}"),
        ],
    );
    put(&b.roots.at(OLD_LOGIN_SYNC), VALUE.as_bytes());
    put(&b.roots.at(GATEWAY_TOKEN), VALUE.as_bytes());
    put(&b.roots.at(INSTALL_KEYS[0]), VALUE.as_bytes());
    put(
        &b.roots.home.join(MACHINE_ENV[0]),
        format!("export STRIPE_SECRET='{VALUE}'\nexport EDITOR='vi'\n").as_bytes(),
    );
    put(&b.roots.home.join(".ssh/id_ed25519"), VALUE.as_bytes());
    put(&b.roots.home.join(".ssh/id_ed25519.pub"), b"ssh-ed25519 AAAA");
    put(
        &b.roots.acpmux_home.join("vault-state.json"),
        format!(r#"{{"env":{{"NPM_TOKEN":{{"fingerprint":"{VALUE}"}}}}}}"#).as_bytes(),
    );
    let report = audit(&b.roots).unwrap();
    assert!(!report.green());
    let leaks = whats(&report, Class::Leak);
    for want in [
        "env:GITHUB_TOKEN",
        "env:DB_PASSWORD",
        "env:INNOCENT",
        "env:ALSO",
        "env:STRIPE_SECRET",
        "vault:NPM_TOKEN",
    ] {
        assert!(leaks.contains(&want.to_owned()), "{want} missing from {leaks:?}");
    }
    for path in [OLD_LOGIN_SYNC, GATEWAY_TOKEN, INSTALL_KEYS[0]] {
        let want = format!("file:{}", b.roots.at(path).display());
        assert!(leaks.contains(&want), "{want} missing from {leaks:?}");
    }
    assert!(leaks.iter().any(|w| w.ends_with(".ssh/id_ed25519")));
    assert!(!leaks.iter().any(|w| w.ends_with(".pub") || w.contains("EDITOR")));
    let printed = serde_json::to_string(&report).unwrap();
    assert!(!printed.contains(VALUE), "a value reached the report");
}

#[test]
fn the_gateway_token_is_machine_identity_only_when_opted_in() {
    let b = scratch();
    put(&b.roots.at(GATEWAY_TOKEN), VALUE.as_bytes());
    put(&b.roots.home.join(GATEWAY_MARKER), b"");
    put(&b.roots.acpmux_home.join("machine-credential.json"), VALUE.as_bytes());
    let report = audit(&b.roots).unwrap();
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
    assert!(audit(&b.roots).unwrap().green());
}

#[test]
fn it_fails_closed_when_it_cannot_list_processes_or_read_state() {
    let b = scratch();
    let gone = Roots { proc: b.roots.proc.join("missing"), ..clone(&b.roots) };
    assert!(audit(&gone).is_err());
    put(&b.roots.acpmux_home.join("vault-state.json"), b"not json");
    assert!(audit(&b.roots).is_err());
}

#[test]
fn other_users_processes_are_not_reachable() {
    let b = scratch();
    process(&b, 30, "cmux-host", &[&format!("SECRET_KEY={VALUE}")]);
    let other = Roots { uid: b.roots.uid.wrapping_add(1), ..clone(&b.roots) };
    let report = audit(&other).unwrap();
    assert_eq!(report.processes, 0);
    assert!(report.green());
}

#[test]
fn shapes() {
    assert!(secret_shaped("AWS_SECRET_ACCESS_KEY", b""));
    assert!(secret_shaped("x", b"sk-abc"));
    assert!(!secret_shaped("ACPMUX_LAUNCH_CREDENTIAL", b"CLAUDE_CODE_OAUTH_TOKEN"));
    assert!(!secret_shaped("PATH", b"/usr/bin"));
}

fn clone(r: &Roots) -> Roots {
    Roots {
        proc: r.proc.clone(),
        home: r.home.clone(),
        acpmux_home: r.acpmux_home.clone(),
        root: r.root.clone(),
        uid: r.uid,
        claude_config: r.claude_config.clone(),
    }
}
