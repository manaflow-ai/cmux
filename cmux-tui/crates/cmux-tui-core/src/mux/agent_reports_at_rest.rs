//! A socket agent report that changes no durable state is answered from memory.
//!
//! A socket reporter (`report-agent` with source `socket`, a poller) says the
//! terminal's state again and again. Two cases change nothing a reader keeps:
//!
//! - a stronger source (hook, plugin, detected) owns the terminal's record:
//!   the report is ignored, the record and the roster entry stay as they are;
//! - the record is the reporter's own and holds the same state and session:
//!   only the record's time moves, and for a socket entry no reader orders
//!   anything by that time but a later socket report, which is later anyway.
//!
//! Before, each such report took the registry lock twice and committed one
//! transaction (its mutation key), with no journal row. Now it takes neither:
//! the answer is the terminal's record from memory.
//!
//! A hook-source report equal to the record still commits and appends its
//! roster echo: the echo moves the roster entry's `updated_at_ms`, which
//! decides whether a plugin or screen observation may take a hook row
//! (`fresh_hook`, `journal_reducers.rs`). The resource `agent.report` keeps
//! its path too: its caller's mutation key needs a durable receipt.

use super::*;

impl Mux {
    /// The answer to a raw socket report that changes no durable state;
    /// `None` when the report must go to the registry (module doc). Memory
    /// only: no registry lock, no commit, no journal row.
    pub(super) fn answer_agent_report_at_rest(
        &self,
        surface: SurfaceId,
        agent_state: AgentState,
        source: AgentSource,
        session: Option<&str>,
    ) -> Option<AgentRecord> {
        if source != AgentSource::Socket || agent_state == AgentState::Done {
            return None;
        }
        // The registry path refuses a reserved hook marker.
        if session.is_some_and(|session| {
            session.starts_with("cmux-hook-sequence:") || session.starts_with("cmux-hook-ended:")
        }) {
            return None;
        }
        let terminal_id = {
            let state = self.state.lock().ok()?;
            let runtime =
                state.surfaces.get(&surface).or_else(|| state.terminal_runtime_by_id(surface))?;
            match &runtime.resource_identity()?.content_id {
                ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
                _ => return None,
            }
        };
        // A hook projection of the terminal waits for a retry, which the
        // registry path runs after the report.
        if self.agent_hook_projection_is_pending(&terminal_id) {
            return None;
        }
        // The lock order of the registry path: fences, then records.
        let fences = self.agent_hook_fences.lock().ok()?;
        let fence = fences.get(&terminal_id);
        // An ended hook session refuses or restarts on the registry path.
        if fence.is_some_and(|fence| fence.ended) {
            return None;
        }
        let mut records = self.agent_records.lock().ok()?;
        let existing = records.get_mut(&terminal_id)?;
        if existing.state == AgentState::Done {
            return None;
        }
        if existing.source == AgentSource::Socket {
            // With no session of its own, the stored projection names the
            // hook fence, which can have moved: the registry path decides.
            if existing.state != agent_state
                || existing.session.as_deref() != session
                || existing.agent_session_id.is_some()
                || (session.is_none() && fence.is_some())
            {
                return None;
            }
            // Live only: what a client lists now.
            existing.updated_at_ms = now_ms();
        }
        let record = existing.clone();
        drop(records);
        drop(fences);
        // Working or idle: the agent no longer waits on its question.
        if record.state != AgentState::Blocked {
            self.forget_agent_question(&terminal_id);
        }
        let last_prompt = self.agent_prompt(&terminal_id);
        Some(AgentRecord {
            surface,
            terminal_id,
            state: record.state,
            source: record.source,
            session: record.session,
            agent: record.agent,
            agent_session_id: record.agent_session_id,
            updated_at_ms: record.updated_at_ms,
            since_ms: record.since_ms,
            last_prompt,
        })
    }
}
