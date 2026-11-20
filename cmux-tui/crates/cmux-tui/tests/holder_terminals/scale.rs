//! The holder at scale: a crash under 50 printing tabs, and input echo beside a tab printing
//! at full speed (holder vs per-terminal hosts). Part of `holder_terminals.rs`.

use super::*;
/// Tabs that print while the holder is SIGKILLed (`a_holder_killed_mid_output_under_fifty_tabs_loses_no_shell_or_line`).
const CRASH_TABS: usize = 50;
/// Numbered lines each tab prints, a few at a time, before it waits for input.
const CRASH_LINES: usize = 3000;

/// Leo's "never close a tab" with the holder as the default (cmux#43143): one process
/// then holds every terminal, so its crash must cost nothing a person sees. 50 tabs print
/// numbered lines, and the holder is SIGKILLed (its own pid) while they all print. Every
/// shell must live, every tab must end with every line in order (no gap), and every tab
/// must take input again. It prints what was lost, when every tab's output resumed after the
/// kill, and when every tab had finished and echoed input, as a `HOLDER-CRASH` line.
#[test]
fn a_holder_killed_mid_output_under_fifty_tabs_loses_no_shell_or_line() {
    let mut daemon = Daemon::start();
    let script = daemon.dir.join("print.sh");
    fs::write(
        &script,
        format!(
            r#"stty -echo
tab=$1
printf 'ready %s\n' "$tab"
read go
i=0
while [ $i -lt {CRASH_LINES} ]; do
  printf 'tab %02d line %06d\n' "$tab" "$i"
  i=$((i + 1))
  [ $((i % 25)) -eq 0 ] && sleep 0.02
done
printf 'done %s\n' "$tab"
while read line; do printf 'got %s\n' "$line"; done
"#
        ),
    )
    .unwrap();
    let mut tabs = Vec::new();
    for tab in 0..CRASH_TABS {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/sh", script.to_str().unwrap(), tab.to_string()],
                "new_workspace": true, "name": format!("crash-{tab}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        tabs.push(surface);
    }
    for (tab, surface) in tabs.iter().enumerate() {
        screen_contains(&daemon.socket, *surface, &format!("ready {tab}"));
    }
    let shells: Vec<i32> = tabs.iter().map(|surface| shell_pid(&daemon.socket, *surface)).collect();
    let holder = parent_of(shells[0]);
    assert!(holder > 1 && shells.iter().all(|shell| parent_of(*shell) == holder));

    // Every tab starts printing; the holder dies once each has printed some of its lines.
    for surface in &tabs {
        request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "go\n"}));
    }
    for (tab, surface) in tabs.iter().enumerate() {
        screen_contains(&daemon.socket, *surface, &format!("tab {tab:02} line 0001"));
    }
    let killed = Instant::now();
    // SAFETY: SIGKILL of the holder this test's daemon started (its own pid, read above).
    unsafe { libc::kill(holder, libc::SIGKILL) };

    let lost_shells = shells.iter().filter(|shell| !alive(**shell)).count();
    // Output resumed: each tab shows a line past the newest it showed right after the kill.
    let at_kill: Vec<usize> = tabs
        .iter()
        .enumerate()
        .map(|(tab, surface)| newest_line(&daemon.socket, *surface, tab))
        .collect();
    for (tab, surface) in tabs.iter().enumerate() {
        let deadline = Instant::now() + Duration::from_secs(60);
        while newest_line(&daemon.socket, *surface, tab) <= at_kill[tab]
            && at_kill[tab] + 1 < CRASH_LINES
        {
            assert!(Instant::now() < deadline, "tab {tab}: no output after the holder crash");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    let resumed = killed.elapsed();
    // Recovered: every tab finished its lines and echoes input again.
    for (tab, surface) in tabs.iter().enumerate() {
        screen_contains_within(
            &daemon.socket,
            *surface,
            &format!("done {tab}"),
            Duration::from_secs(120),
        );
        send(&daemon.socket, *surface, &format!("ping-{tab}"));
    }
    for (tab, surface) in tabs.iter().enumerate() {
        screen_contains(&daemon.socket, *surface, &format!("got ping-{tab}"));
    }
    let recovered = killed.elapsed();

    let mut lost_lines = 0usize;
    let mut kept_min = usize::MAX;
    let mut worst = String::new();
    for (tab, surface) in tabs.iter().enumerate() {
        let mut rows: Vec<String> =
            history(&daemon.socket, *surface).iter().map(row_text).collect();
        rows.extend(screen_lines(&daemon.socket, *surface));
        let prefix = format!("tab {tab:02} line ");
        let mut seen: Vec<usize> =
            rows.iter().filter_map(|row| row.strip_prefix(&prefix)?.trim().parse().ok()).collect();
        seen.sort_unstable();
        seen.dedup();
        // The oldest lines may scroll out of the retained history; none after the first kept
        // one may be missing.
        let first = seen.first().copied().unwrap_or(CRASH_LINES);
        let missing = (first..CRASH_LINES).filter(|line| seen.binary_search(line).is_err()).count();
        if missing > 0 && worst.is_empty() {
            worst = format!("tab {tab}: {missing} lines missing after line {first}");
        }
        lost_lines += missing;
        kept_min = kept_min.min(seen.len());
    }
    eprintln!(
        "HOLDER-CRASH tabs={CRASH_TABS} lines_per_tab={CRASH_LINES} shells_lost={lost_shells} \
         lines_lost={lost_lines} kept_lines_min={kept_min} output_resumed_ms={} all_done_and_echoing_ms={}",
        resumed.as_millis(),
        recovered.as_millis()
    );
    assert_eq!(lost_shells, 0, "shells died with the holder");
    assert_eq!(lost_lines, 0, "lines were lost at the holder crash: {worst}");
}

/// The newest `tab NN line N` number on `surface`'s screen (0 when none shows).
fn newest_line(socket: &Path, surface: u64, tab: usize) -> usize {
    let prefix = format!("tab {tab:02} line ");
    screen_lines(socket, surface)
        .iter()
        .filter_map(|row| row.strip_prefix(&prefix)?.trim().parse().ok())
        .max()
        .unwrap_or(0)
}

/// The visible screen of `surface`, line by line.
fn screen_lines(socket: &Path, surface: u64) -> Vec<String> {
    let text = request(socket, json!({"cmd": "read-screen", "surface": surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    text.lines().map(|line| line.trim_end().to_string()).collect()
}

/// [`screen_contains`] with a longer bound: 50 tabs print while the holder is replaced.
fn screen_contains_within(socket: &Path, surface: u64, marker: &str, limit: Duration) {
    let deadline = Instant::now() + limit;
    loop {
        let text = request(socket, json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if text.contains(marker) {
            return;
        }
        assert!(Instant::now() < deadline, "surface {surface} never showed {marker:?}:\n{text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Tabs that echo input beside one tab that prints as fast as it can.
const NOISY_TABS: usize = 50;
/// Input rounds over every quiet tab.
const NOISY_ROUNDS: usize = 6;

/// The holder's one downside to check before it is the default (#36853, cmux#43143): one event
/// loop holds every terminal, so a tab printing at full speed (`yes`) could slow the echo of
/// the others. 49 tabs run `cat`; each round sends a line to each and times it to the screen
/// (input to echo). Measured on the holder and on per-terminal hosts, each with and without the
/// flood, and printed as `NOISY` lines with p50 and p95. Every echo must arrive.
#[test]
fn input_echo_beside_a_tab_printing_at_full_speed_holder_and_hosts() {
    for model in ["holder", "host"] {
        for flood in [false, true] {
            let (p50, p95, max) = noisy_echo(model, flood);
            eprintln!(
                "NOISY model={model} flood={flood} tabs={NOISY_TABS} samples={} \
                 echo_p50_ms={p50:.1} echo_p95_ms={p95:.1} echo_max_ms={max:.1}",
                (NOISY_TABS - 1) * NOISY_ROUNDS
            );
        }
    }
}

/// Input-to-echo times of the quiet tabs under `model`, with one tab flooding when `flood`:
/// (p50, p95, max) in ms.
fn noisy_echo(model: &str, flood: bool) -> (f64, f64, f64) {
    let model_path = PathBuf::from(model);
    let mut daemon =
        Daemon::start_with_env(&[("CMUX_TUI_TERMINAL_HOST_MODEL", model_path.as_path())]);
    let mut quiet = Vec::new();
    for tab in 0..NOISY_TABS {
        let argv = if tab == 0 && flood {
            json!([
                "/bin/sh",
                "-c",
                "yes 'flood flood flood flood flood flood flood' | head -c 2000000000"
            ])
        } else if tab == 0 {
            json!(["/bin/sh", "-c", "exec sleep 3600"])
        } else {
            json!(["/bin/cat"])
        };
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": argv, "new_workspace": true,
                "name": format!("noisy-{tab}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        if tab == 0 && flood {
            screen_contains(&daemon.socket, surface, "flood flood");
        } else if tab > 0 {
            quiet.push(surface);
        }
    }
    let mut samples = Vec::new();
    for round in 0..NOISY_ROUNDS {
        for (tab, surface) in quiet.iter().enumerate() {
            let marker = format!("echo-{round}-{tab}-x");
            let sent = Instant::now();
            send(&daemon.socket, *surface, &marker);
            let deadline = sent + Duration::from_secs(20);
            loop {
                let screen = request(
                    &daemon.socket,
                    json!({"cmd": "read-screen", "surface": surface}),
                )["text"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string();
                if screen.contains(&marker) {
                    break;
                }
                assert!(Instant::now() < deadline, "{model}: tab {tab} never echoed {marker}");
                std::thread::sleep(Duration::from_millis(1));
            }
            samples.push(sent.elapsed().as_secs_f64() * 1000.0);
        }
    }
    samples.sort_by(f64::total_cmp);
    let at = |q: f64| samples[((samples.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), at(1.0))
}
