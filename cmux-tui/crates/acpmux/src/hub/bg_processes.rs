//! The daemon's own background tasks (`_acpmux/bg/start`) as process-registry rows.
//!
//! A Claude `run_in_background` Bash call becomes such a task (`bg_hook.rs` rewrites it to
//! `acpmux process start`), so its shell never reaches Claude Code's `background_task_update`
//! and the registry, which the composer hat reads, never showed it: the hat said nothing while
//! the chat's background work ran. Each task is a row of origin [`DAEMON_TASK`], written as a
//! `process_update` when it starts and when its end is seen (its lock watch, a list, a stop),
//! and stopped through `_acpmux/bg/stop`. It outlives the harness, so a harness exit loses none.

use super::*;
use crate::bg_run::{self, Record};
use crate::hub::bg_tasks::{bg_generation, bg_gone};

/// The `origin` of a daemon task's row.
pub(in crate::hub) const DAEMON_TASK: &str = "daemon_task";

/// A signal number as its name (`SIGTERM`), or the number when it has none here.
fn signal_name(n: i32) -> String {
    let name = match n {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        _ => return n.to_string(),
    };
    name.to_owned()
}

impl Process {
    /// Task `record`'s row. `gone`: its runner is surely gone, so one with no end recorded is
    /// `lost`. `person`: a person stopped it (`_acpmux/process/kill`).
    fn of_bg_task(session: &Session, record: &Record, gone: bool, person: bool) -> Process {
        let ended = record.ended_at.is_some() || gone;
        let state = if record.ended_at.is_none() {
            if gone { ProcessState::Lost } else { ProcessState::Running }
        } else if record.stopped {
            ProcessState::Killed
        } else if record.exit_code == Some(0) {
            ProcessState::Exited
        } else {
            ProcessState::Failed
        };
        let reason = match state {
            ProcessState::Killed => Some(if person { "person" } else { "agent" }.to_owned()),
            ProcessState::Lost => Some("runner_gone".to_owned()),
            _ => None,
        };
        Process {
            id: format!("{}/{}", session.id, record.id),
            session_id: session.id.clone(),
            subagent_session_id: None,
            workflow_agent_id: None,
            tool_call_id: record.id.clone(),
            task_id: record.id.clone(),
            harness: crate::web_modes::family_of(&session.meta()),
            command: record.command.clone(),
            description: record.description.clone(),
            cwd: record.cwd.clone(),
            started_at: record.started_at,
            ended_at: if ended {
                Some(record.ended_at.unwrap_or_else(crate::store::now_ms))
            } else {
                None
            },
            state,
            exit_code: record.exit_code.map(i64::from),
            signal: record.signal.map(signal_name),
            reason,
            detail: None,
            origin: DAEMON_TASK.to_owned(),
            output_bytes: None,
            output_file: None,
            preview: None,
            logged: true,
        }
    }
}

impl Hub {
    /// Task `record` of `session` as its registry row: written as a `process_update` (and pushed
    /// to the chat's clients) when it changed, never twice for one state, so its start, every
    /// watch that sees its end, a list and a stop may all call it.
    pub(in crate::hub) fn note_bg_task(&self, session: &Session, record: &Record) {
        let dir = self.bg_dir(session);
        // A runner that outlived a purge writes into no later chat of this id.
        if bg_generation(&dir, false).ok().as_deref() != Some(record.generation.as_str()) {
            return;
        }
        let gone = record.ended_at.is_none() && bg_gone(&dir, &record.id);
        self.note_bg_row(session, record, gone);
    }

    fn note_bg_row(&self, session: &Session, record: &Record, gone: bool) {
        let changed = {
            let mut table = self.process_table(session);
            let id = format!("{}/{}", session.id, record.id);
            let person = table.stopping.contains(&id);
            let mut process = Process::of_bg_task(session, record, gone, person);
            // An end seen once keeps its stamp: a lost task's end is when it was first seen.
            if let Some(old) = table.find_id(&id)
                && old.state != ProcessState::Running
                && process.state == old.state
            {
                process.ended_at = old.ended_at;
            }
            if table.find_id(&id) == Some(&process) {
                None
            } else {
                if process.state != ProcessState::Running {
                    table.stopping.remove(&id);
                }
                table.upsert(process.clone());
                Some(process)
            }
        };
        if let Some(process) = changed {
            self.append(session, "mux", "process_update", json!({"process": process}));
        }
    }

    /// Before a list: each daemon task the registry still shows running is read again, so one
    /// that ended unwatched (a task that asked no notice and ended while no daemon ran, or a
    /// runner killed with its lock) shows its end. Reads only the running rows.
    pub(in crate::hub) fn bg_rows_settle(&self, session: &Session) {
        let running: Vec<String> = {
            let table = self.process_table(session);
            table
                .running
                .iter()
                .filter_map(|&i| table.processes.get(i))
                .filter(|p| p.origin == DAEMON_TASK)
                .map(|p| p.task_id.clone())
                .collect()
        };
        if running.is_empty() {
            return;
        }
        let dir = self.bg_dir(session);
        for id in running {
            match bg_run::read_record(&dir, &id) {
                Some(record) => self.note_bg_task(session, &record),
                // Its record is gone (the chat's folder was cleared): the task is too.
                None => {
                    let row = self
                        .process_table(session)
                        .find_id(&format!("{}/{id}", session.id))
                        .cloned();
                    if let Some(mut row) = row {
                        row.state = ProcessState::Lost;
                        row.ended_at = Some(crate::store::now_ms());
                        row.reason = Some("runner_gone".to_owned());
                        self.process_table(session).upsert(row.clone());
                        self.append(session, "mux", "process_update", json!({"process": row}));
                    }
                }
            }
        }
    }

    /// The task behind row `id` (`<session>/<task>`) of `session`, if it is a daemon task's.
    pub(in crate::hub) fn bg_row_task(&self, session: &Session, id: &str) -> Option<String> {
        let table = self.process_table(session);
        let p = table.find_id(id)?;
        (p.origin == DAEMON_TASK).then(|| p.task_id.clone())
    }
}
