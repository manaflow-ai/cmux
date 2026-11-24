//! Supervision of the optional userland journal plugin
//! (`crate::journal_plugin`): configuring it, starting it once the local
//! socket is bound, and journaling the exits its supervisor observes.

use super::*;

impl Mux {
    /// Configure the optional userland agent plugin. The process starts only
    /// after the local resource socket has been bound.
    pub fn configure_journal_plugin(&self, options: Option<crate::JournalPluginOptions>) {
        self.journal_plugin.configure(options);
    }

    /// Start the configured journal plugin against the bound local socket once the daemon holds a
    /// terminal. The plugin (the bundled agent screen detection) reads terminals, so a daemon with
    /// none (the Chief's before its first terminal) does not run its process (CMUX-571, goal
    /// ram-baseline). A daemon that restores terminals starts it at once. Otherwise one thread waits
    /// for the terminal topology to change, and it ends once it has started the plugin.
    pub fn start_journal_plugin(self: &Arc<Self>, socket: std::path::PathBuf) {
        if self.holds_a_terminal() {
            self.start_journal_plugin_now(socket);
            return;
        }
        let events = self.subscribe_terminal_lifecycle();
        // Read again after subscribing: a terminal made between the first read and the
        // subscription sent its event before this receiver existed.
        if self.holds_a_terminal() {
            self.start_journal_plugin_now(socket);
            return;
        }
        let weak = Arc::downgrade(self);
        let gate_socket = socket.clone();
        let spawned = std::thread::Builder::new()
            .name("cmux-journal-plugin-gate".into())
            .spawn(move || wait_for_first_terminal(&weak, events, gate_socket));
        if let Err(error) = spawned {
            // The gate is only a saving: without it the plugin starts as it did before.
            eprintln!(
                "cmux-tui: journal plugin gate did not start, starting the plugin now: {error}"
            );
            self.start_journal_plugin_now(socket);
        }
    }

    /// Whether the terminal catalog holds any terminal (launching, running or restored).
    fn holds_a_terminal(&self) -> bool {
        self.with_state(|state| !state.terminal_catalog.is_empty())
    }

    fn start_journal_plugin_now(&self, socket: std::path::PathBuf) {
        let generation = match self.workspace_registry.lock() {
            Ok(registry) => registry.reserve_journal_plugin_generation(),
            Err(_) => Err(anyhow::anyhow!("workspace registry mutex is poisoned")),
        };
        match generation {
            Ok(generation) => self.journal_plugin.start_with_generation_seed(
                socket,
                self.session.clone(),
                generation,
            ),
            Err(error) => eprintln!(
                "cmux-tui: journal plugin not started because its generation could not be reserved: {error}"
            ),
        }
    }

    /// The running journal plugin's process group, if one runs.
    #[cfg(unix)]
    pub(crate) fn journal_plugin_process_group(&self) -> Option<libc::pid_t> {
        self.journal_plugin.process_group()
    }

    /// Journal a supervisor-observed plugin exit. The roster reducer removes
    /// only entries owned by this producer, so a crash cannot leave stale
    /// rows until the next terminal scan and the cleanup remains replayable.
    pub(super) fn record_journal_plugin_exit(&self, plugin_id: &str, generation: u64) {
        let ingress =
            match crate::agent_hooks::journal_plugin_exit_journal_ingress(plugin_id, generation) {
                Ok(ingress) => ingress,
                Err(error) => {
                    eprintln!("cmux-tui: invalid journal plugin exit id {plugin_id:?}: {error}");
                    return;
                }
            };
        let key =
            format!("journal-plugin-exit-{plugin_id}-{}", crate::workspace_registry::new_uuid_v4());
        if let Err(error) = self.append_journal_ingress(&ingress, "journal-plugin-supervisor", &key)
        {
            eprintln!("cmux-tui: journal plugin exit cleanup could not be journaled: {error}");
        }
    }

    /// One line in the slow request log (`diagnostics/request_log.rs`, kind `plugin_restart`)
    /// for a restart that the plugin's supervisor scheduled: three numbers, no plugin id and no
    /// exit text. Never waits: a full queue of the log drops the line and counts it.
    pub(crate) fn record_journal_plugin_restart(
        &self,
        restart: crate::journal_plugin::JournalPluginRestart,
    ) {
        if let Some(log) = self.connection_stats().request_log() {
            log.plugin_restart(restart.restarts, restart.failures, restart.delay);
        }
    }
}

/// The gate thread of [`Mux::start_journal_plugin`]: waits for the first terminal, starts the
/// plugin, and ends. It never holds the mux across a wait, so it does not keep a stopped daemon's mux
/// alive, and it starts nothing once the daemon is shutting down.
fn wait_for_first_terminal(
    mux: &std::sync::Weak<Mux>,
    mut events: crate::event_bus::MuxEventReceiver,
    socket: std::path::PathBuf,
) {
    loop {
        let Some(live) = mux.upgrade() else { return };
        if live.shutting_down.load(Ordering::Acquire) {
            return;
        }
        if live.holds_a_terminal() {
            live.start_journal_plugin_now(socket);
            return;
        }
        drop(live);
        if events.recv().is_err() {
            // The mailbox overflowed or the bus closed: subscribe again, then read the catalog
            // again before the next wait.
            let Some(live) = mux.upgrade() else { return };
            events = live.subscribe_terminal_lifecycle();
        } else {
            // A burst of topology events needs one read of the catalog.
            while events.try_recv().is_ok() {}
        }
    }
}

#[cfg(all(test, unix))]
#[path = "journal_plugin_host_tests.rs"]
mod tests;
