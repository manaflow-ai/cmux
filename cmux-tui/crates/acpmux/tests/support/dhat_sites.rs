//! A dhat heap profile by acpmux allocation site, shared by the daemon benches that run a
//! `dhat-heap` build (`god_daemon.rs`, `sessions_scale.rs`).

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

/// The frame a dhat site is named by: the first one in acpmux's own code below the allocator,
/// with the function and its file and line.
/// With line tables, a generic frame (`poll<acpmux::...>`, `call_mut<...>`) names acpmux in its
/// type and a std file as its place: only a frame whose file is under `acpmux/src/` is acpmux's.
/// The site is the first three such frames, innermost first (`ACPMUX_GOD_DHAT_FRAMES` more).
fn acpmux_frame(frames: &[&str]) -> String {
    let depth =
        std::env::var("ACPMUX_GOD_DHAT_FRAMES").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
    let own: Vec<String> =
        frames.iter().filter(|f| own_file(f)).take(depth).map(|f| place(f)).collect();
    if own.is_empty() {
        return frames.get(1).map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
    }
    own.join(" < ")
}

/// A frame in acpmux's own source, not the allocator hook in `main.rs` or the profiler's.
fn own_file(frame: &str) -> bool {
    frame.contains("acpmux/src/")
        && !frame.contains("acpmux/src/main.rs")
        && !frame.contains("heap_profile")
}

/// A frame as `function (file:line)`: the function's last two path segments, its generics cut.
fn place(frame: &str) -> String {
    let frame = short_frame(frame);
    let (name, file) = frame.rsplit_once(" (").map_or((frame.as_str(), ""), |(n, f)| (n, f));
    let name = name.split('<').next().unwrap_or(name);
    let name: Vec<&str> = name.rsplit("::").take(2).collect();
    let file = file.trim_end_matches(')').split("acpmux/src/").last().unwrap_or(file);
    format!("{} ({file})", name.into_iter().rev().collect::<Vec<_>>().join("::"))
}

/// `0x1234: acpmux::watch_delta::Known::patched (src/watch_delta.rs:107:9)` without the address
/// and the hash.
pub fn short_frame(frame: &str) -> String {
    let frame = frame.split_once(": ").map_or(frame, |(_, f)| f);
    let frame = frame.replace("/home/runner/", "").replace("cmux-tui/crates/acpmux/", "");
    let hashless: String = frame.split("::h").next().unwrap_or(&frame).to_owned();
    if hashless.len() < frame.len() {
        // `::h<hash>` came before the file: keep the file.
        let file = frame.rsplit_once(" (").map(|(_, f)| format!(" ({f}")).unwrap_or_default();
        return format!("{hashless}{file}");
    }
    frame
}

/// The dhat profile at `path`, by acpmux site (the `top` largest of each list): bytes and blocks at the heap's peak and in total,
/// the largest first; and the sites of blocks of 600 to 700 bytes (serde_json's BTreeMap leaf
/// nodes are 640) at the peak.
pub fn attribute(path: &Path, top: usize) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({"error": format!("no profile at {}", path.display())});
    };
    let doc: Value = serde_json::from_str(&text).unwrap();
    let ftbl: Vec<&str> =
        doc["ftbl"].as_array().unwrap().iter().map(|f| f.as_str().unwrap_or("")).collect();
    #[derive(Default)]
    struct Site {
        gb: u64,
        gbk: u64,
        tb: u64,
        tbk: u64,
        // Held when the profile was written (the daemon's exit): what a run left behind.
        eb: u64,
        leaf_gb: u64,
        leaf_gbk: u64,
        inner: BTreeMap<String, u64>,
    }
    let mut sites: BTreeMap<String, Site> = BTreeMap::new();
    let (mut peak, mut leaves) = (0u64, 0u64);
    for pp in doc["pps"].as_array().unwrap() {
        let frames: Vec<&str> = pp["fs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|i| ftbl.get(i.as_u64()? as usize).copied())
            .collect();
        let gb = pp["gb"].as_u64().unwrap_or(0);
        let gbk = pp["gbk"].as_u64().unwrap_or(0);
        let site = sites.entry(acpmux_frame(&frames)).or_default();
        site.gb += gb;
        site.gbk += gbk;
        site.tb += pp["tb"].as_u64().unwrap_or(0);
        site.tbk += pp["tbk"].as_u64().unwrap_or(0);
        site.eb += pp["eb"].as_u64().unwrap_or(0);
        // The library frame that asked (serde_json, imbl, String), below the allocator's own.
        let inner = frames
            .iter()
            .find(|f| !f.contains("alloc::") && !f.contains("dhat") && !f.contains("[root]"))
            .map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
        *site.inner.entry(inner).or_default() += gb;
        peak += gb;
        if gbk > 0 && (600..=700).contains(&(gb / gbk)) {
            site.leaf_gb += gb;
            site.leaf_gbk += gbk;
            leaves += gb;
        }
    }
    let row = |(name, s): (&String, &Site)| {
        let mut inner: Vec<(&String, &u64)> = s.inner.iter().collect();
        inner.sort_by_key(|(_, b)| std::cmp::Reverse(**b));
        json!({"site": name, "peakBytes": s.gb, "peakBlocks": s.gbk, "endBytes": s.eb, "totalBytes": s.tb,
               "totalBlocks": s.tbk, "leafPeakBytes": s.leaf_gb, "leafPeakBlocks": s.leaf_gbk,
               "via": inner.into_iter().take(3).map(|(f, b)| json!([f, b])).collect::<Vec<_>>()})
    };
    let mut by_peak: Vec<(&String, &Site)> = sites.iter().collect();
    by_peak.sort_by_key(|(_, s)| std::cmp::Reverse(s.gb));
    let mut by_total: Vec<(&String, &Site)> = sites.iter().collect();
    by_total.sort_by_key(|(_, s)| std::cmp::Reverse(s.tb));
    let mut by_leaf: Vec<(&String, &Site)> = sites.iter().filter(|(_, s)| s.leaf_gb > 0).collect();
    by_leaf.sort_by_key(|(_, s)| std::cmp::Reverse(s.leaf_gb));
    let mut by_end: Vec<(&String, &Site)> = sites.iter().collect();
    by_end.sort_by_key(|(_, s)| std::cmp::Reverse(s.eb));
    json!({
        "peakBytes": peak,
        "leafPeakBytes": leaves,
        "byPeak": by_peak.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "byTotal": by_total.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "leavesBySite": by_leaf.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "endBytes": sites.values().map(|s| s.eb).sum::<u64>(),
        "byEnd": by_end.into_iter().take(top).map(row).collect::<Vec<_>>(),
    })
}
