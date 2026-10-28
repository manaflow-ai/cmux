//! One adoption of a surviving terminal host, retried with backoff as work
//! items (`Mux::post_mux_retry_limited`, p02-threads 230).

use super::super::mux_work::Retry;
use super::super::*;
use super::AdoptionEnd;
use cmux_threads::work::{Lane, Priority};

impl Mux {
    /// Posts the adoption retry of `record`'s host; `end` ends the adoption
    /// when the retry ends, however it ends.
    pub(super) fn post_terminal_adoption(
        &self,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
        first_delay: Duration,
        end: AdoptionEnd,
    ) {
        let terminal_id = record.terminal_id.clone();
        let cleanup_id = terminal_id.clone();
        let mut delay = first_delay;
        let mut refusals = pending_terminals::RefusalStreak::default();
        let posted = self.post_mux_retry_limited(
            first_delay,
            Priority::UserVisible,
            Lane::System,
            (&self.terminal_replays, Some(Arc::from(terminal_id.as_str()))),
            move |mux| {
                let _end = &end;
                // Test hook (debug builds): each try holds its permit this
                // much longer, as a slow handshake and replay do.
                #[cfg(debug_assertions)]
                if let Some(hold) = std::env::var("CMUX_TUI_TEST_ADOPTION_TRY_HOLD_MS")
                    .ok()
                    .and_then(|ms| ms.parse::<u64>().ok())
                {
                    cmux_threads::work::will_block(|| {
                        crate::request_path::sleep(Duration::from_millis(hold));
                    });
                }
                let panic_log = options.host_panic_log.as_ref();
                // Retries back off from 100 ms, also after an immediate first try.
                delay = delay.max(Duration::from_millis(50));
                // A failed read proves nothing about the host: retry.
                let Ok(terminal) =
                    mux.workspace_registry.lock().unwrap().terminal_record(&terminal_id)
                else {
                    delay = (delay * 2).min(Duration::from_secs(5));
                    return Retry::After(delay);
                };
                let Some(terminal) = terminal else {
                    if cleanup_terminal_host_record(&record, &record_path, panic_log) {
                        return Retry::Done;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                    return Retry::After(delay);
                };
                if matches!(
                    terminal.lifecycle,
                    TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
                ) {
                    if terminal.lifecycle == TerminalLifecycle::Exited
                        && let Err(error) = mux.detach_exited_terminal_topology(&terminal_id)
                    {
                        eprintln!(
                            "cmux-tui: could not detach exited terminal \
                             {terminal_id}: {error:#}"
                        );
                        delay = (delay * 2).min(Duration::from_secs(5));
                        return Retry::After(delay);
                    }
                    if cleanup_terminal_host_record(&record, &record_path, panic_log) {
                        return Retry::Done;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                    return Retry::After(delay);
                }
                if terminal
                    .incarnation
                    .as_deref()
                    .is_some_and(|incarnation| incarnation != record.incarnation)
                {
                    if let Err(error) = mux.mark_terminal_ended(
                        &terminal_id,
                        "terminal-incarnation-mismatch",
                        "host-incarnation-mismatch",
                        &options,
                    ) {
                        eprintln!(
                            "cmux-tui: could not reconcile exited terminal \
                             {terminal_id}: {error:#}"
                        );
                        delay = (delay * 2).min(Duration::from_secs(5));
                        return Retry::After(delay);
                    }
                    if cleanup_terminal_host_record(&record, &record_path, panic_log) {
                        return Retry::Done;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                    return Retry::After(delay);
                }
                // Only a running row goes back to adopting: a launching one
                // belongs to a respawn, and its new host must not be dropped.
                if terminal.lifecycle == TerminalLifecycle::Running {
                    let already_live = mux
                        .resolve_terminal(&terminal_id)
                        .ok()
                        .flatten()
                        .is_some_and(|resolution| resolution.surface.is_some());
                    if already_live {
                        return Retry::Done;
                    }
                    if mux
                        .transition_terminal_lifecycle(
                            "terminal-adopting",
                            "retry-terminal-adoption",
                            &terminal_id,
                            TerminalLifecycle::Adopting,
                            Some(&record.incarnation),
                        )
                        .is_err()
                    {
                        return Retry::Done;
                    }
                }
                if terminal_host_record_liveness(&record_path, &record)
                    == TerminalHostLiveness::Dead
                {
                    super::deferred_end::end_hold_for_test();
                    if let Err(error) = mux.mark_terminal_ended(
                        &terminal_id,
                        "terminal-host-proven-dead",
                        "host-process-ended-before-adoption",
                        &options,
                    ) {
                        eprintln!(
                            "cmux-tui: could not reconcile exited terminal \
                             {terminal_id}: {error:#}"
                        );
                        delay = (delay * 2).min(Duration::from_secs(5));
                        return Retry::After(delay);
                    }
                    let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                        &record_path,
                        &record,
                        panic_log,
                    );
                    return Retry::Done;
                }
                let restored_binding = match mux.restored_terminal_binding(&terminal_id) {
                    Ok(binding) => binding,
                    Err(_) => {
                        delay = (delay * 2).min(Duration::from_secs(5));
                        return Retry::After(delay);
                    }
                };
                // The handshake and replay wait on the host (up to its
                // handshake timeout): outside the lane's limits.
                let adopted = cmux_threads::work::will_block(|| {
                    mux.adopt_restored_terminal(restored_binding, &options, &record, &record_path)
                });
                if mux.refused_all(
                    &mut refusals,
                    Instant::now(),
                    &adopted,
                    &options,
                    &record_path,
                    &record,
                ) {
                    return Retry::Done;
                }
                if let Ok(surface) = adopted {
                    if mux
                        .finish_terminal_adoption(
                            &terminal_id,
                            &record.incarnation,
                            surface.clone(),
                        )
                        .is_ok()
                    {
                        mux.ensure_template_adoption_completed(&terminal_id);
                        mux.reap_if_dead(&surface);
                        return Retry::Done;
                    }
                    let host_is_dead = surface.is_dead()
                        || terminal_host_record_liveness(&record_path, &record)
                            == TerminalHostLiveness::Dead;
                    surface.disconnect_for_daemon_shutdown();
                    if host_is_dead {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-adoption-failed",
                            "host-exited-during-adoption",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            return Retry::After(delay);
                        }
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                            panic_log,
                        );
                        return Retry::Done;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                    return Retry::After(delay);
                }
                if terminal_host_record_liveness(&record_path, &record)
                    == TerminalHostLiveness::Dead
                {
                    if let Err(error) = mux.mark_terminal_ended(
                        &terminal_id,
                        "terminal-host-proven-dead",
                        "host-process-ended-before-adoption",
                        &options,
                    ) {
                        eprintln!(
                            "cmux-tui: could not reconcile exited terminal \
                             {terminal_id}: {error:#}"
                        );
                        delay = (delay * 2).min(Duration::from_secs(5));
                        return Retry::After(delay);
                    }
                    let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                        &record_path,
                        &record,
                        panic_log,
                    );
                    return Retry::Done;
                }
                delay = (delay * 2).min(Duration::from_secs(5));
                Retry::After(delay)
            },
        );
        if posted.is_err() {
            self.clear_pending_terminal(&cleanup_id);
        }
    }
}
