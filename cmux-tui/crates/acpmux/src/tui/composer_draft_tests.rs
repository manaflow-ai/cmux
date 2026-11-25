//! The terminal chat's unsent draft lives in acpmux's durable draft (`composer_draft.rs`): typed
//! text survives the TUI dying without a clean quit, a restart, and a chat switch.

use super::composer_draft::{BOUND, History, hydrated_draft, merged_draft};
use super::*;
use std::sync::Mutex;
use std::time::Duration;

/// A stand-in daemon that outlives the TUIs that connect to it: it keeps each chat's draft as
/// acpmux does (`Hub::set_composer_draft`: whitespace-only clears it) and answers anything else
/// with `{}`.
type Drafts = Arc<Mutex<HashMap<String, String>>>;

async fn daemon() -> (std::path::PathBuf, Drafts) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let socket = std::env::temp_dir().join(format!("acpmux-draft-{}.sock", uuid::Uuid::now_v7()));
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let drafts: Drafts = Arc::default();
    let store = drafts.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let store = store.clone();
            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let msg: Value = serde_json::from_str(&line).unwrap();
                    if msg.get("id").is_none() {
                        continue;
                    }
                    let id = msg["params"]["sessionId"].as_str().unwrap_or("").to_owned();
                    let result = match msg["method"].as_str() {
                        Some(method::MUX_DRAFT_SET) => {
                            let text = msg["params"]["text"].as_str().unwrap_or("").to_owned();
                            let mut store = store.lock().unwrap();
                            if text.trim().is_empty() {
                                store.remove(&id);
                            } else {
                                store.insert(id.clone(), text);
                            }
                            json!({"sessionId": id, "draft": store.get(&id)})
                        }
                        Some(method::MUX_DRAFT_GET) => {
                            json!({"sessionId": id, "draft": store.lock().unwrap().get(&id)})
                        }
                        _ => json!({}),
                    };
                    let reply =
                        json!({"jsonrpc": "2.0", "id": msg["id"], "result": result}).to_string();
                    if writer.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    (socket, drafts)
}

/// A TUI on `socket` with `ids` as its chats, the first one selected.
async fn tui(socket: &std::path::Path, ids: &[&str]) -> (App, mpsc::UnboundedReceiver<AppMsg>) {
    let client = Client::connect(socket).await.unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    let sessions = ids.iter().map(|id| json!({"sessionId": id})).collect();
    let mut app = run::make_app(client, tx, sessions, crate::config::Config::default()).unwrap();
    app.focus = Focus::Input;
    app.select(0);
    app.draft_tick(Instant::now());
    (app, rx)
}

/// Apply the TUI's messages until `done` holds, as its event loop does.
async fn pump(
    app: &mut App,
    rx: &mut mpsc::UnboundedReceiver<AppMsg>,
    done: impl Fn(&App) -> bool,
) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !done(app) {
        let m = tokio::time::timeout_at(deadline, rx.recv())
            .await
            .expect("the TUI never got there")
            .expect("the TUI's channel closed");
        app.on_msg(m);
        app.draft_tick(Instant::now());
    }
}

fn type_text(app: &mut App, text: &str) {
    for c in text.chars() {
        app.on_key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE));
    }
}

fn stored(drafts: &Drafts, id: &str) -> Option<String> {
    drafts.lock().unwrap().get(id).cloned()
}

/// Leo, 2026-11-24: "big disaster in Mango! i had a draft too that i wanted to send :(". Text typed
/// in the TUI's composer is in acpmux once the write bound passed, so a TUI that dies without a
/// quit (dropped here: no flush, no teardown) loses none of it, and the next TUI shows it.
#[tokio::test]
async fn a_typed_draft_survives_the_tui_dying_and_comes_back_on_reopen() {
    let (socket, drafts) = daemon().await;
    let (mut app, mut rx) = tui(&socket, &["s1"]).await;
    pump(&mut app, &mut rx, |a| a.draft_sync.was_read("s1") && !a.draft_sync.unsettled()).await;
    type_text(&mut app, "half a thought");
    let typed = Instant::now();
    app.draft_tick(typed);
    // Past the bound, the draft has gone to acpmux without any quit.
    app.draft_tick(typed + BOUND);
    pump(&mut app, &mut rx, |a| a.draft_sync.held("s1") == Some("half a thought")).await;
    drop(app);
    drop(rx);
    assert_eq!(stored(&drafts, "s1").as_deref(), Some("half a thought"));

    // A new TUI (a restart) opens the chat: the draft fills its composer.
    let (mut app, mut rx) = tui(&socket, &["s1"]).await;
    pump(&mut app, &mut rx, |a| a.input.text() == "half a thought").await;
}

/// A quit (or a focus loss) writes at once, before any pause or bound.
#[tokio::test]
async fn a_quit_writes_the_last_keystrokes_at_once() {
    let (socket, drafts) = daemon().await;
    let (mut app, mut rx) = tui(&socket, &["s1"]).await;
    pump(&mut app, &mut rx, |a| a.draft_sync.was_read("s1") && !a.draft_sync.unsettled()).await;
    type_text(&mut app, "last words");
    app.flush_draft();
    pump(&mut app, &mut rx, |a| !a.draft_sync.unsettled()).await;
    assert_eq!(stored(&drafts, "s1").as_deref(), Some("last words"));
}

/// Each chat keeps its own draft: a switch writes the one it leaves and shows the other's.
#[tokio::test]
async fn a_chat_switch_keeps_each_chats_draft() {
    let (socket, drafts) = daemon().await;
    drafts.lock().unwrap().insert("s2".into(), "written in the app".into());
    let (mut app, mut rx) = tui(&socket, &["s1", "s2"]).await;
    pump(&mut app, &mut rx, |a| a.draft_sync.was_read("s1") && !a.draft_sync.unsettled()).await;
    type_text(&mut app, "for one");
    app.select(1);
    app.draft_tick(Instant::now());
    pump(&mut app, &mut rx, |a| a.input.text() == "written in the app").await;
    pump(&mut app, &mut rx, |a| !a.draft_sync.unsettled()).await;
    assert_eq!(stored(&drafts, "s1").as_deref(), Some("for one"));
    app.select(0);
    app.draft_tick(Instant::now());
    pump(&mut app, &mut rx, |a| a.input.text() == "for one" && !a.draft_sync.unsettled()).await;
    assert_eq!(stored(&drafts, "s2").as_deref(), Some("written in the app"));
}

/// A send empties the composer, and the emptied draft is written: a restart shows nothing.
#[tokio::test]
async fn a_sent_draft_is_cleared() {
    let (socket, drafts) = daemon().await;
    let (mut app, mut rx) = tui(&socket, &["s1"]).await;
    pump(&mut app, &mut rx, |a| a.draft_sync.was_read("s1") && !a.draft_sync.unsettled()).await;
    type_text(&mut app, "ship it");
    app.flush_draft();
    pump(&mut app, &mut rx, |a| !a.draft_sync.unsettled()).await;
    assert_eq!(stored(&drafts, "s1").as_deref(), Some("ship it"));
    app.send_prompt(false);
    assert!(app.input.text().is_empty());
    // The tick after the send sees the emptied composer; the bound later, it is written.
    let sent = Instant::now();
    app.draft_tick(sent);
    app.draft_tick(sent + BOUND);
    pump(&mut app, &mut rx, |a| !a.draft_sync.unsettled()).await;
    assert_eq!(stored(&drafts, "s1"), None);
}

/// The app chat's rule (`composerDraft.ts` `mergedDraft`): both texts stay, none doubles.
#[test]
fn merged_draft_keeps_both_texts() {
    assert_eq!(merged_draft("typed", None), "typed");
    assert_eq!(merged_draft("", Some("saved")), "saved");
    assert_eq!(merged_draft("same", Some("same")), "same");
    assert_eq!(merged_draft("debugging", Some("bug")), "bug\n\ndebugging");
    assert_eq!(merged_draft("saved\n\ntyped", Some("saved")), "saved\n\ntyped");
    assert_eq!(merged_draft("typed", Some("saved\n\ntyped")), "saved\n\ntyped");
}

/// The app chat's rule (`composerDraft.ts` `hydratedDraft`): a touched prompt is never replaced
/// by another pane's draft; untouched, the newer draft fills it; typed before the first read, both.
#[test]
fn hydrated_draft_never_drops_either_text() {
    let h = |read, edited| History { read, edited, sent: false, pending_write: false };
    // Typed before the chat's first read: both texts, written back.
    let out = hydrated_draft("mine", Some("theirs"), h(false, true));
    assert_eq!((out.text.as_str(), out.shown, out.write), ("theirs\n\nmine", true, true));
    // Read before and untouched: another pane's newer draft fills the prompt.
    let out = hydrated_draft("old", Some("newer"), h(true, false));
    assert_eq!((out.text.as_str(), out.shown, out.write), ("newer", true, false));
    // Read before and edited: the prompt is the draft.
    let out = hydrated_draft("edited", Some("older"), h(true, true));
    assert_eq!((out.text.as_str(), out.shown, out.write), ("edited", false, true));
    // A write on its way: the prompt stays and nothing more is written.
    let pending = History { pending_write: true, ..h(true, true) };
    let out = hydrated_draft("newest", Some("older"), pending);
    assert_eq!((out.text.as_str(), out.write), ("newest", false));
}
