//! Where a push's time went, by stage, on stderr as one `{"timings":{...}}` line when
//! `CMUX_SYNC_PUSH_TIMINGS` is set (a bench or a person reading a slow copy; off otherwise):
//! `list` (the folder read and filtered here), `prepare` (each file's hash, and the machine's
//! folders read and made, one request at a time), `hash` (that hashing alone), `small` (the
//! store's fetch and the small files' writes), `large` (the big files, one at a time) and
//! `finish` (links, the manifest and this Mac's record), each in ms.

use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

pub(super) struct Stages {
    on: bool,
    last: Instant,
    hash: Duration,
    marks: Map<String, Value>,
}

impl Stages {
    pub(super) fn new() -> Self {
        Self {
            on: std::env::var_os("CMUX_SYNC_PUSH_TIMINGS").is_some(),
            last: Instant::now(),
            hash: Duration::ZERO,
            marks: Map::new(),
        }
    }

    /// Ends the stage `name` now.
    pub(super) fn mark(&mut self, name: &str) {
        let now = Instant::now();
        self.marks.insert(name.to_owned(), json!(now.duration_since(self.last).as_millis()));
        self.last = now;
    }

    /// Runs `hash`, counting its time as hashing.
    pub(super) fn hashing<T>(&mut self, hash: impl FnOnce() -> T) -> T {
        let started = Instant::now();
        let answer = hash();
        self.hash += started.elapsed();
        answer
    }

    pub(super) fn print(mut self) {
        if self.on {
            self.marks.insert("hash".to_owned(), json!(self.hash.as_millis()));
            eprintln!("{}", json!({ "timings": self.marks }));
        }
    }
}
