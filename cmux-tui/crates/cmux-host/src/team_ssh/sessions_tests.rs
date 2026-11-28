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
