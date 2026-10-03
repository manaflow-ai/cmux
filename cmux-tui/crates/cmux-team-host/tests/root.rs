//! The reconciler on a real Linux machine as root: real useradd, groupadd, setfacl and kernel
//! permission checks. It changes /etc/passwd and /etc/group, so it runs only on a throwaway box
//! (a Testbox or a container) with `CMUX_TEAM_HOST_ROOT_TESTS=1`, as root:
//!
//!   cargo test -p cmux-team-host --test root --no-run
//!   sudo CMUX_TEAM_HOST_ROOT_TESTS=1 target/debug/deps/root-<hash> --test-threads=1
//!
//! Without the variable every test returns at once (hosted CI runs them as a no-op).

mod common;

use cmux_team_host::directory::Member;
use cmux_team_host::host::HostSystem;
use cmux_team_host::{Accounts, Layout, reconcile};
use std::path::{Path, PathBuf};
use std::process::Command;

fn enabled() -> bool {
    if std::env::var("CMUX_TEAM_HOST_ROOT_TESTS").as_deref() != Ok("1") {
        eprintln!(
            "skipped: set CMUX_TEAM_HOST_ROOT_TESTS=1 and run as root on a throwaway Linux box"
        );
        return false;
    }
    let uid = Command::new("id").arg("-u").output().expect("id");
    assert_eq!(
        String::from_utf8_lossy(&uid.stdout).trim(),
        "0",
        "CMUX_TEAM_HOST_ROOT_TESTS=1 needs root"
    );
    true
}

fn sh(program: &str, args: &[&str]) -> bool {
    Command::new(program).args(args).status().expect(program).success()
}

/// `rwx`, `r-x` or `---` for `user` on `path`, from the kernel.
fn access(user: &str, path: &Path) -> String {
    let p = path.to_str().expect("utf-8 path");
    let t = |flag: &str, c: char| {
        if sh("runuser", &["-u", user, "--", "test", flag, p]) { c } else { '-' }
    };
    [t("-r", 'r'), t("-w", 'w'), t("-x", 'x')].iter().collect()
}

struct Scratch {
    base: PathBuf,
    extra_users: Vec<String>,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let mut users: Vec<String> = ["lawrence", "austin", "aziz"]
            .iter()
            .flat_map(|n| [n.to_string(), format!("{n}-mux"), format!("{n}-agents")])
            .collect();
        users.extend(self.extra_users.iter().cloned());
        for u in &users {
            let _ = Command::new("userdel").arg(u).status();
        }
        let groups = Command::new("getent")
            .arg("group")
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        for line in groups.lines() {
            let name = line.split(':').next().unwrap_or("");
            if name.starts_with("n-acme") || name == "muxes" || users.iter().any(|u| u == name) {
                let _ = Command::new("groupdel").arg(name).status();
            }
        }
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

fn scratch(tag: &str) -> (Scratch, Layout) {
    let base = std::env::temp_dir().join(format!("cmux-team-host-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&base).expect("scratch");
    assert!(sh("chmod", &["0755", base.to_str().expect("utf-8")]));
    let layout = Layout { root: base.join("team"), homes: base.join("home") };
    (Scratch { base, extra_users: Vec::new() }, layout)
}

#[test]
fn spec_matrix_inheritance_drift_and_refusal_on_a_real_machine() {
    if !enabled() {
        return;
    }
    let (mut s, layout) = scratch("spec");
    let acc = Accounts::default();
    let r = reconcile(&mut HostSystem, &acc, &layout, &common::acme());
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    assert!(r.refusals.is_empty(), "{:?}", r.refusals);
    for (path, want) in common::MATRIX {
        for (user, w) in common::USERS.iter().zip(want) {
            assert_eq!(access(user, &layout.root.join(path)), w, "{user} on {path}");
        }
    }

    // A file Austin writes in the project keeps the project's group and default ACL: Aziz reads, cannot write.
    let file = layout.root.join("t/acme/p/web/notes.md");
    let f = file.to_str().expect("utf-8");
    assert!(sh(
        "runuser",
        &["-u", "austin", "--", "sh", "-c", &format!("umask 007; echo x > {f}")]
    ));
    assert!(sh("runuser", &["-u", "aziz", "--", "test", "-r", f]));
    assert!(!sh("runuser", &["-u", "aziz", "--", "test", "-w", f]));
    assert!(sh("runuser", &["-u", "austin-agents", "--", "test", "-w", f]));
    // A sub-directory Austin makes inherits the same ACL.
    let sub = layout.root.join("t/acme/p/web/drafts");
    assert!(sh(
        "runuser",
        &["-u", "austin", "--", "sh", "-c", &format!("umask 007; mkdir {}", sub.display())]
    ));
    assert_eq!(access("aziz", &sub), "r-x");
    assert_eq!(access("lawrence", &sub), "rwx");

    // Second run: nothing to do.
    let again = reconcile(&mut HostSystem, &acc, &layout, &common::acme());
    assert!(again.applied.is_empty(), "{:?}", again.applied);

    // Drift: an extra admin membership, a widened mode, an extra ACL entry. Reverted.
    let web = layout.root.join("t/acme/p/web");
    let w = web.to_str().expect("utf-8");
    assert!(sh("usermod", &["-aG", "n-acme-a", "aziz"]));
    assert!(sh("chmod", &["2777", w]));
    assert!(sh("setfacl", &["-m", "g:aziz:rwx", w]));
    let fixed = reconcile(&mut HostSystem, &acc, &layout, &common::acme());
    assert!(fixed.errors.is_empty(), "{:?}", fixed.errors);
    assert_eq!(access("aziz", &web), "r-x");
    assert_eq!(access("aziz", &layout.root.join("t/acme")), "r-x");
    assert!(reconcile(&mut HostSystem, &acc, &layout, &common::acme()).applied.is_empty());

    // A member whose name a system account already has is refused and the account is untouched.
    assert!(sh("useradd", &["-r", "-M", "-s", "/usr/sbin/nologin", "sysx"]));
    s.extra_users.push("sysx".into());
    let before = Command::new("getent").args(["passwd", "sysx"]).output().expect("getent").stdout;
    let mut d = common::acme();
    d.members.push(Member { name: "sysx".into(), uid: 20_012, roles: vec![], agent_roles: None });
    let refused = reconcile(&mut HostSystem, &acc, &layout, &d);
    assert!(
        refused
            .refusals
            .iter()
            .any(|x| x.subject == "user sysx" && x.reason.contains("system account")),
        "{:?}",
        refused.refusals
    );
    assert_eq!(
        Command::new("getent").args(["passwd", "sysx"]).output().expect("getent").stdout,
        before
    );
    s.extra_users.extend(["sysx-mux".into(), "sysx-agents".into()]);
}
