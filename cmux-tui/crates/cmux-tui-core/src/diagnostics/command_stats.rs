//! `server-stats` section `commands`: which requests the daemon handled, by command name and
//! by client kind, since it started. One read says which calls the session's clients make
//! and which of them take the daemon's time; two reads some seconds apart give a rate and,
//! from the histograms, a p50 and a p95.
//!
//! Privacy: a row's name is a word of the daemon's own source (`Command::wire_name`,
//! `ResourceOperation::wire_name`, [`OTHER`]) and a kind is a word of [`ClientKind`]. No byte
//! of a request line, a parameter, a path, a title or a client label is kept here.
//!
//! Cost: the count is on the path of every request. A request takes three clock reads, one
//! probe of a fixed table, four relaxed atomic updates on the cell of its (name, kind) and
//! three reads of a thread-local number. No lock is taken, nothing is allocated and no
//! syscall is made after the first request of a name; that first request allocates the
//! name's cells once.

use std::cell::Cell as ThreadCell;
use std::sync::atomic::{AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Instant;

use serde::Serialize;

thread_local! {
    /// The requests this thread counted under a name of their own (or said that another
    /// thread counts them). A line that changed it is not also counted as [`OTHER`].
    static NAMED: ThreadCell<u64> = const { ThreadCell::new(0) };
}

/// The line this thread handles is counted under its own name, here or on the thread that
/// runs it later: it is not also counted as [`OTHER`].
#[inline]
pub(crate) fn line_is_named() {
    NAMED.with(|named| named.set(named.get().wrapping_add(1)));
}

/// The name of every line that is not a decoded command or a v2 method: a word the daemon
/// does not know, a line that does not decode, a frame of an app-private family.
pub(crate) const OTHER: &str = "other";

/// Slots of the name table; a power of 2.
const NAME_SLOTS: usize = 1024;
/// The most names with a row of their own; the requests of each further name count in
/// [`OTHER`]. The daemon has about 700 command words, so the table always has free slots.
const NAME_LIMIT: usize = 768;
/// Histogram buckets: below 0.25 ms, then one per power of 2 up to 4.096 s, then above.
const BUCKETS: usize = 16;
/// The upper bound of the first bucket.
const FIRST_BOUND_NS: u64 = 250_000;

/// What the daemon knows about the process at the other end of a connection. The first
/// group is what the client declared (`set-client-info` `kind`), the second what the daemon
/// saw by itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum ClientKind {
    /// Nothing is known: no declaration and no peer evidence.
    Unknown = 0,
    /// A process of the same user outside the session's terminals that declared nothing.
    Local,
    /// A process inside one of the session's terminals that declared nothing: an agent's
    /// `cmux` call, its MCP server, a script in a pane.
    Terminal,
    /// A connection that reports agent hook events (`session.journal.append` of the agent
    /// hook producer): a hook child.
    Hook,
    /// The session owner's own journal plugin (the screen detector).
    Plugin,
    /// Declared `frontend` or `app`: the app and its helpers.
    App,
    /// Declared `tui`.
    Tui,
    /// Declared `cli`.
    Cli,
    /// Declared `mcp`.
    Mcp,
    /// Declared `remote-probe`.
    RemoteProbe,
    /// Declared `remote-link`.
    RemoteLink,
    /// A `cmux link` peer stream through the remote entry.
    Remote,
    /// A WebSocket connection.
    WebSocket,
    /// Declared a kind that is not in this list.
    Other,
}

const KINDS: usize = 14;

impl ClientKind {
    const ALL: [Self; KINDS] = [
        Self::Unknown,
        Self::Local,
        Self::Terminal,
        Self::Hook,
        Self::Plugin,
        Self::App,
        Self::Tui,
        Self::Cli,
        Self::Mcp,
        Self::RemoteProbe,
        Self::RemoteLink,
        Self::Remote,
        Self::WebSocket,
        Self::Other,
    ];

    pub(crate) const fn word(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Local => "local",
            Self::Terminal => "terminal",
            Self::Hook => "hook",
            Self::Plugin => "plugin",
            Self::App => "app",
            Self::Tui => "tui",
            Self::Cli => "cli",
            Self::Mcp => "mcp",
            Self::RemoteProbe => "remote-probe",
            Self::RemoteLink => "remote-link",
            Self::Remote => "remote",
            Self::WebSocket => "websocket",
            Self::Other => "other",
        }
    }

    /// The kind a client declared with `set-client-info` `kind`. A word outside the list is
    /// [`ClientKind::Other`]: the word itself is never kept.
    pub(crate) fn declared(word: &str) -> Self {
        match word {
            "frontend" | "app" => Self::App,
            "tui" => Self::Tui,
            "cli" => Self::Cli,
            "mcp" => Self::Mcp,
            "hook" => Self::Hook,
            "plugin" => Self::Plugin,
            "remote-probe" => Self::RemoteProbe,
            "remote-link" => Self::RemoteLink,
            _ => Self::Other,
        }
    }

    fn from_index(index: u8) -> Self {
        Self::ALL.get(usize::from(index)).copied().unwrap_or(Self::Unknown)
    }

    /// Whether the client said what it is: what the daemon sees later never replaces it.
    fn is_declared(self) -> bool {
        !matches!(
            self,
            Self::Unknown | Self::Local | Self::Terminal | Self::Remote | Self::WebSocket
        )
    }
}

/// One connection's kind. It lives on the connection's writer, so a request reads it with
/// one atomic load and never asks the client registry.
#[derive(Default)]
pub(crate) struct ConnectionKind {
    kind: AtomicU8,
    /// The session's counters, from the moment the connection registered; the connection is
    /// counted there as accepted under its kind.
    counted: OnceLock<Arc<CommandStats>>,
}

impl ConnectionKind {
    pub(crate) fn get(&self) -> ClientKind {
        ClientKind::from_index(self.kind.load(Ordering::Relaxed))
    }

    /// The connection registered with the session: counts it as accepted under `kind`.
    // perf-hot: <1us command-stats
    #[inline]
    pub(crate) fn registered(&self, stats: &Arc<CommandStats>, kind: ClientKind) {
        // Every line of a connection asks: after the first, one load and nothing shared is
        // written.
        if self.counted.get().is_some() {
            return;
        }
        if self.counted.set(stats.clone()).is_ok() {
            self.kind.store(kind as u8, Ordering::Relaxed);
            add_one(&stats.accepted, kind);
        }
    }

    /// What the daemon saw about the peer after it registered (it runs in a terminal, it
    /// sends hook events). A kind the client declared stays.
    pub(crate) fn observed(&self, kind: ClientKind) {
        if !self.get().is_declared() {
            self.replace(kind);
        }
    }

    /// The client declared its kind (`set-client-info` `kind`).
    pub(crate) fn declare(&self, kind: ClientKind) {
        self.replace(kind);
    }

    /// Moves the connection, and its place in the accepted counts, to `kind`.
    fn replace(&self, kind: ClientKind) {
        let previous = self.kind.swap(kind as u8, Ordering::Relaxed);
        if previous == kind as u8 {
            return;
        }
        if let Some(stats) = self.counted.get() {
            add_one(&stats.accepted, kind);
            if let Some(from) = stats.accepted.get(usize::from(previous)) {
                // Never below 0: a count a concurrent change already moved stays where it is.
                let _ = from.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |count| {
                    count.checked_sub(1)
                });
            }
        }
    }
}

/// Adds 1 to the count of `kind`. A kind is always inside the array (`KINDS`).
#[inline]
fn add_one(counts: &[AtomicU64; KINDS], kind: ClientKind) {
    if let Some(count) = counts.get(kind as usize) {
        count.fetch_add(1, Ordering::Relaxed);
    }
}

/// The requests of one name from one client kind.
#[derive(Default)]
struct Cell {
    count: AtomicU64,
    total_ns: AtomicU64,
    max_ns: AtomicU64,
    buckets: [AtomicU64; BUCKETS],
}

impl Cell {
    // perf-hot: <1us command-stats
    #[inline]
    fn record(&self, nanos: u64) {
        self.count.fetch_add(1, Ordering::Relaxed);
        self.total_ns.fetch_add(nanos, Ordering::Relaxed);
        self.max_ns.fetch_max(nanos, Ordering::Relaxed);
        if let Some(bucket) = self.buckets.get(bucket(nanos)) {
            bucket.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// The histogram bucket of a duration: 0 below 0.25 ms, then one per power of 2.
#[inline]
fn bucket(nanos: u64) -> usize {
    match (nanos / FIRST_BOUND_NS).checked_ilog2() {
        None => 0,
        Some(power) => (power as usize).saturating_add(1).min(BUCKETS - 1),
    }
}

/// One name's cells, one per client kind.
struct Entry {
    name: &'static str,
    cells: [Cell; KINDS],
}

impl Entry {
    fn new(name: &'static str) -> Self {
        Self { name, cells: std::array::from_fn(|_| Cell::default()) }
    }

    /// Counts one request of `kind` that took `nanos`. A kind is always inside the array.
    #[inline]
    fn record(&self, kind: ClientKind, nanos: u64) {
        if let Some(cell) = self.cells.get(kind as usize) {
            cell.record(nanos);
        }
    }
}

/// The session's request counters.
pub(crate) struct CommandStats {
    /// Open addressing by the address of the name: the names are words of the daemon's own
    /// source, so one name is one address (two addresses of one word are added up on read).
    slots: Box<[OnceLock<Box<Entry>>]>,
    names: AtomicUsize,
    other: Entry,
    accepted: [AtomicU64; KINDS],
    refused: [AtomicU64; KINDS],
}

impl Default for CommandStats {
    fn default() -> Self {
        Self {
            slots: (0..NAME_SLOTS).map(|_| OnceLock::new()).collect(),
            names: AtomicUsize::new(0),
            other: Entry::new(OTHER),
            accepted: std::array::from_fn(|_| AtomicU64::new(0)),
            refused: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }
}

impl CommandStats {
    /// Starts the count of one request: it ends, with its time, when the value drops, under
    /// the kind the connection has at that moment (so the request that declares a kind counts
    /// under it). `name` is a word of the daemon's source, never a word of the request.
    // perf-hot: <1us command-stats
    #[inline]
    pub(crate) fn start<'a>(&'a self, name: &'static str, kind: &'a ConnectionKind) -> Counted<'a> {
        Counted { entry: self.entry(name), kind, started: Instant::now() }
    }

    /// Starts the count of one line of a connection. When the value drops, the line counts
    /// as [`OTHER`], unless a request of the line was counted under its own name meanwhile.
    // perf-hot: <1us command-stats
    #[inline]
    pub(crate) fn start_line<'a>(&'a self, kind: &'a ConnectionKind) -> CountedLine<'a> {
        CountedLine {
            other: &self.other,
            kind,
            named: NAMED.with(ThreadCell::get),
            started: Instant::now(),
        }
    }

    /// A connection that was refused before it registered (the connection limit).
    pub(crate) fn connection_refused(&self, kind: ClientKind) {
        add_one(&self.refused, kind);
    }

    // perf-hot: <1us command-stats
    #[inline]
    fn entry(&self, name: &'static str) -> &Entry {
        let address = name.as_ptr() as usize as u64;
        // The top 10 bits of a multiplicative hash: an index below NAME_SLOTS.
        let mut index = ((address >> 3).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 54) as usize;
        for _ in 0..NAME_SLOTS {
            let Some(slot) = self.slots.get(index & (NAME_SLOTS - 1)) else {
                return &self.other;
            };
            let entry = match slot.get() {
                Some(entry) => entry,
                None => {
                    // The first request of this name: its cells are made once. At the limit
                    // a further name writes nothing that the connections share.
                    if self.names.load(Ordering::Relaxed) >= NAME_LIMIT {
                        return &self.other;
                    }
                    if self.names.fetch_add(1, Ordering::Relaxed) >= NAME_LIMIT {
                        self.names.fetch_sub(1, Ordering::Relaxed);
                        return &self.other;
                    }
                    let mut made = false;
                    let entry = slot.get_or_init(|| {
                        made = true;
                        Box::new(Entry::new(name))
                    });
                    if !made {
                        // Another thread took the slot first.
                        self.names.fetch_sub(1, Ordering::Relaxed);
                    }
                    entry
                }
            };
            if std::ptr::eq(entry.name.as_ptr(), name.as_ptr()) && entry.name.len() == name.len() {
                return entry;
            }
            index = index.wrapping_add(1);
        }
        &self.other
    }

    pub(crate) fn snapshot(&self) -> CommandStatsSnapshot {
        let mut rows: Vec<CommandRow> = Vec::new();
        let entries = self.slots.iter().filter_map(|slot| slot.get().map(|entry| &**entry));
        for entry in entries.chain(std::iter::once(&self.other)) {
            for (kind, cell) in ClientKind::ALL.iter().zip(&entry.cells) {
                let count = cell.count.load(Ordering::Relaxed);
                if count == 0 {
                    continue;
                }
                let read = CommandRow {
                    name: entry.name,
                    kind: kind.word(),
                    count,
                    total_ns: cell.total_ns.load(Ordering::Relaxed),
                    max_ns: cell.max_ns.load(Ordering::Relaxed),
                    hist: cell
                        .buckets
                        .iter()
                        .map(|bucket| bucket.load(Ordering::Relaxed))
                        .collect(),
                };
                match rows.iter_mut().find(|row| row.name == read.name && row.kind == read.kind) {
                    Some(row) => row.add(&read),
                    None => rows.push(read),
                }
            }
        }
        rows.sort_by(|a, b| b.total_ns.cmp(&a.total_ns).then(a.name.cmp(b.name)));
        let connections = ClientKind::ALL
            .iter()
            .zip(self.accepted.iter().zip(&self.refused))
            .map(|(kind, (accepted, refused))| CommandConnections {
                kind: kind.word(),
                accepted: accepted.load(Ordering::Relaxed),
                refused: refused.load(Ordering::Relaxed),
            })
            .filter(|entry| entry.accepted > 0 || entry.refused > 0)
            .collect();
        CommandStatsSnapshot {
            names: self.names.load(Ordering::Relaxed) as u64,
            name_limit: NAME_LIMIT as u64,
            hist_bounds_ns: (0..BUCKETS as u32 - 1).map(|power| FIRST_BOUND_NS << power).collect(),
            rows,
            connections,
        }
    }
}

/// One request that is being counted; see [`CommandStats::start`].
pub(crate) struct Counted<'a> {
    entry: &'a Entry,
    kind: &'a ConnectionKind,
    started: Instant,
}

impl Drop for Counted<'_> {
    #[inline]
    fn drop(&mut self) {
        self.entry.record(self.kind.get(), elapsed_ns(self.started));
        line_is_named();
    }
}

/// One line that is being counted; see [`CommandStats::start_line`].
pub(crate) struct CountedLine<'a> {
    other: &'a Entry,
    kind: &'a ConnectionKind,
    named: u64,
    started: Instant,
}

impl Drop for CountedLine<'_> {
    #[inline]
    fn drop(&mut self) {
        if NAMED.with(ThreadCell::get) == self.named {
            self.other.record(self.kind.get(), elapsed_ns(self.started));
            // A line inside a line (a proxy's forwarded frame): the outer one is counted now.
            line_is_named();
        }
    }
}

/// The time since `started`. A request always takes time: a clock that did not move still
/// gives 1 ns.
#[inline]
fn elapsed_ns(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_nanos()).unwrap_or(u64::MAX).max(1)
}

/// `server-stats` section `commands`.
#[derive(Clone, Debug, Serialize)]
pub struct CommandStatsSnapshot {
    /// The names that have a row of their own.
    pub names: u64,
    /// The most names with a row of their own; the rest counts in `other`.
    pub name_limit: u64,
    /// The upper bounds of the first 15 buckets of each `hist`, in nanoseconds; the last
    /// bucket has no upper bound.
    pub hist_bounds_ns: Vec<u64>,
    /// One row for each (name, kind) with a request, the largest total time first.
    pub rows: Vec<CommandRow>,
    /// The connections by client kind, for each kind with one.
    pub connections: Vec<CommandConnections>,
}

/// The requests of one command name from one client kind since the daemon started.
#[derive(Clone, Debug, Serialize)]
pub struct CommandRow {
    /// A legacy command (`ping`), a v2 method (`session.ping`) or `other`.
    pub name: &'static str,
    /// The client kind, a word of the daemon's own list.
    pub kind: &'static str,
    pub count: u64,
    /// The handlers' time, from the decoded line to the reply queued for the connection's
    /// writer. A command the connection's queue runs later does not count its wait, and a
    /// command the queue refused (it is full) did not run and is not counted. A command that
    /// answers later from a thread of its own (a URL open, a Cloud call) counts its start.
    pub total_ns: u64,
    pub max_ns: u64,
    /// The requests by time: below 0.25 ms, then one bucket per power of 2 (`hist_bounds_ns`).
    pub hist: Vec<u64>,
}

impl CommandRow {
    fn add(&mut self, other: &Self) {
        self.count = self.count.saturating_add(other.count);
        self.total_ns = self.total_ns.saturating_add(other.total_ns);
        self.max_ns = self.max_ns.max(other.max_ns);
        for (bucket, more) in self.hist.iter_mut().zip(&other.hist) {
            *bucket = bucket.saturating_add(*more);
        }
    }
}

/// The connections of one client kind since the daemon started.
#[derive(Clone, Debug, Serialize)]
pub struct CommandConnections {
    pub kind: &'static str,
    /// Connections that registered, under the kind they have now.
    pub accepted: u64,
    /// Connections refused at the connection limit, under the kind known at that moment.
    pub refused: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_are_powers_of_two_from_a_quarter_millisecond() {
        assert_eq!(bucket(0), 0);
        assert_eq!(bucket(249_999), 0);
        assert_eq!(bucket(250_000), 1);
        assert_eq!(bucket(499_999), 1);
        assert_eq!(bucket(500_000), 2);
        assert_eq!(bucket(4_095_999_999), 14);
        assert_eq!(bucket(4_096_000_000), 15);
        assert_eq!(bucket(u64::MAX), 15);
    }

    #[test]
    fn a_connection_moves_its_accepted_count_with_its_kind() {
        let stats = Arc::new(CommandStats::default());
        let connection = ConnectionKind::default();
        connection.registered(&stats, ClientKind::Unknown);
        connection.observed(ClientKind::Terminal);
        connection.declare(ClientKind::declared("frontend"));
        // What the daemon sees later does not replace what the client said.
        connection.observed(ClientKind::Hook);
        assert_eq!(connection.get(), ClientKind::App);
        let snapshot = stats.snapshot();
        assert_eq!(snapshot.connections.len(), 1, "{snapshot:?}");
        assert_eq!(snapshot.connections[0].kind, "app");
        assert_eq!(snapshot.connections[0].accepted, 1);
    }

    #[test]
    fn names_past_the_limit_count_in_other() {
        let stats = CommandStats::default();
        let words: Vec<&'static str> =
            (0..NAME_LIMIT + 40).map(|number| &*format!("word-{number}").leak()).collect();
        let kind = ConnectionKind::default();
        for word in &words {
            drop(stats.start(word, &kind));
        }
        // A line with no named request counts in the same row.
        drop(stats.start_line(&kind));
        let snapshot = stats.snapshot();
        assert_eq!(snapshot.names, NAME_LIMIT as u64);
        assert_eq!(snapshot.rows.len(), NAME_LIMIT + 1, "one row per name and one for the rest");
        let other = snapshot.rows.iter().find(|row| row.name == OTHER).expect("other");
        assert_eq!(other.count, 41);

        // A line with a named request does not.
        let line = stats.start_line(&kind);
        drop(stats.start(words[0], &kind));
        drop(line);
        let other_after = stats.snapshot().rows.into_iter().find(|row| row.name == OTHER);
        assert_eq!(other_after.map(|row| row.count), Some(41));
    }
}
