//! The respawn worker: one thread per respawn try. It waits out the try's
//! backoff, takes its turn in the respawn gate, runs the try (`Mux::run_terminal_respawn`), gives the turn
//! back, then does what is left with no turn: the wait for the new shell's
//! prompt and the pre-fill (`prefill.rs`), or the start of the next try
//! after a failed launch (`retry.rs`).

use super::*;

impl Mux {
    /// Start the worker of `plan`, with no lock held. Every respawn runs it:
    /// the respawn of a lost host, a restart the person or a frontend asked
    /// for (`restart-tab`, `manual.rs`: Restart Shell Here, and each kept
    /// tab of a restored session), the shell of an `on_exit` shell terminal,
    /// and the next try after a failed launch (`retry.rs`).
    ///
    /// A restart used to run at once on its own thread, outside the gate. A
    /// frontend restarts every kept tab at its connect: 170 launches began in
    /// the same 30 ms, competed with the person's terminal for the CPU, and
    /// macOS refused some of their PTY opens.
    pub(in crate::mux) fn spawn_respawn_worker(mux: Arc<Self>, plan: RespawnPlan) {
        let terminal_id = plan.terminal_id.clone();
        // A first attempt takes its place in line here, on the scheduling
        // thread, so the order is the order of scheduling (the visible
        // workspace first at a start). A try after a backoff takes its
        // place on its worker, when the backoff is over: it must not hold
        // the line for its delay.
        let ticket = plan.delay.is_zero().then(|| mux.respawn_gate.ticket());
        // A respawn that starts at once is sized into the Kitty budget now:
        // its reservation then never waits for another respawn's launch.
        // One after a backoff is not: it would shrink running terminals for
        // the length of the backoff.
        let kitty_expectation = plan
            .delay
            .is_zero()
            .then(|| mux.expect_kitty_image_respawn(plan.old_runtime.as_ref(), plan.slot));
        let gate = mux.respawn_gate.clone();
        let kind = if plan.user_restart { "restart" } else { "respawn" };
        let name = format!("terminal-{kind}-{terminal_id}");
        let worker = Arc::clone(&mux);
        let spawned = std::thread::Builder::new().name(name).spawn(move || {
            let mux = worker;
            let stopping =
                || mux.shutting_down.load(Ordering::Acquire) || mux.session_shutdown.began();
            // A terminal the person sees (shown when it took its place,
            // selected while it waits, or lost while hidden respawns still
            // wait) or asked for (`RespawnPlan::asked`) does not wait for the
            // hidden ones in line or for their turns to end. The slots still
            // bound such terminals among themselves.
            let asked = plan.asked;
            let shown_now = || asked || mux.respawn_slot_shown(plan.slot);
            // A try after a backoff waits it out with no place in the line,
            // then takes its place at the end, as a try with no wait does.
            // It used to take no turn at all: it launched when its wait
            // ended, beside the launches that had the turns, so more shells
            // started at one time than the gate has slots.
            let ticket = match ticket {
                Some(ticket) => ticket,
                None if mux.wait_respawn_backoff(plan.delay) => gate.ticket(),
                None => {
                    mux.abandon_terminal_respawn(&plan.terminal_id);
                    return;
                }
            };
            let Some(turn) = gate.turn_first_if(ticket, stopping, shown_now) else {
                mux.abandon_terminal_respawn(&plan.terminal_id);
                return;
            };
            // The hold of a test (`CMUX_TUI_TEST_RESPAWN_DELAY_MS`) is inside
            // the turn. A backoff counts as a part of it, as before.
            let hold = mux.terminal_respawns.delay.unwrap_or_default().saturating_sub(plan.delay);
            let after = if mux.wait_respawn_backoff(hold) {
                mux.run_terminal_respawn(plan)
            } else {
                mux.abandon_terminal_respawn(&plan.terminal_id);
                AfterTurn::Nothing
            };
            // The turn and the Kitty expectation are given back here, before
            // what is left. The wait for the new shell's prompt (10 s and
            // more, `prefill.rs`) held the turn: the terminals of a restored
            // session came back a few at a time, each wave a prompt wait
            // after the one before. The next try of a failed launch takes
            // its own turn and expectation.
            drop(turn);
            drop(kitty_expectation);
            match after {
                AfterTurn::Nothing => {}
                AfterTurn::Prefill(surface, prefill) => prefill.type_on_prompt(&surface),
                AfterTurn::Again(again) => Self::spawn_respawn_worker(Arc::clone(&mux), *again),
            }
        });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no thread to respawn terminal {terminal_id}: {error}");
            // The plan marked it respawning: take the mark back, so the tab
            // shows its end and nothing waits on a respawn that never runs.
            mux.abandon_terminal_respawn(&terminal_id);
        }
    }
}
