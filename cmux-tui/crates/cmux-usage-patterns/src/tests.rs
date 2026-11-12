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

/// The writer thread sleeps with no timeout while nothing is counted, writes
/// a count once its interval has passed, and writes at once when counting
/// stops. (A 5-second gate loop woke every idle daemon; `idle_wakeups.rs`.)
#[test]
fn the_writer_waits_for_a_count_and_writes_it_after_its_interval() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};
    let dir = scratch("writer");
    let on = config(&dir, true);
    let recorder = Arc::new(Recorder::open(&dir.join("out"), "session-a", on.clone()));
    let stop = Arc::new(AtomicBool::new(false));
    let interval = Duration::from_millis(300);
    let writer = {
        let recorder = Arc::clone(&recorder);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || recorder.run_writer(interval, &|| stop.load(Ordering::Relaxed)))
    };
    std::thread::sleep(interval * 3);
    assert!(!recorder.path().exists(), "the writer wrote with nothing counted");
    let counted = Instant::now();
    recorder.count("command", "split");
    let deadline = counted + Duration::from_secs(5);
    while !recorder.path().exists() {
        assert!(Instant::now() < deadline, "a count was never written");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(read_dir(&dir.join("out")).rollup.counts["command"]["split"], 1);
    // Turning counting off writes what was counted at once, not after the interval.
    recorder.count("command", "split");
    std::fs::write(&on, "{\"diagnostics\":{\"usagePatterns\":false}}  ").unwrap();
    let turned_off = Instant::now();
    assert!(!recorder.refresh_gate());
    while read_dir(&dir.join("out")).rollup.counts["command"]["split"] != 2 {
        assert!(turned_off.elapsed() < Duration::from_secs(5), "turning off did not write");
        std::thread::sleep(Duration::from_millis(5));
    }
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}

/// Waits up to 5 s for the gate to say `on`.
fn gate_becomes(recorder: &Recorder, on: bool, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while recorder.enabled() != on {
        assert!(Instant::now() < deadline, "{what}: the gate did not turn {on}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The gate follows the settings file with no timer: a file created later in
/// a folder created later, then a file replaced by rename (editors and the
/// settings writer save that way), each change the setting at once.
#[test]
fn the_gate_follows_the_settings_file_created_later_and_replaced_by_rename() {
    let dir = scratch("gate-watch");
    let folder = dir.join("config").join("cmux");
    let settings = folder.join("cmux-next.json");
    let recorder = Arc::new(Recorder::open(&dir.join("out"), "session-a", settings.clone()));
    assert!(!recorder.enabled());
    let _watch = watch_gate(&recorder).expect("the gate watch starts");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(&settings, "{\"diagnostics\":{\"usagePatterns\":true}}").unwrap();
    gate_becomes(&recorder, true, "a settings file created in a folder made later");
    let staged = folder.join("cmux-next.json.tmp");
    std::fs::write(&staged, "{\"diagnostics\":{\"usagePatterns\":false}}").unwrap();
    std::fs::rename(&staged, &settings).unwrap();
    gate_becomes(&recorder, false, "a settings file replaced by rename");
    std::fs::write(&staged, "{\"diagnostics\":{\"usagePatterns\":true}} ").unwrap();
    std::fs::rename(&staged, &settings).unwrap();
    gate_becomes(&recorder, true, "a second replace by rename");
}

/// `install` goes on without a watch when [`watch_gate`] gives `None` (the
/// watch could not start). Such a recorder still stops counting when the
/// setting goes off: its writer thread rereads the setting. Here no watch is
/// started and the test never calls `refresh_gate`, so only the writer can
/// see the change.
#[test]
fn a_recorder_without_a_watch_stops_counting_when_the_setting_goes_off() {
    let dir = scratch("no-watch");
    let settings = config(&dir, true);
    let recorder = Arc::new(Recorder::open(&dir.join("out"), "session-a", settings));
    assert!(recorder.enabled());
    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let recorder = Arc::clone(&recorder);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || {
            recorder.run_writer(Duration::from_millis(100), &|| stop.load(Ordering::Relaxed));
        })
    };
    recorder.count("command", "split");
    // One byte longer than the file it replaces, so the file's stamp differs
    // also when both writes fall in one tick of the file system's clock.
    config(&dir, false);
    let turned_off = Instant::now();
    while recorder.enabled() {
        assert!(
            turned_off.elapsed() < Duration::from_secs(5),
            "a recorder without a watch still counts 5 s after the setting went off"
        );
        recorder.count("command", "split");
        std::thread::sleep(Duration::from_millis(10));
    }
    let counted = recorder.snapshot().counts["command"]["split"];
    recorder.count("command", "split");
    assert_eq!(
        recorder.snapshot().counts["command"]["split"],
        counted,
        "a command was counted after the setting went off"
    );
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}

/// A recorder with the setting on and no watch. Its writer thread is started
/// by [`start_writer`] and stopped by [`stop_writer`].
fn recorder_without_a_watch(name: &str) -> (PathBuf, Arc<Recorder>) {
    let dir = scratch(name);
    let settings = config(&dir, true);
    let recorder = Arc::new(Recorder::open(&dir.join("out"), "session-a", settings));
    assert!(recorder.enabled());
    (dir, recorder)
}

fn start_writer(
    recorder: &Arc<Recorder>,
    flush_every: Duration,
) -> (Arc<AtomicBool>, std::thread::JoinHandle<()>) {
    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let recorder = Arc::clone(recorder);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || {
            recorder.run_writer(flush_every, &|| stop.load(Ordering::Relaxed));
        })
    };
    (stop, writer)
}

fn stop_writer(recorder: &Recorder, stop: &AtomicBool, writer: std::thread::JoinHandle<()>) {
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}

/// The setting goes off, then a command is counted, and only then does the
/// writer get to its wait: the wake of that count is pending, which is the
/// path of a writer that the count woke from its sleep. The writer rereads
/// the setting at that wake: it does not count on until the write that the
/// count made due (here 30 s later). The thread starts after the count, so
/// its first reread always finds the whole off file.
#[test]
fn a_writer_without_a_watch_stops_counting_when_the_next_count_wakes_it() {
    let (dir, recorder) = recorder_without_a_watch("no-watch-wake");
    config(&dir, false);
    recorder.count("command", "split");
    let (stop, writer) = start_writer(&recorder, Duration::from_secs(30));
    let started = Instant::now();
    while recorder.enabled() {
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the writer did not reread the setting when a count woke it: the recorder \
             still counts 5 s later"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    recorder.count("command", "split");
    assert_eq!(
        recorder.snapshot().counts["command"]["split"],
        1,
        "a command was counted after the writer read that the setting is off"
    );
    stop_writer(&recorder, &stop, writer);
}

/// The writer waits for its timed write when the setting goes off, and
/// nothing is counted after that. It rereads the setting at that write: with
/// no count to come, no later wake would read it.
#[test]
fn a_writer_without_a_watch_that_waits_for_its_write_stops_counting_at_that_write() {
    let (dir, recorder) = recorder_without_a_watch("no-watch-write-due");
    let (stop, writer) = start_writer(&recorder, Duration::from_millis(300));
    recorder.count("command", "split");
    // Time for the writer to start its 300 ms wait. A writer that starts
    // later than this reads the off file at its first wake, which also passes.
    std::thread::sleep(Duration::from_millis(100));
    config(&dir, false);
    let turned_off = Instant::now();
    while recorder.enabled() {
        assert!(
            turned_off.elapsed() < Duration::from_secs(5),
            "the writer did not reread the setting at its timed write: the recorder \
             still counts 5 s after the setting went off"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    stop_writer(&recorder, &stop, writer);
}

/// A recorder counting into `dir/out` and its writer thread, which writes
/// only an hour after a count: what a stop finds is unwritten.
fn recorder_with_writer(
    dir: &Path,
    on: bool,
) -> (Arc<Recorder>, Arc<AtomicBool>, std::thread::JoinHandle<()>) {
    let recorder = Arc::new(Recorder::open(&dir.join("out"), "session-a", config(dir, on)));
    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let recorder = Arc::clone(&recorder);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || {
            recorder.run_writer(Duration::from_secs(3600), &|| stop.load(Ordering::Relaxed));
        })
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !recorder.wake.writer.load(Ordering::Acquire) {
        assert!(Instant::now() < deadline, "the writer thread did not start");
        std::thread::sleep(Duration::from_millis(5));
    }
    (recorder, stop, writer)
}

/// The stop's last write runs on another thread; the result, or None when it
/// did not return within `within`.
fn stop_flush(recorder: &Arc<Recorder>, within: Duration) -> Option<(bool, Duration)> {
    let (sent, got) = std::sync::mpsc::channel();
    let recorder = Arc::clone(recorder);
    std::thread::spawn(move || {
        let started = Instant::now();
        let written = recorder.flush_within(STOP_FLUSH_WAIT);
        let _ = sent.send((written, started.elapsed()));
    });
    got.recv_timeout(within).ok()
}

/// A stop writes the counts its daemon made since the last write, at once
/// (the writer thread would write them only after its interval).
#[test]
fn a_stop_writes_the_unwritten_counts_at_once() {
    let dir = scratch("stop-writes");
    let (recorder, stop, writer) = recorder_with_writer(&dir, true);
    recorder.count("command", "split");
    let (written, took) = stop_flush(&recorder, Duration::from_secs(5)).expect("the stop returned");
    assert!(written, "the stop did not write");
    assert!(took <= STOP_FLUSH_WAIT, "the stop took {took:?}");
    assert_eq!(read_dir(&dir.join("out")).rollup.counts["command"]["split"], 1);
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}

/// With counting off a stop writes nothing: no file appears.
#[test]
fn a_stop_with_counting_off_writes_nothing() {
    let dir = scratch("stop-off");
    let (recorder, stop, writer) = recorder_with_writer(&dir, false);
    recorder.count("command", "split");
    let (written, _) = stop_flush(&recorder, Duration::from_secs(5)).expect("the stop returned");
    assert!(written);
    assert!(!recorder.path().exists(), "a stop with counting off wrote a file");
    assert!(!dir.join("out").exists(), "a stop with counting off made the folder");
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}

/// A disk that does not answer (here a pipe nobody reads, where the write's
/// open blocks) costs a stop at most [`STOP_FLUSH_WAIT`]: the stop returns
/// false and only the unwritten counts are lost. The stop used to write on
/// its own thread and waited on such a disk for as long as it did not answer.
#[test]
fn a_stop_waits_on_a_disk_that_does_not_answer_at_most_its_bound() {
    let dir = scratch("stop-stalled");
    let (recorder, stop, writer) = recorder_with_writer(&dir, true);
    std::fs::create_dir_all(dir.join("out")).unwrap();
    let staged = recorder.path().with_extension("json.tmp");
    let made = std::process::Command::new("mkfifo").arg(&staged).status().unwrap();
    assert!(made.success(), "mkfifo failed");
    recorder.count("command", "split");
    let returned = stop_flush(&recorder, Duration::from_secs(5));
    // Let the stalled write finish: a reader opens the pipe and drains it.
    let drain = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = std::io::Read::read_to_end(&mut std::fs::File::open(&staged).unwrap(), &mut bytes);
    });
    let (written, took) = returned.expect("the stop waited on the stalled disk past 5 s");
    assert!(!written, "the stop said the counts were written");
    assert!(took < STOP_FLUSH_WAIT + Duration::from_secs(1), "the stop took {took:?}");
    drain.join().unwrap();
    stop.store(true, Ordering::Relaxed);
    recorder.wake_writer();
    writer.join().unwrap();
}
