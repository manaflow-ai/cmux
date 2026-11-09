use std::collections::BTreeSet;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::LINK_PORT;
use cmux_link::key_holder::{KeyFile, KeyHolder};
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use tokio::io::DuplexStream;
use zeroize::Zeroizing;

use super::super::acpmux::AcpmuxTarget;
use super::super::control::{Peers, RekeyTarget, serve_overlay};
use super::super::dial::Overlay;
use super::super::inbound::serve_inbound_watched;
use super::super::mesh::MeshOverlay;
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
    machine_named("inst_a")
}

fn machine_named(install: &str) -> Machine {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("acpmux");
    let link = root.path().join("state/link");
    let state = LinkState::open(Some(link.clone())).unwrap();
    state.init(&LinkConfig { install: install.into(), port: 0, server_identity: None }).unwrap();
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
    let _ = serve_key(&state, &holder, &Pairings::default()).await;
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
        let served = serve_key(&state, &holder, &Pairings::default()).await.unwrap();
        let node = node_public(&machine.home);
        assert!(served.retiring.is_none(), "no paired peer is left to tell");
        assert_eq!(state::public_key(&served.key), node, "{}", step.name());
        assert_ne!(node, old, "{}", step.name());
        assert!(!state.has_link_key(), "{}", step.name());
        let record = adopted(&state).unwrap().unwrap();
        assert_eq!(record.retired_public_key, Some(STANDARD.encode(old)), "{}", step.name());
        assert_eq!(state.own_public_key().unwrap(), node, "show names the node key");
        // And again: nothing left to do, still the node key.
        let again = serve_key(&state, &holder, &Pairings::default()).await.unwrap();
        assert_eq!(state::public_key(&again.key), node);
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
    let served = serve_key(&state, &holder, &Pairings::default()).await.unwrap();
    assert_eq!(state::public_key(&served.key), old);
    assert!(state.has_link_key());
    assert!(adopted(&state).unwrap().is_none());
}

/// Once adopted, a link started with another lock (a hand-run `serve` without
/// the flag) refuses, never falling back to a key it retired.
#[tokio::test]
async fn an_adopted_link_never_serves_under_another_lock() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, &Pairings::default()).await.unwrap();
    drop(holder);
    let own = KeyHolder::acquire(&machine.link).unwrap();
    let Err(refused) = serve_key(&state, &own, &Pairings::default()).await else {
        panic!("an adopted link served under another lock");
    };
    assert!(refused.to_string().starts_with("key_lock_dir:"), "{refused}");
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
    assert_eq!(told, [("inst_b".to_owned(), None)]);
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

// Recovery: no case ends in pairing again.

const FAST: Retry = Retry {
    first: Duration::from_millis(200),
    cap: Duration::from_secs(1),
    tell_for: Duration::from_secs(1),
};

/// Until `done` holds, within 30 s.
async fn until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(tokio::time::Instant::now() < deadline, "not within 30 s: {what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn paired_at(install: &str, key: [u8; 32], endpoint: SocketAddr) -> PairingRecord {
    PairingRecord { endpoint: Some(endpoint), ..record(install, key) }
}

fn pair(machine: &Machine, peers: &[PairingRecord]) {
    let mut pairings = Pairings::default();
    for peer in peers {
        pairings.upsert(peer.clone()).unwrap();
    }
    pairings.save(&LinkState::open(Some(machine.link.clone())).unwrap().peers_path()).unwrap();
}

fn key_of(machine: &Machine, install: &str) -> Option<[u8; 32]> {
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    Pairings::load(&state.peers_path()).unwrap().by_install(install)?.key()
}

async fn socket() -> tokio::net::UdpSocket {
    tokio::net::UdpSocket::bind(SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, 0))).await.unwrap()
}

/// A link as `serve` runs it, in process: the key it serves (adopting when
/// `adopting`), its mesh, its paired peers, the inbound path that takes their
/// rekeys, and the finish of a retirement.
struct Running {
    overlay: Arc<MeshOverlay>,
    public: [u8; 32],
    peers: Arc<Peers>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    _holder: KeyHolder,
}

impl Drop for Running {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn run(machine: &Machine, adopting: bool, socket: tokio::net::UdpSocket) -> Running {
    run_dropping(machine, adopting, socket, 0).await
}

/// [`run`], with the first `drop_replies` rekey answers lost on the way.
async fn run_dropping(
    machine: &Machine,
    adopting: bool,
    socket: tokio::net::UdpSocket,
    drop_replies: usize,
) -> Running {
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(if adopting { &machine.home } else { &machine.link }).unwrap();
    let pairings = Pairings::load(&state.peers_path()).unwrap();
    let served = serve_key(&state, &holder, &pairings).await.unwrap();
    let public = state::public_key(&served.key);
    let mut own_keys = vec![public];
    own_keys.extend(served.retiring.as_ref().map(|retiring| state::public_key(&retiring.key)));
    let install = state.config().unwrap().install;
    let config = WgMeshConfig {
        private_key: served.key,
        addresses: vec![InterfaceAddress {
            address: IpAddr::V6(overlay_address(&install)),
            prefix: 128,
        }],
        mtu: state::LINK_MTU,
    };
    let (mesh, retiring) = match served.retiring {
        Some(retiring) => {
            (WgMesh::start_retiring(config, retiring.key, socket).unwrap(), retiring.pending)
        }
        None => (WgMesh::start(config, socket).unwrap(), Default::default()),
    };
    let still_retiring = !retiring.is_empty();
    let overlay = Arc::new(MeshOverlay::new(mesh));
    overlay.set_retiring(retiring);
    overlay.retiring().answer_with(public);
    let peers = Arc::new(Peers::load(state.peers_path()).unwrap());
    peers.answer_rekeys_from(overlay.retiring());
    peers.own_keys(own_keys);
    peers.drop_replies.store(drop_replies, std::sync::atomic::Ordering::SeqCst);
    overlay.sync_peers(&peers.snapshot()).await.unwrap();
    let listener = overlay.listen(LINK_PORT).await.unwrap();
    let mut tasks =
        vec![tokio::spawn(serve_overlay(listener, peers.clone(), None, None, AcpmuxTarget::Off))];
    tasks.push(tokio::spawn({
        let (peers, overlay) = (peers.clone(), overlay.clone());
        async move { super::super::reload_on_rekey(&peers, &overlay).await }
    }));
    if still_retiring {
        let (peers, overlay) = (peers.clone(), overlay.clone());
        tasks.push(tokio::spawn(async move {
            finish_retiring(&state, &overlay, &peers, &public, FAST).await;
        }));
    }
    Running { overlay, public, peers, tasks, _holder: holder }
}

/// Whether `running`'s mesh holds `key` (its reload after a rekey is done)
/// and its file records it for `install`.
fn holds(running: &Running, machine: &Machine, install: &str, key: [u8; 32]) -> bool {
    key_of(machine, install) == Some(key)
        && running.peers.snapshot().by_install(install).and_then(|record| record.key()) == Some(key)
        && running.overlay.holds(&key)
}

/// `from` reaches `to`'s link port over the keys they hold now.
async fn reaches(from: &Running, to: &str) {
    let remote = SocketAddr::new(IpAddr::V6(overlay_address(to)), LINK_PORT);
    tokio::time::timeout(Duration::from_secs(10), from.overlay.connect(remote))
        .await
        .expect("no connection within 10 s")
        .expect("the connection failed");
}

fn retired(machine: &Machine) -> bool {
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    !state.has_link_key()
        && adopted(&state).unwrap().is_some_and(|record| record.pending.is_empty())
}

/// A peer that was offline when this link adopted the node key reaches it
/// later on the retired key, takes the new key and moves to it; the retired
/// key then goes. Nobody pairs again.
#[tokio::test]
async fn a_peer_offline_during_the_adoption_takes_the_new_key_when_it_is_back() {
    let a = machine_named("inst_a");
    let b = machine_named("inst_b");
    let (a_socket, b_socket) = (socket().await, socket().await);
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let b_key = LinkState::open(Some(b.link.clone())).unwrap().own_public_key().unwrap();
    pair(&a, &[paired_at("inst_b", b_key, b_socket.local_addr().unwrap())]);
    pair(&b, &[paired_at("inst_a", a_old, a_socket.local_addr().unwrap())]);

    // A adopts while B is down (its socket is bound, nothing answers).
    let running_a = run(&a, true, a_socket).await;
    assert_eq!(running_a.public, node_public(&a.home));
    tokio::time::sleep(Duration::from_secs(2)).await;
    let state_a = LinkState::open(Some(a.link.clone())).unwrap();
    assert!(state_a.has_link_key(), "the retired key waits for B");
    assert_eq!(adopted(&state_a).unwrap().unwrap().pending, BTreeSet::from(["inst_b".into()]));
    assert_eq!(key_of(&b, "inst_a"), Some(a_old));

    // B comes back, still knowing A by its old key.
    let running_b = run(&b, false, b_socket).await;
    until("B takes A's node key", || holds(&running_b, &b, "inst_a", running_a.public)).await;
    until("A retires its old key", || retired(&a)).await;
    reaches(&running_b, "inst_a").await;
    reaches(&running_a, "inst_b").await;
}

/// Two links that adopt at once still reach each other on the keys they
/// both knew, tell each other, and end on both node keys.
#[tokio::test]
async fn two_links_that_adopt_at_once_converge_on_both_node_keys() {
    let a = machine_named("inst_a");
    let b = machine_named("inst_b");
    let (a_socket, b_socket) = (socket().await, socket().await);
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let b_old = LinkState::open(Some(b.link.clone())).unwrap().own_public_key().unwrap();
    pair(&a, &[paired_at("inst_b", b_old, b_socket.local_addr().unwrap())]);
    pair(&b, &[paired_at("inst_a", a_old, a_socket.local_addr().unwrap())]);

    let (running_a, running_b) = tokio::join!(run(&a, true, a_socket), run(&b, true, b_socket));
    until("both hold the other's node key", || {
        holds(&running_a, &a, "inst_b", running_b.public)
            && holds(&running_b, &b, "inst_a", running_a.public)
    })
    .await;
    until("both retire their old keys", || retired(&a) && retired(&b)).await;
    reaches(&running_a, "inst_b").await;
    reaches(&running_b, "inst_a").await;
}

/// A rekey nobody can prove is refused: a stranger's key at A's overlay
/// address reaches nothing, and a paired peer cannot take a key another
/// pairing holds.
#[tokio::test]
async fn a_forged_new_key_is_refused() {
    let a = machine_named("inst_a");
    let b = machine_named("inst_b");
    let (a_socket, b_socket, c_socket) = (socket().await, socket().await, socket().await);
    let b_endpoint = b_socket.local_addr().unwrap();
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let b_key = LinkState::open(Some(b.link.clone())).unwrap().own_public_key().unwrap();
    let (c_private, c_public) = cmux_wg::testing::random_keypair();
    pair(&a, &[paired_at("inst_b", b_key, b_endpoint)]);
    pair(
        &b,
        &[
            paired_at("inst_a", a_old, a_socket.local_addr().unwrap()),
            paired_at("inst_c", c_public, c_socket.local_addr().unwrap()),
        ],
    );
    let running_a = run(&a, true, a_socket).await;
    let running_b = run(&b, false, b_socket).await;
    until("B takes A's node key", || holds(&running_b, &b, "inst_a", running_a.public)).await;

    // C, paired with B, claims A's node key as its own.
    let c = in_mesh("inst_c", c_private, c_socket);
    let mut theirs = Pairings::default();
    theirs.upsert(paired_at("inst_b", b_key, b_endpoint)).unwrap();
    c.sync_peers(&theirs).await.unwrap();
    assert!(tell_all(&c, &running_a.public, &theirs, Duration::from_secs(5)).await.is_empty());
    assert_eq!(key_of(&b, "inst_c"), Some(c_public));
    assert_eq!(key_of(&b, "inst_a"), Some(running_a.public));

    // A stranger at A's overlay address, with a key of its own: B never answers.
    let (stranger, _) = cmux_wg::testing::random_keypair();
    let forger = in_mesh("inst_a", stranger, socket().await);
    forger.sync_peers(&theirs).await.unwrap();
    assert!(tell_all(&forger, &[5; 32], &theirs, Duration::from_secs(3)).await.is_empty());
    assert_eq!(key_of(&b, "inst_a"), Some(running_a.public));
}

fn in_mesh(install: &str, private: [u8; 32], socket: tokio::net::UdpSocket) -> MeshOverlay {
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: vec![InterfaceAddress {
            address: IpAddr::V6(overlay_address(install)),
            prefix: 128,
        }],
        mtu: state::LINK_MTU,
    };
    MeshOverlay::new(WgMesh::start(config, socket).unwrap())
}

// Review findings on the recovery (F1 to F5).

/// F1: a rekey to the receiver's own key, current or retired, is refused and
/// changes nothing (a peer record with it would stop every start of the mesh).
#[tokio::test]
async fn a_rekey_to_the_receivers_own_key_is_refused() {
    let far = tempfile::tempdir().unwrap();
    let file = far.path().join("peers.json");
    let mut theirs = Pairings::default();
    theirs.upsert(record("inst_a", [1; 32])).unwrap();
    theirs.save(&file).unwrap();
    let peers = Peers::load(file.clone()).unwrap();
    peers.own_keys(vec![[9; 32], [10; 32]]);
    let far_link =
        FarLink { pairings: theirs, target: peers.rekey_target(), from: "inst_a", key: [1; 32] };
    let mut ours = Pairings::default();
    ours.upsert(record("inst_b", [2; 32])).unwrap();
    for own in [[9; 32], [10; 32]] {
        assert!(tell_all(&far_link, &own, &ours, Duration::from_secs(5)).await.is_empty());
    }
    assert_eq!(Pairings::load(&file).unwrap().by_install("inst_a").unwrap().key(), Some([1; 32]));
}

/// F2: the peer's answer is lost after it saved the new key. The adopted
/// link asks again (its retired key, then its current one), the peer answers
/// the same, and both end on the node key.
#[tokio::test]
async fn a_lost_rekey_answer_is_asked_again_and_converges() {
    let a = machine_named("inst_a");
    let b = machine_named("inst_b");
    let (a_socket, b_socket) = (socket().await, socket().await);
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let b_key = LinkState::open(Some(b.link.clone())).unwrap().own_public_key().unwrap();
    pair(&a, &[paired_at("inst_b", b_key, b_socket.local_addr().unwrap())]);
    pair(&b, &[paired_at("inst_a", a_old, a_socket.local_addr().unwrap())]);
    let running_b = run_dropping(&b, false, b_socket, 1).await;
    let running_a = run(&a, true, a_socket).await;
    until("B takes A's node key", || holds(&running_b, &b, "inst_a", running_a.public)).await;
    until("A retires its old key", || retired(&a)).await;
    reaches(&running_a, "inst_b").await;
    reaches(&running_b, "inst_a").await;
}

/// F2, both adopting: the answer that carries B's node key is lost; A asks
/// again and still learns it.
#[tokio::test]
async fn a_lost_answer_in_a_same_time_adoption_still_converges() {
    let a = machine_named("inst_a");
    let b = machine_named("inst_b");
    let (a_socket, b_socket) = (socket().await, socket().await);
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let b_old = LinkState::open(Some(b.link.clone())).unwrap().own_public_key().unwrap();
    pair(&a, &[paired_at("inst_b", b_old, b_socket.local_addr().unwrap())]);
    pair(&b, &[paired_at("inst_a", a_old, a_socket.local_addr().unwrap())]);
    let (running_a, running_b) =
        tokio::join!(run_dropping(&a, true, a_socket, 1), run_dropping(&b, true, b_socket, 1));
    until("both hold the other's node key", || {
        holds(&running_a, &a, "inst_b", running_b.public)
            && holds(&running_b, &b, "inst_a", running_a.public)
    })
    .await;
    until("both retire their old keys", || retired(&a) && retired(&b)).await;
    reaches(&running_a, "inst_b").await;
    reaches(&running_b, "inst_a").await;
}

/// F3: rekeys that arrive together each persist; none saves over another.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_rekeys_all_persist() {
    let far = tempfile::tempdir().unwrap();
    let file = far.path().join("peers.json");
    let mut theirs = Pairings::default();
    for n in 1..=16u8 {
        theirs.upsert(record(&format!("inst_{n}"), [n; 32])).unwrap();
    }
    theirs.save(&file).unwrap();
    let target = Peers::load(file.clone()).unwrap().rekey_target();
    let tasks: Vec<_> = (1..=16u8)
        .map(|n| {
            let target = target.clone();
            tokio::spawn(async move { target.apply(&format!("inst_{n}"), &[n + 100; 32]).await })
        })
        .collect();
    for task in tasks {
        assert!(task.await.unwrap().unwrap());
    }
    let now = Pairings::load(&file).unwrap();
    for n in 1..=16u8 {
        assert_eq!(now.by_install(&format!("inst_{n}")).unwrap().key(), Some([n + 100; 32]));
    }
}

/// F4: `link init` again after the adoption (a new port, `ensure --handoff`)
/// makes no new link key, which would look like a retired one.
#[tokio::test]
async fn init_after_the_adoption_makes_no_new_link_key() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, &Pairings::default()).await.unwrap();
    assert!(!state.has_link_key());
    state
        .init(&LinkConfig { install: "inst_a".into(), port: 4242, server_identity: None })
        .unwrap();
    assert!(!state.has_link_key(), "init made a new link key after the adoption");
    let served = serve_key(&state, &holder, &Pairings::default()).await.unwrap();
    assert!(served.retiring.is_none());
    assert_eq!(state::public_key(&served.key), node_public(&machine.home));
}

/// F5: an adopted link started with another external lock dir refuses, and
/// makes no node key there.
#[tokio::test]
async fn an_adopted_link_refuses_another_external_lock_dir() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, &Pairings::default()).await.unwrap();
    drop(holder);
    let other = machine.home.parent().unwrap().join("other-home");
    let held = KeyHolder::acquire(&other).unwrap();
    let Err(refused) = serve_key(&state, &held, &Pairings::default()).await else {
        panic!("an adopted link adopted another dir's key");
    };
    assert!(refused.to_string().starts_with("key_lock_dir:"), "{refused}");
    assert!(!other.join(KeyFile::Node.file_name()).exists());
    assert_eq!(adopted(&state).unwrap().unwrap().key_dir, machine.home);
}

/// Second review, F2: `link peer remove` and an inbound rekey of the same
/// install, at once. Both run under the pairing file's lock, so the rekey
/// never saves the removed record back.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_revoke_racing_a_rekey_stays_revoked() {
    for round in 0..40u8 {
        let far = tempfile::tempdir().unwrap();
        let file = far.path().join("peers.json");
        let mut theirs = Pairings::default();
        theirs.upsert(record("inst_x", [1; 32])).unwrap();
        theirs.upsert(record("inst_y", [2; 32])).unwrap();
        theirs.save(&file).unwrap();
        let target = Peers::load(file.clone()).unwrap().rekey_target();
        let path = file.clone();
        let revoke = tokio::task::spawn_blocking(move || {
            Pairings::update(&path, |pairings| Ok(pairings.remove("inst_x")))
        });
        let rekey = target.apply("inst_x", &[round + 50; 32]);
        let (revoked, _) = tokio::join!(revoke, rekey);
        assert!(revoked.unwrap().unwrap(), "round {round}");
        let now = Pairings::load(&file).unwrap();
        assert!(now.by_install("inst_x").is_none(), "round {round}: the revoked pairing came back");
        assert_eq!(now.by_install("inst_y").unwrap().key(), Some([2; 32]));
    }
}

/// Second review, F3: an install moved aside while a paired peer is still
/// pending takes its adoption record along, and gets it back with its
/// retired key: the pending retirement goes on.
#[tokio::test]
async fn an_install_switch_keeps_a_pending_retirement() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let mut pairings = Pairings::default();
    pairings.upsert(record("inst_b", [2; 32])).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, &pairings).await.unwrap();
    assert!(served.retiring.is_some());
    let before = adopted(&state).unwrap().unwrap();
    assert_eq!(before.pending, BTreeSet::from(["inst_b".into()]));

    state.switch_install("inst_a", "inst_other").unwrap();
    assert!(adopted(&state).unwrap().is_none(), "another install has no adoption record");
    assert!(!state.has_link_key());

    state.switch_install("inst_other", "inst_a").unwrap();
    assert_eq!(adopted(&state).unwrap(), Some(before));
    assert!(state.has_link_key(), "the retired key came back with its record");
    let again = serve_key(&state, &holder, &pairings).await.unwrap();
    let retiring = again.retiring.expect("the retirement goes on");
    assert_eq!(retiring.pending, BTreeSet::from(["inst_b".into()]));
}
