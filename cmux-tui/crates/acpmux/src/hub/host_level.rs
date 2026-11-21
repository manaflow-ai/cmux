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

use crate::hub::*;

/// How long a chat whose host must move waits idle first: long enough that what follows its turn
/// (a queued notice, a script's next prompt) comes first, short against the idle period.
pub(super) const MOVE_AFTER: std::time::Duration = std::time::Duration::from_secs(10);

impl Hub {
    /// Whether `session`'s live host moves at its next idle point (module docs). False while a
    /// start or stop holds the child's slot.
    pub(super) fn host_moves(&self, session: &Session) -> bool {
        let below = session.child.try_lock().ok().is_some_and(|child| {
            child.as_ref().is_some_and(|c| c.host_below(crate::agent_host::HOST_LEVEL))
        });
        below
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

/// What the daemon last told a host below the level about next-prompt suggestions
/// ([`Hub::old_host_suggestions`]), for that host only (its start nonce).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Told {
    /// Turned off for a turn no person started; the chat's own pick is on.
    Off,
    /// The host refused the option or did not answer in time: never asked again.
    Refused,
}

/// How long a turn's prompt waits for a host below the level to take the option: Claude Code,
/// idle between turns, answers its control request at once.
const OPTION_ANSWER: std::time::Duration = std::time::Duration::from_secs(3);

/// The value to set the chat's `prompt-suggestions` option to on a host below the level before a
/// turn (`true`: on), or None when the host already has it. `pick`: the chat's own pick;
/// `person`: a person's own prompt starts the turn (`prompt_sender::person_turn`); `told`: what
/// this daemon last set on this host.
pub(super) fn suggestion_step(pick: bool, person: bool, told: Option<Told>) -> Option<bool> {
    // Off by the chat's own pick: the host has it off already, and keeps it so.
    if !pick || told == Some(Told::Refused) {
        return None;
    }
    let off = !person;
    (off != (told == Some(Told::Off))).then_some(!off)
}

impl Hub {
    /// Before a turn on a host below the level (its translator suggests a next prompt after every
    /// turn), what a host at the level does itself: Claude Code suggests one only after a
    /// person's own turn (`claude_stdio/prompt_suggestions.rs`). The chat's `prompt-suggestions`
    /// option, which every host since it came (2026-11-03) takes, goes off before any other
    /// turn and on again before the person's: its host pauses Claude Code's suggestions with it.
    /// That reaches a chat that never moves (always at work, or a process of its own under it),
    /// without a restart. The off is the daemon's, never the chat's pick: the chat's saved
    /// options keep the pick ([`Self::unpaused_options`]), and a person's own write of the option
    /// takes over ([`Self::person_set_suggestions`]).
    pub(super) async fn old_host_suggestions(
        &self,
        session: &Session,
        child: &crate::agent::ChildAgent,
        agent_sid: &str,
        person: bool,
    ) {
        if !child.host_below(crate::agent_host::HOST_LEVEL) {
            return;
        }
        let Some(nonce) = child.host_record().map(|r| r.start_nonce) else { return };
        let pick = {
            let meta = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if !crate::claude_stdio::steers_by_info(meta.agent_info.as_ref()) {
                return;
            }
            crate::claude_stdio::prompt_suggestions::chat_pick(
                super::model_options::current_option(
                    &meta,
                    crate::claude_stdio::prompt_suggestions::OPTION,
                ),
            )
        };
        let told = self.told_suggestions(&session.id, &nonce);
        let Some(on) = suggestion_step(pick, person, told) else { return };
        let params = json!({
            "sessionId": agent_sid,
            "configId": crate::claude_stdio::prompt_suggestions::OPTION,
            "value": if on { "on" } else { "off" },
        });
        let answer = child.request_within(
            crate::rpc::method::SESSION_SET_CONFIG_OPTION,
            params,
            OPTION_ANSWER,
        );
        let told = match answer.await {
            Some(Ok(_)) => (!on).then_some(Told::Off),
            Some(Err(e)) => {
                tracing::info!(session = %session.id, "old host refused prompt-suggestions: {}", e.message);
                Some(Told::Refused)
            }
            None => {
                tracing::warn!(session = %session.id, on, "old host did not take prompt-suggestions in time");
                Some(Told::Refused)
            }
        };
        let mut all =
            self.suggestions_told.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match told {
            Some(told) => all.insert(session.id.clone(), (nonce, told)),
            None => all.remove(&session.id),
        };
    }

    /// What this daemon last set on `session`'s host with start nonce `nonce`.
    fn told_suggestions(&self, session: &str, nonce: &str) -> Option<Told> {
        let all = self.suggestions_told.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        all.get(session).filter(|(n, _)| n == nonce).map(|(_, told)| *told)
    }

    /// A person (a client) writes `session`'s `prompt-suggestions` option: their value is the
    /// chat's pick from now on, and the daemon's own off is forgotten.
    pub(super) fn person_set_suggestions(&self, session: &Session, params: &Value) {
        if params.get("configId").and_then(Value::as_str)
            == Some(crate::claude_stdio::prompt_suggestions::OPTION)
        {
            self.suggestions_told
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&session.id);
        }
    }

    /// `options`, a host's config options for `session`, as the chat keeps them: while the
    /// daemon has turned suggestions off for a turn no person started, the option says the
    /// chat's pick (on), never that off.
    pub(super) fn unpaused_options(&self, session: &Session, mut options: Value) -> Value {
        let off = self
            .suggestions_told
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&session.id)
            .is_some_and(|(_, told)| *told == Told::Off);
        if off && let Some(list) = options.as_array_mut() {
            for option in list {
                if option.get("id").and_then(Value::as_str)
                    == Some(crate::claude_stdio::prompt_suggestions::OPTION)
                {
                    option["currentValue"] = json!("on");
                }
            }
        }
        options
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_old_host_is_off_for_every_turn_but_the_persons_and_never_against_the_chats_pick() {
        // The chat's pick on: off before an agent's turn, on again before the person's.
        assert_eq!(suggestion_step(true, false, None), Some(false));
        assert_eq!(suggestion_step(true, false, Some(Told::Off)), None, "already off");
        assert_eq!(suggestion_step(true, true, Some(Told::Off)), Some(true));
        assert_eq!(suggestion_step(true, true, None), None, "on already");
        // The chat's pick off, or a host that refused: nothing is sent.
        assert_eq!(suggestion_step(false, false, None), None);
        assert_eq!(suggestion_step(false, true, Some(Told::Off)), None);
        assert_eq!(suggestion_step(true, false, Some(Told::Refused)), None);
        assert_eq!(suggestion_step(true, true, Some(Told::Refused)), None);
    }
}
