//! The registry shape of 2026-11-10 (`--shape lawrence`), for the migration
//! proof of journal retention: a 9.6 GB file of 2.26 M journal records, all
//! but about 500 of them in sealed segments, 826 workspaces, 170 agent
//! terminals, 16 checkpoints near the head, and a History fold whose cursor
//! is 30% of the journal behind the head.
//!
//! Rows by count: `agent.state.changed` 64%, `terminal.progress` 11%, the
//! other `agent.*` kinds 4%, `personal.session.put` the rest. Which writer
//! makes each row:
//!
//! - every `agent.*` payload comes from the hook helper's own builder
//!   (`agent_hook_journal_ingress`) and the producer's payload validation;
//! - [`ShapeOptions::receipt_percent`] of all records are `agent.*` rows
//!   committed by the daemon's ingress commit
//!   (`WorkspaceRegistry::append_journal_ingress`): one transaction each,
//!   with its ingress receipt and the subjects that commit derives (the
//!   hook row it stages for the terminal's resource is cleared at once, as
//!   the daemon clears it for a terminal that is gone);
//! - the other `agent.*` rows go through `append_journal_record` with the
//!   same session, producer and terminal subjects, and no receipt;
//! - `terminal.progress` rows are NOT the daemon's (its writer needs a live
//!   terminal): a filler payload through `append_presentation_record`;
//! - `personal.session.put` rows as the first generator writes them.
//!
//! The agent terminals are not resources of the registry, so the ingress
//! commit finds no tab, pane, screen or workspace to add. The rows that do
//! not go through it carry padding subjects (`workspace`, `tab`, `pane`,
//! `screen` kinds with `synth_` ids) until the journal holds
//! [`ShapeOptions::subjects_per_record`] subject rows a record.
//!
//! Then, by owners opened for it: the History fold runs to the journal head
//! of that moment and is saved (`history_ops::fold_for_retention`; if a later
//! owner of the generator saves its fold again, that first saved state is
//! put back at the end), 15
//! checkpoints are taken over the last 2.8% of the sealed records, and the
//! 16th with the seal of every record below it (`Mux::seal_journal_segments`).
//! The roster snapshot is folded here from the same records and saved at the
//! head. Records that an owner writes on its own while it is open (a retired
//! agent of a terminal it does not know) are not in that fold.
//!
//! The agent terminals are journal subjects only: 170 of them for any
//! number of workspaces, and none is a row of `resource_terminals`.
//!
//! [`counts`] reads the numbers of any registry file, read-only.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{Value, json};

use super::{ORIGIN, SEAL_OWNER_SPAN, SynthOptions, Writer, create_workspaces, seal};
use crate::history_ops::AGENT_FOLD_STATE_ID;
use crate::journal_reducers::{
    AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
};
use crate::workspace_registry::journal_extensions::random_event_id;
use crate::workspace_registry::presentation_store::append_presentation_record;
use crate::workspace_registry::session_journal::{
    JournalAppend, append_journal_record, query_journal_head, query_session_journal_after,
    unix_epoch_ms, write_journal_reducer_state,
};
use crate::workspace_registry::{JOURNAL_AUTO_VACUUM_META_KEY, WorkspaceRegistry};
use crate::{JournalAuthority, JournalProducer, JournalSubject};

/// Shares of the journal by count, in percent; session puts are the rest.
const STATE_CHANGED_PERCENT: u64 = 64;
const PROGRESS_PERCENT: u64 = 11;
const AGENT_OTHER_PERCENT: u64 = 4;
/// Filler bytes that bring a record to its size in the real file (about
/// 2,146 bytes for `agent.state.changed`, 3,922 for `terminal.progress`).
const STATE_CHANGED_FILL_BYTES: usize = 1_650;
const AGENT_OTHER_FILL_BYTES: usize = 600;
const PROGRESS_FILL_BYTES: usize = 3_500;
/// Approximate JSON bytes of one `personal.session.put` payload.
const SESSION_PUT_BYTES: usize = 6 * 1024;
/// Turns of an agent session before it ends and the next one starts.
const TURNS_PER_SESSION: u64 = 24;
/// Checkpoints kept by a registry; the newest is the sealed end.
const CHECKPOINTS: u64 = 16;
/// The checkpoints span 63,000 of 2,260,000 sealed records in the real file.
const CHECKPOINT_WINDOW: u128 = 63_000;
const CHECKPOINT_WINDOW_OF: u128 = 2_260_000;
/// The History fold's cursor is this share of the journal behind the head.
const HISTORY_BEHIND_PERCENT: u64 = 30;
/// Subject rows of a session put: the registry's session and the put one.
const SESSION_PUT_SUBJECTS: u64 = 2;
/// At most this many padding subjects on one record.
const MAX_PADDING_SUBJECTS: u64 = 32;
const PADDING_KINDS: [&str; 4] = ["workspace", "tab", "pane", "screen"];
/// The generator's own open of the registry, right after an owner's
/// shutdown: tries and the pause between two.
const OPEN_TRIES: u32 = 100;
const OPEN_RETRY_PAUSE: Duration = Duration::from_millis(100);
/// Owners opened in a row for the History fold before the generator stops.
const MAX_FOLD_OWNERS: u32 = 400;
/// Characters of the filler: 6 bits each, so a sealed segment's gzip keeps
/// about three quarters of it.
const FILL_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// What [`generate_shape`] writes. [`Default`] is the 1 GB class.
#[derive(Debug, Clone)]
pub struct ShapeOptions {
    /// The session name an owner starts with (`--session`).
    pub session: String,
    /// The file size to reach, by [`Self::bytes_per_record`].
    pub target_bytes: u64,
    /// File bytes per journal record (4,300 in the real file). The file's
    /// real size is in the report; adjust this or give [`Self::records`].
    pub bytes_per_record: u64,
    /// Journal records to reach, instead of the size.
    pub records: Option<u64>,
    /// Workspaces the first owner creates.
    pub workspaces: u32,
    /// Terminals with an agent.
    pub agent_terminals: usize,
    /// Records left live (not sealed) at the head.
    pub live_rows: u64,
    /// Percent of all records that the ingress commit writes, each with an
    /// ingress receipt.
    pub receipt_percent: u64,
    /// Subject rows a record over the whole journal.
    pub subjects_per_record: u64,
    /// Move every segment's `sealed_at_ms` this many minutes back (0: not).
    pub seal_age_minutes: u64,
    /// The newest segments that keep their real `sealed_at_ms`.
    pub young_segments: u64,
    /// Leave the file with `auto_vacuum` none and no migration marker, as a
    /// registry made before journal maintenance has it.
    pub legacy_auto_vacuum: bool,
    /// Print progress to stderr.
    pub progress: bool,
}

impl Default for ShapeOptions {
    fn default() -> Self {
        Self {
            session: "synth".into(),
            target_bytes: 1 << 30,
            bytes_per_record: 4_300,
            records: None,
            workspaces: 826,
            agent_terminals: 170,
            live_rows: 500,
            receipt_percent: 36,
            subjects_per_record: 12,
            seal_age_minutes: 0,
            young_segments: 0,
            legacy_auto_vacuum: true,
            progress: false,
        }
    }
}

impl ShapeOptions {
    /// The journal head to reach.
    pub fn record_target(&self) -> u64 {
        self.records.unwrap_or(self.target_bytes / self.bytes_per_record.max(1))
    }

    /// The first generator's options that the shared steps read.
    fn base(&self) -> SynthOptions {
        SynthOptions {
            session: self.session.clone(),
            session_puts: 0,
            agent_events: 0,
            output_bytes: 0,
            workspaces: self.workspaces,
            payload_bytes: SESSION_PUT_BYTES,
            seal: true,
            seal_segments: None,
            roster_version_bump: false,
            batch_rows: 1,
            progress: self.progress,
        }
    }
}

/// What [`generate_shape`] wrote: the generator's own row counts, and
/// [`counts`] of the finished file.
#[derive(Debug, Clone)]
pub struct ShapeReport {
    pub registry_path: PathBuf,
    /// [`counts`] of the file after the last write.
    pub counts: Value,
    pub state_changed: u64,
    pub agent_other: u64,
    pub progress_rows: u64,
    pub session_puts: u64,
    /// Rows the ingress commit wrote (each with a receipt).
    pub ingress_rows: u64,
    /// Highest sequence in a sealed segment.
    pub sealed_through: u64,
    pub segments_sealed: u64,
    pub segments_backdated: u64,
    pub elapsed: Duration,
}

impl ShapeReport {
    pub fn to_json(&self) -> Value {
        let seconds = self.elapsed.as_secs_f64();
        let mut report = self.counts.clone();
        if let Some(fields) = report.as_object_mut() {
            fields.insert(
                "written".into(),
                json!({
                    "agent_state_changed": self.state_changed,
                    "agent_other": self.agent_other,
                    "terminal_progress": self.progress_rows,
                    "session_puts": self.session_puts,
                    "ingress_commit_rows": self.ingress_rows,
                    "sealed_through": self.sealed_through,
                    "segments_sealed": self.segments_sealed,
                    "segments_backdated": self.segments_backdated,
                }),
            );
            fields.insert("elapsed_s".into(), json!((seconds * 10.0).round() / 10.0));
        }
        report
    }
}

/// Write the registry of `options.session` below `state_root` in the shape
/// above. The session must not exist yet, and no owner may run on it while
/// this runs.
pub fn generate_shape(state_root: &Path, options: &ShapeOptions) -> anyhow::Result<ShapeReport> {
    let started = Instant::now();
    let registry_path = super::registry_path(state_root, &options.session);
    anyhow::ensure!(!registry_path.exists(), "{} already exists", registry_path.display());
    anyhow::ensure!(options.agent_terminals > 0, "the shape needs an agent terminal");
    let base = options.base();

    // The registry and its workspaces, made by an owner as the app makes them.
    {
        let mux = open_owner(state_root, &base)?;
        let created = create_workspaces(&mux, options.workspaces);
        mux.shutdown();
        created?;
    }
    let mut writer = Writer::open(&registry_path, &base)?;
    // Every later row goes through the registry's own connection.
    drop(writer.connection.take());

    let mut shape = Shape {
        state_root: state_root.to_path_buf(),
        options: options.clone(),
        writer,
        registry: None,
        lanes: (0..options.agent_terminals)
            .map(|index| Lane {
                // The v4 layout of a terminal's public id.
                terminal: format!("term_00000000000040008000{index:012x}"),
                session: format!("synth-agent-{index}-1"),
                sessions: 1,
                step: 0,
                tools: 0,
            })
            .collect(),
        counters: Counters::default(),
        history: None,
    };
    shape.open_registry()?;
    let records = options.record_target();
    let sealed_end = records.saturating_sub(options.live_rows.min(records));
    shape.start_sessions()?;

    // The History fold stops here, behind every later record.
    let fold_at = records.saturating_sub(records * HISTORY_BEHIND_PERCENT / 100).min(sealed_end);
    shape.append_to(fold_at)?;
    shape.close_registry()?;
    fold_history(state_root, &base)?;
    shape.open_registry()?;
    shape.history = shape.registry()?.journal_reducer_state(AGENT_FOLD_STATE_ID)?;

    // Fifteen checkpoints over the window below the sealed end.
    let window = (u128::from(sealed_end) * CHECKPOINT_WINDOW / CHECKPOINT_WINDOW_OF) as u64;
    for index in 1..CHECKPOINTS {
        // Each checkpoint needs a journal head of its own, also when an
        // owner's own records moved the head past the planned place.
        let stop = (sealed_end - window + window * index / CHECKPOINTS).max(shape.head()? + 1);
        shape.append_to(stop)?;
        shape.close_registry()?;
        checkpoint(state_root, &base, index)?;
        shape.open_registry()?;
    }

    // The last checkpoint, and every record below it into segments.
    let last = sealed_end.max(shape.head()? + 1);
    shape.append_to(last)?;
    shape.close_registry()?;
    let (sealed_through, segments_sealed) = seal(state_root, &base)?;
    shape.open_registry()?;
    shape.append(options.live_rows.min(records))?;
    shape.save_roster()?;
    let segments_backdated = shape.backdate_segments()?;
    shape.finish()?;

    Ok(ShapeReport {
        counts: counts(&registry_path)?,
        registry_path,
        state_changed: shape.counters.state_changed,
        agent_other: shape.counters.agent_other,
        progress_rows: shape.counters.progress_rows,
        session_puts: shape.writer.written.session_puts,
        ingress_rows: shape.counters.ingress_rows,
        sealed_through,
        segments_sealed,
        segments_backdated,
        elapsed: started.elapsed(),
    })
}

/// An owner on the session with its maintenance worker stopped: the
/// generator takes each checkpoint and seals each segment itself.
fn open_owner(state_root: &Path, base: &SynthOptions) -> anyhow::Result<Arc<crate::Mux>> {
    let mux = crate::Mux::open_persistent(
        base.session.clone(),
        crate::SurfaceOptions::default(),
        state_root,
    )?;
    mux.stop_journal_maintenance();
    Ok(mux)
}

/// Run the daemon's History fold to the journal head and save it, on owners
/// opened for at most [`SEAL_OWNER_SPAN`] each (as the seal step does).
fn fold_history(state_root: &Path, base: &SynthOptions) -> anyhow::Result<()> {
    for owner in 0..MAX_FOLD_OWNERS {
        let mux = open_owner(state_root, base)?;
        let complete = crate::history_ops::fold_for_retention(&mux, SEAL_OWNER_SPAN, 1);
        mux.shutdown();
        drop(mux);
        if complete? {
            return Ok(());
        }
        if base.progress {
            eprintln!("synth: the History fold goes on in owner {}", owner + 2);
        }
    }
    anyhow::bail!("the History fold did not reach the journal head in {MAX_FOLD_OWNERS} owners")
}

/// One checkpoint at the journal head, by an owner. Returns its sequence.
fn checkpoint(state_root: &Path, base: &SynthOptions, index: u64) -> anyhow::Result<u64> {
    let mux = open_owner(state_root, base)?;
    let made = mux.create_journal_checkpoint(ORIGIN, &format!("synth-shape-checkpoint-{index}"));
    mux.shutdown();
    Ok(made?.checkpoint.source_sequence)
}

#[derive(Debug, Default, Clone, Copy)]
struct Counters {
    /// Every row this generator wrote.
    rows: u64,
    state_changed: u64,
    agent_other: u64,
    progress_rows: u64,
    ingress_rows: u64,
    /// Subject rows written.
    subject_rows: u64,
    /// Turns of the lane round for the other `agent.*` kinds.
    other_turns: u64,
}

#[derive(Clone, Copy)]
enum Kind {
    StateChanged,
    Progress,
    AgentOther,
    SessionPut,
}

/// One terminal's agent: its session and how far that is.
struct Lane {
    terminal: String,
    session: String,
    sessions: u64,
    /// Turn events since the session started.
    step: u64,
    tools: u64,
}

struct Shape {
    state_root: PathBuf,
    options: ShapeOptions,
    /// The first generator's writer, with no connection of its own: its
    /// session puts, its roster fold and its payload validation.
    writer: Writer,
    registry: Option<WorkspaceRegistry>,
    lanes: Vec<Lane>,
    counters: Counters,
    /// The History fold as the daemon's fold saved it (version, cursor,
    /// snapshot).
    history: Option<(u32, u64, String)>,
}

impl Shape {
    fn open_registry(&mut self) -> anyhow::Result<()> {
        // An owner's last worker may still hold the session for a moment
        // after its shutdown.
        let mut tries = 0;
        let registry = loop {
            match WorkspaceRegistry::open(&self.state_root, &self.options.session) {
                Ok(registry) => break registry,
                Err(error) if tries >= OPEN_TRIES => return Err(error),
                Err(_) => {
                    tries += 1;
                    std::thread::sleep(OPEN_RETRY_PAUSE);
                }
            }
        };
        // A crash of the generator may lose the registry: it is made again.
        registry
            .connection
            .get()
            .execute_batch("PRAGMA synchronous=OFF; PRAGMA cache_size=-262144;")?;
        self.registry = Some(registry);
        Ok(())
    }

    fn registry(&self) -> anyhow::Result<&WorkspaceRegistry> {
        self.registry.as_ref().context("the generator's registry is closed")
    }

    fn head(&self) -> anyhow::Result<u64> {
        query_journal_head(&self.registry()?.connection.get())
    }

    /// Save the roster at the head and close the registry for an owner.
    fn close_registry(&mut self) -> anyhow::Result<()> {
        self.save_roster()?;
        self.registry = None;
        Ok(())
    }

    /// The roster folded here, at the journal head and the current version.
    fn save_roster(&self) -> anyhow::Result<u64> {
        let connection = self.registry()?.connection.get();
        let head = query_journal_head(&connection)?;
        write_journal_reducer_state(
            &connection,
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            head,
            &self.writer.roster.snapshot().to_string(),
        )?;
        Ok(head)
    }

    /// A `SessionStart` of every lane.
    fn start_sessions(&mut self) -> anyhow::Result<()> {
        for lane in 0..self.lanes.len() {
            self.hook_row(lane, "SessionStart", AGENT_OTHER_FILL_BYTES)?;
            self.counters.agent_other += 1;
        }
        Ok(())
    }

    /// Append rows until the journal head is `stop`.
    fn append_to(&mut self, stop: u64) -> anyhow::Result<()> {
        let head = self.head()?;
        self.append(stop.saturating_sub(head))
    }

    fn append(&mut self, rows: u64) -> anyhow::Result<()> {
        let started = Instant::now();
        let end = self.counters.rows + rows;
        while self.counters.rows < end {
            match self.next_kind() {
                Kind::StateChanged => self.state_changed()?,
                Kind::Progress => self.progress_row()?,
                Kind::AgentOther => self.agent_other()?,
                Kind::SessionPut => self.session_put()?,
            }
            if self.options.progress && self.counters.rows.is_multiple_of(50_000) {
                eprintln!(
                    "synth: {} rows ({} left in this step, {:.1} s)",
                    self.counters.rows,
                    end.saturating_sub(self.counters.rows),
                    started.elapsed().as_secs_f64()
                );
            }
        }
        Ok(())
    }

    /// The kind furthest behind its share.
    fn next_kind(&self) -> Kind {
        let done = self.counters.rows + 1;
        let behind = |percent: u64, made: u64| (percent * done) as i128 - (made * 100) as i128;
        let puts = 100 - STATE_CHANGED_PERCENT - PROGRESS_PERCENT - AGENT_OTHER_PERCENT;
        [
            (Kind::StateChanged, behind(STATE_CHANGED_PERCENT, self.counters.state_changed)),
            (Kind::Progress, behind(PROGRESS_PERCENT, self.counters.progress_rows)),
            (Kind::AgentOther, behind(AGENT_OTHER_PERCENT, self.counters.agent_other)),
            (Kind::SessionPut, behind(puts, self.writer.written.session_puts)),
        ]
        .into_iter()
        .max_by_key(|(_, behind)| *behind)
        .map_or(Kind::SessionPut, |(kind, _)| kind)
    }

    fn filler(&mut self, bytes: usize) -> String {
        let mut text = String::with_capacity(bytes + 10);
        while text.len() < bytes {
            let mut random = self.writer.next_random();
            for _ in 0..10 {
                let letter = FILL_ALPHABET.get((random & 63) as usize).copied().unwrap_or(b'A');
                text.push(char::from(letter));
                random >>= 6;
            }
        }
        text.truncate(bytes);
        text
    }

    /// Padding subjects for a record that already has `own` subject rows,
    /// so that the journal reaches its subject rows a record.
    fn padding(&mut self, lane: usize, own: u64) -> Vec<JournalSubject> {
        let want = self.options.subjects_per_record * (self.counters.rows + 1);
        let room = want.saturating_sub(self.counters.subject_rows + own).min(MAX_PADDING_SUBJECTS);
        self.counters.subject_rows += own + room;
        (0..room as usize)
            .map(|slot| {
                let kind =
                    PADDING_KINDS.get(slot % PADDING_KINDS.len()).copied().unwrap_or("workspace");
                JournalSubject {
                    kind: kind.into(),
                    id: format!("synth_{kind}_{lane:04}_{slot:02}"),
                }
            })
            .collect()
    }

    /// A tool event of the next lane: `agent.state.changed`.
    fn state_changed(&mut self) -> anyhow::Result<()> {
        let index = (self.counters.state_changed % self.lanes.len() as u64) as usize;
        let lane = self.lanes.get_mut(index).context("agent lane")?;
        lane.tools += 1;
        let event = if lane.tools % 2 == 1 { "PreToolUse" } else { "PostToolUse" };
        self.hook_row(index, event, STATE_CHANGED_FILL_BYTES)?;
        self.counters.state_changed += 1;
        Ok(())
    }

    /// The next turn event of the next lane; after the session's last turn
    /// its end, and the start of the lane's next session.
    fn agent_other(&mut self) -> anyhow::Result<()> {
        let index = (self.counters.other_turns % self.lanes.len() as u64) as usize;
        self.counters.other_turns += 1;
        let step = self.lanes.get(index).context("agent lane")?.step;
        if step < TURNS_PER_SESSION * 2 {
            let event = if step.is_multiple_of(2) { "UserPromptSubmit" } else { "Stop" };
            self.hook_row(index, event, AGENT_OTHER_FILL_BYTES)?;
            self.lanes.get_mut(index).context("agent lane")?.step += 1;
            self.counters.agent_other += 1;
            return Ok(());
        }
        self.hook_row(index, "SessionEnd", AGENT_OTHER_FILL_BYTES)?;
        let lane = self.lanes.get_mut(index).context("agent lane")?;
        lane.sessions += 1;
        lane.session = format!("synth-agent-{index}-{}", lane.sessions);
        lane.step = 0;
        self.hook_row(index, "SessionStart", AGENT_OTHER_FILL_BYTES)?;
        self.counters.agent_other += 2;
        Ok(())
    }

    /// One hook event of `lane`'s agent, built by the hook helper's own
    /// builder, committed by the ingress commit or by hand (see the module
    /// doc), and folded into the roster.
    fn hook_row(&mut self, lane: usize, native_event: &str, fill: usize) -> anyhow::Result<()> {
        let (terminal, session) = {
            let lane = self.lanes.get(lane).context("agent lane")?;
            (lane.terminal.clone(), lane.session.clone())
        };
        let native = json!({
            "session_id": session,
            "hook_event_name": native_event,
            "cwd": format!("/home/synth/project-{lane}"),
            "tool_name": "Bash",
            // A name the hook redaction keeps, so the record keeps its size.
            "synth_fill_path": self.filler(fill),
        });
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            native_event,
            Some(terminal.as_str()),
            native,
        )?;
        let validated = self.writer.kernel.validate_ingress(&ingress)?;
        let through_ingress = self.counters.ingress_rows * 100
            < self.options.receipt_percent * (self.counters.rows + 1);
        // The session, the producer, and what the builder named.
        let own = 2 + ingress.subjects.len() as u64;
        let padding = if through_ingress {
            self.counters.subject_rows += own;
            Vec::new()
        } else {
            self.padding(lane, own)
        };
        let key = format!("synth-shape-{}", self.counters.rows);
        let registry = self.registry.as_mut().context("the generator's registry is closed")?;
        let sequence = if through_ingress {
            self.counters.ingress_rows += 1;
            let sequence =
                registry.append_journal_ingress(&ingress, &validated, ORIGIN, &key)?.sequence;
            // The commit stages the hook for the terminal's resource row. The
            // daemon clears that row when the terminal is gone, as here.
            registry.clear_agent_hook_pending(&ingress.producer_id, ORIGIN, &key)?;
            sequence
        } else {
            let connection = registry.connection.get();
            let tx = connection.unchecked_transaction()?;
            let mut subjects = BTreeSet::from([
                JournalSubject { kind: "session".into(), id: super::transaction_session_id(&tx)? },
                JournalSubject { kind: "producer".into(), id: ingress.producer_id.clone() },
            ]);
            subjects.extend(ingress.subjects.iter().cloned());
            subjects.extend(padding);
            let subjects = subjects.into_iter().collect::<Vec<_>>();
            let producer =
                JournalProducer { kind: "agent_adapter".into(), id: ingress.producer_id.clone() };
            let authority = JournalAuthority {
                principal_id: "agent-hook".into(),
                lease_id: format!("producer:{}", ingress.producer_id),
                generation: ingress.manifest_version.to_string(),
                role: "agent.adapter".into(),
            };
            let event_id = random_event_id("agent");
            let sequence = append_journal_record(
                &tx,
                &JournalAppend {
                    event_id: &event_id,
                    schema_version: ingress.schema_version,
                    kind: &ingress.kind,
                    class: validated.class,
                    replay: validated.replay,
                    occurred_at_ms: unix_epoch_ms()?,
                    producer: &producer,
                    authority: Some(&authority),
                    causation_id: None,
                    correlation_id: Some(key.as_str()),
                    causation_depth: 0,
                    subjects: &subjects,
                    sensitivity: validated.sensitivity,
                    payload: &ingress.payload,
                    content: None,
                    resource_revision: None,
                    previous_resource_revision: None,
                    actor: None,
                },
            )?;
            tx.commit()?;
            sequence
        };
        // Fold the record as the daemon decodes it.
        let page = query_session_journal_after(&registry.connection.get(), sequence - 1, 1)?;
        let record = page.records.first().context("the appended agent record reads back")?;
        self.writer.roster.apply(&RosterEvent::from_record(record));
        self.counters.rows += 1;
        Ok(())
    }

    /// One `terminal.progress` row with a filler payload (not the daemon's
    /// writer, which needs a live terminal).
    fn progress_row(&mut self) -> anyhow::Result<()> {
        let index = (self.counters.progress_rows % self.lanes.len() as u64) as usize;
        let terminal = self.lanes.get(index).context("agent lane")?.terminal.clone();
        let mut subjects = vec![JournalSubject { kind: "terminal".into(), id: terminal.clone() }];
        subjects.extend(self.padding(index, 2));
        let payload = json!({
            "terminal_id": terminal,
            "progress": {"state": "set", "value": self.counters.progress_rows % 100},
            "synth_fill": self.filler(PROGRESS_FILL_BYTES),
        });
        {
            let connection = self.registry()?.connection.get();
            let tx = connection.unchecked_transaction()?;
            append_presentation_record(&tx, "terminal.progress", subjects, &payload)?;
            tx.commit()?;
        }
        self.counters.progress_rows += 1;
        self.counters.rows += 1;
        Ok(())
    }

    fn session_put(&mut self) -> anyhow::Result<()> {
        {
            let registry = self.registry.as_ref().context("the generator's registry is closed")?;
            let connection = registry.connection.get();
            let tx = connection.unchecked_transaction()?;
            self.writer.session_put(&tx)?;
            tx.commit()?;
        }
        self.counters.subject_rows += SESSION_PUT_SUBJECTS;
        self.counters.rows += 1;
        Ok(())
    }

    /// Move `sealed_at_ms` of every segment but the newest
    /// [`ShapeOptions::young_segments`] back by
    /// [`ShapeOptions::seal_age_minutes`]. A segment row refuses an update,
    /// so its trigger is dropped and made again in the same transaction.
    /// Returns the segments moved.
    fn backdate_segments(&self) -> anyhow::Result<u64> {
        if self.options.seal_age_minutes == 0 {
            return Ok(0);
        }
        let age_ms = self.options.seal_age_minutes.saturating_mul(60_000);
        let young = self.options.young_segments;
        let connection = self.registry()?.connection.get();
        let segments =
            connection.query_row("SELECT COUNT(*) FROM journal_segments", [], |row| {
                row.get::<_, i64>(0)
            })?;
        let segments = u64::try_from(segments)?;
        connection.execute_batch(&format!(
            "BEGIN IMMEDIATE;
             DROP TRIGGER journal_segments_reject_update;
             UPDATE journal_segments SET sealed_at_ms = MAX(sealed_at_ms - {age_ms}, 0)
              WHERE start_sequence NOT IN (
                SELECT start_sequence FROM journal_segments
                 ORDER BY start_sequence DESC LIMIT {young});
             CREATE TRIGGER journal_segments_reject_update
               BEFORE UPDATE ON journal_segments
             BEGIN
               SELECT RAISE(ABORT, 'journal segments are immutable');
             END;
             COMMIT;"
        ))?;
        Ok(segments.saturating_sub(young))
    }

    /// The last writes: the file as an old registry has it, and no WAL.
    fn finish(&mut self) -> anyhow::Result<()> {
        let registry = self.registry.take().context("the generator's registry is closed")?;
        // A later owner of the generator may have saved its own fold: put
        // back the one saved behind the head.
        let saved = registry.journal_reducer_state(AGENT_FOLD_STATE_ID)?;
        {
            let connection = registry.connection.get();
            if let Some((version, cursor, snapshot)) = &self.history
                && saved.as_ref() != self.history.as_ref()
            {
                write_journal_reducer_state(
                    &connection,
                    AGENT_FOLD_STATE_ID,
                    *version,
                    *cursor,
                    snapshot,
                )?;
            }
            if self.options.legacy_auto_vacuum {
                if self.options.progress {
                    eprintln!("synth: VACUUM to auto_vacuum none");
                }
                connection
                    .execute("DELETE FROM meta WHERE key = ?1", [JOURNAL_AUTO_VACUUM_META_KEY])?;
                connection.execute_batch("PRAGMA auto_vacuum=NONE; VACUUM;")?;
            }
            connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
        }
        drop(registry);
        Ok(())
    }
}

/// The saved state of a reducer in `meta`: version, cursor, snapshot.
fn reducer_state(raw: Option<String>) -> Option<(u64, u64, String)> {
    let value: Value = serde_json::from_str(&raw?).ok()?;
    let version = value.get("version")?.as_u64()?;
    let cursor = value.get("cursor")?.as_str()?.parse().ok()?;
    let snapshot = value.get("snapshot")?.as_str()?.to_string();
    Some((version, cursor, snapshot))
}

/// The counts of a registry file, as one JSON object with no path and no
/// row content. The connection is read-only: no migration runs and no row is
/// written (for a file in WAL mode SQLite may make the `-shm` and `-wal`
/// files beside it, so the folder must allow that when they are absent).
/// The agents and the History sessions are those of the SAVED reducer states
/// in `meta`, decoded with the reducers' own types; a state that is absent
/// or does not decode gives `null`, as does a table an older schema lacks.
pub fn counts(registry_path: &Path) -> anyhow::Result<Value> {
    let connection = Connection::open_with_flags(
        registry_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("open {} read-only", registry_path.display()))?;
    let number = |sql: &str| -> Option<i64> {
        connection.query_row(sql, [], |row| row.get::<_, Option<i64>>(0)).ok().flatten()
    };
    let meta = |key: &str| -> Option<String> {
        connection
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get::<_, String>(0)
            })
            .optional()
            .ok()
            .flatten()
    };
    let bytes = |path: &Path| std::fs::metadata(path).map(|file| file.len()).ok();
    let mut wal = registry_path.as_os_str().to_os_string();
    wal.push("-wal");

    let roster = reducer_state(meta(&format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}")));
    let history = reducer_state(meta(&format!("journal_reducer.{AGENT_FOLD_STATE_ID}")));
    let live = number("SELECT COUNT(*) FROM session_journal");
    let sealed = number("SELECT COALESCE(SUM(record_count), 0) FROM journal_segments");
    let floor = meta("journal_retention_floor").and_then(|floor| floor.parse::<u64>().ok());
    Ok(json!({
        "registry_bytes": bytes(registry_path),
        "wal_bytes": bytes(Path::new(&wal)).unwrap_or(0),
        "workspaces": number("SELECT COUNT(*) FROM resource_workspaces"),
        "tabs": number("SELECT COUNT(*) FROM resource_tabs"),
        "terminals": number("SELECT COUNT(*) FROM resource_terminals"),
        "roster_agents": roster.as_ref().and_then(|(version, _, snapshot)| {
            AgentRoster::migrate(*version as u32, snapshot).map(|roster| roster.entries.len())
        }),
        "history_sessions": history.as_ref().and_then(|(_, _, snapshot)| {
            serde_json::from_str::<cmux_history::AgentSessionFold>(snapshot)
                .ok()
                .map(|fold| fold.len())
        }),
        "history_cursor": history.as_ref().map(|(_, cursor, _)| *cursor),
        "roster_cursor": roster.as_ref().map(|(_, cursor, _)| *cursor),
        "journal_head": query_journal_head(&connection).ok(),
        "records": live.zip(sealed).map(|(live, sealed)| live + sealed),
        "segments": number("SELECT COUNT(*) FROM journal_segments"),
        "live_rows": live,
        "checkpoints": number("SELECT COUNT(*) FROM journal_checkpoints"),
        "pruned_ranges": number("SELECT COUNT(*) FROM journal_pruned_ranges").unwrap_or(0),
        "retention_floor": floor.unwrap_or(0),
        "receipts": number("SELECT COUNT(*) FROM journal_ingress_receipts"),
        "subject_rows": number("SELECT COUNT(*) FROM journal_subject_index"),
        "freelist_pages": number("PRAGMA freelist_count"),
        "auto_vacuum": number("PRAGMA auto_vacuum"),
    }))
}

#[cfg(test)]
#[path = "synth_shape_tests.rs"]
mod tests;
