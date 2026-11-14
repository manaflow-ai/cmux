//! MEASURE BRANCH ONLY, never merged: where the time of a `list-workspaces` request and of a
//! `session.snapshot` request goes in a session of 826 workspaces, and how long each request
//! holds the mux state lock.
//!
//! The session: a registry that is a FILE in a temporary directory with the journal writer
//! thread, 826 workspaces with one terminal tab each (made with the debug cross-check off), each
//! terminal in a directory of its own below one test repository, and ONE conversation tab.
//!
//! Each scenario: a warm-up, then `REQUESTS` requests on this one thread. A `session.snapshot`
//! line goes through the entry of a connection's line (`handle_connection_message`). A
//! `list-workspaces` line is parsed and goes to `handle_request`, where the connection's
//! dispatch thread starts it: the probe is of one thread, so the move of the request to that
//! thread is not in the time. The parts are the laps of `crate::measure_probe`; a hold of the
//! state lock is taken where `server-stats` takes it (`StateGuard::drop`). The test asserts no
//! time: it prints.
//!
//! What it leaves out: a release build (this is a test build), terminals with screen content,
//! a second client at the same time, the host load, a registry of a real size, the queue of
//! the connection's dispatch thread.

use super::*;
use crate::measure_probe::{self, Laps};
use crate::state::conversation_tabs_store::{
    AGENT_SESSION_TABS_CAPABILITY, CLOSED_CONVERSATION_TABS_CAPABILITY,
    CONVERSATION_TABS_CAPABILITY, PAGE_TABS_CAPABILITY,
};
use std::collections::BTreeMap;
use std::time::Instant;

const WORKSPACES: usize = 826;
const WARM_UP: usize = 3;
const REQUESTS: usize = 25;

fn workspace_key(index: usize) -> String {
    format!("018f6e21-7b70-7e70-8000-{index:012}")
}

/// `WORKSPACES` workspaces with one running terminal each on a registry file below `root`, the
/// second workspace selected and the journal's public fold complete, as in a live session.
fn session(root: &std::path::Path) -> (Arc<Mux>, Vec<crate::SurfaceId>) {
    let name = "list-request-shares";
    let registry = crate::workspace_registry::WorkspaceRegistry::open(root, name).unwrap();
    let mux = Mux::from_workspace_registry(
        name.to_string(),
        SurfaceOptions::default(),
        registry,
        crate::mux::ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    assert!(mux.disk_usage_stats().is_some(), "the registry of this session is not a file");
    assert!(mux.journal_writer_stats().is_some(), "this session has no journal writer thread");
    // Only the test writes: a commit of the maintenance worker would make a cached snapshot
    // reader a first reader.
    mux.stop_journal_maintenance();
    let surfaces = crate::mux::without_crosscheck(|| {
        let mut terminals = Vec::with_capacity(WORKSPACES);
        for index in 0..WORKSPACES {
            mux.create_empty_workspace(
                Some(format!("ws {index}")),
                Some(workspace_key(index)),
                None,
            )
            .unwrap();
            let number = index + 1;
            terminals.push((
                format!("00000000000040008000{number:012x}"),
                format!("10000000000040008000{number:012x}"),
                workspace_key(index),
            ));
        }
        let surfaces = mux.seed_running_terminals_for_test(&terminals).unwrap();
        mux.select_workspace(Some(1), None);
        let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
        let fingerprint = json!({"operation": operation, "fixture": key});
        let expected_revision = mux.with_state(|state| state.resource_revision);
        mux.prepare_resource_effect(
            &crate::workspace_registry::WorkspaceMutation::daemon(key, "test").unwrap(),
            operation,
            &fingerprint,
            &json!({}),
            None,
            Some(expected_revision),
        )
        .unwrap();
        mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
        mux.commit_full_resource_effect_projection(key, operation, &fingerprint, json!({}))
            .unwrap();
        surfaces
    });
    (mux, surfaces)
}

/// A local (Unix socket) connection of the daemon.
struct Connection {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

impl Connection {
    fn open(mux: &Arc<Mux>, render: &Arc<RenderService>) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: None },
            render.clone(),
        );
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        Self { client, writer, outbound }
    }

    /// Removes each line that the connection queued; how many there were.
    fn drain(&self) -> usize {
        let mut lines = 0;
        while self.outbound.try_pop().is_some() {
            lines += 1;
        }
        lines
    }

    /// The next line that the connection queued.
    fn reply(&self) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(line) = self.outbound.try_pop() {
                return line;
            }
            assert!(Instant::now() < deadline, "no reply");
            std::thread::yield_now();
        }
    }
}

/// One request: its time from the line to the queued reply, its laps, and its reply.
struct Sample {
    total: Duration,
    laps: Laps,
    reply: String,
}

fn measured(
    mux: &Arc<Mux>,
    connection: &Connection,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    line: &str,
) -> Sample {
    // A line that the session queued for this connection before the request is not its reply.
    connection.drain();
    let resource = line.contains("\"protocol\"");
    measure_probe::begin();
    let start = Instant::now();
    let open = if resource {
        handle_connection_message(mux, connection.client, line, &connection.writer, scheduler)
    } else {
        let request: Request = serde_json::from_str(line).unwrap();
        handle_request(mux, connection.client, request, &connection.writer)
    };
    let total = start.elapsed();
    let laps = measure_probe::end();
    assert!(open, "the connection closed on: {line}");
    let reply = connection.reply();
    assert!(
        reply.contains("\"ok\":true"),
        "not an ok reply: {}",
        reply.chars().take(600).collect::<String>()
    );
    Sample { total, laps, reply }
}

fn ms(time: Duration) -> f64 {
    time.as_secs_f64() * 1000.0
}

fn median(mut times: Vec<Duration>) -> Duration {
    times.sort();
    times.get(times.len() / 2).copied().unwrap_or_default()
}

fn longest(times: &[Duration]) -> Duration {
    times.iter().copied().max().unwrap_or_default()
}

/// The time of `part` in `sample`: the sum of its laps, or `None` when it did not run.
fn part_time(sample: &Sample, part: &str) -> Option<Duration> {
    let mut sum = None;
    for (name, time) in &sample.laps.parts {
        if *name == part {
            sum = Some(sum.unwrap_or(Duration::ZERO) + *time);
        }
    }
    sum
}

/// The time of `sample` that no part holds. A part whose name starts with `=` holds other parts.
fn other_time(sample: &Sample) -> Duration {
    let mut parts = Duration::ZERO;
    for (name, time) in &sample.laps.parts {
        if !name.starts_with('=') {
            parts += *time;
        }
    }
    sample.total.saturating_sub(parts)
}

fn report(name: &str, samples: &[Sample]) {
    let totals: Vec<Duration> = samples.iter().map(|sample| sample.total).collect();
    let total = median(totals.clone());
    let share = |time: Duration| {
        if total.is_zero() { 0.0 } else { 100.0 * time.as_secs_f64() / total.as_secs_f64() }
    };
    let bytes = samples.iter().map(|sample| sample.reply.len()).max().unwrap_or(0);
    eprintln!(
        "LIST-SHARES [{name}] {} requests after {WARM_UP} of warm-up: total median {:.3} ms, \
         longest {:.3} ms, shortest {:.3} ms; reply {bytes} bytes",
        samples.len(),
        ms(total),
        ms(longest(&totals)),
        ms(totals.iter().copied().min().unwrap_or_default()),
    );
    let mut names: Vec<&'static str> = Vec::new();
    for sample in samples {
        for (part, _) in &sample.laps.parts {
            if !names.contains(part) {
                names.push(*part);
            }
        }
    }
    for part in names {
        let mut times = Vec::with_capacity(samples.len());
        let mut ran = 0;
        for sample in samples {
            let time = part_time(sample, part);
            ran += usize::from(time.is_some());
            times.push(time.unwrap_or_default());
        }
        let middle = median(times.clone());
        eprintln!(
            "LIST-SHARES [{name}]   part {part}: median {:.3} ms = {:.1}% of the total; longest \
             {:.3} ms; ran in {ran} of {} requests",
            ms(middle),
            share(middle),
            ms(longest(&times)),
            samples.len(),
        );
    }
    let others: Vec<Duration> = samples.iter().map(other_time).collect();
    let other = median(others.clone());
    eprintln!(
        "LIST-SHARES [{name}]   part (no probe: the rest of the request): median {:.3} ms = \
         {:.1}% of the total; longest {:.3} ms",
        ms(other),
        share(other),
        ms(longest(&others)),
    );

    let mut counts = Vec::with_capacity(samples.len());
    let mut sums = Vec::with_capacity(samples.len());
    let mut tops = Vec::with_capacity(samples.len());
    let mut sites: BTreeMap<String, Vec<Duration>> = BTreeMap::new();
    for sample in samples {
        let holds: Vec<Duration> = sample.laps.state_holds.iter().map(|(_, held)| *held).collect();
        counts.push(holds.len());
        let mut sum = Duration::ZERO;
        for held in &holds {
            sum += *held;
        }
        sums.push(sum);
        tops.push(longest(&holds));
        for (site, held) in &sample.laps.state_holds {
            sites.entry(site.clone()).or_default().push(*held);
        }
    }
    counts.sort_unstable();
    eprintln!(
        "LIST-SHARES [{name}]   STATE LOCK: holds in one request median {} (most {}); sum of the \
         holds of one request median {:.3} ms; longest hold of one request median {:.3} ms; \
         longest hold of all {} requests {:.3} ms",
        counts.get(counts.len() / 2).copied().unwrap_or(0),
        counts.last().copied().unwrap_or(0),
        ms(median(sums)),
        ms(median(tops.clone())),
        samples.len(),
        ms(longest(&tops)),
    );
    for (site, holds) in sites {
        eprintln!(
            "LIST-SHARES [{name}]     hold at {site}: {} holds in {} requests, median {:.3} ms, \
             longest {:.3} ms",
            holds.len(),
            samples.len(),
            ms(median(holds.clone())),
            ms(longest(&holds)),
        );
    }
}

/// Waits until no background refresh of git HEADs runs, so a request does not share the host
/// with the refresh of the request before it (a client that asks each few seconds does not).
fn settle_git_head_refresh() {
    let deadline = Instant::now() + Duration::from_secs(60);
    while Mux::git_head_refreshes_running() != 0 {
        assert!(Instant::now() < deadline, "a git HEAD refresh did not end");
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// A warm-up, then `REQUESTS` requests; `before` runs before each request, outside its time.
fn scenario(name: &str, mut before: impl FnMut(), mut request: impl FnMut() -> Sample) {
    for _ in 0..WARM_UP {
        settle_git_head_refresh();
        before();
        request();
    }
    let mut samples = Vec::with_capacity(REQUESTS);
    let mut reads = 0;
    for _ in 0..REQUESTS {
        settle_git_head_refresh();
        before();
        let read = Mux::git_head_reads_on_this_thread();
        samples.push(request());
        reads += Mux::git_head_reads_on_this_thread() - read;
    }
    report(name, &samples);
    eprintln!(
        "LIST-SHARES [{name}]   GIT HEAD READS on the thread of the request: {reads} in {} \
         requests",
        samples.len()
    );
}

/// The name of this host, its CPU count and its CPU model.
fn runner() -> String {
    let host = std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .or_else(|| {
            let output = std::process::Command::new("hostname").output().ok()?;
            Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let cpus = std::thread::available_parallelism().map(|count| count.get()).unwrap_or(0);
    let model = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|text| {
            let line = text.lines().find(|line| line.starts_with("model name"))?;
            Some(line.split(':').nth(1)?.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    format!(
        "host {host}, {cpus} CPUs, CPU model {model}, {} {}",
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

#[test]
fn list_request_shares_at_826_workspaces() {
    let root = std::env::temp_dir().join(format!(
        "cmux-list-request-shares-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let made = Instant::now();
    let (mux, surfaces) = session(&root);

    // One repository, one directory for each terminal: a read of the tree with no cached HEAD
    // reads one HEAD for each terminal (the most that 826 terminals can ask for).
    let repository = root.join("measure-repository");
    std::fs::create_dir_all(repository.join(".git")).unwrap();
    std::fs::write(repository.join(".git").join("HEAD"), "ref: refs/heads/main\n").unwrap();
    let mut with_directory = 0;
    for (index, surface) in surfaces.iter().enumerate() {
        let directory = repository.join(format!("project-{index}")).join("src");
        std::fs::create_dir_all(&directory).unwrap();
        if let Some(runtime) = mux.surface(*surface) {
            runtime.commit_published_directory(Some(directory.to_string_lossy().into_owned()));
            with_directory += 1;
        }
    }

    // ONE conversation tab, in the pane of the first terminal. Not fatal: without it the tab
    // projection has nothing to rewrite, and the lines below say so.
    let conversation_tab = match mux.with_state(|state| state.pane_of(surfaces[0])) {
        Some(pane) => run_json_command(
            &mux,
            json!({"cmd": "new-conversation-tab", "pane": pane,
                   "agent_session": {"host": "install:mac-test"}}),
        )
        .map(|_| "made".to_string())
        .unwrap_or_else(|error| format!("NOT MADE: {error:#}")),
        None => "NOT MADE: the first terminal has no pane".to_string(),
    };
    let session_ms = ms(made.elapsed());

    let render = Arc::new(RenderService::new());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let plain = Connection::open(&mux, &render);
    let app = Connection::open(&mux, &render);
    let info = json!({"id": "info", "cmd": "set-client-info", "name": "measure",
        "capabilities": [CONVERSATION_TABS_CAPABILITY, AGENT_SESSION_TABS_CAPABILITY,
                         PAGE_TABS_CAPABILITY, CLOSED_CONVERSATION_TABS_CAPABILITY]})
    .to_string();
    let info: Request = serde_json::from_str(&info).unwrap();
    assert!(handle_request(&mux, app.client, info, &app.writer));
    let info_reply = app.reply();
    assert!(info_reply.contains("\"ok\":true"), "{info_reply}");

    let list = json!({"id": 1, "cmd": "list-workspaces"}).to_string();
    let snapshot = resource_request(
        "snapshot",
        "session.snapshot",
        json!({"machine": "current", "session": "current"}),
        None,
    );

    eprintln!("LIST-SHARES runner: {}", runner());
    eprintln!(
        "LIST-SHARES session: {} workspaces, {} surfaces in the state, {with_directory} terminals \
         with a directory, conversation tab {conversation_tab}; made in {session_ms:.0} ms; a \
         test build (debug assertions {})",
        mux.with_state(|state| state.workspaces.len()),
        mux.with_state(|state| state.surfaces.len()),
        cfg!(debug_assertions),
    );
    for (who, connection) in [("no client info", &plain), ("4 tab capabilities", &app)] {
        let tree = measured(&mux, connection, &scheduler, &list).reply;
        let rows = measured(&mux, connection, &scheduler, &snapshot).reply;
        eprintln!(
            "LIST-SHARES check [{who}]: list-workspaces reply {} bytes, {} tabs of kind \
             conversation, {} tabs with git_branch main; session.snapshot reply {} bytes, {} \
             times the text \"conversation\"",
            tree.len(),
            tree.matches("\"kind\":\"conversation\"").count(),
            tree.matches("\"git_branch\":\"main\"").count(),
            rows.len(),
            rows.matches("\"conversation").count(),
        );
    }

    for (who, connection) in [("no client info", &plain), ("4 tab capabilities", &app)] {
        scenario(
            &format!("list-workspaces, {who}, git HEADs cached"),
            || {},
            || measured(&mux, connection, &scheduler, &list),
        );
        let mut not_aged = 0;
        scenario(
            &format!("list-workspaces, {who}, each cached git HEAD older than 2 s"),
            || not_aged += usize::from(!mux.age_git_heads_for_test()),
            || measured(&mux, connection, &scheduler, &list),
        );
        eprintln!(
            "LIST-SHARES [list-workspaces, {who}, each cached git HEAD older than 2 s]   requests \
             whose cached values could not be made older: {not_aged}"
        );
        scenario(
            &format!("list-workspaces, {who}, no git HEAD cached"),
            || mux.forget_git_heads_for_measure(),
            || measured(&mux, connection, &scheduler, &list),
        );
    }
    settle_git_head_refresh();

    // One copy of the whole state with the state lock held, and its drop with no lock: the
    // cost of a reply that builds its nodes from a copy.
    let mut copies = Vec::with_capacity(REQUESTS);
    let mut drops = Vec::with_capacity(REQUESTS);
    for round in 0..WARM_UP + REQUESTS {
        let start = Instant::now();
        let copy = mux.with_state(|state| state.clone());
        let copied = start.elapsed();
        let start = Instant::now();
        drop(copy);
        let dropped = start.elapsed();
        if round >= WARM_UP {
            copies.push(copied);
            drops.push(dropped);
        }
    }
    eprintln!(
        "LIST-SHARES [one copy of the state] {} copies after {WARM_UP} of warm-up: the copy \
         (state lock held) median {:.3} ms, longest {:.3} ms; its drop (no lock) median {:.3} \
         ms, longest {:.3} ms",
        copies.len(),
        ms(median(copies.clone())),
        ms(longest(&copies)),
        ms(median(drops.clone())),
        ms(longest(&drops)),
    );
    for (who, connection) in [("no client info", &plain), ("4 tab capabilities", &app)] {
        scenario(
            &format!("session.snapshot, {who}, cached rows"),
            || {},
            || measured(&mux, connection, &scheduler, &snapshot),
        );
    }
    // Last, because each request follows one new empty workspace: the session grows by one for
    // each request of these two scenarios.
    for (who, connection) in [("4 tab capabilities", &app), ("no client info", &plain)] {
        scenario(
            &format!("session.snapshot, {who}, first reader after a commit"),
            || {
                crate::mux::without_crosscheck(|| {
                    mux.create_empty_workspace(None, None, None).unwrap();
                });
            },
            || measured(&mux, connection, &scheduler, &snapshot),
        );
    }
    eprintln!(
        "LIST-SHARES end: {} workspaces at the end",
        mux.with_state(|state| state.workspaces.len())
    );

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
