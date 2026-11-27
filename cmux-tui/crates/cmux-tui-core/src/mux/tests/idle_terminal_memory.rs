//! What the daemon holds per idle terminal on the holder (Leo, 2026-11-22: "infinite fucking
//! tabs and workspaces and shit without getting starved of cpu/ram"). A measurement, not a
//! gate: it opens `CMUX_IDLE_TERMINALS` (200) workspaces of one terminal each, the way the
//! daemon opens a new workspace (`Mux::new_workspace_as`), each a shell on a real holder
//! process that prints its prompt and waits; then it prints what this process (the daemon's
//! side: parser, surface, threads) grew by, per terminal, as one `IDLE-TERMINAL` line plus
//! where the resident memory sits (`IDLE-TERMINAL-MAP` lines, by mapping kind and size).
//!
//! The shells and the holder are other processes and are not counted. Run it (Linux; the
//! holder is the `cmux-holder` binary of the same tree):
//!
//! ```sh
//! cargo build -p cmux-holder
//! CMUX_TUI_TERMINAL_HOST_MODEL=holder CMUX_TUI_HOLDER_EXE=$PWD/target/debug/cmux-holder \
//!   cargo test -p cmux-tui-core --lib idle_holder_terminal_memory -- --ignored --nocapture
//! ```

use std::collections::BTreeMap;

use super::*;

/// One reading of this process's memory.
#[derive(Clone, Copy, Debug, Default)]
struct Reading {
    /// Resident set (`VmRSS`), bytes.
    rss: u64,
    /// Anonymous resident memory (`RssAnon`), bytes.
    anon: u64,
    /// Bytes malloc handed out and not freed (`mallinfo2` `uordblks + hblkhd`).
    malloc_live: u64,
    /// Bytes malloc's arenas hold, used or free (`arena + hblkhd`).
    malloc_held: u64,
    threads: u64,
}

fn status_kib(status: &str, key: &str) -> u64 {
    status
        .lines()
        .find_map(|line| line.strip_prefix(key))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
}

fn read() -> Reading {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    // SAFETY: glibc's mallinfo2 takes no pointer and only reads the allocator's counters.
    let info = unsafe { libc::mallinfo2() };
    Reading {
        rss: status_kib(&status, "VmRSS:") * 1024,
        anon: status_kib(&status, "RssAnon:") * 1024,
        malloc_live: (info.uordblks + info.hblkhd) as u64,
        malloc_held: (info.arena + info.hblkhd) as u64,
        threads: status_kib(&status, "Threads:"),
    }
}

/// Resident bytes and mapping count by mapping kind: the named ones (`[heap]`, `[stack]`, a
/// file) by name, an anonymous one by its size, so the thread stacks (one size), the malloc
/// arenas and the terminals' pages (each its own size) sit apart.
fn mappings() -> BTreeMap<String, (u64, u64)> {
    let smaps = std::fs::read_to_string("/proc/self/smaps").unwrap_or_default();
    let mut kinds: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    let mut current: Option<String> = None;
    for line in smaps.lines() {
        let mut fields = line.split_whitespace();
        let Some(first) = fields.next() else { continue };
        if let Some((start, end)) = first.split_once('-')
            && let (Ok(start), Ok(end)) =
                (u64::from_str_radix(start, 16), u64::from_str_radix(end, 16))
        {
            let perms = fields.next().unwrap_or("");
            let name = fields.nth(3).unwrap_or("");
            let kind = if name.starts_with('/') {
                "file".to_string()
            } else if !name.is_empty() {
                name.to_string()
            } else {
                format!("anon {perms} {} KiB", (end - start) / 1024)
            };
            kinds.entry(kind.clone()).or_default().1 += 1;
            current = Some(kind);
        } else if first == "Rss:"
            && let Some(kind) = current.as_ref()
        {
            let kib: u64 = fields.next().and_then(|value| value.parse().ok()).unwrap_or(0);
            kinds.entry(kind.clone()).or_default().0 += kib * 1024;
        }
    }
    kinds
}

fn wait_for_prompt(surface: &Surface, deadline: Instant) {
    loop {
        let text = surface
            .with_terminal(|terminal| terminal.plain_text())
            .and_then(Result::ok)
            .unwrap_or_default();
        if text.contains('$') || text.contains('#') || text.contains('%') {
            return;
        }
        assert!(Instant::now() < deadline, "no prompt; screen: {text:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Lets the reader threads park and the holder's first frames settle.
fn settle() -> (Reading, BTreeMap<String, (u64, u64)>) {
    std::thread::sleep(Duration::from_secs(2));
    (read(), mappings())
}

fn per(delta: i128, count: usize) -> String {
    format!("{:.1}", delta as f64 / count.max(1) as f64 / 1024.0)
}

#[test]
#[ignore = "a measurement (CMUX-571 infinite items): run by hand, see the module docs"]
fn idle_holder_terminal_memory() {
    assert!(
        crate::holder_runtime::enabled(),
        "set CMUX_TUI_TERMINAL_HOST_MODEL=holder (and CMUX_TUI_HOLDER_EXE): see the module docs"
    );
    let count: usize = std::env::var("CMUX_IDLE_TERMINALS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(200);
    let root = std::env::temp_dir().join(format!("cmux-idle-memory-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let mux = Mux::new(
        "idle-terminal-memory",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-i".into()]),
            terminal_host_root: Some(root.clone()),
            ..SurfaceOptions::default()
        },
    );
    let open = |deadline: Instant| {
        let surface = mux.new_workspace_as(&Actor::Daemon, None, Some((80, 24))).unwrap();
        assert!(surface.runs_on_holder(), "the terminal is not on the holder");
        wait_for_prompt(&surface, deadline);
        surface
    };
    // The first terminal starts the holder, its link and every once-per-process piece.
    let mut surfaces = vec![open(Instant::now() + Duration::from_secs(30))];
    let (before, before_maps) = settle();
    cmux_tui_platform::malloc_quiet_trim::release_free_pages();
    let trimmed_before = read();

    let deadline = Instant::now() + Duration::from_secs(120);
    for _ in 0..count {
        surfaces.push(open(deadline));
    }
    let (after, after_maps) = settle();
    cmux_tui_platform::malloc_quiet_trim::release_free_pages();
    let trimmed_after = read();

    let delta = |after: u64, before: u64| i128::from(after) - i128::from(before);
    eprintln!(
        "IDLE-TERMINAL terminals={count} per_terminal_kib: rss={} anon={} malloc_live={} \
         malloc_held={} rss_after_trim={} threads_per_terminal={:.2} \
         (total rss {:.1} -> {:.1} MiB)",
        per(delta(after.rss, before.rss), count),
        per(delta(after.anon, before.anon), count),
        per(delta(after.malloc_live, before.malloc_live), count),
        per(delta(after.malloc_held, before.malloc_held), count),
        per(delta(trimmed_after.rss, trimmed_before.rss), count),
        delta(after.threads, before.threads) as f64 / count as f64,
        before.rss as f64 / 1048576.0,
        after.rss as f64 / 1048576.0,
    );
    let mut grown: Vec<(String, i128, i128)> = after_maps
        .iter()
        .map(|(kind, (rss, maps))| {
            let (old_rss, old_maps) = before_maps.get(kind).copied().unwrap_or_default();
            (kind.clone(), delta(*rss, old_rss), delta(*maps, old_maps))
        })
        .filter(|(_, rss, maps)| *rss != 0 || *maps != 0)
        .collect();
    grown.sort_by_key(|(_, rss, _)| std::cmp::Reverse(*rss));
    for (kind, rss, maps) in grown.iter().take(12) {
        eprintln!(
            "IDLE-TERMINAL-MAP {kind}: rss_per_terminal_kib={} mappings_per_terminal={:.2}",
            per(*rss, count),
            *maps as f64 / count as f64
        );
    }

    // Holds the idle terminals open for an outside profiler (heaptrack, a bpftrace of malloc).
    if let Some(secs) = std::env::var("CMUX_IDLE_HOLD_SECS").ok().and_then(|v| v.parse().ok()) {
        eprintln!("IDLE-TERMINAL-HOLD pid={} secs={secs}", std::process::id());
        std::thread::sleep(Duration::from_secs(secs));
    }
    for surface in &surfaces {
        surface.kill();
    }
    drop(surfaces);
    let _ = std::fs::remove_dir_all(&root);
}
