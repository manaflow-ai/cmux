//! The generator against the repository's real recordings: the spec, every file's shape, the
//! stream's rate, the link model's bounds, the chat's numbering and ids, determinism, and `gen`
//! end to end for every preset (timed: heavy must stay fast).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use cmux_duress::link::Link;
use cmux_duress::{Inputs, Knobs, generate, history::Rows, inputs, stream};
use cmux_fault::Rng;
use cmux_fault::shaper::LinkProfile;

// affected-reads: cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
fn repo() -> PathBuf {
    // affected-reads: cmux-tui webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
    // affected-reads: cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl webviews/test/fixtures/chat-sim/replay-lane-session.ndjson cmux-tui/crates/cmux-duress/scenarios
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap()
}

fn recordings() -> Inputs {
    Inputs::load_repo(&repo()).expect("the PTY and chat fixtures (a full checkout)")
}

fn knobs(spec: &str) -> Knobs {
    Knobs::parse(spec).unwrap()
}

#[test]
fn spec_picks_a_preset_and_overrides_knobs() {
    let heavy = knobs("heavy");
    assert_eq!(
        (heavy.history_rows, heavy.stream_kbps, heavy.panes, heavy.workspaces),
        (100_000, 2048, 8, 500)
    );
    assert_eq!((heavy.chat_records, heavy.chat_rate, heavy.cpu_threads), (20_000, 200, 4));
    assert_eq!(heavy.link.as_deref(), Some("lossy-3"));
    let idle = knobs("idle");
    assert_eq!(
        (idle.history_rows, idle.stream_kbps, idle.panes, idle.workspaces, idle.link),
        (0, 0, 1, 20, None)
    );
    let duress = knobs("duress");
    assert_eq!((duress.chat_records, duress.chat_rate, duress.cpu_duty), (3561, 40, 0.5));
    assert_eq!(duress.link.as_deref(), Some("lte"));

    let tuned = knobs("heavy,link=2g-trickle,cpu_threads=6");
    assert_eq!(tuned.link.as_deref(), Some("2g-trickle"));
    assert_eq!(tuned.cpu_threads, 6);
    assert_eq!(tuned.history_rows, 100_000);
    assert_eq!(knobs("duress,link=none").link, None);
    assert_eq!(knobs("idle, seed=9 ,cpu_duty=0.25").seed, 9);
}

#[test]
fn spec_errors_list_what_is_valid() {
    let error = Knobs::parse("hevy").unwrap_err();
    assert!(error.contains("idle, duress, heavy"), "{error}");
    let error = Knobs::parse("heavy,rows=3").unwrap_err();
    assert!(error.contains("history_rows") && error.contains("stream_seconds"), "{error}");
    let error = Knobs::parse("heavy,link=5g-moon").unwrap_err();
    assert!(error.contains("lossy-3") && error.contains("2g-trickle"), "{error}");
    assert!(Knobs::parse("heavy,cpu_duty=1.5").unwrap_err().contains("cpu_duty"));
    assert!(Knobs::parse("heavy,panes=many").unwrap_err().contains("panes"));
    assert!(Knobs::parse("heavy,panes").unwrap_err().contains("knob=value"));
}

#[test]
fn history_has_exactly_the_rows_asked_for() {
    let inputs = recordings();
    let generated = generate(&knobs("idle,history_rows=5000"), &inputs).unwrap();
    let rows = &generated.history[generated.history_prefix_bytes..];
    assert!(generated.history_prefix_bytes > 512, "the recorded banner leads");
    let text = std::str::from_utf8(rows).expect("rows are UTF-8");
    assert!(text.ends_with("\r\n"));
    let split: Vec<&str> = text.split_inclusive("\r\n").collect();
    assert_eq!(split.len(), 5000);
    assert!(split.iter().all(|row| row.ends_with("\r\n") && !row[..row.len() - 2].contains('\n')));
    assert!(text.contains("● ") && text.contains("  ⎿  ") && text.contains("\x1b[48;2;61;1;0m"));
    assert!(text.contains("\x1b[38;5;") && text.contains("\x1b[1m"));
    assert!(text.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)), "some wide text");
    // A word lifted from the recording's printable text.
    assert!(text.contains("hello.py") || text.contains("python3"));
    assert!(generate(&knobs("idle"), &inputs).unwrap().history.is_empty());
}

#[test]
fn stream_averages_its_rate_without_a_link() {
    let inputs = recordings();
    for kbps in [1, 64, 256, 2048] {
        let generated = generate(
            &knobs(&format!("duress,link=none,stream_kbps={kbps},stream_seconds=30")),
            &inputs,
        )
        .unwrap();
        let bytes: usize = generated.stream.iter().map(|chunk| chunk.bytes.len()).sum();
        let want = (kbps * 125 * 30) as f64;
        assert!((bytes as f64 - want).abs() / want < 0.10, "{kbps} kbit/s: {bytes} B, want {want}");
        assert!(generated.stream.windows(2).all(|pair| pair[0].t_ms <= pair[1].t_ms));
        assert!(generated.stream.last().unwrap().t_ms <= 30_000);
    }
    assert!(generate(&knobs("duress,stream_kbps=0"), &inputs).unwrap().stream.is_empty());
}

fn test_profile(down_kbit: u64, rtt_ms: u64) -> LinkProfile {
    LinkProfile {
        name: "test-256".to_owned(),
        version: 1,
        up_kbit: down_kbit,
        down_kbit,
        rtt_ms,
        jitter_ms: 40,
        loss_percent: 1.0,
        rto_min_ms: 200,
        disruption: None,
        source: String::new(),
    }
}

fn shaped(profile: Option<LinkProfile>, kbps: u64) -> Vec<stream::Chunk> {
    let inputs = recordings();
    let words = inputs::printable_words(&inputs.pty);
    let mut rows = Rows::new(Rng::new(5), &words);
    let mut link = Link::new(profile, Rng::new(6));
    stream::stream(&inputs.pty, kbps, 20, &mut Rng::new(7), &mut rows, &mut link)
}

#[test]
fn link_holds_order_rate_and_delay() {
    let plain = shaped(None, 2048);
    let slow = shaped(Some(test_profile(256, 300)), 2048);
    assert_eq!(plain.len(), slow.len());
    assert!(
        slow.windows(2).all(|pair| pair[0].t_ms <= pair[1].t_ms),
        "head of line: never backwards"
    );
    let mut through = 0_u64;
    for (sent, delivered) in plain.iter().zip(&slow) {
        assert_eq!(sent.bytes, delivered.bytes);
        through += delivered.bytes.len() as u64;
        // Every byte through this chunk has serialized at 256 kbit/s (256 bits a ms) by now.
        assert!(through * 8 <= 256 * (delivered.t_ms + 1), "{through} B by {} ms", delivered.t_ms);
        assert!(
            delivered.t_ms + 1 >= sent.t_ms + 150,
            "rtt/2 at least: {} vs {}",
            delivered.t_ms,
            sent.t_ms
        );
    }
    // 2048 kbit/s of writes through a 256 kbit/s link takes about 8x the length.
    assert!(slow.last().unwrap().t_ms >= 20_000 * 7);
}

#[test]
fn chat_renumbers_and_keeps_ids_apart() {
    let inputs = recordings();
    let count = inputs.chat.len() as u64 * 2 + 17;
    let generated = generate(&knobs(&format!("duress,chat_records={count}")), &inputs).unwrap();
    assert_eq!(generated.chat.len() as u64, count);
    let mut tool_calls = std::collections::BTreeSet::new();
    let mut last_at = 0;
    for (index, line) in generated.chat.iter().enumerate() {
        let record: serde_json::Value = serde_json::from_str(line).unwrap();
        assert_eq!(record["seq"], index as u64 + 1);
        let at = record["at"].as_u64().unwrap();
        assert!(at >= last_at);
        last_at = at;
        if record["kind"] == "tool_call" {
            let id = record["msg"]["params"]["update"]["toolCallId"].as_str().unwrap().to_owned();
            assert!(tool_calls.insert(id.clone()), "{id} repeats");
        }
    }
    // The first replay keeps each msg byte for byte.
    let first: serde_json::Value = serde_json::from_str(&generated.chat[5]).unwrap();
    let raw = &generated.chat[5];
    assert!(raw.ends_with(&format!("\"msg\":{}}}", inputs.chat[5].msg)), "{raw}");
    assert_eq!(first["kind"], inputs.chat[5].kind.as_str());
    // About 40 records a second (plus the link's delay).
    let mean_ms = last_at as f64 / count as f64;
    assert!((20.0..40.0).contains(&mean_ms), "mean gap {mean_ms} ms");
}

#[test]
fn a_seed_gives_the_same_bytes() {
    let inputs = recordings();
    let one = generate(&knobs("duress,history_rows=2000,chat_records=500"), &inputs).unwrap();
    let again = generate(&knobs("duress,history_rows=2000,chat_records=500"), &inputs).unwrap();
    assert_eq!(one.history, again.history);
    assert_eq!(one.stream, again.stream);
    assert_eq!(one.chat, again.chat);
    let other =
        generate(&knobs("duress,history_rows=2000,chat_records=500,seed=2"), &inputs).unwrap();
    assert_ne!(one.history, other.history);
    assert_ne!(one.stream, other.stream);
}

#[test]
fn gen_writes_every_file_for_every_preset() {
    for preset in ["idle", "duress", "heavy"] {
        let dir =
            std::env::temp_dir().join(format!("cmux-duress-test-{preset}-{}", std::process::id()));
        let started = Instant::now();
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-duress"))
            .args(["gen", "--spec", preset, "--out"])
            .arg(&dir)
            .arg("--repo")
            .arg(repo())
            .output()
            .unwrap();
        let elapsed = started.elapsed();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let summary = String::from_utf8_lossy(&output.stdout);
        let sizes: Vec<String> =
            ["duress.json", "pty-history.bin", "pty-stream.jsonl", "chat.ndjson"]
                .iter()
                .map(|name| {
                    format!("{name} {} B", std::fs::metadata(dir.join(name)).unwrap().len())
                })
                .collect();
        println!("{} [{elapsed:?}; {}]", summary.trim(), sizes.join(", "));
        let manifest: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("duress.json")).unwrap())
                .unwrap();
        let knobs = knobs(preset);
        assert_eq!(manifest["knobs"]["history_rows"], knobs.history_rows);
        assert_eq!(manifest["counts"]["chat_records"], knobs.chat_records);
        assert_eq!(manifest["inputs"]["pty"]["sha256"].as_str().unwrap().len(), 64);
        let history = std::fs::metadata(dir.join("pty-history.bin")).unwrap().len();
        assert_eq!(manifest["counts"]["history_bytes"], history);
        let stream_lines =
            std::fs::read_to_string(dir.join("pty-stream.jsonl")).unwrap().lines().count();
        assert_eq!(manifest["counts"]["stream_chunks"], stream_lines as u64);
        if preset == "idle" {
            assert_eq!(history, 0);
            assert_eq!(stream_lines, 0);
            assert!(manifest["link"].is_null());
        } else {
            assert!(manifest["link"]["down_kbit"].as_u64().unwrap() > 0);
        }
        if preset == "heavy" {
            assert!(elapsed.as_secs_f64() < 10.0, "heavy took {elapsed:?}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
