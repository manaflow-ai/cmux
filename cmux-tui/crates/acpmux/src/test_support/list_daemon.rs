//! A daemon in this process that serves the v2 list (or does not), on a unix socket as the
//! daemon serves it: v1 and the v2 list on one socket, the list tee filling the index. Row 7b's
//! callers' tests and row 7c's (`cmux-tui-core`, through the `test-support` feature) read it by
//! its socket only, so no type of a caller's crate crosses here. Also the gates' byte-counting
//! proxy and their p95 line (`V2_GATE_OUT`).

use crate::hub::Hub;
use acpmux_book::gate_rounds::{self, all_p95, best_p95};
use acpmux_book::index::SummaryIndex;
use acpmux_core::life::V2;
use serde_json::{Value, json};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// An error of this module's own: what a step that cannot go on found.
fn failed(what: impl std::fmt::Display) -> io::Error {
    io::Error::other(what.to_string())
}

/// What the v2 side of a daemon serves.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Serves {
    /// No v2 handle: the upgrade is not a method.
    NoV2,
    /// v2 with no surface: the upgrade names `list`, and is refused.
    ListOff,
    /// v2 with `list`.
    List,
}

/// A daemon in this process on a unix socket. It serves until `tasks` is dropped: its server, tee
/// and v2 writer are that scope's, and stop there.
pub struct ListDaemon {
    pub hub: Arc<Hub>,
    pub v2: Option<Arc<V2>>,
    pub path: PathBuf,
    pub dir: tempfile::TempDir,
    pub tasks: cmux_scope::Scope,
}

fn memory_hub() -> io::Result<Arc<Hub>> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).map_err(failed)?;
    Ok(Hub::new(config, store))
}

/// A session's record: `status`, updated at `at`, with `tags` (`{key: value}`). An error: a
/// `status` the record does not know.
pub fn meta(
    id: &str,
    name: &str,
    status: &str,
    at: u64,
    tags: Value,
) -> io::Result<crate::store::SessionMeta> {
    let tags: serde_json::Map<String, Value> = tags
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, value)| (key.clone(), json!({"value": value})))
        .collect();
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "title": format!("{name}'s title"),
        "harness": "claude", "cwd": "/work", "status": status, "createdAt": at - 1_000,
        "updatedAt": at, "turnCount": 3, "nameGiven": true, "tags": tags,
    }))
    .map_err(failed)
}

/// Puts a session of `meta` in `hub`, as a store load does.
pub fn insert(hub: &Hub, meta: crate::store::SessionMeta) {
    hub.insert_test_session(meta);
}

/// A peer `name` that listed `rows` (v1 rows, each with `sessionId`) and is down now: its
/// rows are in the v1 list and not in the v2 index's local origin.
pub fn seed_down_peer(hub: &Hub, name: &str, rows: Vec<Value>) {
    hub.seed_down_peer(name, rows);
}

/// Gives the v2 index's row of `chat_id` an `extra` too large for a summary, as another
/// writer could, and waits until the index holds it with `extra` `{}` (`Summary::bounded`): a
/// reader that needs a field of `extra` reads that chat by key. The tee itself cuts a local
/// summary's texts to fit, so only a direct write reaches this.
pub async fn bound_away(v2: &V2, chat_id: &str) -> io::Result<()> {
    let held = v2.hub.snapshot().get(chat_id);
    let mut summary =
        (*held.ok_or_else(|| failed(format!("{chat_id} is not in the index")))?).clone();
    let mut extra: serde_json::Map<String, Value> =
        serde_json::from_str(summary.extra.get()).map_err(failed)?;
    extra.insert("pad".into(), Value::String("x".repeat(acpmux_book::index::MAX_SUMMARY_BYTES)));
    summary.extra = serde_json::value::to_raw_value(&extra).map_err(failed)?;
    v2.hub.submit(summary).map_err(|error| failed(format!("{error:?}")))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while v2.hub.snapshot().get(chat_id).is_none_or(|row| row.extra.get() != "{}") {
        if Instant::now() >= deadline {
            return Err(failed(format!("the index kept {chat_id}'s extra")));
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Ok(())
}

/// Serves a new hub on a new socket, `seed` giving it its rows (and their count). With the v2
/// list, the tee is started first and fills its index from the hub, and this waits until it
/// holds that many rows (an error past a minute). Call it on a tokio runtime that outlives the
/// daemon's use.
pub async fn serve(serves: Serves, seed: impl FnOnce(&Hub) -> usize) -> io::Result<ListDaemon> {
    let hub = memory_hub()?;
    let tasks = cmux_scope::Scope::new("list-daemon");
    let v2 = match serves {
        Serves::NoV2 => None,
        Serves::ListOff | Serves::List => {
            let (index, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
            let surfaces = if serves == Serves::List {
                ["list".to_owned()].into_iter().collect()
            } else {
                Default::default()
            };
            let v2 = Arc::new(V2::with_surfaces(index, writer, surfaces));
            let (tee, task) = crate::hub::list_tee::start_v2_tee(hub.clone(), v2.clone());
            hub.install_v2_tee(tee);
            v2.hub.set_page_provider(Arc::new(crate::hub::list_tee::V1PageProvider::new(
                hub.clone(),
            )));
            tasks.spawn_until_cancelled("list-daemon tee", task);
            let writer = v2.take_writer().ok_or_else(|| failed("the v2 writer was taken"))?;
            tasks.spawn_until_cancelled("list-daemon v2 writer", writer.run());
            Some(v2)
        }
    };
    let rows = seed(&hub);
    if let Some(v2) = &v2 {
        let deadline = Instant::now() + Duration::from_secs(60);
        while v2.hub.snapshot().len() < rows {
            if Instant::now() >= deadline {
                let held: Vec<String> =
                    v2.hub.snapshot().iter().map(|row| row.key().chat_id.to_string()).collect();
                return Err(failed(format!(
                    "the tee holds {} of {rows} rows: {held:?}",
                    held.len()
                )));
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("acpmux.sock");
    let listener = crate::server::bind_unix(&path).await.map_err(failed)?;
    let server = crate::server::serve_unix_with_v2(hub.clone(), listener, v2.clone());
    tasks.spawn_until_cancelled("list-daemon server", server);
    Ok(ListDaemon { hub, v2, path, dir, tasks })
}

/// The gates' fixture: 20 live chats, and `closed` closed ones beside them (all older). The
/// rows the v2 index holds.
pub fn twenty_live_beside(hub: &Hub, closed: usize) -> io::Result<usize> {
    let now = crate::store::now_ms();
    for n in 0..20_u64 {
        let tags = json!({"area": "acpmux"});
        insert(
            hub,
            meta(&format!("live-{n:02}"), &format!("live-{n}"), "idle", now - n * 1_000, tags)?,
        );
    }
    for n in 0..closed as u64 {
        insert(
            hub,
            meta(
                &format!("closed-{n:05}"),
                &format!("closed-{n}"),
                "closed",
                now - 60_000 - n,
                json!({}),
            )?,
        );
    }
    Ok(20 + closed)
}

/// The live and closed-today chats of [`usage_beside`]: each a Claude chat with its own
/// transcript, so a usage pass reads every one of them.
pub const USAGE_LIVE: usize = 8;
pub const USAGE_CLOSED_TODAY: usize = 8;

/// The usage pass's fixture (`hub/usage_view.rs`): [`USAGE_LIVE`] live Claude chats and
/// [`USAGE_CLOSED_TODAY`] closed an hour ago, each with an agent session id and a transcript in
/// `store` (their `CLAUDE_CONFIG_DIR`), and `closed` closed two days ago or more beside them,
/// Claude chats with ids too, which the pass reads none of. The rows the v2 index holds.
pub fn usage_beside(hub: &Hub, closed: usize, store: &Path) -> io::Result<usize> {
    let now = crate::store::now_ms();
    let day = crate::usage_stats::DAY_MS;
    let projects = store.join("projects").join("-work");
    std::fs::create_dir_all(&projects)?;
    let claude = |id: &str, status: &str, at: u64, tags: Value| -> io::Result<_> {
        let mut meta = meta(id, id, status, at, tags)?;
        let sid = format!("sid-{id}");
        meta.family = Some("claude".to_owned());
        meta.agent_session_id = Some(sid.clone());
        meta.chat_store = Some(store.to_path_buf());
        Ok((meta, sid))
    };
    let add = |id: String, status: &str, at: u64, transcript: bool| -> io::Result<()> {
        let tags = if status == "closed" { json!({}) } else { json!({"area": "acpmux"}) };
        let (meta, sid) = claude(&id, status, at, tags)?;
        if transcript {
            std::fs::write(projects.join(format!("{sid}.jsonl")), "")?;
        }
        insert(hub, meta);
        Ok(())
    };
    for n in 0..USAGE_LIVE as u64 {
        add(format!("live-{n:02}"), "idle", now - n * 1_000, true)?;
    }
    for n in 0..USAGE_CLOSED_TODAY as u64 {
        add(format!("today-{n:02}"), "closed", now - 3_600_000 - n * 1_000, true)?;
    }
    for n in 0..closed as u64 {
        add(format!("closed-{n:06}"), "closed", now - 2 * day - n, false)?;
    }
    Ok(USAGE_LIVE + USAGE_CLOSED_TODAY + closed)
}

/// A proxy to a daemon's socket that counts the bytes the daemon sends, and the connections it
/// relays. It relays until dropped.
pub struct Counted {
    pub path: PathBuf,
    pub bytes: Arc<AtomicU64>,
    open: Arc<Open>,
    _dir: tempfile::TempDir,
    _tasks: cmux_scope::Scope,
}

/// The connections a [`Counted`] relays now, and a wake as each one ends.
#[derive(Default)]
struct Open {
    count: AtomicUsize,
    ended: tokio::sync::Notify,
}

/// One relay's place in [`Open`], given back when the relay ends.
struct Relaying(Arc<Open>);

impl Relaying {
    fn new(open: &Arc<Open>) -> Self {
        open.count.fetch_add(1, Ordering::AcqRel);
        Self(open.clone())
    }
}

impl Drop for Relaying {
    fn drop(&mut self) {
        self.0.count.fetch_sub(1, Ordering::AcqRel);
        self.0.ended.notify_waiters();
    }
}

/// How long [`Counted::settled`] waits for the daemon to close the connections clients left.
const SETTLE: Duration = Duration::from_secs(10);

impl Counted {
    /// The bytes the daemon has sent through the proxy.
    pub fn sent(&self) -> u64 {
        self.bytes.load(Ordering::Relaxed)
    }

    /// Waits until the proxy relays no connection: each client that left had its daemon side
    /// shut, and the daemon closed it, having sent all it owed. An error past [`SETTLE`]: the
    /// daemon keeps a connection its client left.
    pub async fn settled(&self) -> io::Result<()> {
        let deadline = tokio::time::Instant::now() + SETTLE;
        loop {
            let ended = self.open.ended.notified();
            tokio::pin!(ended);
            ended.as_mut().enable();
            if self.open.count.load(Ordering::Acquire) == 0 {
                return Ok(());
            }
            if tokio::time::timeout_at(deadline, ended).await.is_err() {
                let open = self.open.count.load(Ordering::Acquire);
                return Err(failed(format!(
                    "the daemon kept {open} connections open {SETTLE:?} after their clients left"
                )));
            }
        }
    }
}

/// The descriptors this process holds (`None` off Linux).
pub fn open_fds() -> Option<usize> {
    std::fs::read_dir("/proc/self/fd").ok().map(Iterator::count)
}

/// The descriptors a gate may hold past its first round's start, after any round: room for
/// the runtime's own and descriptors still closing after [`Counted::settled`] returns (the
/// client's reader task, the in-process daemon's halves), never for a sample's connections
/// (7 each). Keep that slack: at 0 the assert fails on closes still in flight.
pub const FDS_PAST_A_ROUND: usize = 6;

/// Fails `name` if this process holds more than [`FDS_PAST_A_ROUND`] descriptors beyond
/// `before` ([`open_fds`] before the gate's first round): a fixture that keeps a sample's
/// connections grows by each sample.
pub fn assert_fds_given_back(name: &str, before: Option<usize>) {
    if let (Some(before), Some(now)) = (before, open_fds()) {
        assert!(
            now <= before + FDS_PAST_A_ROUND,
            "{name}: {now} descriptors open after a round, {before} before the first"
        );
    }
}

/// [`Counted`] in front of the socket at `target`.
pub async fn counted(target: PathBuf) -> io::Result<Counted> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("counted.sock");
    let listener = tokio::net::UnixListener::bind(&path)?;
    let bytes = Arc::new(AtomicU64::new(0));
    let total = bytes.clone();
    let open = Arc::new(Open::default());
    let relaying = open.clone();
    let tasks = cmux_scope::Scope::new("list-daemon counted proxy");
    // One task: the accepts and every connection's relay, polled together.
    tasks.spawn_until_cancelled("list-daemon counted proxy", async move {
        use futures::StreamExt as _;
        let mut relays = futures::stream::FuturesUnordered::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let Ok((client, _)) = accepted else { return };
                    let Ok(server) = tokio::net::UnixStream::connect(&target).await else { return };
                    let place = Relaying::new(&relaying);
                    relays.push(relay(client, server, total.clone(), place));
                }
                Some(()) = relays.next(), if !relays.is_empty() => {}
            }
        }
    });
    Ok(Counted { path, bytes, open, _dir: dir, _tasks: tasks })
}

/// One connection through [`Counted`]: the client's bytes up, the daemon's down and counted,
/// until the daemon's side ends. Both sockets, and `_place`, go with it.
async fn relay(
    client: tokio::net::UnixStream,
    server: tokio::net::UnixStream,
    total: Arc<AtomicU64>,
    _place: Relaying,
) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (mut client_read, mut client_write) = client.into_split();
    let (mut server_read, mut server_write) = server.into_split();
    let up = async move {
        let _ = tokio::io::copy(&mut client_read, &mut server_write).await;
        // The client's side ended: the daemon reads its end too, and its answers still come
        // down until it closes.
        let _ = server_write.shutdown().await;
        std::future::pending::<()>().await;
    };
    let down = async move {
        let mut buf = vec![0_u8; 64 * 1024];
        while let Ok(n) = server_read.read(&mut buf).await {
            if n == 0 || client_write.write_all(&buf[..n]).await.is_err() {
                break;
            }
            total.fetch_add(n as u64, Ordering::Relaxed);
        }
    };
    tokio::select! {
        () = up => {}
        () = down => {}
    }
}

/// The gate line of `name`: each side's best round p95, printed and appended to `V2_GATE_OUT`,
/// after its rounds ([`gate_rounds::report`]).
pub fn emit(name: &str, small: &[Vec<u128>], god: &[Vec<u128>], unit: &str) -> (u128, u128) {
    gate_rounds::report(name, &[("small", small), ("god", god)]);
    let (small_p95, god_p95) = (best_p95(small), best_p95(god));
    write_line(json!({"name": name, "small_p95": small_p95, "god_p95": god_p95, "unit": unit}));
    (small_p95, god_p95)
}

/// [`emit`] and, beside the best rounds, the god side's p95 over every sample of every round
/// (`god_p95_all`, a row's `ratio_all`): a slow round the best one hides still shows. The
/// best p95s and that one.
pub fn emit_with_all(
    name: &str,
    small: &[Vec<u128>],
    god: &[Vec<u128>],
    unit: &str,
) -> (u128, u128, u128) {
    gate_rounds::report(name, &[("small", small), ("god", god)]);
    let (small_p95, god_p95, god_p95_all) = (best_p95(small), best_p95(god), all_p95(god));
    write_line(json!({"name": name, "small_p95": small_p95, "god_p95": god_p95,
        "god_p95_all": god_p95_all, "unit": unit}));
    (small_p95, god_p95, god_p95_all)
}

/// One gate line, printed and appended to `V2_GATE_OUT`.
fn write_line(line: Value) {
    let line = line.to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}
