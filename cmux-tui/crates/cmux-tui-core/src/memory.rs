//! The daemon's memory registry. The `Mux` composition root makes one
//! (`Mux::memory`) and hands it to every consumer; the kernel pressure source
//! of `cmux-memory` starts on first use, so a headless daemon that never
//! needs it starts none. The app's `memory.limit` push
//! (server/memory_limit.rs) votes through a voter of its own, so the level is
//! the worst of the daemon's own reading and the app's: Chrome's
//! `ChildMemoryConsumerRegistryHost`, where the most restrictive limit wins
//! (content/browser/memory_coordinator/README.md). The app's vote lasts as
//! long as the control connection that sent it, so a daemon with no app
//! follows its own source alone. The same limit goes on to acpmux
//! (mux/acpmux_energy.rs).
//!
//! Consumers: the standby host slot (lossless, `terminal.standby-host`), the
//! Kitty pixel maps (lossless, `terminal.kitty-pixels`, which start the
//! source with the mux) and the output store's scrollback budget (lossy,
//! `terminal.scrollback`, which starts the source with the store).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use cmux_memory::{MemoryRegistry, PressureLevel, PressureWatch, Voter, WatchError};

/// Where [`DaemonMemory::watch_system_pressure`] gets the system's level.
enum SystemSource {
    /// The kernel source of `cmux-memory`.
    Kernel,
    /// None: the level stays where the registry's other voters put it.
    #[cfg(test)]
    Off,
    /// A stand-in kernel that votes this level when the watch starts.
    #[cfg(test)]
    StandIn(PressureLevel),
}

/// What an owner's memory response starts with (`Mux` construction): its
/// registry, and whether the output store's scrollback budget is one of the
/// registry's consumers.
pub(crate) struct MemorySetup {
    pub(crate) memory: Arc<DaemonMemory>,
    /// The `memoryScrollbackPressure` feature
    /// (`crate::output_store::SCROLLBACK_PRESSURE_FEATURE`).
    pub(crate) scrollback_pressure: bool,
    /// The `memoryKittyShare` feature (`crate::mux::KITTY_SHARE_FEATURE`).
    pub(crate) kitty_share: bool,
}

impl MemorySetup {
    /// A registry fed by the kernel source, the feature from the process's
    /// feature lists.
    pub(crate) fn from_env() -> Self {
        Self {
            memory: Arc::new(DaemonMemory::new()),
            scrollback_pressure: cmux_features::listed_in_env(
                crate::output_store::SCROLLBACK_PRESSURE_FEATURE,
            ),
            kitty_share: cmux_features::listed_in_env(crate::mux::KITTY_SHARE_FEATURE),
        }
    }
}

/// A running system source; dropping it withdraws its vote.
enum RunningSource {
    Kernel(#[allow(dead_code)] PressureWatch),
    #[cfg(test)]
    StandIn(#[allow(dead_code)] Voter),
}

/// The app's Memory Saver mode (`memory.saver`, the app's `MemorySaverMode`),
/// spelled the same on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SaverMode {
    Off,
    Conservative,
    Medium,
    Aggressive,
}

impl SaverMode {
    const ALL: [Self; 4] = [Self::Off, Self::Conservative, Self::Medium, Self::Aggressive];

    fn code(self) -> u64 {
        match self {
            Self::Off => 1,
            Self::Conservative => 2,
            Self::Medium => 3,
            Self::Aggressive => 4,
        }
    }

    fn from_code(code: u64) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.code() == code)
    }
}

/// What the app last sent in `memory.limit`: its coordinator's level (its
/// debug override folded in), its Memory Saver mode, and the debug override
/// it holds, if any.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AppLimit {
    pub(crate) level: PressureLevel,
    pub(crate) mode: SaverMode,
    pub(crate) pressure_override: Option<PressureLevel>,
}

fn level_code(level: PressureLevel) -> u64 {
    match level {
        PressureLevel::Normal => 1,
        PressureLevel::Warning => 2,
        PressureLevel::Critical => 3,
    }
}

fn level_from_code(code: u64) -> Option<PressureLevel> {
    [PressureLevel::Normal, PressureLevel::Warning, PressureLevel::Critical]
        .into_iter()
        .find(|level| level_code(*level) == code)
}

/// The app's limit packed into the low [`SETTER_SHIFT`] bits of one atomic
/// (level, mode, override: three bits each; zero is none), with the low 48
/// bits of the control client that set it above them, so a reader never sees
/// one limit's level with another's mode and a departing client clears only
/// the limit it set. Ids count up by one per connection and never reach 2^48.
const SETTER_SHIFT: u32 = 16;
const FIELD_BITS: u32 = 3;
const FIELD_MASK: u64 = (1 << FIELD_BITS) - 1;

fn pack(client: u64, limit: AppLimit) -> u64 {
    (client << SETTER_SHIFT)
        | level_code(limit.level)
        | (limit.mode.code() << FIELD_BITS)
        | (limit.pressure_override.map_or(0, level_code) << (2 * FIELD_BITS))
}

fn unpack(state: u64) -> Option<AppLimit> {
    Some(AppLimit {
        level: level_from_code(state & FIELD_MASK)?,
        mode: SaverMode::from_code((state >> FIELD_BITS) & FIELD_MASK)?,
        pressure_override: level_from_code((state >> (2 * FIELD_BITS)) & FIELD_MASK),
    })
}

/// Called after each change of the app's limit: it only queues the change
/// for its owner (the acpmux relay's thread), never does the work.
type LimitRelay = Box<dyn Fn() + Send + Sync>;

pub(crate) struct DaemonMemory {
    registry: MemoryRegistry,
    system_source: SystemSource,
    watch: OnceLock<Option<RunningSource>>,
    /// The app's vote in [`Self::registry`]: normal while no app holds a limit.
    app_voter: Voter,
    /// The app's limit and its setter ([`pack`]); zero while none holds.
    app_limit: AtomicU64,
    /// Who hears each change of the app's limit (mux/acpmux_energy.rs).
    relay: OnceLock<LimitRelay>,
}

impl DaemonMemory {
    /// The owner's registry, fed by the kernel source once it starts.
    pub(crate) fn new() -> Self {
        Self::with_source(SystemSource::Kernel)
    }

    fn with_source(system_source: SystemSource) -> Self {
        let registry = MemoryRegistry::new();
        let app_voter = registry.voter();
        Self {
            registry,
            system_source,
            watch: OnceLock::new(),
            app_voter,
            app_limit: AtomicU64::new(0),
            relay: OnceLock::new(),
        }
    }

    /// A registry no system source feeds; the test votes its level.
    #[cfg(test)]
    pub(crate) fn without_system_source() -> Self {
        Self::with_source(SystemSource::Off)
    }

    /// A registry whose system source reports `level` from the moment it
    /// starts, as the kernel does when it is already under pressure.
    #[cfg(test)]
    pub(crate) fn with_stand_in_system_level(level: PressureLevel) -> Self {
        Self::with_source(SystemSource::StandIn(level))
    }

    pub(crate) fn registry(&self) -> &MemoryRegistry {
        &self.registry
    }

    /// Starts the system pressure source once for this owner; later calls do
    /// nothing. The source reads the current level before this returns.
    /// Without a source, or where this process may not use it, it votes
    /// nothing.
    pub(crate) fn watch_system_pressure(&self) {
        self.watch.get_or_init(|| match &self.system_source {
            SystemSource::Kernel => match self.registry.watch_system_pressure() {
                Ok(watch) => Some(RunningSource::Kernel(watch)),
                Err(WatchError::Unsupported | WatchError::NotPermitted(_)) => None,
                Err(error) => {
                    eprintln!("cmux-tui: {error}");
                    None
                }
            },
            #[cfg(test)]
            SystemSource::Off => None,
            #[cfg(test)]
            SystemSource::StandIn(level) => {
                let voter = self.registry.voter();
                voter.set_level(*level);
                Some(RunningSource::StandIn(voter))
            }
        });
    }

    /// The limit the app holds now; `None` while no app does.
    pub(crate) fn app_limit(&self) -> Option<AppLimit> {
        unpack(self.app_limit.load(Ordering::Acquire))
    }

    /// Sets the limit of control client `client` (`memory.limit`): its
    /// level votes in the registry until it is replaced or `client` leaves
    /// ([`Self::client_left`]). Under pressure every consumer hears the new
    /// level before this returns. Returns whether the limit changed.
    pub(crate) fn set_app(&self, client: u64, limit: AppLimit) -> bool {
        self.store(|_| Some(pack(client, limit)))
    }

    /// Control client `client` left: the limit it set goes with it, and the
    /// daemon follows its own source again. Returns whether a limit went.
    pub(crate) fn client_left(&self, client: u64) -> bool {
        self.store(|state| (state != 0 && state >> SETTER_SHIFT == client).then_some(0))
    }

    /// Calls `relay` after each change of the app's limit, for as long as
    /// this registry lives; a second relay is refused and handed back.
    pub(crate) fn relay_app_limit(&self, relay: LimitRelay) -> Result<(), LimitRelay> {
        self.relay.set(relay)
    }

    /// Stores `change(state)` (nothing when it is `None`), then votes the
    /// level it holds. A writer that raced this one may have voted an older
    /// limit after this store, so each writer votes again until the vote
    /// matches the limit it reads last: the last store always wins.
    fn store(&self, change: impl Fn(u64) -> Option<u64>) -> bool {
        let Ok(before) =
            self.app_limit.fetch_update(Ordering::AcqRel, Ordering::Acquire, |state| {
                change(state).filter(|next| *next != state)
            })
        else {
            return false;
        };
        loop {
            let voted = self.app_limit().map_or(PressureLevel::Normal, |limit| limit.level);
            self.app_voter.set_level(voted);
            if self.app_limit().map_or(PressureLevel::Normal, |limit| limit.level) == voted {
                break;
            }
        }
        let changed = unpack(before) != self.app_limit();
        if changed && let Some(relay) = self.relay.get() {
            relay();
        }
        changed
    }
}

#[cfg(test)]
#[path = "memory_tests.rs"]
mod tests;
