//! Ranking speed over the equality corpus, through the C ABI the app calls.
//!
//!   cargo run --release -p cmux-palette-eval --example corpus_bench [PASSES]   (PASSES > 0, default 30)
//!
//! Each pass installs every entry set once, then ranks every corpus request against it, the
//! way the palette does per keystroke. Prints the median pass and the per-request median and p95.

use cmux_palette_ranker::ffi::{
    OK, cmux_palette_ranker_free, cmux_palette_ranker_install, cmux_palette_ranker_new,
    cmux_palette_ranker_rank,
};
use serde_json::Value;
use std::time::Instant;

fn main() -> Result<(), String> {
    let passes: usize =
        std::env::args().nth(1).and_then(|arg| arg.parse().ok()).filter(|&n| n > 0).unwrap_or(30);
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../cmux-palette-ranker/tests/corpus/palette-corpus.json"
    );
    let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    let corpus: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
    let sets = corpus["sets"].as_object().ok_or("corpus has no sets")?;
    let cases = corpus["cases"].as_array().ok_or("corpus has no cases")?;
    let installs: Vec<(i64, Vec<u8>)> = sets
        .values()
        .map(|set| {
            let version = set["version"].as_i64().unwrap_or(0);
            (version, serde_json::to_vec(&set["entries"]).unwrap_or_default())
        })
        .collect();
    let requests: Vec<(Option<i64>, Vec<u8>)> = cases
        .iter()
        .map(|case| {
            let set = &sets[case["set"].as_str().unwrap_or("")];
            let version = (case["inline"].as_bool() != Some(true))
                .then(|| set["version"].as_i64().unwrap_or(0));
            (version, serde_json::to_vec(&case["request"]).unwrap_or_default())
        })
        .collect();
    let handle = cmux_palette_ranker_new();
    let mut pass_ms = Vec::new();
    let mut request_us = Vec::new();
    for _ in 0..passes {
        let start = Instant::now();
        let mut installed = None;
        for (version, request) in &requests {
            if let Some(version) = version
                && installed != Some(*version)
            {
                let (_, entries) = installs
                    .iter()
                    .find(|(candidate, _)| candidate == version)
                    .ok_or("no set for version")?;
                // SAFETY: a live handle and a readable buffer.
                let code = unsafe {
                    cmux_palette_ranker_install(handle, *version, entries.as_ptr(), entries.len())
                };
                if code != OK {
                    return Err(format!("install returned {code}"));
                }
                installed = Some(*version);
            }
            let one = Instant::now();
            let mut response: *const u8 = std::ptr::null();
            let mut response_len = 0usize;
            // SAFETY: a live handle, a readable request and writable out pointers.
            let code = unsafe {
                cmux_palette_ranker_rank(
                    handle,
                    request.as_ptr(),
                    request.len(),
                    &mut response,
                    &mut response_len,
                )
            };
            request_us.push(one.elapsed().as_secs_f64() * 1e6);
            if code != OK {
                return Err(format!("rank returned {code}"));
            }
        }
        pass_ms.push(start.elapsed().as_secs_f64() * 1e3);
    }
    // SAFETY: the handle from cmux_palette_ranker_new, freed once.
    unsafe { cmux_palette_ranker_free(handle) };
    report("rust (C ABI)", requests.len(), &mut pass_ms, &mut request_us);
    Ok(())
}

fn report(name: &str, requests: usize, pass_ms: &mut [f64], request_us: &mut [f64]) {
    pass_ms.sort_by(f64::total_cmp);
    request_us.sort_by(f64::total_cmp);
    let at = |values: &[f64], q: f64| values[((values.len() - 1) as f64 * q) as usize];
    println!(
        "{name}: {requests} requests, pass median {:.1} ms, request median {:.0} us, p95 {:.0} us",
        at(pass_ms, 0.5),
        at(request_us, 0.5),
        at(request_us, 0.95)
    );
}
