//! The hand-back (b): a link up without the feature, `peers` off, or a mirror ended for good
//! after its takeover gives the origin back to v1's tee. Each way ends with the origin's rows
//! equal to v1's list and the mirror's mark written off.
use super::*;
use crate::hub::session_pages::PageRow as _;
use acpmux_book::index::{MirrorMark, SummaryIndex};
use acpmux_core::hub::{MirrorUnit, UnitChange};
use std::time::Duration;

const SSH: &str = "ssh-box";
const WAIT: Duration = Duration::from_secs(10);

fn v1_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    config.peers.insert(
        SSH.into(),
        crate::config::PeerConfig {
            link_host: None,
            wireguard: None,
            url: "ws://127.0.0.1:9/ssh-box".into(),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
    );
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::build(config, store, crate::mailbox::Mailbox::memory(), false, false, None, false)
}

/// An ssh peer's row, announced as a peer's listing announces it.
fn ssh_row(v1: &Hub, id: &str) {
    let summary = Hub::remote_summary(
        SSH,
        json!({"sessionId": id, "name": id, "status": "idle", "harness": "codex", "updatedAt": 9}),
    );
    let receipt = crate::session_identity::SessionReceipt::new(SSH, id, None, 1);
    v1.remote_sessions.write().insert(
        format!("{SSH}/{id}"),
        RemoteSession { peer: SSH.into(), summary: summary.clone().into(), receipt },
    );
    v1.announce_remote(SSH, summary, "status");
}

/// A v2 handle over `index` with its writer running.
fn v2_over(index: SummaryIndex, surfaces: &[&str]) -> Arc<V2> {
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = Arc::new(V2::with_surfaces(
        hub,
        writer,
        surfaces.iter().map(|surface| (*surface).to_owned()).collect(),
    ));
    tokio::spawn(v2.take_writer().unwrap().run());
    v2
}

/// What an earlier mirror left: a row v1 no longer lists, a row v1 lists, and a whole mark.
async fn mirrored(index: &acpmux_core::hub::Hub) {
    let mark = MirrorMark { cursor: 1, edition: 1, whole: true };
    let changes = ["gone-1", "r1"]
        .into_iter()
        .map(|id| {
            let mut summary = Summary::new(id);
            summary.origin = SSH.to_owned();
            summary.state = "running".to_owned();
            summary.title = "the mirror's".to_owned();
            UnitChange::Summary(Box::new(summary))
        })
        .collect();
    let unit = MirrorUnit { origin: SSH.to_owned(), after: None, changes, mark };
    index.submit_unit(Source::Mirror, unit).unwrap();
    until("the mirror's unit applied", || index.mirror_mark(SSH) == Some(mark)).await;
}

/// v1's tee running over `v2`, its remote rows ready.
fn tee(v1: &Arc<Hub>, v2: &Arc<V2>) {
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    tokio::spawn(task);
    v1.events.remote_tee_ready();
}

fn v1_ids(v1: &Hub) -> Vec<String> {
    let list = v1.list_rows(false, false);
    let mut ids: Vec<_> = list
        .rows()
        .iter()
        .filter(|row| row.peer() == Some(SSH) && row.status() != Some("closed"))
        .map(|row| row.session_id().to_owned())
        .collect();
    ids.sort();
    ids
}

fn v2_ids(v2: &V2) -> Vec<String> {
    v2.hub.snapshot().origin_chat_ids(SSH).map(str::to_owned).collect()
}

async fn until(what: &str, mut done: impl FnMut() -> bool) {
    let waited = tokio::time::timeout(WAIT, async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    assert!(waited.is_ok(), "never: {what}");
}

/// v1 and v2 with an earlier mirror's rows and source, and v1's rows the tee stood aside for.
async fn mirrored_rig() -> (Arc<Hub>, Arc<V2>, Arc<crate::peer::Peer>) {
    let v1 = v1_hub();
    let v2 = v2_over(SummaryIndex::new(), &["list", "peers"]);
    v1.link_v2.install(v2.clone());
    mirrored(&v2.hub).await;
    tee(&v1, &v2);
    ssh_row(&v1, "r1");
    ssh_row(&v1, "r2");
    let (notices, _) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(SSH, "ws://127.0.0.1:9/ssh-box", None, None, notices);
    peer.set_mirror(v1.link_v2.clone());
    assert_eq!(v2.hub.source(SSH), Some(Source::Mirror));
    (v1, v2, peer)
}

async fn handed_back(v1: &Hub, v2: &V2, peer: &crate::peer::Peer) {
    until("the origin's rows are v1's", || {
        v2.hub.source(SSH) == Some(Source::V1) && v2_ids(v2) == v1_ids(v1)
    })
    .await;
    assert_eq!(v1_ids(v1), ["r1", "r2"]);
    assert_eq!(v2.hub.mirror_mark(SSH), None, "the takeover writes the mark off");
    assert_eq!(peer.mirror_counters().hand_backs.load(Ordering::Relaxed), 1);
}

/// A link that comes up without the feature hands the origin back.
#[tokio::test]
async fn a_link_without_the_feature_hands_the_origin_back() {
    let (v1, v2, peer) = mirrored_rig().await;
    peer.start_mirror(peer.link_epoch());
    handed_back(&v1, &v2, &peer).await;
}

/// A mirror that ends for good on a link still up (here, a peer past its credit) hands the
/// origin back.
#[tokio::test]
async fn a_mirror_ended_on_a_live_link_hands_the_origin_back() {
    let (v1, v2, peer) = mirrored_rig().await;
    peer.seed_features(&[crate::link_v2::FEATURE]);
    let link = peer.link_epoch();
    peer.start_mirror(link);
    let past = "x".repeat(crate::peer_mirror::MIRROR_INBOX_BYTES + 1);
    peer.mirror_frame(
        link,
        format!(
            r#"{{"jsonrpc":"2.0","method":"_acpmux/v2","params":{{"kind":3,"payload":"{past}"}}}}"#
        ),
    );
    handed_back(&v1, &v2, &peer).await;
    assert_eq!(peer.mirror_counters().inbox_overflows.load(Ordering::Relaxed), 1);
}

/// With `peers` off no mirror runs: a mark an earlier run's mirror left is written off, and the
/// tee's walk leaves the origin's rows v1's.
#[tokio::test]
async fn peers_off_writes_off_the_mark_and_v1_holds_the_rows() {
    let earlier = v2_over(SummaryIndex::new(), &["list", "peers"]);
    mirrored(&earlier.hub).await;
    let v2 = v2_over((*earlier.hub.snapshot()).clone(), &["list"]);
    assert!(v2.hub.mirror_mark(SSH).is_some());
    assert_eq!(v2.hub.source(SSH), Some(Source::Mirror), "the mark opens it as the mirror's");
    let v1 = v1_hub();
    ssh_row(&v1, "r1");
    ssh_row(&v1, "r2");
    tee(&v1, &v2);
    until("the origin's rows are v1's and the mark is off", || {
        v2_ids(&v2) == v1_ids(&v1) && v2.hub.mirror_mark(SSH).is_none()
    })
    .await;
    assert_eq!(v2.hub.source(SSH), Some(Source::V1));
}

/// Decision 264 with `peers` off at the second start: the daemon reopened from its store opens
/// the origin as the mirror's, the write-off takes it over as v1, and the tee's walk leaves the
/// origin's rows v1's with the mark off.
#[tokio::test]
async fn peers_off_at_a_second_start_from_the_store_hands_the_origin_to_v1() {
    let directory = tempfile::tempdir().unwrap();
    {
        let (index, writer) = acpmux_core::hub::Hub::open(directory.path(), 1, || 7).unwrap();
        let writing = tokio::spawn(writer.run());
        mirrored(&index).await;
        index.close();
        writing.await.unwrap().unwrap();
    }
    let (index, writer) = acpmux_core::hub::Hub::open(directory.path(), 2, || 8).unwrap();
    let v2 = Arc::new(V2::with_surfaces(index, writer, ["list".to_owned()].into()));
    tokio::spawn(v2.take_writer().unwrap().run());
    v2.hub.wait_hydrated().await.unwrap();
    assert_eq!(
        v2.hub.source(SSH),
        Some(Source::Mirror),
        "the stored mark opens it as the mirror's"
    );
    let v1 = v1_hub();
    ssh_row(&v1, "r1");
    ssh_row(&v1, "r2");
    tee(&v1, &v2);
    until("the origin's rows are v1's and the mark is off", || {
        v2.hub.source(SSH) == Some(Source::V1)
            && v2_ids(&v2) == v1_ids(&v1)
            && v2.hub.mirror_mark(SSH).is_none()
    })
    .await;
    assert_eq!(v2_ids(&v2), ["r1", "r2"]);
}
