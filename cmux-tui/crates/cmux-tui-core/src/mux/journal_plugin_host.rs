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

    /// Start the configured journal plugin against the bound local socket.
    pub fn start_journal_plugin(&self, socket: std::path::PathBuf) {
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
}
