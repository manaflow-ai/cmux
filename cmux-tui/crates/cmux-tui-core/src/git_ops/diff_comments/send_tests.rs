//! `diff.comments.send` against a real session ledger, with the acpmux
//! hand-over replaced: a key is bound to its first request before the
//! prompt leaves, and the prompt id is the session's own.

use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};

use super::send::{prompt_id, send_with};
use super::{File, Store};
use crate::mux::agent_message_pump::Handover;
use crate::resource_router::{ParsedResourceRequest, parse_resource_request};
use crate::{Mux, SurfaceOptions};

const ROOT: &str = "/work/app";
const KEY: &str = "send-key";

struct Session {
    mux: Arc<Mux>,
    store: Store,
    directory: PathBuf,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn session(name: &str) -> Session {
    let stamp = super::now_ms();
    let directory =
        std::env::temp_dir().join(format!("dcs-{name}-{}-{stamp}", std::process::id()));
    let mux =
        Mux::open_persistent(format!("dcs-{name}"), SurfaceOptions::default(), &directory).unwrap();
    let store = Store::open(&mux, "diff.comments.send").unwrap();
    let comments = ["a", "b"]
        .iter()
        .map(|id| json!({"id": id, "message": id}).as_object().unwrap().clone())
        .collect();
    store.write(ROOT, &File { root: ROOT.into(), comments }).unwrap();
    Session { mux, store, directory }
}

fn request(text: &str, key: &str) -> ParsedResourceRequest {
    let envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "send",
        "operation": "diff.comments.send",
        "params": {
            "machine": "current",
            "session": "current",
            "root": ROOT,
            "acp_session": "fake-session-1",
            "text": text,
            "ids": ["a", "b"],
        },
        "idempotency_key": key,
    });
    parse_resource_request(&envelope.to_string()).unwrap()
}

/// One send whose hand-over answers `answer`, recording the prompt ids it was given.
fn send(
    session: &Session,
    request: &ParsedResourceRequest,
    answer: Handover,
    handed: &RefCell<Vec<(String, String)>>,
) -> Result<Value, crate::resource::ResourceError> {
    send_with(&session.mux, &session.store, request, ROOT, |_, prompt_id, text, meta| {
        assert_eq!(meta["promptId"], prompt_id);
        handed.borrow_mut().push((prompt_id.to_owned(), text));
        answer
    })
}

fn left(session: &Session) -> usize {
    session.store.read(ROOT).unwrap().comments.len()
}

#[test]
fn a_send_whose_acknowledgement_is_lost_retries_only_as_itself() {
    let session = session("lost");
    let handed = RefCell::new(Vec::new());
    let review_a = request("Review A", KEY);

    // acpmux takes review A, but its acknowledgement never comes back.
    let lost = send(&session, &review_a, Handover::Unsettled("lost".into()), &handed).unwrap_err();
    assert_eq!(lost.details["reason"], "send_unsettled", "{lost:?}");
    assert_eq!(left(&session), 2, "nothing is cleared without an acknowledgement");

    // The same key with edited text is refused before anything is handed
    // over, though acpmux would acknowledge the prompt id as a duplicate.
    let edited = request("Review B, edited", KEY);
    let refused = send(&session, &edited, Handover::Delivered, &handed).unwrap_err();
    assert_eq!(refused.code, "idempotency.conflict", "{refused:?}");
    assert_eq!(handed.borrow().len(), 1, "the edited review never reaches acpmux");
    assert_eq!(left(&session), 2, "the comments acpmux never got stay");

    // Review A itself retries under the same prompt id and clears.
    let sent = send(&session, &review_a, Handover::Delivered, &handed).unwrap();
    assert_eq!(sent["value"], json!({"sent": 2, "cleared": ["a", "b"]}), "{sent}");
    let prompts = handed.borrow().clone();
    assert_eq!(prompts.len(), 2);
    assert_eq!(prompts[0], prompts[1], "the retry is the same prompt under the same id");
    assert_eq!(left(&session), 0);

    // Once committed the ledger answers: a replay sends nothing, other input conflicts.
    let replayed = send(&session, &review_a, Handover::Delivered, &handed).unwrap();
    assert_eq!(replayed["replayed"], true, "{replayed}");
    let refused = send(&session, &edited, Handover::Delivered, &handed).unwrap_err();
    assert_eq!(refused.code, "idempotency.conflict", "{refused:?}");
    assert_eq!(handed.borrow().len(), 2);
}

#[test]
fn a_refused_send_frees_its_key() {
    let session = session("refused");
    let handed = RefCell::new(Vec::new());
    let gone = send(&session, &request("Review A", KEY), Handover::Unreachable, &handed);
    assert_eq!(gone.unwrap_err().details["reason"], "no_session");
    // acpmux took nothing, so the key may carry a corrected review.
    let sent = send(&session, &request("Review B", KEY), Handover::Delivered, &handed).unwrap();
    assert_eq!(sent["value"]["cleared"], json!(["a", "b"]), "{sent}");
}

#[test]
fn prompt_ids_are_stable_per_session_and_distinct_between_sessions() {
    let first = session("first");
    let second = session("second");
    let id = prompt_id(&first.mux, KEY);
    assert!(id.starts_with("dcs_") && id.len() == 36, "{id}");
    assert_eq!(prompt_id(&first.mux, KEY), id);
    assert_ne!(prompt_id(&first.mux, "other-key"), id);
    assert_ne!(prompt_id(&second.mux, KEY), id, "the same key in another session");
    assert_ne!(id, KEY, "never the caller's raw key");
}
