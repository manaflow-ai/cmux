//! Part of `Hub`; see `hub/mod.rs`. A chat whose agent host is below this build's level moves onto
//! the installed build at its next idle point.
//!
//! An update swaps the daemon at once, while every agent host it adopts keeps the binary it
//! started from until its chat hibernates (`views/host_build.rs`), and a chat at work never
//! reaches the 2-minute idle period: its turns follow each other within it. So a fix that lives in
//! the host, as Claude Code's translator does, never reached the chats that needed it most: after
//! the next-prompt suggestions moved behind a person's own turn
//! (`claude_stdio/prompt_suggestions.rs`), 35 of 41 live hosts on one Mac and the busy lanes still
//! ran the build before it, and the team gateway still saw about 1,100 suggestions an hour (sr2
//! audit, 2026-11-21).
//!
//! A host whose record says a lower [`crate::agent_host::HOST_LEVEL`] (an older build's says none:
//! 0) and another build than the daemon's moves once its chat is idle for [`MOVE_AFTER`]: the
//! idle pass hibernates it as at the end of an idle period, under every gate of that pass (no
//! turn running or queued, no question, nothing at work below it, its process census clear), so
//! nothing is lost, and the next prompt resumes the chat (`claude --resume`) on a host of the
//! installed build. A census that finds a process the harness did not report keeps it up, and
//! the chat then waits for the normal idle period as before: such a process (a dev server) would
//! keep it up at every try. Each chat moves at most once per daemon run, so a wake that starts a
//! host below the level again (a launcher of an older binary) never makes it move at every idle
//! point. Nothing moves while idle hibernation is off (`ACPMUX_IDLE_CHILD_SECS=0`): an agent the
//! daemon is told to keep, it keeps.
//!
//! A host on this build moves the same way when no daemon of this level started it and its chat
//! is no person's (`Hub::host_moves`): what a start asks of the agent is the daemon's to decide,
//! and an older daemon decided it for a host of the new binary while an update waited out its
//! restart window. Each start this daemon makes keeps its level in the chat's meta
//! (`SessionMeta::start_level`, `note_start_level`) for the next daemon.
//!
//! Who a start is for (`Hub::start_params`): Claude Code reads whether to suggest next prompts
//! once, at `initialize`, and honours the per-turn pause only under a server-side flag of its own
//! that is off by default, so the start is where suggestions are decided. A start for no person
//! asks for none.

use crate::hub::*;

/// `Session::start_for`: a person's start.
pub(super) const FOR_A_PERSON: u8 = 1;
/// `Session::start_for`: a start for no person.
pub(super) const FOR_NO_PERSON: u8 = 2;

/// `Session::start_for` of a start for queued prompt `run` (`provenance`: its turn's effective
/// one, `prompt_sender::person_turn`).
pub(super) fn start_for(run: &super::queue::PromptRun, provenance: Option<&Value>) -> u8 {
    if super::prompt_sender::person_turn(run, provenance) { FOR_A_PERSON } else { FOR_NO_PERSON }
}

/// `Session::start_for` of the first start of a chat that records no creator (`created_by.rs`:
/// an adopt, a move's target), which `person` (`NewRequest::person`) says the person asked for or
/// not. Counted as the person's before, so a lane's adopt (a failover, a successor) asked Claude
/// Code for a suggestion after every turn: on one lane Mac most chats made on 2026-11-20 and 21
/// had no creator (sr2 audit).
pub(super) fn start_for_creator(person: bool) -> u8 {
    if person { FOR_A_PERSON } else { FOR_NO_PERSON }
}

/// Whether a chat created by `created_by` (`person`: `NewRequest::person`) is the person's at
/// creation: the person made it, or it records no creator and the person asked for it. A pooled
/// Claude Code is taken only by such a chat (`lifecycle.rs` `shaped`): the pool started it for
/// the person, with suggestions, so a lane's chat that took one kept them for the process's life.
/// On two Cloud agent machines 81 of the chats scripts made had taken one (sr2 audit,
/// 2026-11-22: about 20 suggestions an hour through one team gateway).
pub(super) fn made_for_a_person(
    created_by: Option<&crate::store::CreatedBy>,
    person: bool,
) -> bool {
    match created_by {
        Some(c) => c.kind == crate::store::CreatorKind::Person,
        None => person,
    }
}

/// How long a chat whose host must move waits idle first: long enough that what follows its turn
/// (a queued notice, a script's next prompt) comes first, short against the idle period.
pub(super) const MOVE_AFTER: std::time::Duration = std::time::Duration::from_secs(10);

impl Hub {
    /// Whether the agent start of `session` beginning now is a person's: the chat on a person's
    /// screen (`seen.rs` `shown`), else what asked for it (`Session::start_for`): their own
    /// prompt, their typing or open (`wake_for`), a chat with no creator the person asked for
    /// (`start_for_creator`), else, for a start nothing marked (the one `session/new` makes),
    /// whoever created the chat (`created_by.rs`): the person, or one from before creators
    /// were kept (a fork the person made records none either); never an agent or a script.
    pub(super) fn for_a_person(&self, session: &Session) -> bool {
        if self.shown(session) {
            return true;
        }
        match session.start_for.load(Ordering::SeqCst) {
            FOR_A_PERSON => true,
            FOR_NO_PERSON => false,
            _ => session
                .meta()
                .created_by
                .as_ref()
                .is_none_or(|c| c.kind == crate::store::CreatorKind::Person),
        }
    }

    /// The `initialize` params of a start of `session`'s agent. One that is no person's asks
    /// Claude Code for no next-prompt suggestions (`prompt_suggestions::NO_SUGGESTIONS`): Claude Code honours the
    /// per-turn pause (`claude_stdio/prompt_suggestions.rs`) only under a server-side flag of its
    /// own, `tengu_chomp_sable`, off by default ("a CLI build where this is not yet enabled
    /// acknowledges and keeps generating"), and reads `promptSuggestions` once, at `initialize`:
    /// a later one only turns it on. So a process started for another agent's message, which no
    /// person reads, suggested a next prompt after every turn, about $0.10 each (sr2 audit,
    /// 2026-11-21: 1,022 an hour, 15:30-16:30Z, after both host fixes had reached the lanes). A
    /// process a person started keeps them for its whole life, agent turns included; one an
    /// agent started has none until it hibernates and a person's prompt, typing or open starts
    /// it again.
    pub(super) fn start_params(&self, session: &Session) -> Value {
        let mut params = super::pool::initialize_params();
        if !self.for_a_person(session) {
            params["_meta"] =
                json!({"acpmux": {crate::claude_stdio::prompt_suggestions::NO_SUGGESTIONS: true}});
        }
        params
    }

    /// Keeps in `session`'s meta (saved by the caller) that this daemon started `child`'s host
    /// at [`crate::agent_host::HOST_LEVEL`], when `asked_right`: its `initialize` asked what
    /// `start_params` asks for this chat. A pooled agent a chat takes started for the person
    /// (`pool/start.rs`), so it is right only for a person's chat. Nothing for an agent this
    /// daemon runs as its own child: no host outlives it.
    pub(super) fn note_start_level(
        &self,
        session: &Session,
        child: &ChildAgent,
        asked_right: bool,
    ) {
        let level =
            child.host_record().filter(|_| asked_right).map(|record| crate::store::StartLevel {
                incarnation: record.incarnation,
                level: crate::agent_host::HOST_LEVEL,
            });
        session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).start_level = level;
    }

    /// Whether `session`'s live host moves at its next idle point (module docs). False while a
    /// start or stop holds the child's slot. Also a host on this build that no daemon of this
    /// level started, for a chat that is no person's: during an update the new binary is in
    /// place up to an hour before the daemon restarts on it (`cli/host_update.rs`
    /// `RESTART_WINDOW_SECS`), and each host started meanwhile ran the new build but was asked,
    /// by the old daemon, for a next-prompt suggestion after every turn. Its record says this
    /// build's level, so it never moved: on one lane, starts with suggestions until 20:37Z,
    /// about 80 minutes after its new binary came (sr2 audit, 2026-11-21).
    pub(super) fn host_moves(&self, session: &Session) -> bool {
        let level = crate::agent_host::HOST_LEVEL;
        let (below, incarnation) = session
            .child
            .try_lock()
            .ok()
            .and_then(|child| {
                child
                    .as_ref()
                    .map(|c| (c.host_below(level), c.host_record().map(|r| r.incarnation)))
            })
            .unwrap_or((false, None));
        let started_below = || {
            incarnation.as_ref().is_some_and(|incarnation| {
                !session.read_meta(|m| {
                    m.start_level
                        .as_ref()
                        .is_some_and(|s| s.incarnation == *incarnation && s.level >= level)
                })
            }) && !self.for_a_person(session)
        };
        (below || started_below())
            && !self
                .host_moved
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(&session.id)
    }

    /// The idle period of `session`: [`MOVE_AFTER`] when its host moves, else `idle`.
    pub(super) fn idle_period(
        &self,
        session: &Session,
        idle: std::time::Duration,
    ) -> std::time::Duration {
        if self.host_moves(session) { MOVE_AFTER.min(idle) } else { idle }
    }

    /// `session`'s move is done or given up: it waits for the normal idle period from now on.
    pub(super) fn host_move_settled(&self, session: &Session) {
        self.host_moved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(session.id.clone());
    }
}
