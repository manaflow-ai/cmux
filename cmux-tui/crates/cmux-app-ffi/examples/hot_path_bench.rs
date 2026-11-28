//! Times the app FFI's per-keystroke C ABIs as the app calls them, for
//! comparing release opt-levels (scripts/measure/app-ffi-hot-bench.sh):
//! the palette rank of one typed query against an installed catalog
//! (cmux-palette-ranker, pinned at opt-level 3) and the omnibox's typed-URL
//! resolve (cmux-url-input, at the profile's level) and a transcript's
//! markdown parse (cmux-chat-markdown pinned at 3; its unicode crates are not). Prints one
//! `hot-path NAME ns_per_call=N` line per path, the median of 7 rounds.

use std::time::Instant;

use cmux_chat_markdown::{DefaultPolicy, parse};
use cmux_palette_ranker::ffi as palette;
use cmux_url_input::ffi as url;

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[v.len() / 2]
}

fn entries_json(n: usize) -> String {
    let words = [
        "open", "split", "pane", "browser", "agent", "chat", "settings", "theme", "close",
        "window", "tab", "focus", "search", "palette", "terminal", "cloud",
    ];
    let mut out = String::from("[");
    for i in 0..n {
        if i > 0 {
            out.push(',');
        }
        let a = words[i % words.len()];
        let b = words[(i * 7 + 3) % words.len()];
        let c = words[(i * 11 + 5) % words.len()];
        out.push_str(&format!(
            r#"{{"title":"{a} {b} {c} {i}","keywords":["{c}","{b}{i}"],"subtitle":"{b}","sectionIndex":{},"actionID":"cmux.{a}.{b}.{i}","isEnabled":true,"isVisibleWhenQueryEmpty":true}}"#,
            i % 4
        ));
    }
    out.push(']');
    out
}

fn bench_palette() -> f64 {
    let ranker = palette::cmux_palette_ranker_new();
    let entries = entries_json(1200);
    let rc =
        unsafe { palette::cmux_palette_ranker_install(ranker, 1, entries.as_ptr(), entries.len()) };
    assert_eq!(rc, palette::OK, "install");
    let typed = "open browser settings";
    let requests: Vec<String> = (1..=typed.len())
        .map(|n| format!(r#"{{"operation":"rank","version":1,"query":"{}","now":1795866000.0,"showsRecent":true}}"#, &typed[..n]))
        .collect();
    let mut rounds = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        let mut calls = 0u32;
        for _ in 0..40 {
            for req in &requests {
                let mut resp: *const u8 = std::ptr::null();
                let mut len = 0usize;
                let rc = unsafe {
                    palette::cmux_palette_ranker_rank(
                        ranker,
                        req.as_ptr(),
                        req.len(),
                        &mut resp,
                        &mut len,
                    )
                };
                assert_eq!(rc, palette::OK, "rank");
                std::hint::black_box(len);
                calls += 1;
            }
        }
        rounds.push(start.elapsed().as_nanos() as f64 / f64::from(calls));
    }
    unsafe { palette::cmux_palette_ranker_free(ranker) };
    median(rounds)
}

fn bench_url() -> f64 {
    let typed = "https://github.com/manaflow-ai/cmux/pulls?q=is%3Aopen+bundle size falls";
    let home = "/Users/someone";
    let inputs: Vec<&str> = (1..=typed.len()).map(|n| &typed[..n]).collect();
    let mut out = vec![0u8; 4096];
    let mut rounds = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        let mut calls = 0u32;
        for _ in 0..2000 {
            for input in &inputs {
                let mut len = 0usize;
                let rc = unsafe {
                    url::cmux_url_input_resolve_typed(
                        input.as_ptr(),
                        input.len(),
                        home.as_ptr(),
                        home.len(),
                        url::FLAG_ALLOWS_CHROMIUM,
                        out.as_mut_ptr(),
                        out.len(),
                        &mut len,
                    )
                };
                assert!(rc >= 0, "resolve {rc}");
                std::hint::black_box(len);
                calls += 1;
            }
        }
        rounds.push(start.elapsed().as_nanos() as f64 / f64::from(calls));
    }
    median(rounds)
}

fn bench_markdown() -> f64 {
    let mut text = String::new();
    for i in 0..40 {
        text.push_str(&format!("## Step {i}: café naïve résumé\n\nEdited **3 files** `+70 -11`: GETs now retry 408, 429 and 5xx with [jittered backoff](https://example.com/{i}) — see _src/fetch.rs_.\n\n- one ✅ item\n- two 🚀 item with `code`\n\n```rust\nfn retry(n: u32) -> u32 {{ n * 2 }}\n```\n\n"));
    }
    let mut rounds = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        for _ in 0..200 {
            std::hint::black_box(parse(std::hint::black_box(&text), &DefaultPolicy));
        }
        rounds.push(start.elapsed().as_nanos() as f64 / 200.0);
    }
    median(rounds)
}

fn main() {
    println!("hot-path palette_rank_keystroke ns_per_call={:.0}", bench_palette());
    println!("hot-path markdown_parse_8kb ns_per_call={:.0}", bench_markdown());
    println!("hot-path url_resolve_typed ns_per_call={:.0}", bench_url());
}
