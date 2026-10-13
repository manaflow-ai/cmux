//! The palette ranker equality corpus through the C ABI.
//!
//! `tests/corpus/palette-corpus.json` holds real palette requests and the answers of the
//! TypeScript ranker this crate replaced, taken from its native bridge
//! (`webviews/scripts/palette-ranker-corpus.ts`). Each request goes through the same C calls the
//! macOS app makes: install a snapshot's entries once per version, then one rank call per query.
//! Every ordered result, score and highlight must be identical.

use cmux_palette_ranker::ffi::{
    CmuxPaletteRanker, ERR_NOT_INSTALLED, OK, cmux_palette_ranker_free,
    cmux_palette_ranker_install, cmux_palette_ranker_new, cmux_palette_ranker_rank,
};
use serde_json::Value;
use std::collections::HashSet;

struct Handle(*mut CmuxPaletteRanker);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: a handle from cmux_palette_ranker_new, freed once.
        unsafe { cmux_palette_ranker_free(self.0) };
    }
}

impl Handle {
    fn install(&self, version: i64, entries: &Value) -> Result<(), String> {
        let bytes = serde_json::to_vec(entries).map_err(|error| error.to_string())?;
        // SAFETY: a live handle and a readable buffer.
        let code =
            unsafe { cmux_palette_ranker_install(self.0, version, bytes.as_ptr(), bytes.len()) };
        if code == OK { Ok(()) } else { Err(format!("install {version} returned {code}")) }
    }

    fn rank(&self, request: &Value) -> Result<(i32, Vec<u8>), String> {
        let bytes = serde_json::to_vec(request).map_err(|error| error.to_string())?;
        let mut response: *const u8 = std::ptr::null();
        let mut response_len = 0usize;
        // SAFETY: a live handle, a readable request and writable out pointers.
        let code = unsafe {
            cmux_palette_ranker_rank(
                self.0,
                bytes.as_ptr(),
                bytes.len(),
                &mut response,
                &mut response_len,
            )
        };
        if response.is_null() {
            return Err(format!("rank returned {code} with no response"));
        }
        // SAFETY: the response stays valid until the next call on this handle.
        let body = unsafe { std::slice::from_raw_parts(response, response_len) }.to_vec();
        Ok((code, body))
    }
}

fn corpus() -> Result<Value, String> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/palette-corpus.json");
    let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("{path}: {error}"))
}

#[test]
fn every_corpus_request_ranks_like_the_typescript_ranker() -> Result<(), String> {
    let corpus = corpus()?;
    let sets = corpus["sets"].as_object().ok_or("corpus has no sets")?;
    let cases = corpus["cases"].as_array().ok_or("corpus has no cases")?;
    assert!(cases.len() >= 200, "the corpus has {} requests, fewer than 200", cases.len());
    let handle = Handle(cmux_palette_ranker_new());
    let mut installed = None;
    let mut failures = Vec::new();
    let mut operations = HashSet::new();
    let mut inline = 0;
    for case in cases {
        let name = case["name"].as_str().unwrap_or("?");
        let set = &sets[case["set"].as_str().ok_or("case without set")?];
        let version = set["version"].as_i64().ok_or("set without version")?;
        // An inline request carries its own entries; the others rank the installed snapshot.
        if case["inline"].as_bool() == Some(true) {
            inline += 1;
        } else if installed != Some(version) {
            handle.install(version, &set["entries"])?;
            installed = Some(version);
        }
        operations.insert(case["request"]["operation"].as_str().unwrap_or("").to_owned());
        let (code, body) = handle.rank(&case["request"])?;
        if code != OK {
            failures.push(format!("{name}: code {code}: {}", String::from_utf8_lossy(&body)));
            continue;
        }
        let actual: Value =
            serde_json::from_slice(&body).map_err(|error| format!("{name}: {error}"))?;
        if actual != case["expected"] {
            failures
                .push(format!("{name}:\n  expected {}\n  actual   {}", case["expected"], actual));
        }
    }
    assert!(
        operations.contains("rank") && operations.contains("rankEmpty"),
        "operations {operations:?}"
    );
    assert!(inline > 0, "the corpus has no inline-entries request");
    assert!(
        failures.is_empty(),
        "{} of {} requests differ:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
    Ok(())
}

#[test]
fn a_request_for_a_version_that_is_not_installed_is_refused() -> Result<(), String> {
    let handle = Handle(cmux_palette_ranker_new());
    handle.install(1, &serde_json::json!([{ "title": "Split Right" }]))?;
    let (code, body) =
        handle.rank(&serde_json::json!({ "operation": "rank", "version": 2, "query": "split" }))?;
    assert_eq!(code, ERR_NOT_INSTALLED);
    assert_eq!(
        String::from_utf8_lossy(&body),
        "palette ranker: no entries installed for version 2"
    );
    let (code, body) =
        handle.rank(&serde_json::json!({ "operation": "rank", "version": 1, "query": "split" }))?;
    assert_eq!(code, OK);
    let ranked: Value = serde_json::from_slice(&body).map_err(|error| error.to_string())?;
    assert_eq!(ranked[0]["rows"][0]["index"], 0);
    Ok(())
}
