//! Packaged daemon build identity and idle update handoff.

use std::path::{Path, PathBuf};

/// The content fingerprint injected by `build-terminal-backend.sh`.
///
/// Direct developer `cargo` builds remain explicitly unstamped. They never
/// retire themselves based on an app-bundle sidecar.
pub const BUILD_ID: &str = match option_env!("CMUX_TUI_BUILD_FINGERPRINT") {
    Some(value) => value,
    None => "unstamped",
};

pub const PACKAGED_BUILD_ID_SUFFIX: &str = ".build-id";

/// Returns the build-ID sidecar next to an executable.
pub fn packaged_build_id_path(executable: &Path) -> PathBuf {
    let mut value = executable.as_os_str().to_os_string();
    value.push(PACKAGED_BUILD_ID_SUFFIX);
    PathBuf::from(value)
}

/// Reads a valid packaged SHA-256 build identity.
///
/// Missing, malformed, or non-UTF-8 files are treated as unavailable. An
/// update must never terminate a daemon from ambiguous filesystem state.
pub fn read_packaged_build_id(executable: &Path) -> Option<String> {
    let value = std::fs::read_to_string(packaged_build_id_path(executable)).ok()?;
    let value = value.trim();
    is_sha256(value).then(|| value.to_owned())
}

/// Whether an app-service daemon may retire so launchd starts the packaged build.
pub fn should_retire_for_packaged_build(
    running_build_id: &str,
    packaged_build_id: Option<&str>,
    canonical_surface_count: usize,
) -> bool {
    canonical_surface_count == 0
        && is_sha256(running_build_id)
        && packaged_build_id
            .is_some_and(|packaged| is_sha256(packaged) && packaged != running_build_id)
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    const OLD: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    const NEW: &str = "2222222222222222222222222222222222222222222222222222222222222222";

    #[test]
    fn live_surfaces_fence_old_daemon_retirement() {
        assert!(!should_retire_for_packaged_build(OLD, Some(NEW), 1));
        assert!(should_retire_for_packaged_build(OLD, Some(NEW), 0));
    }

    #[test]
    fn missing_matching_and_malformed_ids_never_retire() {
        assert!(!should_retire_for_packaged_build(OLD, None, 0));
        assert!(!should_retire_for_packaged_build(OLD, Some(OLD), 0));
        assert!(!should_retire_for_packaged_build("unstamped", Some(NEW), 0));
        assert!(!should_retire_for_packaged_build(OLD, Some("new"), 0));
    }

    #[test]
    fn sidecar_path_does_not_replace_executable_extension() {
        assert_eq!(
            packaged_build_id_path(Path::new("/Applications/cmux.app/backend")),
            PathBuf::from("/Applications/cmux.app/backend.build-id")
        );
    }
}
