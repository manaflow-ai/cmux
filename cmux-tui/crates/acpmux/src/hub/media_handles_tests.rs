//! Unit tests of `media_handles.rs`: the caps (a peer link's included), a gone chat's handles, and
//! the table closed at the connection's end.

use super::*;
use crate::hub::media_read::open_in;
use std::path::PathBuf;

/// The global count is the process's: these tests take turns.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A stand-in for the hub's session.
struct Chat(#[allow(dead_code)] u8);

struct Folder(PathBuf);

impl Folder {
    fn new(tag: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("acpmux-handles-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let clip = [&b"\0\0\0\x18ftypisom\0\0\x02\0isomiso2"[..], &[1; 40]].concat();
        std::fs::write(dir.join("clip.mp4"), clip).unwrap();
        Folder(dir)
    }

    fn open(&self) -> Opened {
        open_in(std::slice::from_ref(&self.0), "clip.mp4", None, &mut |_| {}).unwrap()
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn reason(e: RpcError) -> String {
    e.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default().to_owned()
}

fn sweeping<O>(handles: &Handles<O>) -> bool {
    lock(&handles.state).sweeper.is_some()
}

#[tokio::test]
async fn handles_are_capped_per_connection_and_per_daemon() {
    let _turn = SERIAL.lock().await;
    let folder = Folder::new("caps");
    let (handles, chat) = (Handles::default(), Arc::new(Chat(0)));
    let first = handles.insert(&chat, folder.open()).unwrap();
    for _ in 1..MAX_HANDLES {
        handles.insert(&chat, folder.open()).unwrap();
    }
    assert_eq!(reason(handles.insert(&chat, folder.open()).unwrap_err()), "media.handles");
    handles.close(&chat, &first);
    let last = handles.insert(&chat, folder.open()).unwrap();
    handles.close(&chat, &last);
    // The daemon's places are taken by other connections.
    let taken: Vec<Slot> = std::iter::from_fn(Slot::take).collect();
    assert_eq!(OPEN.load(Ordering::SeqCst), MAX_OPEN);
    assert_eq!(reason(handles.insert(&chat, folder.open()).unwrap_err()), "media.busy");
    drop(taken);
    handles.insert(&chat, folder.open()).unwrap();
    // Closing the table gives every place back.
    handles.close_all();
    assert_eq!(OPEN.load(Ordering::SeqCst), 0);
    // A peer link carries all its daemon's clients, each capped there: only MAX_OPEN caps it.
    let link = Handles::for_peer_link();
    for _ in 0..=MAX_HANDLES {
        link.insert(&chat, folder.open()).unwrap();
    }
    link.close_all();
}

/// A chat that went away leaves its handles counting toward no cap. `forget_orphan` closes a
/// handle only once its own chat is gone: a live chat's handle stays, whoever names it.
#[tokio::test]
async fn a_gone_chats_handles_give_their_places_back() {
    let _turn = SERIAL.lock().await;
    let folder = Folder::new("gone");
    let (handles, chat) = (Handles::default(), Arc::new(Chat(0)));
    for _ in 0..MAX_HANDLES {
        handles.insert(&chat, folder.open()).unwrap();
    }
    drop(chat);
    let other = Arc::new(Chat(1));
    let kept = handles.insert(&other, folder.open()).unwrap();
    assert_eq!(OPEN.load(Ordering::SeqCst), 1);
    handles.forget_orphan(&kept);
    assert!(handles.get(&other, &kept).is_ok(), "a live chat's handle was closed");
    assert_eq!(OPEN.load(Ordering::SeqCst), 1);
    let gone = Arc::downgrade(&other);
    drop(other);
    assert!(gone.upgrade().is_none());
    handles.forget_orphan(&kept);
    assert_eq!(OPEN.load(Ordering::SeqCst), 0);
    handles.close_all();
}

/// Race: an open still running when the connection ends inserts after `close_all`: refused, its
/// file closed, and no sweeper starts.
#[tokio::test]
async fn an_open_that_finishes_after_the_connection_ended_is_refused() {
    let _turn = SERIAL.lock().await;
    let folder = Folder::new("closed");
    let (handles, chat) = (Handles::default(), Arc::new(Chat(0)));
    let handle = handles.insert(&chat, folder.open()).unwrap();
    let late = folder.open();
    handles.close_all();
    assert!(!sweeping(&handles));
    assert_eq!(reason(handles.get(&chat, &handle).unwrap_err()), "media.handle");
    assert_eq!(reason(handles.insert(&chat, late).unwrap_err()), "media.closed");
    assert!(!sweeping(&handles));
    assert_eq!(OPEN.load(Ordering::SeqCst), 0);
}
