//! MEASURE, NOT FOR A MERGE. The commits of the registry's file and their WAL
//! frames by the name of their writer (`server-stats`
//! `write_path.commits_by_writer`), for a flow of agents and of a person on a
//! small store.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The row
//! reads the section as a client does (its JSON) after each step of the flow
//! and prints the writers whose row moved, with the journal rows that the
//! step added by kind. Under each step: one line for each commit that the
//! step put in the WAL file, in the WAL's order, with its frames by the
//! b-tree of their page (`dbstat`, read after the step).
//!
//! The flow: 2 agents with hooks (a session's start, a turn's start, 2 tools,
//! one of them with a permission request, the turn's end, the session's end);
//! 2 agents that a screen plugin reports; 1 agent that reports through the
//! socket; a person's creates and closes (a workspace with a terminal, 2
//! splits, a tab, an empty workspace); 2 hooks on a real terminal; a
//! notification with one read mark; a frontend's projection document.
//!
//! What the table leaves out:
//! - Each step ends with a settle of the roster's owner, which saves the
//!   roster's snapshot row at once. A daemon saves it each 512 journal rows
//!   or at its tick: the commits of `agent_roster_save` here are more than a
//!   daemon's for the same flow.
//! - The journal maintenance worker is stopped: it has no commit here.
//! - A small store's frames a commit are not a large store's: fuller pages
//!   split and rewrite more.
//! - A step that fails says so in its line and the flow goes on.
//!
//! It fails by design: its words are the result.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::agent_reports_at_rest::{Agent, kinds_after, session_with_terminals, tick};
use super::*;
use crate::mux::resource_content::without_crosscheck;

const PLUGIN: &str = "screen_table_test";
const WORKSPACES: usize = 60;
const FREE_PAGE: &str = "(no b-tree now: a free page)";
const WAL_HEADER: usize = 32;
const WAL_FRAME_HEADER: usize = 24;

/// The frames that the registry's WAL file holds now.
#[derive(Default)]
struct Wal {
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: Vec<u8>,
    /// Each frame of this WAL: its page number, and if it ends a commit.
    frames: Vec<(u32, bool)>,
}

/// Reads the WAL file: each frame after the header is 24 bytes and one page;
/// its first 4 bytes are the page's number, the next 4 are not zero in the
/// last frame of a commit, and bytes 8 to 16 are the salts of the header.
fn read_wal(mux: &Mux) -> Wal {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let mut path = database.as_os_str().to_owned();
    path.push("-wal");
    let bytes = std::fs::read(&path).unwrap_or_default();
    let Some(header) = bytes.get(..WAL_HEADER) else { return Wal::default() };
    let page = u32::from_be_bytes(header[8..12].try_into().unwrap()) as usize;
    if page == 0 {
        return Wal::default();
    }
    let salts = header[16..24].to_vec();
    let mut frames = Vec::new();
    for frame in bytes[WAL_HEADER..].chunks_exact(WAL_FRAME_HEADER + page) {
        if frame[8..16] != salts[..] {
            break;
        }
        let number = u32::from_be_bytes(frame[..4].try_into().unwrap());
        frames.push((number, frame[4..8] != [0; 4]));
    }
    Wal { salts, frames }
}

/// The b-tree of each page of the registry, by `dbstat`.
fn page_trees(mux: &Mux) -> BTreeMap<u32, String> {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let reader = crate::workspace_registry::open_registry_database_read_only(database).unwrap();
    let mut statement = reader.prepare("SELECT pageno, name, pagetype FROM dbstat").unwrap();
    let pages = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .unwrap()
        .map(|row| {
            let (page, name, kind) = row.unwrap();
            let tree = if kind == "overflow" { format!("{name} (overflow)") } else { name };
            (u32::try_from(page).unwrap(), tree)
        })
        .collect::<BTreeMap<_, _>>();
    pages
}

/// One line for each commit of `frames`, in the WAL's order: its frames by
/// the b-tree of their page.
fn commit_lines(frames: &[(u32, bool)], trees: &BTreeMap<u32, String>) -> Vec<String> {
    let mut lines = Vec::new();
    let mut by_tree = BTreeMap::<&str, usize>::new();
    let mut count = 0;
    for (page, ends_a_commit) in frames {
        *by_tree.entry(trees.get(page).map_or(FREE_PAGE, String::as_str)).or_default() += 1;
        count += 1;
        if *ends_a_commit {
            lines.push(format!("    COMMIT {}: {count} frames: {by_tree:?}", lines.len() + 1));
            by_tree.clear();
            count = 0;
        }
    }
    if count > 0 {
        lines.push(format!("    {count} frames with no commit mark: {by_tree:?}"));
    }
    lines
}

/// The section's rows: writer -> (commits, WAL frames).
type Rows = BTreeMap<String, (u64, u64)>;

/// The `write_path` section as a client reads it.
fn section(mux: &Mux) -> Value {
    serde_json::to_value(mux.write_path_stats()).unwrap()
}

fn rows_of(section: &Value) -> Rows {
    section["commits_by_writer"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| {
            (
                row["writer"].as_str().unwrap_or_default().to_owned(),
                (row["commits"].as_u64().unwrap_or(0), row["wal_frames"].as_u64().unwrap_or(0)),
            )
        })
        .collect()
}

/// Commits, frames and the frames of one commit (cut to 1 decimal).
fn cost(commits: u64, frames: u64) -> String {
    if commits == 0 {
        return format!("0 commits, {frames} frames");
    }
    let tenths = frames * 10 / commits;
    format!("{commits} commits, {frames} frames, {}.{} frames a commit", tenths / 10, tenths % 10)
}

/// The writers whose row moved from `before` to `after`.
fn moved(before: &Rows, after: &Rows) -> String {
    let words = after
        .iter()
        .filter_map(|(writer, &(commits, frames))| {
            let (commits_before, frames_before) = before.get(writer).copied().unwrap_or((0, 0));
            let (commits, frames) = (commits - commits_before, frames - frames_before);
            (commits > 0 || frames > 0).then(|| format!("{writer} {}", cost(commits, frames)))
        })
        .collect::<Vec<_>>();
    if words.is_empty() { "no commit".to_owned() } else { words.join("; ") }
}

/// Nothing for a step that did its work, the error's words for one that did
/// not.
fn note<T, E: std::fmt::Debug>(result: Result<T, E>) -> String {
    match result {
        Ok(_) => String::new(),
        Err(error) => format!(" (FAILED: {error:?})"),
    }
}

/// Keeps a terminal that a create made.
fn keep(made: &mut Vec<Arc<Surface>>, result: anyhow::Result<Arc<Surface>>) -> String {
    match result {
        Ok(surface) => {
            made.push(surface);
            String::new()
        }
        Err(error) => format!(" (FAILED: {error:?})"),
    }
}

/// The flow's lines: the section's rows and the journal's head after the
/// step before.
struct Table<'a> {
    mux: &'a Arc<Mux>,
    rows: Rows,
    head: u64,
    /// The WAL after the step before: its salts and the count of its frames.
    wal: (Vec<u8>, usize),
    lines: Vec<String>,
}

impl<'a> Table<'a> {
    fn new(mux: &'a Arc<Mux>) -> Self {
        settled(mux);
        let wal = read_wal(mux);
        Table {
            mux,
            rows: rows_of(&section(mux)),
            head: mux.session_journal_head().unwrap(),
            wal: (wal.salts, wal.frames.len()),
            lines: Vec::new(),
        }
    }

    /// Runs one step of the flow, lets the roster's owner settle, and writes
    /// the step's line.
    fn step(&mut self, name: &str, act: impl FnOnce() -> String) {
        let failure = act();
        settled(self.mux);
        let now = rows_of(&section(self.mux));
        let head = self.mux.session_journal_head().unwrap();
        let kinds = kinds_after(self.mux, self.head);
        let wal = read_wal(self.mux);
        let same_wal = wal.salts == self.wal.0 && wal.frames.len() >= self.wal.1;
        let frames = if same_wal { &wal.frames[self.wal.1..] } else { &wal.frames[..] };
        let again = if same_wal { "" } else { " | THE WAL STARTED AGAIN: its frames from there" };
        self.lines.push(format!(
            "STEP {name}{failure}: {} | journal rows: {kinds:?}{again}",
            moved(&self.rows, &now)
        ));
        self.lines.extend(commit_lines(frames, &page_trees(self.mux)));
        self.rows = now;
        self.head = head;
        self.wal = (wal.salts, wal.frames.len());
    }
}

/// One hook of the agent session `session` on `terminal`, through the journal
/// ingress path, as its hook helper sends it.
fn hook(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    session: &str,
    event: &str,
    mut native: Value,
) -> String {
    native["session_id"] = json!(session);
    native["cwd"] = json!("/srv/project");
    let ingress = match crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    ) {
        Ok(ingress) => ingress,
        Err(error) => return format!(" (NOT SENT: {error:?})"),
    };
    let key = format!("writer-table-{}", crate::workspace_registry::new_uuid_v4());
    note(mux.append_journal_ingress(&ingress, "test", &key))
}

fn put_plugin_manifest(mux: &Mux) {
    let event = |name: &str| crate::JournalEventSchema {
        kind: format!("plugin.{PLUGIN}.agent.{name}"),
        schema_version: 1,
        class: crate::JournalClass::State,
        replay: crate::JournalReplayPolicy::Advisory,
        sensitivity: crate::JournalSensitivity::Metadata,
        payload_schema: json!({"type":"object"}),
    };
    let manifest = crate::JournalProducerManifest {
        producer_id: PLUGIN.into(),
        namespace: format!("plugin.{PLUGIN}"),
        manifest_version: 1,
        max_sensitivity: crate::JournalSensitivity::Metadata,
        permissions: vec![format!("journal.append.plugin.{PLUGIN}")],
        events: vec![event("state.changed"), event("session.ended")],
    };
    mux.put_journal_producer(&manifest, "test", "screen-table-manifest").unwrap();
}

/// One report of the screen plugin about the agent process `pid` on `agent`'s
/// terminal, observed now, through the journal ingress the plugin's
/// `session.journal.append` reaches.
fn screen(mux: &Arc<Mux>, agent: &Agent, state: &str, pid: usize) -> String {
    let ingress = crate::JournalIngress {
        producer_id: PLUGIN.into(),
        manifest_version: 1,
        kind: format!("plugin.{PLUGIN}.agent.state.changed"),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![crate::JournalSubject {
            kind: "terminal".into(),
            id: agent.terminal.to_string(),
        }],
        sensitivity: None,
        payload: json!({
            "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
            "plugin": {"id": PLUGIN, "version": 1},
            "adapter": {"id": "claude", "version": 1},
            "event": "state.changed",
            "normalized": {
                "state": state,
                "source_session": format!("pid:{pid}"),
                "observed_at_ms": crate::workspace_registry::unix_epoch_ms().unwrap().to_string(),
                "plugin_generation": "1",
            },
            "native": {"visible": {"blocker": state == "blocked"}},
        }),
        causation_id: None,
        correlation_id: None,
    };
    let key = format!("writer-table-screen-{}", crate::workspace_registry::new_uuid_v4());
    note(mux.append_journal_ingress(&ingress, "screen", &key))
}

/// The hooks of one session of an agent: its start, one turn with 2 tools
/// (the second one asks for a permission), and its end.
fn hooks_of_a_session() -> Vec<(&'static str, Value)> {
    vec![
        ("SessionStart", json!({})),
        ("UserPromptSubmit", json!({ "prompt": "go on" })),
        ("PreToolUse", json!({ "tool_name": "Read" })),
        ("PostToolUse", json!({ "tool_name": "Read" })),
        ("PermissionRequest", json!({ "tool_name": "Bash" })),
        ("PostToolUse", json!({ "tool_name": "Bash" })),
        ("Stop", json!({})),
        ("SessionEnd", json!({})),
    ]
}

#[test]
fn the_commits_and_the_frames_of_each_writer_in_a_flow_of_agents() {
    let root = std::env::temp_dir()
        .join(format!("cmux-writer-table-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_terminals(WORKSPACES, &root);
    put_plugin_manifest(&mux);
    let fold = mux.workspace_registry.lock().unwrap().public_fold_complete_for_test();
    let mut table = Table::new(&mux);
    let setup = table.rows.clone();

    for (index, agent) in agents.iter().take(2).enumerate() {
        let session = format!("writer-table-session-{index}");
        for (event, native) in hooks_of_a_session() {
            let tool = native["tool_name"].as_str().map(|tool| format!(" of {tool}"));
            tick();
            table.step(&format!("hook agent {index}: {event}{}", tool.unwrap_or_default()), || {
                hook(&mux, &agent.terminal, &session, event, native)
            });
        }
    }

    for (index, agent) in agents.iter().skip(20).take(2).enumerate() {
        for state in ["working", "blocked", "working", "idle"] {
            tick();
            table.step(&format!("plugin agent {index}: {state}"), || {
                screen(&mux, agent, state, 4000 + index)
            });
        }
    }

    for (state, name) in [(AgentState::Working, "working"), (AgentState::Idle, "idle")] {
        let agent = &agents[40];
        tick();
        table.step(&format!("socket agent: {name}"), || {
            note(mux.report_agent(
                agent.surface,
                state,
                AgentSource::Socket,
                Some("writer-table-socket".into()),
            ))
        });
    }

    let mut made: Vec<Arc<Surface>> = Vec::new();
    table.step("create: a workspace with a terminal (the first create)", || {
        keep(
            &mut made,
            without_crosscheck(|| mux.new_workspace(Some("made".into()), Some((80, 24)))),
        )
    });
    let pane = made.first().and_then(|surface| mux.with_state(|state| state.pane_of(surface.id)));
    if let Some(pane) = pane {
        for round in 1..=2 {
            table.step(&format!("create: split {round} of that terminal's pane"), || {
                keep(&mut made, without_crosscheck(|| mux.split(pane, SplitDir::Down, None)))
            });
        }
        table.step("create: a tab in that pane", || {
            keep(&mut made, without_crosscheck(|| mux.new_tab(Some(pane), None, Some((80, 24)))))
        });
    }
    table.step("create: a second workspace with a terminal", || {
        keep(
            &mut made,
            without_crosscheck(|| mux.new_workspace(Some("more".into()), Some((80, 24)))),
        )
    });

    let mut empty = None;
    table.step("create: an empty workspace", || {
        match mux.create_empty_workspace(Some("empty".into()), None, None) {
            Ok(placement) => {
                empty = Some(placement.workspace);
                String::new()
            }
            Err(error) => format!(" (FAILED: {error:?})"),
        }
    });
    if let Some(empty) = empty {
        table.step("close: the empty workspace", || {
            if without_crosscheck(|| mux.close_workspace(empty)) {
                String::new()
            } else {
                " (FAILED: it did not close)".to_owned()
            }
        });
    }

    let real = made.first().and_then(|surface| surface.terminal_public_id().cloned());
    if let Some(real) = &real {
        for (event, native) in hooks_of_a_session().into_iter().take(2) {
            tick();
            table.step(&format!("hook on the first real terminal: {event}"), || {
                hook(&mux, real, "writer-table-real", event, native)
            });
        }
    }

    if let Some(surface) = made.first().map(|surface| surface.id) {
        table.step("notification: a post on the first real terminal", || {
            note(mux.post_notification(
                "one".into(),
                "".into(),
                NotificationLevel::Info,
                Some(surface),
            ))
        });
        let newest = mux.resource_notifications(16).first().map(|row| row.id.clone());
        if let Some(newest) = newest {
            table.step("notification: the read mark of one client", || {
                let mutation = WorkspaceMutation::daemon("writer-table-ack", "test").unwrap();
                note(mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&newest)))
            });
        }
    }

    table.step("frontend projection: the put of a new document", || {
        let mutation = WorkspaceMutation::daemon("writer-table-projection", "test").unwrap();
        note(mux.put_frontend_projection(
            &mutation,
            "writer-table",
            "session",
            "catalog",
            1,
            Some(0),
            &json!({ "rows": [] }),
        ))
    });

    // The terminal made last closes; the others end with the session.
    let closed = made.pop();
    if let Some(surface) = &closed {
        table.step("close: the terminal made last", || {
            note(without_crosscheck(|| mux.close_surface(surface.id)))
        });
    }

    let Table { rows: end, lines: steps, .. } = table;
    let all = section(&mux);
    let commits: u64 = end.values().map(|row| row.0).sum();
    let frames: u64 = end.values().map(|row| row.1).sum();
    let mut lines = vec![
        format!(
            "THE STORE: {WORKSPACES} workspaces, {} seeded terminals, the public fold complete \
             before the flow: {fold}",
            agents.len()
        ),
        format!(
            "THE TOTALS from the daemon's start: wal_commits {} (the rows' sum {commits}), \
             registry_wal_frame_bytes {} (the rows' frames {frames})",
            all["wal_commits"], all["registry_wal_frame_bytes"]
        ),
    ];
    lines.extend(steps);
    for (writer, &(commits, frames)) in &end {
        let (commits_before, frames_before) = setup.get(writer).copied().unwrap_or((0, 0));
        lines.push(format!(
            "WRITER {writer}: in the flow {} | from the daemon's start {}",
            cost(commits - commits_before, frames - frames_before),
            cost(commits, frames)
        ));
    }
    let table = lines.join("\n");
    eprintln!("{table}");

    for surface in made {
        surface.kill();
    }
    drop(closed);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    panic!("MEASURE (it fails by design):\n{table}");
}
