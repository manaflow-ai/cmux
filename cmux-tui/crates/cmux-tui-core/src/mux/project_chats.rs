//! The chat-index project sources (plans/cmux-next/projects.md section 3):
//! the daemon reads acpmux's grouped chat index itself. Red step of A14: the
//! rule and the import are not here yet, so the tests below fail.
#![allow(dead_code)]

use std::collections::HashMap;
use std::io::Write;

use serde_json::Value;

use crate::state::projects::Observation;

const WATCH_ID: u64 = 2;

type Imported = HashMap<String, Vec<Observation>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Signal {
    Changed,
    Projects,
    Other,
}

fn signal(_message: &Value, _asked: Option<u64>) -> Signal {
    Signal::Other
}

fn batches(_result: &Value, _imported: &Imported) -> Vec<(String, Vec<Observation>)> {
    Vec::new()
}

struct Reads {
    asked: Option<u64>,
    again: bool,
    next_id: u64,
}

impl Reads {
    fn ask(&mut self, _writer: &mut impl Write) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
#[path = "project_chats_tests.rs"]
mod tests;
