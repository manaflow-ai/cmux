//! A fake ssh that keeps a master as real ssh does: with a ControlPath whose socket is there it
//! is a mux client ("mux"), else it logs in (0.3 s, "login") and leaves the socket behind,
//! as the master ssh backgrounds once authenticated does. `-O exit` removes it ("exit").

use super::*;
use std::sync::Arc;
use tokio::sync::mpsc;

const PEER_TOKEN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

struct Fake {
    dir: tempfile::TempDir,
    log: PathBuf,
    program: PathBuf,
}

impl Fake {
    fn new() -> Self {
        // A short base: a socket path must fit `SOCKET_PATH_MAX` on every host's TMPDIR.
        let dir = tempfile::Builder::new().prefix("sm").tempdir_in("/tmp").unwrap();
        let log = dir.path().join("log");
        let program = dir.path().join("ssh");
        let script = format!(
            r#"#!/bin/sh
log='{log}'
cp=''; tunnel=0; op=''; prev=''
for a in "$@"; do
  case "$a" in
    ControlPath=*) cp="${{a#ControlPath=}}" ;;
    -W) tunnel=1 ;;
  esac
  [ "$prev" = "-O" ] && op="$a"
  prev="$a"
done
if [ -n "$op" ]; then echo exit >> "$log"; rm -f "$cp"; exit 0; fi
if [ -n "$cp" ] && [ -e "$cp" ]; then echo mux >> "$log"
else sleep 0.3; echo login >> "$log"; if [ -n "$cp" ]; then : > "$cp"; fi
fi
if [ "$tunnel" = 1 ]; then exec cat; fi
printf '{{"websocket":{{"token":"dash"}}}}\0{PEER_TOKEN}'
"#,
            log = log.display()
        );
        std::fs::write(&program, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { dir, log, program }
    }

    /// The daemon's own: masters under the home's `run/ssh`.
    fn mux(&self) -> SshMux {
        SshMux { program: self.program.clone().into(), ..SshMux::for_home(self.dir.path()) }
    }

    /// No master options: ssh as before this change.
    fn plain(&self) -> SshMux {
        SshMux { program: self.program.clone().into(), dir: None }
    }

    fn peer(&self, name: &str, host: &str, mux: SshMux) -> Arc<Peer> {
        override_for_tests(name, mux);
        let (tx, _notices) = mpsc::channel(64);
        Peer::new(name, &format!("ssh://{host}"), None, None, tx)
    }

    /// The ssh spawns so far: (logins, all).
    fn count(&self) -> (usize, usize) {
        let log = std::fs::read_to_string(&self.log).unwrap_or_default();
        (log.lines().filter(|l| *l == "login").count(), log.lines().count())
    }
}

/// A first connect as `open_ssh` runs it: the tunnel, and the token read beside it.
async fn first_connect(peer: &Peer) {
    let _tunnel = peer.open_tunnel().await.unwrap();
    let ((token, peer_token), kept) = peer.connect_tokens_after(true).await.unwrap();
    assert_eq!((token.as_str(), peer_token.as_deref(), kept), ("dash", Some(PEER_TOKEN), false));
    peer.end_tunnel().await;
}

fn args(peer: &Peer) -> Vec<String> {
    let ssh = peer.ssh_command();
    ssh.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect()
}

#[tokio::test]
async fn every_ssh_to_a_host_names_its_one_master_under_the_home() {
    let fake = Fake::new();
    let a = fake.peer("sm-opt-a", "box-a", fake.mux());
    let again = fake.peer("sm-opt-a2", "box-a", fake.mux());
    let b = fake.peer("sm-opt-b", "box-b", fake.mux());
    let dir = fake.dir.path().join("run").join("ssh");
    let path = dir.join(key("box-a"));
    assert_eq!(
        args(&a),
        [
            "-o",
            "ControlMaster=auto",
            "-o",
            &format!("ControlPath={}", path.display()),
            "-o",
            &format!("ControlPersist={CONTROL_PERSIST_SECS}"),
        ]
    );
    assert_eq!(args(&again), args(&a), "two peers of one host share its master");
    assert_ne!(args(&b), args(&a), "another host has its own");
    assert_eq!(key("box-a"), key("box-a"), "the same name in the next run");
    assert!(!key("box-a").contains('%'));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700, "the sockets' directory is private");
    }
}

#[tokio::test]
async fn a_home_too_long_for_a_socket_leaves_ssh_as_the_config_says() {
    let fake = Fake::new();
    let long = fake.dir.path().join("h".repeat(90));
    let mux = SshMux { program: fake.program.clone().into(), dir: Some(long) };
    let peer = fake.peer("sm-long", "box-long", mux);
    assert!(peer.master_path().is_none());
    assert!(args(&peer).iter().all(|a| !a.starts_with("Control")), "{:?}", args(&peer));
}

/// The before/after numbers of the PR: ssh logins on a first connect (the tunnel and the token
/// read) and on the next daemon run's connect (kept tokens: the tunnel alone).
#[tokio::test]
async fn a_first_connect_is_one_login_and_a_restarted_daemon_logs_in_none() {
    // Before: no master options. Two logins on a first connect, one more for each restart.
    let before = Fake::new();
    let peer = before.peer("sm-before", "box-before", before.plain());
    first_connect(&peer).await;
    assert_eq!(before.count(), (2, 2), "before: the tunnel and the read each log in");
    let restarted = before.peer("sm-before-2", "box-before", before.plain());
    let _tunnel = restarted.open_tunnel().await.unwrap();
    restarted.end_tunnel().await;
    assert_eq!(before.count(), (3, 3), "before: a restart logs in again");

    // After: the read rides the tunnel's master, and the next run finds it.
    let after = Fake::new();
    let peer = after.peer("sm-after", "box-after", after.mux());
    first_connect(&peer).await;
    assert_eq!(after.count(), (1, 2), "one login; the read is a mux client of its master");
    // A new daemon (a restart, an update, a handoff): new peers, the same home.
    let restarted = after.peer("sm-after-2", "box-after", after.mux());
    let _tunnel = restarted.open_tunnel().await.unwrap();
    restarted.end_tunnel().await;
    let tokens = restarted.connect_tokens_after(false).await.unwrap();
    assert_eq!(tokens.0.1.as_deref(), Some(PEER_TOKEN));
    assert_eq!(after.count(), (1, 4), "the restart's tunnel and read log in none");
}

#[tokio::test]
async fn a_dial_that_timed_out_with_no_word_from_ssh_drops_the_master() {
    let fake = Fake::new();
    let peer = fake.peer("sm-stale", "box-stale", fake.mux());
    let path = peer.master_path().unwrap();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, b"").unwrap();
    // ssh named a cause: its master is not the one at fault for a timeout of its own.
    peer.note_ssh_failure_over_master(Some(ssh_errors_timeout()), Some(DialFail::Timeout)).await;
    peer.note_ssh_failure_over_master(None, Some(DialFail::Refused)).await;
    assert!(path.exists());
    assert_eq!(fake.count(), (0, 0));
    peer.note_ssh_failure_over_master(None, Some(DialFail::Timeout)).await;
    assert!(!path.exists(), "the next attempt logs in again");
    assert_eq!(fake.count(), (0, 1), "`ssh -O exit`, no login");
}

fn ssh_errors_timeout() -> &'static str {
    "SSH connection timed out"
}
