use super::*;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-usage-patterns-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn config(dir: &Path, on: bool) -> PathBuf {
    let path = dir.join("cmux-next.json");
    std::fs::write(
        &path,
        format!("// a comment\n{{ \"diagnostics\": {{ \"usagePatterns\": {on} }} }}\n"),
    )
    .unwrap();
    path
}

#[test]
fn nothing_is_counted_while_the_setting_is_off() {
    let dir = scratch("off");
    let missing = dir.join("absent.json");
    let recorder = Recorder::open(&dir.join("out"), "session-a", missing);
    assert!(!recorder.enabled(), "a missing settings file is off");
    recorder.count("command", "split");
    recorder.peak("connections", 4);
    recorder.flush().unwrap();
    assert!(recorder.snapshot().is_empty());
    assert!(!recorder.path().exists(), "off writes no file");

    let off = config(&dir, false);
    let recorder = Recorder::open(&dir.join("out"), "session-a", off);
    recorder.count("command", "split");
    assert!(recorder.snapshot().is_empty());
}

#[test]
fn counts_flush_and_merge_across_writers() {
    let dir = scratch("merge");
    let on = config(&dir, true);
    let out = dir.join("out");
    let a = Recorder::open(&out, "session-a", on.clone());
    let b = Recorder::open(&out, "acpmux", on);
    assert!(a.enabled() && b.enabled());
    a.count("command", "split");
    a.count("command", "split");
    a.count("layout", "split-right");
    a.peak("connections.open", 3);
    b.count("command", "split");
    b.peak("connections.open", 5);
    a.flush().unwrap();
    b.flush().unwrap();

    let readout = read_dir(&out);
    assert_eq!(readout.writers.len(), 2);
    assert_eq!(readout.rollup.counts["command"]["split"], 3);
    assert_eq!(readout.rollup.counts["layout"]["split-right"], 1);
    assert_eq!(readout.rollup.peaks["connections.open"], 5);
    assert_eq!(readout.rollup.hours.iter().sum::<u64>(), 4);
    assert_eq!(readout.rollup.days.values().flat_map(|f| f.values()).sum::<u64>(), 4);

    // A reopened writer keeps its earlier counts.
    let again = Recorder::open(&out, "session-a", dir.join("cmux-next.json"));
    assert_eq!(again.snapshot().counts["command"]["split"], 2);
}

#[test]
fn keys_that_could_carry_content_count_as_other() {
    for bad in [
        "",
        "hello world",
        "https://example.com/?q=secret",
        "/Users/leo/private.txt",
        "~/notes",
        "me@example.com",
        "a=b",
        "C:\\Users\\leo",
        "../etc/passwd",
        "\"quoted\"",
        "file:/Users/leo/x",
        "Users/leo/notes",
        &"x".repeat(MAX_KEY_BYTES + 1),
    ] {
        assert_eq!(clean_key(bad), OTHER, "{bad:?} must not be kept");
    }
    for good in
        ["split", "tab.create_browser", "new-browser-tab", "claude", "session/new", "_acpmux/stats"]
    {
        assert_eq!(clean_key(good), good);
    }
}

#[test]
fn a_rollup_stays_bounded() {
    let mut rollup = Rollup::default();
    for i in 0..(MAX_KEYS_PER_FAMILY as u64 + 50) {
        rollup.add("command", &format!("k{i}"), 1, i);
    }
    assert_eq!(rollup.counts["command"].len(), MAX_KEYS_PER_FAMILY + 1);
    assert_eq!(rollup.counts["command"][OTHER], 50);
    for day in 0..(KEEP_DAYS as u64 + 30) {
        rollup.add("command", "k0", 1, day * 86_400_000);
    }
    assert_eq!(rollup.days.len(), KEEP_DAYS);
    assert_eq!(rollup.hours.len(), 24);
}

#[test]
fn a_reset_file_is_not_written_back() {
    let dir = scratch("reset");
    let on = config(&dir, true);
    let out = dir.join("out");
    let recorder = Recorder::open(&out, "session-a", on);
    recorder.count("command", "split");
    recorder.flush().unwrap();
    assert!(recorder.path().exists());
    recorder.count("command", "split");
    assert_eq!(reset_dir(&out).unwrap(), 1);
    recorder.flush().unwrap();
    assert!(!recorder.path().exists(), "the reset stays reset");
    assert!(recorder.snapshot().is_empty());
    recorder.count("command", "new-tab");
    recorder.flush().unwrap();
    assert_eq!(read_dir(&out).rollup.counts["command"].len(), 1);
}

#[test]
fn turning_the_setting_off_stops_counting_at_the_next_tick() {
    let dir = scratch("toggle");
    let on = config(&dir, true);
    let recorder = Recorder::open(&dir.join("out"), "session-a", on.clone());
    recorder.count("command", "split");
    // A different size so the stamp changes even within one mtime tick.
    std::fs::write(&on, "{\"diagnostics\":{\"usagePatterns\":false}}  ").unwrap();
    recorder.tick();
    assert!(!recorder.enabled());
    recorder.count("command", "split");
    assert_eq!(recorder.snapshot().counts["command"]["split"], 1);
    assert!(recorder.path().exists(), "turning off writes what was counted");
}

#[test]
fn the_dotted_key_also_turns_it_on() {
    let dir = scratch("dotted");
    let path = dir.join("cmux-next.json");
    std::fs::write(&path, "{\"diagnostics.usagePatterns\": true}").unwrap();
    assert!(setting_enabled(&path));
}

#[test]
fn opaque_ids_are_stable_and_do_not_show_the_id() {
    let a = opaque_id("machine-1234");
    assert_eq!(a, opaque_id("machine-1234"));
    assert_ne!(a, opaque_id("machine-1235"));
    assert_eq!(a.len(), 12);
    assert!(!a.contains("1234"));
    assert_eq!(clean_key(&a), a);
}

#[test]
fn utc_days_are_civil_dates() {
    assert_eq!(utc_day(0), "1970-01-01");
    assert_eq!(utc_day(951_782_400_000), "2000-02-29");
    assert_eq!(utc_day(1_793_836_800_000), "2026-11-05");
}

#[test]
fn pruning_keeps_the_newest_writers() {
    let dir = scratch("prune");
    for i in 0..5 {
        std::fs::write(dir.join(format!("w{i}.json")), "{}").unwrap();
        std::thread::sleep(Duration::from_millis(15));
    }
    assert_eq!(prune_writers(&dir, 3), 2);
    let mut left: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, ["w2.json", "w3.json", "w4.json"]);
}

#[test]
fn opaque_ids_are_sha_based_and_stable() {
    assert_eq!(opaque_id("main"), opaque_id("main"));
    assert_eq!(opaque_id("main").len(), 12);
}
