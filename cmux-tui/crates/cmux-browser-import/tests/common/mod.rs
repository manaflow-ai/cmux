//! Fixture builders shared by the tests.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

use std::path::Path;

/// The mozLz4 wrapper around a block that holds `json` as one literal run (the Swift
/// `FirefoxSessionReaderTests.session` builder, byte for byte).
pub fn moz_lz4(json: &str) -> Vec<u8> {
    let payload = json.as_bytes();
    let mut block: Vec<u8> = Vec::new();
    if payload.len() < 15 {
        block.push((payload.len() as u8) << 4);
    } else {
        block.push(0xF0);
        let mut rest = payload.len() - 15;
        while rest >= 255 {
            block.push(255);
            rest -= 255;
        }
        block.push(rest as u8);
    }
    let mut data = b"mozLz40\0".to_vec();
    data.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    data.extend_from_slice(&block);
    data.extend_from_slice(payload);
    data
}

pub fn write(folder: &Path, name: &str, bytes: &[u8]) {
    let path = folder.join(name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, bytes).unwrap();
}

/// The `{"ok": ...}` of an op reply.
pub fn ok(reply: serde_json::Value) -> serde_json::Value {
    reply.get("ok").cloned().unwrap_or_else(|| panic!("not ok: {reply}"))
}
