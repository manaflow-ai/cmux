//! Producer, session and mirror wired through encoded frames, delivered at
//! once in both directions.

use cmux_tab_snapshots::wire::kind;
use cmux_tab_snapshots::{
    Applied, BlobHash, FaviconInput, ImageInput, Kind, Message, Mime, Mirror, Observation,
    Producer, ScreenInput, Session, Viewport,
};

fn browser(id: &str, favicon: &[u8], thumb: &[u8]) -> Observation {
    Observation {
        tab_id: id.to_owned(),
        title: format!("Page {id}"),
        kind: Kind::Browser,
        favicon: Some(FaviconInput { mime: Mime::Png, bytes: favicon.to_vec() }),
        thumb: Some(ImageInput {
            mime: Mime::Jpeg,
            bytes: thumb.to_vec(),
            width: 516,
            height: 344,
        }),
        screen: None,
        frame: None,
        captured_at_ms: 10,
    }
}

fn terminal(id: &str, text: &str) -> Observation {
    Observation {
        tab_id: id.to_owned(),
        title: format!("zsh {id}"),
        kind: Kind::Terminal,
        favicon: None,
        thumb: None,
        screen: Some(ScreenInput { text: text.to_owned(), cols: 120, rows: 40 }),
        frame: None,
        captured_at_ms: 10,
    }
}

fn mac() -> Producer {
    let mut p = Producer::new("e1", 1_000, 64, 16);
    p.observe(browser("b1", b"icon-github", &[1; 4000]));
    p.observe(browser("b2", b"icon-github", &[2; 4000]));
    p.observe(browser("b3", b"icon-docs", &[3; 4000]));
    p.observe(terminal("t1", "$ cargo test\nok\n"));
    p
}

#[derive(Default, Debug)]
struct Traffic {
    manifests: usize,
    deltas: usize,
    blobs: Vec<BlobHash>,
    blob_bytes: usize,
    down_bytes: usize,
    up_bytes: usize,
}

/// Runs one link from link-up until neither side has anything to send.
fn run(
    producer: &Producer,
    session: &mut Session,
    mirror: &mut Mirror,
    up: Vec<Vec<u8>>,
) -> Traffic {
    let mut t = Traffic::default();
    let mut up = up;
    loop {
        let mut progress = false;
        for frame in up.drain(..) {
            t.up_bytes += frame.len();
            session.on_frame(&frame).unwrap();
            progress = true;
        }
        while let Some(frame) = session.next_frame(producer) {
            progress = true;
            t.down_bytes += frame.len();
            match mirror.apply_frame(&frame).unwrap() {
                Applied::Manifest { .. } | Applied::Delta { .. } => {
                    if frame[0] == kind::MANIFEST {
                        t.manifests += 1;
                    } else {
                        t.deltas += 1;
                    }
                    // A pushing Mac sends every card blob unasked; the
                    // phone wants only from a Mac that does not push.
                    if !session.pushes() {
                        up.extend(mirror.want_frame());
                    }
                }
                Applied::Gap { .. } => up.extend(mirror.resume_frame()),
                Applied::Blob { hash, len, .. } => {
                    t.blobs.push(hash);
                    t.blob_bytes += len;
                }
            }
        }
        if !progress {
            return t;
        }
    }
}

fn link_up(mirror: &Mirror) -> Vec<Vec<u8>> {
    let mut frames = mirror.link_up_frames();
    frames.push(Message::Viewport(Viewport::default()).encode());
    frames
}

fn all_filled(mirror: &Mirror) -> bool {
    (0..mirror.rows().len()).all(|i| mirror.card_filled(i)) && mirror.missing().is_empty()
}

#[test]
fn cold_open_fills_every_card_and_sends_a_shared_favicon_once() {
    let p = mac();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    let t = run(&p, &mut Session::new(), &mut phone, up);
    assert_eq!(phone.rows().len(), 4);
    assert!(all_filled(&phone));
    assert_eq!((t.manifests, t.deltas), (1, 0));
    // 2 favicons (one shared by b1 and b2), 3 thumbnails, 1 screen.
    assert_eq!(t.blobs.len(), 6);
    let github = BlobHash::of(b"icon-github");
    assert_eq!(t.blobs.iter().filter(|h| **h == github).count(), 1);
    // Pushed in row order: per row the favicon, then the thumbnail or screen.
    let docs = BlobHash::of(b"icon-docs");
    let thumb = |n: u8| BlobHash::of(&[n; 4000]);
    let screen = BlobHash::of(b"$ cargo test\nok\n");
    assert_eq!(t.blobs, vec![github, thumb(1), thumb(2), docs, thumb(3), screen]);
    // No want went up: the only up frame is the viewport.
    assert_eq!(t.up_bytes, Message::Viewport(Viewport::default()).encode().len());
}

#[test]
fn second_open_with_a_persisted_cache_moves_no_blob_bytes() {
    let p = mac();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    run(&p, &mut Session::new(), &mut phone, up);
    let mut relaunched = Mirror::new();
    relaunched.import_held(phone.export_held());
    let up = link_up(&relaunched);
    let t = run(&p, &mut Session::new(), &mut relaunched, up);
    assert_eq!(t.manifests, 1);
    assert_eq!(t.blob_bytes, 0);
    assert!(t.blobs.is_empty());
    assert!(all_filled(&relaunched));
}

#[test]
fn one_changed_thumbnail_moves_one_delta_and_one_blob() {
    let mut p = mac();
    let mut phone = Mirror::new();
    let mut session = Session::new();
    let up = link_up(&phone);
    run(&p, &mut session, &mut phone, up);
    assert!(p.observe(browser("b2", b"icon-github", &[9; 4000])));
    let t = run(&p, &mut session, &mut phone, Vec::new());
    assert_eq!((t.manifests, t.deltas), (0, 1));
    assert_eq!(t.blobs, vec![BlobHash::of(&[9; 4000])]);
    assert!(all_filled(&phone));
    // Observing the same bytes again sends nothing.
    assert!(!p.observe(browser("b2", b"icon-github", &[9; 4000])));
    let t = run(&p, &mut session, &mut phone, Vec::new());
    assert_eq!(t.down_bytes, 0);
}

#[test]
fn reconnect_resumes_with_a_delta_not_a_manifest() {
    let mut p = mac();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    run(&p, &mut Session::new(), &mut phone, up);
    // The link drops; three tabs change while it is down.
    p.observe(browser("b1", b"icon-github", &[11; 4000]));
    p.observe(browser("b3", b"icon-new", &[3; 4000]));
    p.observe(terminal("t1", "$ cargo test\nok\n$ ls\n"));
    let up = link_up(&phone);
    let t = run(&p, &mut Session::new(), &mut phone, up);
    assert_eq!((t.manifests, t.deltas), (0, 1));
    assert_eq!(t.blobs.len(), 3);
    assert_eq!(phone.rev(), Some(p.rev()));
    assert!(all_filled(&phone));
}

#[test]
fn a_gap_recovers_through_resume() {
    let mut p = mac();
    let mut phone = Mirror::new();
    let mut session = Session::new();
    let up = link_up(&phone);
    run(&p, &mut session, &mut phone, up);
    p.observe(browser("b1", b"icon-github", &[12; 4000]));
    // The phone loses the delta (for example it was dropped by the app).
    let lost = session.next_frame(&p).unwrap();
    assert_eq!(lost[0], kind::DELTA);
    p.observe(browser("b2", b"icon-github", &[13; 4000]));
    let t = run(&p, &mut session, &mut phone, Vec::new());
    // The next delta is a gap; the phone resumes and applies one delta from
    // its own rev.
    assert_eq!((t.manifests, t.deltas), (0, 1));
    assert_eq!(phone.rev(), Some(p.rev()));
    assert!(all_filled(&phone));
}

#[test]
fn a_restarted_mac_answers_an_old_resume_with_a_manifest() {
    let p = mac();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    run(&p, &mut Session::new(), &mut phone, up);
    // The host restarts with a fresh epoch and the same first rev, so the
    // phone's rev is a valid number in the new run but means something else.
    let mut restarted = Producer::new("e2", 1_000, 64, 16);
    restarted.observe(browser("b1", b"icon-github", &[1; 4000]));
    restarted.observe(browser("x9", b"icon-docs", &[7; 4000]));
    restarted.observe(browser("b3", b"icon-docs", &[3; 4000]));
    restarted.observe(terminal("t1", "$ cargo test\nok\n"));
    assert_eq!(restarted.rev(), p.rev());
    let up = link_up(&phone);
    let t = run(&restarted, &mut Session::new(), &mut phone, up);
    assert_eq!((t.manifests, t.deltas), (1, 0));
    assert_eq!(phone.epoch(), "e2");
    let ids: Vec<_> = phone.rows().iter().map(|r| r.tab_id.as_str()).collect();
    assert_eq!(ids, vec!["b1", "x9", "b3", "t1"]);
    assert!(all_filled(&phone));
}

#[test]
fn a_reorder_while_disconnected_reaches_the_phone_in_one_delta() {
    let mut p = mac();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    run(&p, &mut Session::new(), &mut phone, up);
    assert!(p.set_order(&["t1", "b3"]));
    p.remove("b1");
    p.observe(browser("b4", b"icon-docs", &[4; 4000]));
    let up = link_up(&phone);
    let t = run(&p, &mut Session::new(), &mut phone, up);
    assert_eq!((t.manifests, t.deltas), (0, 1));
    let ids: Vec<_> = phone.rows().iter().map(|r| r.tab_id.as_str()).collect();
    let mac_ids: Vec<_> = p.rows().iter().map(|r| r.tab_id.as_str()).collect();
    assert_eq!(ids, vec!["t1", "b3", "b2", "b4"]);
    assert_eq!(ids, mac_ids);
}

#[test]
fn cold_open_without_push_moves_the_same_blobs_after_want() {
    let p = mac();
    let mut pushed = Mirror::new();
    let up = link_up(&pushed);
    let push = run(&p, &mut Session::new(), &mut pushed, up);
    let mut wanted = Mirror::new();
    let up = link_up(&wanted);
    let want = run(&p, &mut Session::without_push(), &mut wanted, up);
    assert!(all_filled(&wanted));
    assert_eq!(push.blob_bytes, want.blob_bytes);
    // Push and want differ in order only: per row versus favicons first.
    let mut a = push.blobs.clone();
    let mut b = want.blobs.clone();
    a.sort_unstable();
    b.sort_unstable();
    assert_eq!(a, b);
    assert!(push.up_bytes < want.up_bytes, "push sends no want");
}

#[test]
fn a_want_after_eviction_resends_a_pushed_blob() {
    let p = mac();
    let mut phone = Mirror::new();
    let mut session = Session::new();
    let up = link_up(&phone);
    run(&p, &mut session, &mut phone, up);
    // The phone evicted b3's thumbnail and asks for it again.
    let thumb = BlobHash::of(&[3; 4000]);
    let want = Message::Want(vec![thumb]).encode();
    let t = run(&p, &mut session, &mut phone, vec![want]);
    assert_eq!(t.blobs, vec![thumb]);
    assert_eq!(session.stats().resent, 1);
}
