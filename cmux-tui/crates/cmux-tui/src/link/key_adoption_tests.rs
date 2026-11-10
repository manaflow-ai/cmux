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
    let _ = serve_key(&state, &holder, Some(Path::new(&lock))).await;
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
        let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
        let node = node_public(&machine.home);
        assert!(served.retiring.is_none(), "no paired peer is left to tell");
        assert_eq!(state::public_key(&served.key), node, "{}", step.name());
        assert_ne!(node, old, "{}", step.name());
        assert!(!state.has_link_key(), "{}", step.name());
        let record = adopted(&state).unwrap().unwrap();
        assert_eq!(record.retired_public_key, Some(STANDARD.encode(old)), "{}", step.name());
        assert_eq!(state.own_public_key().unwrap(), node, "show names the node key");
        // And again: nothing left to do, still the node key.
        let again = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
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
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
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
    serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    drop(holder);
    let own = KeyHolder::acquire(&machine.link).unwrap();
    let Err(refused) = serve_key(&state, &own, Some(&machine.home)).await else {
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
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
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
            let from = record(&format!("inst_{n}"), [n; 32]);
            tokio::spawn(async move { target.apply(&from.peer(), &[n; 32], &[n + 100; 32]).await })
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
    serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert!(!state.has_link_key());
    state
        .init(&LinkConfig { install: "inst_a".into(), port: 4242, server_identity: None })
        .unwrap();
    assert!(!state.has_link_key(), "init made a new link key after the adoption");
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert!(served.retiring.is_none());
    assert_eq!(state::public_key(&served.key), node_public(&machine.home));
}

/// An adopted link has no `private.key`, so `init --server-identity` once took it
/// for a fresh one and overwrote its config, leaving a state `serve_key` refuses.
/// It is refused, and the config and the adoption stay as they were.
#[tokio::test]
async fn init_with_a_server_identity_after_the_adoption_is_refused() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    let before = std::fs::read(machine.link.join("config.json")).ok();
    let Err(refused) = state.init(&LinkConfig {
        install: "inst_a".into(),
        port: 4242,
        server_identity: Some(machine.home.join("identity.json")),
    }) else {
        panic!("an adopted link was converted to a server link");
    };
    assert_eq!(refused.to_string(), "server_link.identity_conflict");
    assert_eq!(std::fs::read(machine.link.join("config.json")).ok(), before);
    assert!(!state.has_link_key());
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert_eq!(state::public_key(&served.key), node_public(&machine.home));
}

/// Once adopted, a node key that is gone (a leave of an older acpmux, a hand
/// removal) is never made again: every told peer knows the link by it, and a
/// fresh one would reach nobody. The link refuses until the key is back, and
/// then serves it again, with the record and pairings untouched.
#[tokio::test]
async fn an_adopted_link_whose_node_key_is_gone_refuses_and_makes_none() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    pair(&machine, &[record("inst_b", [7; 32])]);
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert!(served.retiring.is_some(), "the paired peer is still to tell");
    let node = KeyFile::Node.path_in(&machine.home);
    let aside = machine.home.join("node.wg.key.aside");
    let before = adopted(&state).unwrap().unwrap();
    std::fs::rename(&node, &aside).unwrap();
    for _ in 0..2 {
        let Err(refused) = serve_key(&state, &holder, Some(&machine.home)).await else {
            panic!("an adopted link served without its node key");
        };
        assert!(refused.to_string().starts_with("key_adoption.node_key_missing:"), "{refused}");
        assert!(!node.exists(), "a fresh node key was made");
        assert_eq!(adopted(&state).unwrap().unwrap(), before, "the record changed");
        assert!(state.has_link_key(), "the retired key went while peers were left to tell");
    }
    std::fs::rename(&aside, &node).unwrap();
    let again = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert_eq!(state::public_key(&again.key), node_public(&machine.home));
    assert_eq!(again.retiring.map(|retiring| retiring.pending), Some(before.pending));
}

/// F5: an adopted link started with another external lock dir refuses, and
/// makes no node key there.
#[tokio::test]
async fn an_adopted_link_refuses_another_external_lock_dir() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    drop(holder);
    let other = machine.home.parent().unwrap().join("other-home");
    let held = KeyHolder::acquire(&other).unwrap();
    let Err(refused) = serve_key(&state, &held, Some(&machine.home)).await else {
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
        let new_key = [round + 50; 32];
        let from = record("inst_x", [1; 32]).peer();
        let rekey = target.apply(&from, &[1; 32], &new_key);
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
    pair(&machine, &[record("inst_b", [2; 32])]);
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert!(served.retiring.is_some());
    let before = adopted(&state).unwrap().unwrap();
    assert_eq!(before.pending, BTreeSet::from(["inst_b".into()]));

    state.switch_install("inst_a", "inst_other").unwrap();
    assert!(adopted(&state).unwrap().is_none(), "another install has no adoption record");
    assert!(!state.has_link_key());

    state.switch_install("inst_other", "inst_a").unwrap();
    assert_eq!(adopted(&state).unwrap(), Some(before));
    assert!(state.has_link_key(), "the retired key came back with its record");
    let again = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    let retiring = again.retiring.expect("the retirement goes on");
    assert_eq!(retiring.pending, BTreeSet::from(["inst_b".into()]));
}

/// Third review, F1: `link peer add` replaces an install's pairing (a new
/// key, or another user) while a rekey from the old one waits for the
/// file's lock. The rekey was authenticated by the old record, so it is
/// refused: the replacement stays.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pairing_replaced_while_a_rekey_waits_is_never_written_over() {
    for (round, other_user) in [(0u8, false), (1, true), (2, false), (3, true)] {
        let far = tempfile::tempdir().unwrap();
        let file = far.path().join("peers.json");
        let mut theirs = Pairings::default();
        theirs.upsert(record("inst_x", [1; 32])).unwrap();
        theirs.save(&file).unwrap();
        let target = Peers::load(file.clone()).unwrap().rekey_target();
        let authenticated = record("inst_x", [1; 32]);
        let replacement = PairingRecord {
            user: if other_user { "43".into() } else { "42".into() },
            ..record("inst_x", if other_user { [1; 32] } else { [9; 32] })
        };
        // The replacement holds the lock when the rekey asks for it.
        let lock = Pairings::lock(&file).unwrap();
        let rekey = {
            let target = target.clone();
            let from = authenticated.peer();
            tokio::spawn(async move { target.apply(&from, &[1; 32], &[round + 60; 32]).await })
        };
        tokio::time::sleep(Duration::from_millis(200)).await;
        let mut replaced = Pairings::load(&file).unwrap();
        replaced.upsert(replacement.clone()).unwrap();
        replaced.save(&file).unwrap();
        drop(lock);
        let refused = rekey.await.unwrap().unwrap_err();
        assert_eq!(refused.to_string(), "pairing_changed", "round {round}");
        let now = Pairings::load(&file).unwrap();
        assert_eq!(now.by_install("inst_x"), Some(&replacement), "round {round}");
    }
}

/// A link without rekeys (the version before this one): it reads the hello,
/// does not know the service and closes. Every other stream is echoed.
fn spawn_base_link(mut listener: cmux_wg::WgMeshListener) -> tokio::task::JoinHandle<()> {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    tokio::spawn(async move {
        while let Some((mut stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 16 * 1024];
                loop {
                    match stream.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(count) => {
                            if buffer[..count].windows(5).any(|window| window == b"rekey") {
                                let _ = stream.write_all(b"{\"ok\":false}\n").await;
                                break;
                            }
                            if stream.write_all(&buffer[..count]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = stream.shutdown().await;
            });
        }
    })
}

/// Third review, F2: during a rolling upgrade the peer is still a link
/// without rekeys. Each retry is refused, and the old key's tunnel carries
/// traffic all along: every round trip across the retries answers at once.
#[tokio::test]
async fn retries_against_a_link_without_rekeys_never_interrupt_the_old_tunnel() {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let a = machine_named("inst_a");
    let (a_socket, b_socket) = (socket().await, socket().await);
    let a_endpoint = a_socket.local_addr().unwrap();
    let b_endpoint = b_socket.local_addr().unwrap();
    let a_old = LinkState::open(Some(a.link.clone())).unwrap().own_public_key().unwrap();
    let (b_private, b_public) = cmux_wg::testing::random_keypair();
    pair(&a, &[paired_at("inst_b", b_public, b_endpoint)]);
    let b = in_mesh("inst_b", b_private, b_socket);
    let mut theirs = Pairings::default();
    theirs.upsert(paired_at("inst_a", a_old, a_endpoint)).unwrap();
    b.sync_peers(&theirs).await.unwrap();
    let _base = spawn_base_link(b.listen(LINK_PORT).await.unwrap());

    let running_a = run(&a, true, a_socket).await;
    let remote = SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), LINK_PORT);
    let mut stream =
        tokio::time::timeout(Duration::from_secs(10), running_a.overlay.connect(remote))
            .await
            .expect("no tunnel within 10 s")
            .expect("the old tunnel failed");
    // FAST retries every 0.2 s to 1 s: 4 s spans several.
    let started = tokio::time::Instant::now();
    let mut slowest = Duration::ZERO;
    let mut rounds = 0;
    while started.elapsed() < Duration::from_secs(4) {
        let sent = tokio::time::Instant::now();
        stream.write_all(b"ping\n").await.expect("the tunnel dropped a write");
        let mut answer = [0u8; 5];
        tokio::time::timeout(Duration::from_secs(2), stream.read_exact(&mut answer))
            .await
            .expect("the tunnel stalled")
            .expect("the tunnel closed");
        assert_eq!(&answer, b"ping\n");
        slowest = slowest.max(sent.elapsed());
        rounds += 1;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(rounds > 20, "{rounds} round trips");
    assert!(slowest < Duration::from_millis(500), "a round trip took {slowest:?}");
    let state = LinkState::open(Some(a.link.clone())).unwrap();
    assert!(state.has_link_key(), "the retired key went while the peer was never told");
    assert_eq!(adopted(&state).unwrap().unwrap().pending, BTreeSet::from(["inst_b".into()]));
}

/// `link peer add`, as the command runs it: under the pairing file's lock.
fn peer_add(link: &Path, peer: PairingRecord) {
    let state = LinkState::open(Some(link.to_path_buf())).unwrap();
    Pairings::update(&state.peers_path(), |pairings| pairings.upsert(peer)).unwrap();
}

/// Fourth review, F1: a `link peer add` that lands after `serve` started but
/// before the adoption commits is in the record's pending peers: the link
/// keeps answering it on the retired key and tells it the node key.
#[tokio::test]
async fn a_peer_added_just_before_the_adoption_is_still_told() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    pair(&machine, &[record("inst_b", [2; 32])]);
    let link = machine.link.clone();
    hooks::BEFORE_PAIRINGS_LOCK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || peer_add(&link, record("inst_c", [3; 32]))));
    });
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    let both = BTreeSet::from(["inst_b".to_owned(), "inst_c".to_owned()]);
    assert_eq!(served.retiring.expect("peers are left to tell").pending, both);
    assert_eq!(adopted(&state).unwrap().unwrap().pending, both);
    assert!(state.has_link_key(), "the retired key went while a peer was never told");
}

/// Fourth review, F1: a `link peer add` that starts while the adoption holds
/// the pairing file's lock waits for the commit; by then `link show` (what
/// the far side pairs with) names the node key, so it needs no retired key.
#[tokio::test]
async fn a_peer_added_during_the_adoption_lands_after_the_commit_on_the_node_key() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    pair(&machine, &[record("inst_b", [2; 32])]);
    let link = machine.link.clone();
    let adding = Arc::new(std::sync::Mutex::new(None));
    let handle = adding.clone();
    hooks::PAIRINGS_LOCKED.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            let thread = std::thread::spawn(move || {
                peer_add(&link, record("inst_c", [3; 32]));
                LinkState::open(Some(link)).unwrap().own_public_key().unwrap()
            });
            std::thread::sleep(Duration::from_millis(200));
            assert!(!thread.is_finished(), "the peer add did not wait for the adoption's lock");
            *handle.lock().unwrap() = Some(thread);
        }));
    });
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    let shown = adding.lock().unwrap().take().expect("the hook ran").join().unwrap();
    assert_eq!(
        shown,
        node_public(&machine.home),
        "the peer paired with a key other than the node key"
    );
    let pending = BTreeSet::from(["inst_b".to_owned()]);
    assert_eq!(served.retiring.expect("inst_b is left to tell").pending, pending);
    assert_eq!(adopted(&state).unwrap().unwrap().pending, pending);
    assert_eq!(key_of(&machine, "inst_c"), Some([3; 32]), "the peer add was lost");
}

/// Fourth review, F2: an explicit `--key-lock-dir` that is not this
/// machine's acpmux home never adopts: the link keeps its own key, and no
/// `node.wg.key` or record is made there.
#[tokio::test]
async fn an_explicit_lock_dir_that_is_not_the_acpmux_home_never_adopts() {
    let machine = machine();
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    pair(&machine, &[record("inst_b", [2; 32])]);
    let old = state.own_public_key().unwrap();
    let other = machine.home.parent().unwrap().join("other-dir");
    for home in [Some(machine.home.as_path()), None] {
        let holder = KeyHolder::acquire(&other).unwrap();
        let served = serve_key(&state, &holder, home).await.unwrap();
        assert_eq!(state::public_key(&served.key), old, "home {home:?}");
        assert!(served.retiring.is_none());
        assert!(!other.join(KeyFile::Node.file_name()).exists(), "a node key was made there");
        assert!(state.has_link_key());
        assert!(adopted(&state).unwrap().is_none());
        assert!(!adopts(&state, &other, home).unwrap());
    }
    // The acpmux home itself does.
    assert!(adopts(&state, &machine.home, Some(&machine.home)).unwrap());
}

/// Puts in acpmux home `home` a machine record joined on another box and not
/// settled yet (`cloned` unset: its node key not replaced), the way a copy
/// looks before acpmux's daemon first starts on the new machine.
fn joined_on_another_box(home: &Path) {
    use std::os::unix::fs::OpenOptionsExt as _;
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::create_dir_all(home).unwrap();
    std::fs::set_permissions(home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let record = serde_json::json!({
        "credential": "cmm_original", "machine_id": "machine_original", "team_id": "team",
        "name": "original", "hub_origin": "https://example.com", "last_heartbeat": null,
        "revoked": false, "wgPublicKey": "original-key", "credential_generation": 1,
        "host_fingerprint": "another-box",
    });
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(home.join("machine-credential.json"))
        .unwrap();
    std::io::Write::write_all(&mut file, record.to_string().as_bytes()).unwrap();
}

/// Whether this box has an OS machine identity: without one acpmux's clone
/// check compares nothing, and neither do these tests.
fn box_named() -> bool {
    let named = acpmux::cli::mesh_node_key::box_stamp().is_some();
    if !named {
        eprintln!("skipped: this box names no machine, so no copy can be told apart");
    }
    named
}

async fn adopted_machine() -> Machine {
    let machine = machine();
    pair(&machine, &[record("inst_b", [2; 32])]);
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    machine
}

async fn refused(machine: &Machine, home: Option<&Path>) -> String {
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    match serve_key(&state, &holder, home).await {
        Ok(served) => panic!("served {:?}", state::public_key(&served.key)),
        Err(refused) => format!("{refused:#}"),
    }
}

/// Review F2 at 9e91bcea: a copied home, not settled, with an adopted link
/// never serves the original's node key (with the recorded home, and with
/// none); the refusal is kept, also after a new join. The original serves.
#[tokio::test]
async fn a_copied_home_with_an_adopted_link_refuses_to_serve_and_the_original_still_does() {
    if !box_named() {
        return;
    }
    let original = adopted_machine().await;
    let copy = adopted_machine().await;
    joined_on_another_box(&copy.home);
    for home in [Some(copy.home.as_path()), None] {
        let refused = refused(&copy, home).await;
        assert!(refused.starts_with("key_adoption.cloned_home:"), "{refused}");
        assert!(refused.contains("cmux host join") && refused.contains("aside"), "{refused}");
    }
    assert!(copy.link.join(LINK_COPIED).is_file(), "the refusal was not kept");
    assert!(acpmux::cli::mesh_node_key::serves_copied_key(&copy.home));
    assert!(!acpmux::cli::mesh_node_key::link_serves_node_key(Some(&copy.link), &copy.home));
    // A new join of the copy leaves the copied link refused.
    std::fs::remove_file(copy.home.join("machine-credential.json")).unwrap();
    let refused = refused(&copy, Some(&copy.home)).await;
    assert!(refused.starts_with("key_adoption.cloned_home:"), "{refused}");
    let state = LinkState::open(Some(original.link.clone())).unwrap();
    let holder = KeyHolder::acquire(&original.home).unwrap();
    let served = serve_key(&state, &holder, Some(&original.home)).await.unwrap();
    assert_eq!(state::public_key(&served.key), node_public(&original.home));
    acpmux::cli::mesh_node_key::record_link_home(&original.link, Some(&original.home)).unwrap();
    assert!(acpmux::cli::mesh_node_key::link_serves_node_key(Some(&original.link), &original.home));
}

/// Review F1 at d1e8f0ed: a leave on the copy finds it and removes the machine
/// record before the link ever starts there. What it found is recorded first
/// (the node key, `node-key-copied.json`), so the link's next start still
/// refuses, with no record left to compare.
#[tokio::test]
async fn a_copy_found_then_left_before_the_link_starts_still_refuses() {
    if !box_named() {
        return;
    }
    let copy = adopted_machine().await;
    joined_on_another_box(&copy.home);
    // What `machine leave` does on a copy: the clone check, then the record goes.
    assert!(acpmux::cli::mesh_node_key::home_copied(&copy.home));
    std::fs::remove_file(copy.home.join("machine-credential.json")).unwrap();
    assert!(!copy.link.join(LINK_COPIED).exists(), "the link has not started yet");
    let refused = refused(&copy, Some(&copy.home)).await;
    assert!(refused.starts_with("key_adoption.cloned_home:"), "{refused}");
    assert!(copy.link.join(LINK_COPIED).is_file());
}

/// The link's own state directory copied to another box (its stamp names
/// that box): it serves neither the adopted node key nor, never adopted, its
/// own key and pairings, with no machine record anywhere; and it records the
/// node key as copied, so acpmux never serves it either.
#[tokio::test]
async fn a_link_state_dir_stamped_on_another_box_never_serves() {
    if !box_named() {
        return;
    }
    let stamped_elsewhere = |machine: &Machine| {
        std::fs::write(machine.link.join(STAMP), r#"{"fingerprint":"another-box"}"#).unwrap();
    };
    let copy = adopted_machine().await;
    stamped_elsewhere(&copy);
    let refused_now = refused(&copy, Some(&copy.home)).await;
    assert!(refused_now.starts_with("key_adoption.cloned_home:"), "{refused_now}");
    assert!(acpmux::cli::mesh_node_key::serves_copied_key(&copy.home));
    // Never adopted: its own copied key is not served either, under any lock.
    let fresh = machine();
    stamped_elsewhere(&fresh);
    let state = LinkState::open(Some(fresh.link.clone())).unwrap();
    let own = KeyHolder::acquire(&fresh.link).unwrap();
    let Err(refused_own) = serve_key(&state, &own, Some(&fresh.home)).await else {
        panic!("a copied link key was served");
    };
    assert!(refused_own.to_string().starts_with("key_adoption.cloned_home:"), "{refused_own}");
    assert!(adopted(&state).unwrap().is_none());
}

/// Review F1 at d1e8f0ed, the case with no evidence left: an adopted link with
/// no stamp of the box it was adopted on fails closed.
#[tokio::test]
async fn an_adopted_link_with_no_stamp_fails_closed() {
    let machine = adopted_machine().await;
    std::fs::remove_file(machine.link.join(STAMP)).unwrap();
    let refused = refused(&machine, Some(&machine.home)).await;
    assert!(refused.starts_with("key_adoption.unstamped:"), "{refused}");
    // A link never adopted and set up before stamps is stamped at its start.
    let fresh = machine_named("inst_c");
    std::fs::remove_file(fresh.link.join(STAMP)).unwrap();
    let state = LinkState::open(Some(fresh.link.clone())).unwrap();
    let own = KeyHolder::acquire(&fresh.link).unwrap();
    serve_key(&state, &own, Some(&fresh.home)).await.unwrap();
    assert!(fresh.link.join(STAMP).is_file());
}

/// A link of this box's own never adopts a node key recorded as copied; once
/// acpmux replaces it (nothing adopted it), the link adopts the new one.
#[tokio::test]
async fn a_fresh_link_never_adopts_a_copied_node_key() {
    let machine = machine();
    let copied = acpmux::cli::mesh_node_key::load_or_create_at(&machine.home).unwrap();
    acpmux::cli::mesh_node_key::record_copied_key(&machine.home).unwrap();
    let refused = refused(&machine, Some(&machine.home)).await;
    assert!(refused.starts_with("key_adoption.cloned_home:"), "{refused}");
    assert!(!machine.link.join(LINK_COPIED).exists(), "the link's own identity is not copied");
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    assert!(adopted(&state).unwrap().is_none());
    let fresh = acpmux::cli::mesh_node_key::replace_at(&machine.home).unwrap();
    assert_ne!(fresh.public_key, copied.public_key);
    let holder = KeyHolder::acquire(&machine.home).unwrap();
    let served = serve_key(&state, &holder, Some(&machine.home)).await.unwrap();
    assert_eq!(state::public_key(&served.key), fresh.public_key);
}

/// Review F1 at 6b797bbf: a home copied to B, settled there with B's own key (an older copy
/// named), then joined again on B or not, and copied to C with a fresh link: C's link finds
/// the copy live and never adopts or serves B's key. On B the same home adopts.
#[tokio::test]
async fn a_copy_of_a_settled_copy_never_serves_the_settling_machines_key() {
    if !box_named() {
        return;
    }
    let here = acpmux::cli::mesh_node_key::box_stamp().unwrap();
    // (record as B left it, which box C is: another one, or this one for B itself)
    for (cloned, on_c) in [(false, true), (true, true), (false, false), (true, false)] {
        let machine = machine();
        let home = &machine.home;
        acpmux::cli::mesh_node_key::load_or_create_at(home).unwrap();
        acpmux::cli::mesh_node_key::record_copied_key(home).unwrap();
        let key_b = acpmux::cli::mesh_node_key::replace_at(home).unwrap().public_key;
        let box_b = if on_c { "box-b".to_owned() } else { here.clone() };
        let mut record = serde_json::json!({
            "credential": "cmm_b", "machine_id": "machine_b", "team_id": "team",
            "name": "b", "hub_origin": "https://example.com", "last_heartbeat": null,
            "revoked": false, "wgPublicKey": "b-key", "credential_generation": 1,
            "host_fingerprint": if cloned { "box-a" } else { box_b.as_str() },
        });
        if cloned {
            record["cloned"] = serde_json::json!(true);
            record["cloned_on"] = serde_json::json!(box_b);
        }
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(home.join("machine-credential.json"))
                .unwrap();
            std::io::Write::write_all(&mut file, record.to_string().as_bytes()).unwrap();
        }
        assert!(!acpmux::cli::mesh_node_key::serves_copied_key(home), "the marker names A only");
        let state = LinkState::open(Some(machine.link.clone())).unwrap();
        let holder = KeyHolder::acquire(home).unwrap();
        let served = serve_key(&state, &holder, Some(home)).await;
        if on_c {
            let Err(refused) = served else {
                panic!("C served B's key (cloned {cloned})");
            };
            assert!(refused.to_string().starts_with("key_adoption.cloned_home:"), "{refused}");
            assert!(adopted(&state).unwrap().is_none(), "C adopted B's key");
            assert!(acpmux::cli::mesh_node_key::serves_copied_key(home), "C's copy not recorded");
        } else {
            let served = served.unwrap();
            assert_eq!(state::public_key(&served.key), key_b, "B serves its own key");
        }
    }
}

/// Review F2 at 6b797bbf: a rekey pending (its answer lost) when the link first starts puts
/// the adoption off: the link serves its own key, records nothing, and leaves the node key and
/// the candidate as they are. Once acpmux promotes the candidate (or drops it), the next start
/// adopts the final key.
#[tokio::test]
async fn a_pending_rekey_puts_off_the_first_adoption_until_it_is_settled() {
    for promoted in [true, false] {
        let machine = machine();
        let home = &machine.home;
        let before = acpmux::cli::mesh_node_key::load_or_create_at(home).unwrap().public_key;
        let candidate = [9u8; 32];
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(KeyFile::NodePending.path_in(home))
                .unwrap();
            std::io::Write::write_all(&mut file, &candidate).unwrap();
        }
        let state = LinkState::open(Some(machine.link.clone())).unwrap();
        let own = state.own_public_key().unwrap();
        let holder = KeyHolder::acquire(home).unwrap();
        let served = serve_key(&state, &holder, Some(home)).await.unwrap();
        assert_eq!(state::public_key(&served.key), own, "adopted with a rekey pending");
        assert!(adopted(&state).unwrap().is_none());
        assert!(state.has_link_key());
        assert_eq!(node_public(home), before);
        assert!(acpmux::cli::mesh_node_key::rekey_pending(home), "the candidate went");
        drop(holder);
        // acpmux settles it (`machine.tunnel` attach): promoted, or dropped as refused.
        if promoted {
            std::fs::rename(KeyFile::NodePending.path_in(home), KeyFile::Node.path_in(home))
                .unwrap();
        } else {
            std::fs::remove_file(KeyFile::NodePending.path_in(home)).unwrap();
        }
        let holder = KeyHolder::acquire(home).unwrap();
        let served = serve_key(&state, &holder, Some(home)).await.unwrap();
        let final_key = node_public(home);
        assert_eq!(state::public_key(&served.key), final_key);
        assert_eq!(final_key == before, !promoted);
        assert!(adopted(&state).unwrap().is_some());
    }
}

/// Review F1 at 7837efd1: a home with a node key and a join begun on another box (no machine
/// record yet): a fresh link never adopts or serves the key.
#[tokio::test]
async fn a_home_with_a_pending_join_from_another_box_is_never_adopted() {
    if !box_named() {
        return;
    }
    use std::os::unix::fs::OpenOptionsExt as _;
    let machine = machine();
    let home = &machine.home;
    acpmux::cli::mesh_node_key::load_or_create_at(home).unwrap();
    let pending = serde_json::json!({"version": 1, "credential": "cmm_x",
        "hub": "https://example.com", "name": "original", "hostname": "original",
        "platform": "linux", "wg_public_key": "k", "prior": null, "host_fingerprint": "another-box"});
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(home.join("machine-join.pending.json"))
        .unwrap();
    std::io::Write::write_all(&mut file, pending.to_string().as_bytes()).unwrap();
    drop(file);
    let refused = refused(&machine, Some(home)).await;
    assert!(refused.starts_with("key_adoption.cloned_home:"), "{refused}");
    let state = LinkState::open(Some(machine.link.clone())).unwrap();
    assert!(adopted(&state).unwrap().is_none());
    assert!(acpmux::cli::mesh_node_key::serves_copied_key(home));
}
