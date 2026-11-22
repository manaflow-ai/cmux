//! Synthetic fixture helpers. Every fixture is made up in a temp dir; no
//! test reads a real harness store.
#![allow(dead_code)]

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};

use cmux_chat_index::{AdapterConfig, AdapterKind, ChatEntry, RootScan, scan_root};
use serde_json::Value;

pub fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().expect("fixture path has a parent"))
        .expect("create fixture dir");
    fs::write(path, text).expect("write fixture");
}

pub fn jsonl(records: &[Value]) -> String {
    records.iter().map(|record| format!("{record}\n")).collect()
}

pub fn write_jsonl(path: &Path, records: &[Value]) {
    write(path, &jsonl(records));
}

pub fn append_jsonl(path: &Path, records: &[Value]) {
    use std::io::Write;
    let mut file = fs::OpenOptions::new().append(true).open(path).expect("open fixture for append");
    file.write_all(jsonl(records).as_bytes()).expect("append fixture");
}

pub fn set_mtime_ms(path: &Path, ms: u64) {
    let file = File::options().write(true).open(path).expect("open fixture");
    file.set_modified(UNIX_EPOCH + Duration::from_millis(ms)).expect("set mtime");
}

pub fn scan(kind: AdapterKind, root: &Path) -> RootScan {
    scan_root(&AdapterConfig::new(kind, root), &HashMap::new()).expect("scan root")
}

pub fn by_id(scan: &RootScan) -> HashMap<String, ChatEntry> {
    scan.entries.iter().map(|entry| (entry.session_id.clone(), entry.clone())).collect()
}

pub fn ids(scan: &RootScan) -> HashSet<String> {
    scan.entries.iter().map(|entry| entry.session_id.clone()).collect()
}
