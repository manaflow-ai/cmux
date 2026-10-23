//! Unit tests of `media_handles.rs`: the caps, the binding to the very session, the sweeper on
//! paused time, and the table closed at the connection's end or dropped.

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

#[tokio::test(start_paused = true)]
async fn an_idle_handle_closes_its_file_and_the_sweeper_stops() {
    let _turn = SERIAL.lock().await;
    let folder = Folder::new("idle");
    let (handles, chat) = (Handles::default(), Arc::new(Chat(0)));
    let handle = handles.insert(&chat, folder.open()).unwrap();
    let file = Arc::downgrade(&handles.get(&chat, &handle).unwrap().0);
    assert!(sweeping(&handles));
    tokio::time::sleep(IDLE - Duration::from_secs(1)).await;
    // A read keeps it open another IDLE.
    assert!(handles.get(&chat, &handle).is_ok());
    tokio::time::sleep(IDLE - Duration::from_secs(1)).await;
    assert!(file.upgrade().is_some());
    tokio::time::sleep(Duration::from_secs(2)).await;
    tokio::task::yield_now().await;
    assert!(file.upgrade().is_none(), "the descriptor outlived IDLE");
    assert!(!sweeping(&handles), "the sweeper runs on an empty table");
    assert_eq!(reason(handles.get(&chat, &handle).unwrap_err()), "media.handle");
    // The next handle starts a sweeper again; a dropped table closes its files and its sweeper.
    handles.insert(&chat, folder.open()).unwrap();
    assert!(sweeping(&handles));
    let state = Arc::downgrade(&handles.state);
    drop(handles);
    assert!(state.upgrade().is_none() && OPEN.load(Ordering::SeqCst) == 0);
}

#[tokio::test]
async fn a_handle_serves_only_the_session_that_opened_it() {
    let _turn = SERIAL.lock().await;
    let folder = Folder::new("owner");
    let handles = Handles::default();
    let (chat, other) = (Arc::new(Chat(0)), Arc::new(Chat(1)));
    let handle = handles.insert(&chat, folder.open()).unwrap();
    assert_eq!(reason(handles.get(&other, &handle).unwrap_err()), "media.handle");
    handles.close(&other, &handle);
    assert!(handles.get(&chat, &handle).is_ok(), "another session closed the handle");
    assert_eq!(reason(handles.get(&chat, "not-a-handle").unwrap_err()), "media.handle");
    // The chat is replaced: a new session under the same ID is another owner, and the old one,
    // once gone, serves nothing either.
    let replaced = Arc::new(Chat(0));
    assert_eq!(reason(handles.get(&replaced, &handle).unwrap_err()), "media.handle");
    let weak = Arc::downgrade(&chat);
    drop(chat);
    assert!(weak.upgrade().is_none());
    assert_eq!(reason(handles.get(&replaced, &handle).unwrap_err()), "media.handle");
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
