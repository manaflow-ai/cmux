//! A synthetic workspace registry shaped like a long-lived owner's, for
//! startup measurements and fault tests (`examples/synth_registry.rs`,
//! `scripts/measure/daemon-registry-start.sh`).
//!
//! The registry that restart-looped on 2026-11-09 was a 59 GB file of about
//! 12M journal rows, 96.6% of them `personal.session.put`; an agent-roster
//! reducer version bump made its start re-fold all of them (26 min). This
//! module writes that shape at a chosen size:
//!
//! - `personal.session.put` rows of about [`SynthOptions::payload_bytes`]
//!   each, a few sessions put over and over (the app re-registers them);
//! - `agent.*` hook events of the built-in agent producer, which the roster
//!   folds (`journal_reducers`), cycling sessions and turns on a set of
//!   terminals;
//! - optionally legacy `terminal.output` rows (older builds journaled output;
//!   a start schedules their cleanup);
//! - workspaces, created by an owner through the resource API;
//! - optionally sealed segments: an owner takes a checkpoint and seals the
//!   first half of the journal through the daemon's own sealing path
//!   (`Mux::seal_journal_segments`), then the second half stays live.
//!
//! Rows are appended in large transactions on a connection of the
//! generator's own, but every row goes through the daemon's record encoding
//! (`append_journal_record`, `append_presentation_record`, and the built-in
//! producer's payload validation), so the daemon reads them as its own.
//!
//! At the end the roster snapshot (`journal_reducer.agent_roster` in `meta`)
//! is written at the journal head, folded here from the same records, so the
//! next start replays nothing; with [`SynthOptions::roster_version_bump`] it
//! is written at the version before the current one, so the next start
//! discards it and re-folds the whole journal, as after a reducer bump.
//!
//! ```sh
//! cargo run --release -p cmux-tui-core --example synth_registry -- \
//!   --out /tmp/synth/sessions --session synth \
//!   --session-puts 1500000 --agent-events 60000 --output-bytes 0 --seal \
//!   --roster-version-bump
//! ```
//!
//! Then start an owner on it with `CMUX_TUI_STATE_DIR=/tmp/synth/sessions
//! cmux-tui --headless --session synth --socket /tmp/synth.sock`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use rusqlite::{Connection, Transaction, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::journal_extensions::random_event_id;
use super::personal_store::{PersonalSession, bump_personal_revision};
use super::presentation_store::append_presentation_record;
use super::session_journal::{
    JournalAppend, append_journal_record, query_journal_head, query_session_journal_after,
    write_journal_reducer_state,
};
use super::{WORKSPACE_REGISTRY_FILE, WorkspaceRegistry, persistent_session_state_dir};
use crate::journal_reducers::{
    AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
};
use crate::{
    JournalAuthority, JournalClass, JournalIngress, JournalProducer, JournalReplayPolicy,
    JournalSensitivity, JournalSubject,
};

/// Bytes of terminal output per `terminal.output` row.
const OUTPUT_CHUNK_BYTES: u64 = 4096;
/// Sessions whose records are put over and over.
const SESSIONS: usize = 8;
/// Terminals the agent events cycle over.
const AGENT_TERMINALS: usize = 24;
/// Turns per agent session before it ends and the next one starts.
const TURNS_PER_SESSION: usize = 3;
/// An owner opened for sealing is reopened after this long, before its
/// output cleanup could start (its start delay is 60 s).
const SEAL_OWNER_SPAN: Duration = Duration::from_secs(40);
const ORIGIN: &str = "synth-registry";

/// What to generate. [`Default`] is a small registry.
#[derive(Debug, Clone)]
pub struct SynthOptions {
    /// The session name an owner starts with (`--session`).
    pub session: String,
    /// `personal.session.put` rows.
    pub session_puts: u64,
    /// `agent.*` hook events.
    pub agent_events: u64,
    /// Bytes of legacy `terminal.output` content, in 4 KiB rows.
    pub output_bytes: u64,
    /// Workspaces the first owner creates.
    pub workspaces: u32,
    /// Approximate JSON bytes of one `personal.session.put` payload.
    pub payload_bytes: usize,
    /// Seal the first half of the journal into segments.
    pub seal: bool,
    /// Write the roster snapshot one version behind the current reducer.
    pub roster_version_bump: bool,
    /// Rows per transaction.
    pub batch_rows: u64,
    /// Print progress to stderr.
    pub progress: bool,
}

impl Default for SynthOptions {
    fn default() -> Self {
        Self {
            session: "synth".into(),
            session_puts: 960,
            agent_events: 40,
            output_bytes: 0,
            workspaces: 4,
            payload_bytes: 6 * 1024,
            seal: false,
            roster_version_bump: false,
            batch_rows: 20_000,
            progress: false,
        }
    }
}

/// What [`generate`] wrote.
#[derive(Debug, Clone)]
pub struct SynthReport {
    pub session_dir: PathBuf,
    pub registry_path: PathBuf,
    pub registry_bytes: u64,
    pub workspaces: Vec<String>,
    pub session_puts: u64,
    pub agent_events: u64,
    pub output_rows: u64,
    /// Journal head after the last write.
    pub journal_head: u64,
    /// Highest sequence moved into sealed segments (0: none).
    pub sealed_through: u64,
    pub segments: u64,
    /// The roster snapshot as written: version, cursor, live entries.
    pub roster_version: u32,
    pub roster_cursor: u64,
    pub roster_entries: usize,
    pub elapsed: Duration,
}

impl SynthReport {
    pub fn to_json(&self) -> Value {
        let seconds = self.elapsed.as_secs_f64();
        json!({
            "session_dir": self.session_dir,
            "registry_path": self.registry_path,
            "registry_bytes": self.registry_bytes,
            "workspaces": self.workspaces.len(),
            "session_puts": self.session_puts,
            "agent_events": self.agent_events,
            "output_rows": self.output_rows,
            "journal_head": self.journal_head,
            "sealed_through": self.sealed_through,
            "segments": self.segments,
            "roster_version": self.roster_version,
            "roster_current_version": AGENT_ROSTER_REDUCER_VERSION,
            "roster_cursor": self.roster_cursor,
            "roster_entries": self.roster_entries,
            "elapsed_s": (seconds * 10.0).round() / 10.0,
            "mib_per_s": if seconds > 0.0 {
                ((self.registry_bytes as f64 / 1_048_576.0 / seconds) * 10.0).round() / 10.0
            } else {
                0.0
            },
        })
    }
}

/// Write a registry for `options.session` below `state_root` (the
/// `CMUX_TUI_STATE_DIR` of the owner that will open it). The session must
/// not exist yet, and no owner may run on it while this runs.
pub fn generate(state_root: &Path, options: &SynthOptions) -> anyhow::Result<SynthReport> {
    let started = Instant::now();
    let session_dir = persistent_session_state_dir(state_root, &options.session);
    let registry_path = session_dir.join(WORKSPACE_REGISTRY_FILE);
    anyhow::ensure!(!registry_path.exists(), "{} already exists", registry_path.display());

    // The registry and its workspaces, made by an owner as the app makes them.
    let workspaces = {
        let mux = crate::Mux::open_persistent(
            options.session.clone(),
            crate::SurfaceOptions::default(),
            state_root,
        )?;
        let created = create_workspaces(&mux, options.workspaces);
        mux.shutdown();
        created?
    };

    let mut writer = Writer::open(&registry_path, options)?;
    let total = writer.plan.total();
    let first_half = if options.seal { total / 2 } else { total };
    writer.append(first_half)?;
    writer.save_roster(AGENT_ROSTER_REDUCER_VERSION)?;
    let (sealed_through, segments) = if options.seal {
        drop(writer.connection.take());
        let sealed = seal(state_root, options)?;
        writer.reopen(&registry_path)?;
        sealed
    } else {
        (0, 0)
    };
    writer.append(total - first_half)?;
    let version = if options.roster_version_bump {
        AGENT_ROSTER_REDUCER_VERSION - 1
    } else {
        AGENT_ROSTER_REDUCER_VERSION
    };
    let (roster_cursor, roster_entries) = writer.save_roster(version)?;
    let connection = writer.connection.take().context("generator connection")?;
    connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
    drop(connection);
    Ok(SynthReport {
        registry_bytes: std::fs::metadata(&registry_path)?.len(),
        session_dir,
        registry_path,
        workspaces,
        session_puts: writer.written.session_puts,
        agent_events: writer.written.agent_events,
        output_rows: writer.written.output_rows,
        journal_head: roster_cursor,
        sealed_through,
        segments,
        roster_version: version,
        roster_cursor,
        roster_entries,
        elapsed: started.elapsed(),
    })
}

fn create_workspaces(mux: &Arc<crate::Mux>, count: u32) -> anyhow::Result<Vec<String>> {
    (0..count)
        .map(|index| {
            let key = format!("synth-workspace-{index}");
            let request = json!({
                "protocol": "cmux.protocol/2",
                "type": "request",
                "id": key,
                "operation": "workspace.create",
                "params": {
                    "machine": "current",
                    "session": "current",
                    "name": format!("synth {index}"),
                    "initial_content": "empty",
                },
                "idempotency_key": key,
            });
            let created =
                crate::resource_router::handle_resource_message(mux, &request.to_string())
                    .map_err(|error| anyhow::anyhow!("workspace.create: {error:?}"))?;
            created
                .pointer("/result/value/workspace_id")
                .or_else(|| created.pointer("/value/workspace_id"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .with_context(|| format!("workspace.create answered no workspace id: {created}"))
        })
        .collect()
}

/// Seal the journal through a fresh checkpoint, one segment per call, on
/// owners opened for it. Returns the sealed end and the segments sealed.
fn seal(state_root: &Path, options: &SynthOptions) -> anyhow::Result<(u64, u64)> {
    let open = || {
        crate::Mux::open_persistent(
            options.session.clone(),
            crate::SurfaceOptions::default(),
            state_root,
        )
    };
    let mut mux = open()?;
    let mut opened = Instant::now();
    let target =
        mux.create_journal_checkpoint(ORIGIN, "synth-checkpoint")?.checkpoint.source_sequence;
    let mut segments = 0_u64;
    let mut through = 0;
    while through < target {
        if opened.elapsed() > SEAL_OWNER_SPAN {
            mux.shutdown();
            drop(mux);
            mux = open()?;
            opened = Instant::now();
        }
        let sealed = mux.seal_journal_segments(target, ORIGIN, &format!("synth-seal-{segments}"));
        let sealed = match sealed {
            Ok(sealed) => sealed,
            Err(error) => {
                mux.shutdown();
                return Err(error);
            }
        };
        segments += sealed.segments.len() as u64;
        anyhow::ensure!(sealed.through_sequence > through, "sealing made no progress");
        through = sealed.through_sequence;
        if options.progress && segments.is_multiple_of(200) {
            eprintln!("synth: sealed {segments} segments through {through} of {target}");
        }
    }
    mux.shutdown();
    Ok((through, segments))
}

#[derive(Debug, Default, Clone, Copy)]
struct Written {
    session_puts: u64,
    agent_events: u64,
    output_rows: u64,
}

/// How many rows of each kind, spread evenly over the journal.
struct Plan {
    session_puts: u64,
    agent_events: u64,
    output_rows: u64,
}

#[derive(Clone, Copy)]
enum RowKind {
    SessionPut,
    AgentEvent,
    Output,
}

impl Plan {
    fn total(&self) -> u64 {
        self.session_puts + self.agent_events + self.output_rows
    }

    /// The kind furthest behind its share after `written` rows.
    fn next(&self, written: &Written) -> RowKind {
        let total = self.total().max(1) as f64;
        let done = (written.session_puts + written.agent_events + written.output_rows + 1) as f64;
        let behind = |planned: u64, made: u64| {
            if made >= planned { f64::MIN } else { planned as f64 * done / total - made as f64 }
        };
        let candidates = [
            (RowKind::SessionPut, behind(self.session_puts, written.session_puts)),
            (RowKind::AgentEvent, behind(self.agent_events, written.agent_events)),
            (RowKind::Output, behind(self.output_rows, written.output_rows)),
        ];
        candidates
            .into_iter()
            .max_by(|left, right| left.1.total_cmp(&right.1))
            .map(|(kind, _)| kind)
            .unwrap_or(RowKind::SessionPut)
    }
}

/// One terminal's agent: its current session and how far it is.
#[derive(Clone)]
struct AgentLane {
    terminal: String,
    session: Option<String>,
    step: usize,
    sessions: u64,
    output_offset: u64,
}

struct Writer {
    connection: Option<Connection>,
    plan: Plan,
    written: Written,
    options: SynthOptions,
    kernel: Arc<crate::journal_kernel::JournalKernel>,
    sessions: Vec<PersonalSession>,
    capabilities: Value,
    lanes: Vec<AgentLane>,
    roster: AgentRoster,
    rng: u64,
}

impl Writer {
    fn open(registry_path: &Path, options: &SynthOptions) -> anyhow::Result<Self> {
        let output_rows = options.output_bytes.div_ceil(OUTPUT_CHUNK_BYTES);
        let mut writer = Self {
            connection: None,
            plan: Plan {
                session_puts: options.session_puts,
                agent_events: options.agent_events,
                output_rows,
            },
            written: Written::default(),
            options: options.clone(),
            kernel: crate::journal_kernel::JournalKernel::new(
                None,
                &[crate::agent_hooks::built_in_agent_producer_manifest()],
            )?,
            sessions: Vec::new(),
            capabilities: capabilities(),
            lanes: (0..AGENT_TERMINALS)
                .map(|index| AgentLane {
                    terminal: format!("term_{:032x}", 0x5e17_0000_u128 + index as u128),
                    session: None,
                    step: 0,
                    sessions: 0,
                    output_offset: 0,
                })
                .collect(),
            roster: AgentRoster::default(),
            rng: 0x9e37_79b9_7f4a_7c15,
        };
        writer.reopen(registry_path)?;
        writer.put_sessions()?;
        Ok(writer)
    }

    fn reopen(&mut self, registry_path: &Path) -> anyhow::Result<()> {
        let connection = Connection::open(registry_path)?;
        // The owner's own pragmas, except that a crash of the generator may
        // lose the registry: it is rebuilt, never repaired.
        connection.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=WAL;
             PRAGMA synchronous=OFF;
             PRAGMA cache_size=-262144;
             PRAGMA temp_store=MEMORY;",
        )?;
        self.connection = Some(connection);
        Ok(())
    }

    fn connection(&self) -> anyhow::Result<&Connection> {
        self.connection.as_ref().context("generator connection is closed")
    }

    /// The sessions, each put once through the daemon's own path.
    fn put_sessions(&mut self) -> anyhow::Result<()> {
        let connection = self.connection.take().context("generator connection")?;
        let result = (|| {
            let tx = connection.unchecked_transaction()?;
            for index in 0..SESSIONS {
                let transport = self.transport(index, 0);
                let (session, _) = WorkspaceRegistry::put_session_in(
                    &tx,
                    &format!("synth-session-{index}"),
                    Some(&format!("synth-machine-{index}")),
                    Some(&format!("synth-{index}")),
                    &transport,
                    Some(&self.capabilities),
                    None,
                )?;
                self.sessions.push(session);
            }
            tx.commit()?;
            anyhow::Ok(())
        })();
        self.connection = Some(connection);
        result
    }

    /// Append `rows` rows in transactions of `batch_rows`.
    fn append(&mut self, rows: u64) -> anyhow::Result<()> {
        let started = Instant::now();
        let mut done = 0;
        while done < rows {
            let batch = (rows - done).min(self.options.batch_rows.max(1));
            let connection = self.connection.take().context("generator connection")?;
            let result = (|| {
                let tx = connection.unchecked_transaction()?;
                for _ in 0..batch {
                    match self.plan.next(&self.written) {
                        RowKind::SessionPut => self.session_put(&tx)?,
                        RowKind::AgentEvent => self.agent_event(&tx)?,
                        RowKind::Output => self.output(&tx)?,
                    }
                }
                self.save_output_offsets(&tx)?;
                tx.commit()?;
                anyhow::Ok(())
            })();
            self.connection = Some(connection);
            result?;
            done += batch;
            if self.options.progress {
                eprintln!("synth: {done}/{rows} rows in {:.1} s", started.elapsed().as_secs_f64());
            }
        }
        Ok(())
    }

    fn next_random(&mut self) -> u64 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        self.rng
    }

    /// A transport object of about the payload's size less the capabilities.
    fn transport(&mut self, session: usize, put: u64) -> Value {
        let capabilities = serde_json::to_string(&self.capabilities).map_or(0, |text| text.len());
        let room = self
            .options
            .payload_bytes
            .saturating_sub(capabilities + 400)
            .min(super::personal_store::MAX_PERSONAL_JSON_BYTES - 256);
        let mut path = String::with_capacity(room);
        while path.len() + 16 <= room {
            path.push_str(&format!("{:016x}", self.next_random()));
        }
        json!({
            "kind": "ssh",
            "host": format!("synth-host-{session}.internal"),
            "socket": format!("/tmp/cmux-synth-{session}.sock"),
            "put": put,
            "route": path,
        })
    }

    /// One `personal.session.put` as `commit_personal` writes it (its
    /// sidebar document sync aside: the sessions do not change).
    fn session_put(&mut self, tx: &Transaction<'_>) -> anyhow::Result<()> {
        let put = self.written.session_puts;
        let index = (put % SESSIONS as u64) as usize;
        let transport = self.transport(index, put);
        let mut session = self.sessions[index].clone();
        session.transport = transport;
        session.last_seen_ms = Some(super::session_journal::unix_epoch_ms()?);
        let revision = bump_personal_revision(tx)?;
        append_presentation_record(
            tx,
            "personal.session.put",
            vec![JournalSubject { kind: "session".into(), id: session.session_id.clone() }],
            &json!({"session": session, "created": false, "personal_revision": revision}),
        )?;
        self.written.session_puts += 1;
        Ok(())
    }

    /// One hook event of the built-in agent producer, written as its
    /// ingress commit writes it, and folded into the roster.
    fn agent_event(&mut self, tx: &Transaction<'_>) -> anyhow::Result<()> {
        let index = (self.written.agent_events % AGENT_TERMINALS as u64) as usize;
        let mut lane = self.lanes[index].clone();
        let session = match &lane.session {
            Some(session) => session.clone(),
            None => {
                lane.sessions += 1;
                let session = format!("synth-agent-{index}-{}", lane.sessions);
                lane.session = Some(session.clone());
                lane.step = 0;
                session
            }
        };
        let last_step = 1 + TURNS_PER_SESSION * 2;
        let (kind, native_event) = match lane.step {
            0 => ("agent.session.started", "SessionStart"),
            step if step == last_step => ("agent.session.ended", "SessionEnd"),
            step if step % 2 == 1 => ("agent.turn.started", "UserPromptSubmit"),
            _ => ("agent.turn.completed", "Stop"),
        };
        if lane.step == last_step {
            lane.session = None;
        } else {
            lane.step += 1;
        }
        let ingress = JournalIngress {
            producer_id: crate::agent_hooks::AGENT_HOOK_PRODUCER_ID.into(),
            manifest_version: crate::agent_hooks::AGENT_HOOK_MANIFEST_VERSION,
            kind: kind.into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: vec![JournalSubject { kind: "terminal".into(), id: lane.terminal.clone() }],
            sensitivity: None,
            payload: json!({
                "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
                "adapter": {"id": "claude", "version": 1},
                "native_event": native_event,
                "normalized": {"agent_session_id": session},
                "native": {"session_id": session, "cwd": format!("/home/synth/project-{index}")},
            }),
            causation_id: None,
            correlation_id: None,
        };
        let validated = self.kernel.validate_ingress(&ingress)?;
        let mut subjects = BTreeSet::from([
            JournalSubject { kind: "session".into(), id: transaction_session_id(tx)? },
            JournalSubject { kind: "producer".into(), id: ingress.producer_id.clone() },
        ]);
        subjects.extend(ingress.subjects.iter().cloned());
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
        let correlation = format!("synth-agent-{}", self.written.agent_events);
        let sequence = append_journal_record(
            tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: ingress.schema_version,
                kind,
                class: validated.class,
                replay: validated.replay,
                occurred_at_ms: super::session_journal::unix_epoch_ms()?,
                producer: &producer,
                authority: Some(&authority),
                causation_id: None,
                correlation_id: Some(&correlation),
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
        // Fold the record as the daemon decodes it.
        let page = query_session_journal_after(tx, sequence - 1, 1)?;
        let record = page.records.first().context("the appended agent record reads back")?;
        self.roster.apply(&RosterEvent::from_record(record));
        self.lanes[index] = lane;
        self.written.agent_events += 1;
        Ok(())
    }

    /// One legacy `terminal.output` row, as older builds journaled output.
    fn output(&mut self, tx: &Transaction<'_>) -> anyhow::Result<()> {
        let index = (self.written.output_rows % AGENT_TERMINALS as u64) as usize;
        let mut bytes = Vec::with_capacity(OUTPUT_CHUNK_BYTES as usize);
        while (bytes.len() as u64) < OUTPUT_CHUNK_BYTES {
            bytes.extend_from_slice(
                format!("{:016x} synth output\r\n", self.next_random()).as_bytes(),
            );
        }
        bytes.truncate(OUTPUT_CHUNK_BYTES as usize);
        let lane = &mut self.lanes[index];
        let start = lane.output_offset;
        let end = start + bytes.len() as u64;
        lane.output_offset = end;
        let terminal = lane.terminal.clone();
        let subjects = vec![
            JournalSubject { kind: "session".into(), id: transaction_session_id(tx)? },
            JournalSubject { kind: "terminal".into(), id: terminal.clone() },
        ];
        let producer = JournalProducer { kind: "terminal_runtime".into(), id: terminal.clone() };
        let authority = JournalAuthority {
            principal_id: "cmux.terminal-runtime".into(),
            lease_id: format!("terminal:{terminal}"),
            generation: "synth".into(),
            role: "terminal.runtime".into(),
        };
        let payload = json!({
            "format": "cmux.terminal-output.v1",
            "encoding": "raw",
            "byte_count": bytes.len().to_string(),
            "sha256": Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect::<String>(),
            "stream_offset_start": start.to_string(),
            "stream_offset_end": end.to_string(),
        });
        let event_id = random_event_id("terminal");
        append_journal_record(
            tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "terminal.output",
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: super::session_journal::unix_epoch_ms()?,
                producer: &producer,
                authority: Some(&authority),
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &payload,
                content: Some(&bytes),
                resource_revision: None,
                previous_resource_revision: None,
                actor: None,
            },
        )?;
        self.written.output_rows += 1;
        Ok(())
    }

    /// Each terminal's output stream end, as the journal writer keeps it.
    fn save_output_offsets(&self, tx: &Transaction<'_>) -> anyhow::Result<()> {
        for lane in self.lanes.iter().filter(|lane| lane.output_offset > 0) {
            tx.execute(
                "INSERT INTO journal_terminal_streams(terminal_id, generation, next_offset)
                 VALUES(?1, 'synth', ?2)
                 ON CONFLICT(terminal_id, generation) DO UPDATE SET
                   next_offset = excluded.next_offset",
                params![lane.terminal, i64::try_from(lane.output_offset)?],
            )?;
        }
        Ok(())
    }

    /// Write the roster snapshot at the journal head with `version`.
    /// Returns the cursor and the live entries.
    fn save_roster(&self, version: u32) -> anyhow::Result<(u64, usize)> {
        let connection = self.connection()?;
        let head = query_journal_head(connection)?;
        write_journal_reducer_state(
            connection,
            AGENT_ROSTER_REDUCER_ID,
            version,
            head,
            &self.roster.snapshot().to_string(),
        )?;
        Ok((head, self.roster.entries.len()))
    }
}

/// A capability list of about 2 KiB, as a current daemon advertises.
fn capabilities() -> Value {
    Value::Array(
        (0..96).map(|index| Value::String(format!("synth.capability-{index:04}"))).collect(),
    )
}

fn transaction_session_id(tx: &Transaction<'_>) -> anyhow::Result<String> {
    tx.query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| row.get(0))
        .context("read the registry's session id")
}

/// The registry file of `session` below `state_root`.
pub fn registry_path(state_root: &Path, session: &str) -> PathBuf {
    persistent_session_state_dir(state_root, session).join(WORKSPACE_REGISTRY_FILE)
}

#[cfg(test)]
#[path = "synth_tests.rs"]
mod tests;
