//! This process's acpmux build id, and the `--version` line that shows it.

/// This process's build id (git short hash and date, acpmux-build-id). The
/// cmux-tui binary installs it at start (`install_build`) and builds this
/// crate without the `build-id` feature, so a new stamp does not recompile
/// it. With the feature (the standalone `acpmux` binary, this crate's tests)
/// the stamped value is the default. Without either, `unstamped`.
pub fn build() -> &'static str {
    INSTALLED_BUILD.get().copied().unwrap_or_else(default_build)
}

static INSTALLED_BUILD: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();

#[cfg(feature = "build-id")]
fn default_build() -> &'static str {
    acpmux_build_id::build()
}
#[cfg(not(feature = "build-id"))]
fn default_build() -> &'static str {
    "unstamped"
}

/// Records this process's build id. The first call wins: a running daemon's
/// build never changes. Call it before anything reads `build()`.
pub fn install_build(build: &'static str) {
    let _ = INSTALLED_BUILD.set(build);
}

/// `<version> (<build>)`, for `--version`.
pub fn version_line() -> &'static str {
    static LINE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    LINE.get_or_init(|| format!("{} ({})", super::VERSION, build()))
}
