use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io;
use std::path::Path;

use super::sessions::{Host, SessionRecord, Verdict, judge, load_all, reap, save};
use crate::config::Paths;

#[derive(Default)]
struct FakeHost {
    procs: BTreeMap<u32, (u64, &'static str)>,
    revoked: Vec<String>,
    check_fails: bool,
    /// Certificates whose revocation check fails.
    unreadable: Vec<String>,
    end_fails: bool,
    ended: RefCell<Vec<u32>>,
    lingering: RefCell<Vec<String>>,
    /// Every user-manager action, in order (`linger-off <user>`, `stop <user>`).
    actions: RefCell<Vec<String>>,
}

impl Host for FakeHost {
    fn start_time(&self, pid: u32) -> Option<u64> {
        self.procs.get(&pid).map(|p| p.0)
    }
    fn comm(&self, pid: u32) -> Option<String> {
        self.procs.get(&pid).map(|p| p.1.to_owned())
    }
    fn revoked(&self, _krl: &Path, cert: &str) -> io::Result<bool> {
        if self.check_fails || self.unreadable.iter().any(|u| u.as_str() == cert) {
            return Err(io::Error::other("ssh-keygen failed"));
        }
        Ok(self.revoked.iter().any(|r| r.as_str() == cert))
    }
    fn end(&self, record: &SessionRecord) -> io::Result<()> {
        if self.end_fails {
            return Err(io::Error::other("no such process"));
        }
        self.ended.borrow_mut().push(record.pid);
        Ok(())
    }
    fn disable_linger(&self, user: &str) -> io::Result<bool> {
        let mut lingering = self.lingering.borrow_mut();
        let was = lingering.iter().any(|u| u == user);
        lingering.retain(|u| u != user);
        if was {
            self.actions.borrow_mut().push(format!("linger-off {user}"));
        }
        Ok(was)
    }
    fn stop_user_manager(&self, user: &str, revoked_sessions: &[String]) -> io::Result<bool> {
        self.actions.borrow_mut().push(format!("stop {user} {}", revoked_sessions.join(",")));
        Ok(true)
    }
}

fn user_record(pid: u32, user: &str, cert: &str) -> SessionRecord {
    SessionRecord {
        user: user.into(),
        logind_session: Some(format!("s{pid}")),
        ..record(pid, 500, cert)
    }
}

fn record(pid: u32, start_time: u64, cert: &str) -> SessionRecord {
    SessionRecord {
        pid,
        start_time,
        user: "cmux".into(),
        certs: vec![cert.into()],
        serials: vec![1],
        key_ids: vec!["alice/g/i/n".into()],
        logind_session: None,
    }
}

#[test]
fn only_a_live_recorded_sshd_process_with_a_revoked_certificate_is_ended() {
    let host = FakeHost {
        procs: BTreeMap::from([
            (10, (500, "sshd")),
            (11, (900, "sshd")),
            (12, (700, "bash")),
            (13, (800, "sshd-session")),
        ]),
        revoked: vec!["cert-revoked".into()],
        ..FakeHost::default()
    };
    let krl = Path::new("/krl");
    let j = |r: SessionRecord| judge(&host, krl, &r).expect("judge");
    assert_eq!(j(record(10, 500, "cert-revoked")), Verdict::End);
    assert_eq!(
        j(record(13, 800, "cert-revoked")),
        Verdict::End,
        "OpenSSH 9.8+ session process name"
    );
    assert_eq!(j(record(10, 500, "cert-ok")), Verdict::Keep);
    assert_eq!(
        j(record(11, 500, "cert-revoked")),
        Verdict::Forget,
        "pid reused: start time differs"
    );
    assert_eq!(j(record(12, 700, "cert-revoked")), Verdict::Forget, "pid is not sshd");
    assert_eq!(j(record(99, 1, "cert-revoked")), Verdict::Forget, "process gone");
}

#[test]
fn reap_ends_revoked_sessions_and_drops_dead_records_but_keeps_the_rest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    for r in
        [record(10, 500, "cert-revoked"), record(11, 1, "cert-revoked"), record(12, 600, "cert-ok")]
    {
        save(&paths, &r).expect("save");
    }
    let host = FakeHost {
        procs: BTreeMap::from([(10, (500, "sshd")), (11, (2, "sshd")), (12, (600, "sshd"))]),
        revoked: vec!["cert-revoked".into()],
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![10]);
    assert_eq!(out.forgotten, vec![11]);
    assert!(out.errors.is_empty());
    assert_eq!(*host.ended.borrow(), vec![10], "the reused pid 11 is never signalled");
    assert_eq!(load_all(&paths).iter().map(|r| r.pid).collect::<Vec<_>>(), vec![12]);
}

#[test]
fn forgetting_a_dead_session_keeps_the_record_of_a_new_session_on_the_same_pid() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    save(&paths, &record(10, 500, "cert-old")).expect("save");
    save(&paths, &record(10, 600, "cert-new")).expect("save");
    let host = FakeHost { procs: BTreeMap::from([(10, (600, "sshd"))]), ..FakeHost::default() };
    let out = reap(&paths, &host);
    assert_eq!(out.forgotten, vec![10]);
    let left = load_all(&paths);
    assert_eq!(left.len(), 1);
    assert_eq!((left[0].pid, left[0].start_time), (10, 600));
}

#[test]
fn failures_keep_the_record_and_are_reported() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    save(&paths, &record(10, 500, "cert-revoked")).expect("save");
    let procs = BTreeMap::from([(10, (500, "sshd"))]);
    let host = FakeHost {
        procs: procs.clone(),
        revoked: vec!["cert-revoked".into()],
        end_fails: true,
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.errors.len(), 1);
    assert_eq!(load_all(&paths).len(), 1, "an unended session stays recorded for the next pass");
    let host = FakeHost { procs, check_fails: true, ..FakeHost::default() };
    let out = reap(&paths, &host);
    assert_eq!((out.ended.len(), out.errors.len()), (0, 1));
    assert_eq!(load_all(&paths).len(), 1);
}

#[test]
fn revoking_a_users_last_valid_session_turns_lingering_off_then_stops_its_user_manager() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    save(&paths, &user_record(10, "alice", "cert-revoked")).expect("save");
    save(&paths, &user_record(11, "bob", "cert-ok")).expect("save");
    let host = FakeHost {
        procs: BTreeMap::from([(10, (500, "sshd")), (11, (500, "sshd"))]),
        revoked: vec!["cert-revoked".into()],
        lingering: RefCell::new(vec!["alice".into(), "bob".into()]),
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![10]);
    assert_eq!(*host.actions.borrow(), vec!["linger-off alice", "stop alice s10"]);
    assert_eq!(out.linger_off, vec!["alice"]);
    assert_eq!(out.managers_stopped, vec!["alice"]);
    assert_eq!(*host.lingering.borrow(), vec!["bob"], "bob has no principals file: untouched");
}

#[test]
fn a_user_with_another_valid_live_session_keeps_its_user_manager() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    save(&paths, &user_record(10, "alice", "cert-revoked")).expect("save");
    save(&paths, &user_record(11, "alice", "cert-ok")).expect("save");
    let host = FakeHost {
        procs: BTreeMap::from([(10, (500, "sshd")), (11, (500, "sshd"))]),
        revoked: vec!["cert-revoked".into()],
        lingering: RefCell::new(vec!["alice".into()]),
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![10]);
    assert_eq!(*host.actions.borrow(), vec!["linger-off alice"], "no stop under a valid session");
    // The second certificate is revoked later: now the manager stops.
    let host = FakeHost {
        procs: BTreeMap::from([(11, (500, "sshd"))]),
        revoked: vec!["cert-ok".into()],
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![11]);
    assert_eq!(*host.actions.borrow(), vec!["stop alice s11"]);
}

#[test]
fn an_unchecked_session_of_the_user_keeps_its_user_manager() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    save(&paths, &user_record(10, "alice", "cert-revoked")).expect("save");
    save(&paths, &user_record(11, "alice", "cert-unreadable")).expect("save");
    let host = FakeHost {
        procs: BTreeMap::from([(10, (500, "sshd")), (11, (500, "sshd"))]),
        revoked: vec!["cert-revoked".into()],
        unreadable: vec!["cert-unreadable".into()],
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![10]);
    assert_eq!(out.errors.len(), 1, "{out:?}");
    assert!(host.actions.borrow().is_empty(), "no stop while a session is unchecked: {out:?}");
}

#[test]
fn every_pass_turns_lingering_off_for_users_with_a_principals_file_only() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    let principals = paths.at(super::PRINCIPALS_DIR);
    std::fs::create_dir_all(&principals).expect("dir");
    std::fs::write(principals.join("alice"), "alice\n").expect("write");
    std::fs::write(principals.join("Not A User"), "x\n").expect("write");
    let host = FakeHost {
        lingering: RefCell::new(vec!["alice".into(), "runner".into()]),
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.linger_off, vec!["alice"]);
    assert!(out.managers_stopped.is_empty(), "no revocation, no stop: logind stops it");
    assert_eq!(*host.lingering.borrow(), vec!["runner"]);
}

#[test]
fn a_member_who_left_has_its_sessions_ended_and_its_user_manager_stopped() {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    let principals = paths.at(super::PRINCIPALS_DIR);
    std::fs::create_dir_all(&principals).expect("dir");
    // ada left (managed, no principals file); bob is still a member; the
    // work user `cmux` was never managed and has no principals file here.
    std::fs::write(paths.at(super::ACCOUNTS_FILE), r#"{"users":{"ada":20000,"bob":20004}}"#)
        .expect("accounts");
    std::fs::write(principals.join("bob"), "bob\n").expect("bob");
    for r in [
        user_record(10, "ada", "cert-ok"),
        user_record(11, "bob", "cert-ok"),
        record(12, 500, "cert-ok"),
    ] {
        save(&paths, &r).expect("save");
    }
    let host = FakeHost {
        procs: BTreeMap::from([(10, (500, "sshd")), (11, (500, "sshd")), (12, (500, "sshd"))]),
        ..FakeHost::default()
    };
    let out = reap(&paths, &host);
    assert_eq!(out.ended, vec![10]);
    assert_eq!(*host.actions.borrow(), vec!["stop ada s10"]);
    assert_eq!(load_all(&paths).iter().map(|r| r.pid).collect::<Vec<_>>(), vec![11, 12]);
}

#[cfg(target_os = "linux")]
mod linux {
    //! The real host against real processes and a real KRL from ssh-keygen.
    use std::path::Path;
    use std::process::{Child, Command};

    use super::super::linux_host::{LinuxHost, proc_start_time};
    use super::super::sessions::{SessionRecord, load_all, reap, save};
    use super::super::{KRL_FILE, SESSIONS_DIR};
    use crate::config::Paths;

    fn keygen(args: &[&str]) {
        let status = Command::new("/usr/bin/ssh-keygen").args(args).status().expect("ssh-keygen");
        assert!(status.success(), "ssh-keygen {args:?}");
    }

    /// A long-lived process whose command name is `sshd` (a copy of sleep).
    fn fake_sshd(dir: &Path) -> Child {
        let bin = dir.join("sshd");
        if !bin.exists() {
            std::fs::copy("/bin/sleep", &bin).expect("copy sleep");
        }
        Command::new(&bin).arg("300").spawn().expect("spawn")
    }

    fn cert_line(dir: &Path, name: &str, serial: u64) -> String {
        let key = dir.join(name);
        let ks = key.to_str().expect("path");
        let ca = dir.join("ca");
        keygen(&["-q", "-t", "ed25519", "-N", "", "-f", ks]);
        keygen(&[
            "-q",
            "-s",
            ca.to_str().expect("ca"),
            "-I",
            name,
            "-n",
            "cmux",
            "-z",
            &serial.to_string(),
            "-V",
            "+10m",
            &format!("{ks}.pub"),
        ]);
        let text = std::fs::read_to_string(format!("{ks}-cert.pub")).expect("cert");
        text.split(' ').take(2).collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn a_krl_entry_ends_exactly_the_recorded_session_process() {
        let dir = tempfile::tempdir().expect("tempdir");
        let work = dir.path().join("work");
        std::fs::create_dir_all(&work).expect("work");
        let paths = Paths::new(dir.path().join("root"));
        keygen(&["-q", "-t", "ed25519", "-N", "", "-f", work.join("ca").to_str().expect("ca")]);
        let revoked = cert_line(&work, "revoked", 7);
        let kept = cert_line(&work, "kept", 8);
        // KRL revoking serial 7 of this CA.
        let krl = paths.at(KRL_FILE);
        std::fs::create_dir_all(krl.parent().expect("parent")).expect("dir");
        let spec = work.join("spec");
        std::fs::write(&spec, "serial: 7\n").expect("spec");
        keygen(&[
            "-q",
            "-k",
            "-f",
            krl.to_str().expect("krl"),
            "-s",
            work.join("ca.pub").to_str().expect("pub"),
            spec.to_str().expect("spec"),
        ]);

        let mut target = fake_sshd(&work);
        let mut innocent = fake_sshd(&work);
        let mut reused = fake_sshd(&work);
        let rec = |child: &Child, start: u64, cert: &str| SessionRecord {
            pid: child.id(),
            start_time: start,
            user: "cmux".into(),
            certs: vec![cert.to_owned()],
            serials: vec![],
            key_ids: vec![],
            logind_session: None,
        };
        let start = |child: &Child| proc_start_time(child.id()).expect("start time");
        save(&paths, &rec(&target, start(&target), &revoked)).expect("save");
        save(&paths, &rec(&innocent, start(&innocent), &kept)).expect("save");
        // Same pid, other start time: a reused pid must never be signalled.
        save(&paths, &rec(&reused, start(&reused) + 1, &revoked)).expect("save");

        let host = LinuxHost::new(paths.at(SESSIONS_DIR));
        let out = reap(&paths, &host);
        assert_eq!(out.ended, vec![target.id()], "{out:?}");
        assert!(out.errors.is_empty(), "{out:?}");
        assert!(target.wait().expect("wait").code().is_none(), "ended by a signal");
        assert!(innocent.try_wait().expect("try_wait").is_none(), "not revoked: still running");
        assert!(reused.try_wait().expect("try_wait").is_none(), "reused pid: still running");
        assert_eq!(load_all(&paths).iter().map(|r| r.pid).collect::<Vec<_>>(), vec![innocent.id()]);
        for child in [&mut innocent, &mut reused] {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
