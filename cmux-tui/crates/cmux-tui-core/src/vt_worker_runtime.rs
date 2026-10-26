//! Where the daemon parses terminal output: in its own VT pool threads
//! (phase A, `vt_pool`) or in sandboxed `cmux-vt-worker` processes (phase B,
//! the broker of this module). terminal-host-model-DESIGN.md, option E;
//! plans/cmux-next/chrome-parity/p01-process.md, tasks 134 and 137.
//!
//! Which mode a daemon runs is a per-channel default plus one override, the
//! way Chromium rolls out a process-model change: a feature has a default
//! state (`base::Feature`, `FEATURE_ENABLED_BY_DEFAULT` in
//! base/feature_list.h), the default can differ per channel
//! (`chrome::GetChannel()`, chrome/common/channel_info.h), and an explicit
//! `--enable-features` / `--disable-features` switch wins over the default
//! (`FeatureList::InitFromCommandLine`, base/feature_list.cc). Here:
//!
//! - DEV builds default to [`VtParseMode::Process`] (task 137, after the
//!   phase B rows passed).
//! - NIGHTLY, staging, RC, Release and an unbundled daemon (a standalone
//!   CLI, the cargo tests) default to [`VtParseMode::Threads`]. NIGHTLY moves
//!   only with its own task.
//! - `CMUX_TUI_VT_WORKERS=process` turns workers on in any build;
//!   `CMUX_TUI_VT_WORKERS=threads` keeps a DEV daemon on the pool threads.
//!   The `threads` fallback is kept for one release after the DEV default
//!   changed, then removed with the phase A path for workers.
//!
//! The build kind is injected: it comes from the app bundle around the
//! daemon executable (`cmux-tui` `app_identity`), never from an inherited
//! environment, so a daemon started from another build's terminal keeps
//! its own build's default.

use cmux_agent_pane_policy::build_identity::BuildKind;

/// The environment variable that overrides the per-build default.
pub const VT_WORKERS_ENV: &str = "CMUX_TUI_VT_WORKERS";

/// Where terminal output is parsed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VtParseMode {
    /// Phase A: the daemon's VT pool threads parse every terminal.
    Threads,
    /// Phase B: sandboxed `cmux-vt-worker` processes parse, sharded by
    /// trust class; the daemon reads their screen pages.
    Process,
}

impl VtParseMode {
    /// The name in [`VT_WORKERS_ENV`], `debug.vt` and the process census.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Threads => "threads",
            Self::Process => "process",
        }
    }

    /// The mode a build runs when nothing overrides it.
    pub const fn default_for(build: BuildKind) -> Self {
        match build {
            BuildKind::Dev => Self::Process,
            BuildKind::Nightly
            | BuildKind::Staging
            | BuildKind::Rc
            | BuildKind::Release
            | BuildKind::Unbundled => Self::Threads,
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "threads" => Some(Self::Threads),
            "process" => Some(Self::Process),
            _ => None,
        }
    }
}

/// Why a daemon runs the mode it runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VtParseModeSource {
    /// [`VtParseMode::default_for`] the daemon's build.
    BuildDefault,
    /// A valid [`VT_WORKERS_ENV`] value.
    Override,
    /// [`VT_WORKERS_ENV`] held a value that names no mode; the build default
    /// applies. The value is kept for the startup log line.
    InvalidOverride(String),
}

/// The parse mode of one daemon, decided once at start. The broker and the
/// VT pool read it; it never changes while the daemon runs, so a terminal
/// never moves between modes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VtWorkerPolicy {
    mode: VtParseMode,
    build: BuildKind,
    source: VtParseModeSource,
}

impl VtWorkerPolicy {
    /// The policy of a daemon of `build` whose [`VT_WORKERS_ENV`] is
    /// `override_value`. Blank counts as unset.
    pub fn resolve(build: BuildKind, override_value: Option<&str>) -> Self {
        let override_value = override_value.filter(|value| !value.trim().is_empty());
        let (mode, source) = match override_value {
            None => (VtParseMode::default_for(build), VtParseModeSource::BuildDefault),
            Some(value) => match VtParseMode::parse(value) {
                Some(mode) => (mode, VtParseModeSource::Override),
                None => (
                    VtParseMode::default_for(build),
                    VtParseModeSource::InvalidOverride(value.to_owned()),
                ),
            },
        };
        Self { mode, build, source }
    }

    /// The policy of this daemon process: `build` from its app bundle,
    /// the override from its environment.
    pub fn for_daemon(build: BuildKind) -> Self {
        Self::resolve(build, std::env::var(VT_WORKERS_ENV).ok().as_deref())
    }

    pub fn mode(&self) -> VtParseMode {
        self.mode
    }

    pub fn build(&self) -> BuildKind {
        self.build
    }

    pub fn source(&self) -> &VtParseModeSource {
        &self.source
    }

    /// Whether this daemon starts `cmux-vt-worker` processes.
    pub fn workers_enabled(&self) -> bool {
        self.mode == VtParseMode::Process
    }

    /// One line for the startup log and `debug.vt`, e.g.
    /// `vt parse: process (dev default)`. An invalid override names its
    /// value; the value is a mode name the person typed, not terminal data.
    pub fn describe(&self) -> String {
        let mode = self.mode.name();
        let build = self.build.name();
        match &self.source {
            VtParseModeSource::BuildDefault => format!("vt parse: {mode} ({build} default)"),
            VtParseModeSource::Override => format!("vt parse: {mode} ({VT_WORKERS_ENV})"),
            VtParseModeSource::InvalidOverride(value) => format!(
                "vt parse: {mode} ({build} default; ignored {VT_WORKERS_ENV}={value:?}, expected threads or process)"
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_BUILDS: [BuildKind; 6] = [
        BuildKind::Dev,
        BuildKind::Nightly,
        BuildKind::Staging,
        BuildKind::Rc,
        BuildKind::Release,
        BuildKind::Unbundled,
    ];

    #[test]
    fn dev_defaults_to_worker_processes() {
        let policy = VtWorkerPolicy::resolve(BuildKind::Dev, None);
        assert_eq!(policy.mode(), VtParseMode::Process);
        assert_eq!(policy.source(), &VtParseModeSource::BuildDefault);
        assert!(policy.workers_enabled());
    }

    #[test]
    fn every_other_build_defaults_to_pool_threads() {
        for build in ALL_BUILDS.into_iter().filter(|build| *build != BuildKind::Dev) {
            let policy = VtWorkerPolicy::resolve(build, None);
            assert_eq!(policy.mode(), VtParseMode::Threads, "{}", build.name());
            assert!(!policy.workers_enabled(), "{}", build.name());
        }
    }

    #[test]
    fn the_bundle_ids_of_shipped_channels_keep_pool_threads() {
        use cmux_agent_pane_policy::build_identity::BuildIdentity;
        for (bundle_id, mode) in [
            ("com.cmuxterm.app.debug", VtParseMode::Process),
            ("com.cmuxterm.app.debug.cp-137", VtParseMode::Process),
            ("com.cmuxterm.app.nightly", VtParseMode::Threads),
            ("com.cmuxterm.app.nightly.cmux-next", VtParseMode::Threads),
            ("com.cmuxterm.app.rc", VtParseMode::Threads),
            ("com.cmuxterm.app.staging", VtParseMode::Threads),
            ("com.cmuxterm.app", VtParseMode::Threads),
        ] {
            let build = BuildIdentity::new(Some(bundle_id), None).kind();
            assert_eq!(VtWorkerPolicy::resolve(build, None).mode(), mode, "{bundle_id}");
        }
        assert_eq!(
            VtWorkerPolicy::resolve(BuildIdentity::new(None, None).kind(), None).mode(),
            VtParseMode::Threads
        );
    }

    #[test]
    fn threads_override_keeps_dev_on_the_pool() {
        let policy = VtWorkerPolicy::resolve(BuildKind::Dev, Some("threads"));
        assert_eq!(policy.mode(), VtParseMode::Threads);
        assert_eq!(policy.source(), &VtParseModeSource::Override);
    }

    #[test]
    fn process_override_turns_workers_on_in_any_build() {
        for build in ALL_BUILDS {
            let policy = VtWorkerPolicy::resolve(build, Some(" process\n"));
            assert_eq!(policy.mode(), VtParseMode::Process, "{}", build.name());
            assert_eq!(policy.source(), &VtParseModeSource::Override);
        }
    }

    #[test]
    fn blank_override_is_unset() {
        for build in ALL_BUILDS {
            assert_eq!(
                VtWorkerPolicy::resolve(build, Some("  ")),
                VtWorkerPolicy::resolve(build, None),
                "{}",
                build.name()
            );
        }
    }

    #[test]
    fn invalid_override_keeps_the_build_default_and_says_so() {
        let release = VtWorkerPolicy::resolve(BuildKind::Release, Some("on"));
        assert_eq!(release.mode(), VtParseMode::Threads);
        assert_eq!(release.source(), &VtParseModeSource::InvalidOverride("on".into()));
        assert!(release.describe().contains("ignored CMUX_TUI_VT_WORKERS=\"on\""));
        let dev = VtWorkerPolicy::resolve(BuildKind::Dev, Some("PROCESS"));
        assert_eq!(dev.mode(), VtParseMode::Process);
        assert!(matches!(dev.source(), VtParseModeSource::InvalidOverride(_)));
    }

    #[test]
    fn mode_names_round_trip_through_the_override() {
        for mode in [VtParseMode::Threads, VtParseMode::Process] {
            assert_eq!(VtParseMode::parse(mode.name()), Some(mode));
        }
    }

    #[test]
    fn describe_names_mode_and_source() {
        assert_eq!(
            VtWorkerPolicy::resolve(BuildKind::Dev, None).describe(),
            "vt parse: process (dev default)"
        );
        assert_eq!(
            VtWorkerPolicy::resolve(BuildKind::Nightly, Some("process")).describe(),
            "vt parse: process (CMUX_TUI_VT_WORKERS)"
        );
    }
}
