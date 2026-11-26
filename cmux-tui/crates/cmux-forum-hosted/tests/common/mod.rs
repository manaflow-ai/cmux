//! A scripted transport and a settable clock.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cmux_forum_hosted::{Clock, Request, Response, Transport, TransportError};
use serde_json::Value;

#[derive(Clone, Default)]
pub struct FakeTransport {
    replies: Arc<Mutex<VecDeque<Result<Response, TransportError>>>>,
    pub sent: Arc<Mutex<Vec<Request>>>,
}

impl FakeTransport {
    pub fn push(&self, reply: Result<Response, TransportError>) {
        self.replies.lock().unwrap().push_back(reply);
    }

    pub fn push_json(&self, status: u16, body: Value) {
        self.push(Ok(json(status, body)));
    }

    pub fn requests(&self) -> Vec<Request> {
        self.sent.lock().unwrap().clone()
    }

    pub fn remaining(&self) -> usize {
        self.replies.lock().unwrap().len()
    }
}

impl Transport for FakeTransport {
    async fn send(&self, request: Request) -> Result<Response, TransportError> {
        self.sent.lock().unwrap().push(request);
        self.replies.lock().unwrap().pop_front().expect("unscripted request")
    }
}

pub fn json(status: u16, body: Value) -> Response {
    Response {
        status,
        headers: vec![("content-type".into(), "application/json".into())],
        body: serde_json::to_vec(&body).unwrap(),
    }
}

pub fn with_etag(mut r: Response, etag: &str) -> Response {
    r.headers.push(("ETag".into(), etag.into()));
    r
}

pub fn not_modified() -> Response {
    Response { status: 304, headers: vec![], body: vec![] }
}

#[derive(Default)]
pub struct FakeClock(pub AtomicU64);

impl FakeClock {
    pub fn at(secs: u64) -> Arc<Self> {
        Arc::new(Self(AtomicU64::new(secs)))
    }

    pub fn set(&self, secs: u64) {
        self.0.store(secs, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now_unix(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

pub fn event(seq: u64, kind: &str, thread: u64, title: &str, state: &str, at: &str) -> Value {
    serde_json::json!({
        "seq": seq, "kind": kind, "at": at, "space": "general", "thread": thread,
        "title": title, "state": state, "actor": {"kind": "agent", "id": "a1"},
        "origin": null, "comment": null
    })
}

pub fn feed_page(events: Vec<Value>, next: u64, head: u64) -> Value {
    serde_json::json!({ "events": events, "next": next, "head": head })
}

/// The value of query parameter `name` in a request's path.
pub fn query(req: &Request, name: &str) -> Option<String> {
    let q = req.path_and_query.split_once('?')?.1;
    url::form_urlencoded::parse(q.as_bytes()).find(|(k, _)| k == name).map(|(_, v)| v.into_owned())
}
