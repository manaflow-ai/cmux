use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::key_holder::{KeyFile, KeyHolder};
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use tokio::io::DuplexStream;

use super::super::acpmux::AcpmuxTarget;
use super::super::control::{Peers, RekeyTarget};
use super::super::dial::Overlay;
use super::super::inbound::serve_inbound_watched;
use super::super::state::{self, LinkConfig, LinkState};
use super::*;

const CHILD_LOCK: &str = "CMUX_LINK_TEST_ADOPT_LOCK_DIR";
const CHILD_STATE: &str = "CMUX_LINK_TEST_ADOPT_STATE_DIR";

/// A Mac's layout: the app's acpmux home (the key lock and `node.wg.key`) and
/// a link set up before adoption, with its own `private.key`.
struct Machine {
    _root: tempfile::TempDir,
    home: PathBuf,
    link: PathBuf,
}

fn machine() -> Machine {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("acpmux");
    let link = root.path().join("state/link");
    let state = LinkState::open(Some(link.clone())).unwrap();
    state.init(&LinkConfig { install: "inst_a".into(), port: 0, server_identity: None }).unwrap();
    Machine { home, link, _root: root }
}

fn node_public(home: &Path) -> [u8; 32] {
    acpmux::cli::mesh_node_key::public_key_at(home).unwrap()
}

/// Runs in a child process only ([`CHILD_LOCK`] set): an adoption that
/// aborts after the step [`ABORT_AFTER`] names.
#[tokio::test]
async fn adopt_child() {
    let (Ok(lock), Ok(link)) = (std::env::var(CHILD_LOCK), std::env::var(CHILD_STATE)) else {
        return;
    };
    let state = LinkState::open(Some(PathBuf::from(link))).unwrap();
    let holder = KeyHolder::acquire(Path::new(&lock)).unwrap();
    let _ = serve_key(&state, &holder, 0, &Pairings::default()).await;
}

/// Killed after each step, the next start finishes the adoption: the link
/// serves the node key, `private.key` is gone, the record names the retired
/// key, and the old key is never served again.
#[tokio::test]
async fn a_link_killed_at_each_step_of_the_adoption_finishes_it_on_its_next_start() {
    for step in Step::ALL {
        let machine = machine();
        let state = LinkState::open(Some(machine.link.clone())).unwrap();
        let old = state.own_public_key().unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "link::key_adoption::tests::adopt_child", "--nocapture"])
            .env(CHILD_LOCK, &machine.home)
            .env(CHILD_STATE, &machine.link)
            .env(ABORT_AFTER, step.name())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(!child.success(), "the child was not stopped after {}", step.name());
        assert!(machine.home.join(KeyFile::Node.file_name()).exists(), "{}", step.name());
        assert_eq!(
            state.has_link_key(),
            step != Step::Retired,
            "the old key is removed in the last step only ({})",
            step.name()
        );
        // The next start, once the killed child's lock is free.
        let holder = KeyHolder::acquire(&machine.home).unwrap();
        let served = serve_key(&state, &holder, 0, &Pairings::default()).await.unwrap();
        let node = node_public(&machine.home);
        assert_eq!(state::public_key(&served), node, "{}", step.name());
        assert_ne!(node, old, "{}", step.name());
        assert!(!state.has_link_key(), "{}", step.name());
        let record = adopted(&state).unwrap().unwrap();
        assert_eq!(record.retired_public_key, Some(STANDARD.encode(old)), "{}", step.name());
        assert_eq!(state.own_public_key().unwrap(), node, "show names the node key");
        // And again: nothing left to do, still the node key.
        let again = serve_key(&state, &holder, 0, &Pairings::default()).await.unwrap();
        assert_eq!(state::public_key(&again), node);
    }
}

/// A link that locks in its own state directory (a hand-run link, a test) has
/// no acpmux home next to it and keeps its own key.
#[tokio::test]
async fn a_link_locked_in_its_own_state_dir_keeps_its_own_key() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let old = state.own_public_key().unwrap();
    let holder = KeyHolder::acquire(&machine.link).unwrap();
    let served = serve_key(&state, &holder, 0, &Pairings::default()).await.unwrap();
    assert_eq!(state::public_key(&served), old);
    assert!(state.has_link_key());
    assert!(adopted(&state).unwrap().is_none());
}

fn record(install: &str, key: [u8; 32]) -> PairingRecord {
    PairingRecord {
        install: install.into(),
        user: "42".into(),
        team: "team_a".into(),
        public_key: STANDARD.encode(key),
        endpoint: None,
    }
}

/// A far link, reached in process: each connect is served by its inbound
/// path, as from `from` (the dialing install) with key `key`.
struct FarLink {
    pairings: Pairings,
    target: RekeyTarget,
    from: &'static str,
    key: [u8; 32],
}

impl Overlay for FarLink {
    type Stream = DuplexStream;

    async fn connect(&self, _remote: SocketAddr) -> io::Result<DuplexStream> {
        let (ours, theirs) = tokio::io::duplex(4096);
        let pairings = self.pairings.clone();
        let target = self.target.clone();
        let source = SocketAddr::new(IpAddr::V6(overlay_address(self.from)), 40000);
        let key = self.key;
        tokio::spawn(async move {
            let _ = serve_inbound_watched(
                theirs,
                key,
                source,
                &pairings,
                None,
                None,
                &AcpmuxTarget::Off,
                None,
                Some(&target),
            )
            .await;
        });
        Ok(ours)
    }

    async fn sync_peers(&self, _pairings: &Pairings) -> io::Result<()> {
        Ok(())
    }
}

/// Republish: the far link moves its record of this install to the new key
/// (and reloads); a key another install's record holds is refused there.
#[tokio::test]
async fn a_paired_peer_takes_the_new_key_over_the_old_session_and_never_another_peers() {
    let far = tempfile::tempdir().unwrap();
    let file = far.path().join("peers.json");
    let mut theirs = Pairings::default();
    theirs.upsert(record("inst_a", [1; 32])).unwrap();
    theirs.upsert(record("inst_c", [3; 32])).unwrap();
    theirs.save(&file).unwrap();
    let peers = Peers::load(file.clone()).unwrap();
    let far_link = FarLink {
        pairings: theirs.clone(),
        target: peers.rekey_target(),
        from: "inst_a",
        key: [1; 32],
    };
    let mut ours = Pairings::default();
    ours.upsert(record("inst_b", [2; 32])).unwrap();

    let reloaded = peers.rekeyed();
    let told = tell_all(&far_link, &[7; 32], &ours, Duration::from_secs(5)).await;
    assert_eq!(told, ["inst_b"]);
    tokio::time::timeout(Duration::from_secs(5), reloaded).await.expect("no reload was asked");
    let now = Pairings::load(&file).unwrap();
    assert_eq!(now.by_install("inst_a").unwrap().key(), Some([7; 32]));

    // inst_c's key: refused, and inst_c keeps it.
    let told = tell_all(&far_link, &[3; 32], &ours, Duration::from_secs(5)).await;
    assert!(told.is_empty());
    let now = Pairings::load(&file).unwrap();
    assert_eq!(now.by_install("inst_c").unwrap().key(), Some([3; 32]));
    assert_eq!(now.by_install("inst_a").unwrap().key(), Some([7; 32]));

    // An install the far link has not paired is refused before its hello is read.
    let stranger = FarLink { from: "inst_x", key: [9; 32], ..far_link };
    assert!(tell_all(&stranger, &[8; 32], &ours, Duration::from_secs(5)).await.is_empty());
}
