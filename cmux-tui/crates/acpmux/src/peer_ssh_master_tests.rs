//! A fake ssh that keeps a master as real ssh does: with a ControlPath whose socket is there it
//! is a mux client ("mux"), else it logs in (0.3 s, "login") and leaves the socket behind,
//! as the master ssh backgrounds once authenticated does.

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
cp=''; tunnel=0; prev=''
for a in "$@"; do
  case "$a" in
    -W) tunnel=1 ;;
  esac
  [ "$prev" = "-S" ] && cp="$a"
  prev="$a"
done
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
        let (tx, _notices) = mpsc::channel(64);
        let peer = Peer::new(name, &format!("ssh://{host}"), None, None, tx);
        peer.ssh_mux_override.set(mux).unwrap();
        peer
    }

    /// The ssh spawns so far: (logins, all).
    fn count(&self) -> (usize, usize) {
        let log = std::fs::read_to_string(&self.log).unwrap_or_default();
        (log.lines().filter(|l| *l == "login").count(), log.lines().count())
    }

    /// Until `total` ssh spawns have logged (a tunnel ended at once may not have yet), at most 5 s.
    async fn settle(&self, total: usize) {
        for _ in 0..200 {
            if self.count().1 >= total {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
    }
}

/// A first connect as `open_ssh` runs it: the tunnel, and the token read beside it.
async fn first_connect(fake: &Fake, peer: &Peer) {
    let _tunnel = peer.open_tunnel().await.unwrap();
    let ((token, peer_token), kept) = peer.connect_tokens().await.unwrap();
    assert_eq!((token.as_str(), peer_token.as_deref(), kept), ("dash", Some(PEER_TOKEN), false));
    fake.settle(2).await;
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
            "-S",
            path.to_str().unwrap(),
            "-o",
            &format!("ControlPersist={CONTROL_PERSIST_SECS}"),
            // Whichever ssh becomes the master (the token read, on a redial) keeps it probed.
            "-o",
            &format!("ServerAliveInterval={}", crate::peer::SSH_ALIVE_INTERVAL_SECS),
            "-o",
            &format!("ServerAliveCountMax={}", crate::peer::SSH_ALIVE_COUNT_MAX),
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
    first_connect(&before, &peer).await;
    assert_eq!(before.count(), (2, 2), "before: the tunnel and the read each log in");
    let restarted = before.peer("sm-before-2", "box-before", before.plain());
    let _tunnel = restarted.open_tunnel().await.unwrap();
    before.settle(3).await;
    restarted.end_tunnel().await;
    assert_eq!(before.count(), (3, 3), "before: a restart logs in again");

    // After: the read rides the tunnel's master, and the next run finds it.
    let after = Fake::new();
    let peer = after.peer("sm-after", "box-after", after.mux());
    first_connect(&after, &peer).await;
    assert_eq!(after.count(), (1, 2), "one login; the read is a mux client of its master");
    // A new daemon (a restart, an update, a handoff): new peers, the same home.
    let restarted = after.peer("sm-after-2", "box-after", after.mux());
    let _tunnel = restarted.open_tunnel().await.unwrap();
    after.settle(3).await;
    restarted.end_tunnel().await;
    let tokens = restarted.connect_tokens().await.unwrap();
    assert_eq!(tokens.0.1.as_deref(), Some(PEER_TOKEN));
    assert_eq!(after.count(), (1, 4), "the restart's tunnel and read log in none");
}

#[tokio::test]
async fn cold_peers_and_a_probe_share_one_login_to_the_same_host() {
    let fake = Fake::new();
    let mut mux = fake.mux();
    mux.dir = Some(fake.dir.path().join("a space and a 'quote"));
    let a = fake.peer("sm-race-a", "box-race", mux.clone());
    let b = fake.peer("sm-race-b", "box-race", mux.clone());
    let probe = fake.peer("sm-race-probe", "box-race", mux);
    let ((), (), probe_tunnel) =
        tokio::join!(first_connect(&fake, &a), first_connect(&fake, &b), probe.spawn_tunnel());
    let _probe = probe_tunnel.unwrap();
    fake.settle(5).await;
    assert_eq!(fake.count(), (1, 5), "two tunnels, two reads, and one probe share one login");
}

#[tokio::test]
async fn an_exited_tunnel_releases_its_login_immediately() {
    let fake = Fake::new();
    let peer = fake.peer("sm-exited", "box-exited", fake.mux());
    std::fs::write(&fake.program, "#!/bin/sh\nexit 1\n").unwrap();
    let _tunnel = tokio::time::timeout(Duration::from_secs(1), peer.open_tunnel())
        .await
        .expect("a failed login should not take the SSH connect timeout")
        .unwrap();
    peer.end_tunnel().await;
}

/// A replacement peer with the same name must not change the transport of a live instance.
#[tokio::test]
async fn same_named_peers_keep_their_own_ssh_transport() {
    let first = Fake::new();
    let second = Fake::new();
    let a = first.peer("same-name", "box", first.mux());
    let b = second.peer("same-name", "box", second.mux());
    assert_eq!(a.ssh_mux(), first.mux());
    assert_eq!(b.ssh_mux(), second.mux());
    drop(b);
    assert_eq!(a.ssh_mux(), first.mux());
}

/// Directory creation must stay in the held home after its pathname is replaced.
#[cfg(unix)]
#[test]
fn ssh_master_directory_stays_in_the_held_home() {
    crate::lost_home_race_tests::isolated(
        module_path!(),
        "ssh_master_directory_stays_in_the_held_home",
        |home| {
            crate::config::hold_home();
            crate::lost_home_race_tests::replace(home);
            let path = home.join("run/ssh/socket");
            assert!(options(&path).is_some());
            assert!(!home.join("run").exists(), "the replacement home stays untouched");
            assert!(home.with_extension("old").join("run/ssh").is_dir());
        },
        |_, _| {},
    );
}
