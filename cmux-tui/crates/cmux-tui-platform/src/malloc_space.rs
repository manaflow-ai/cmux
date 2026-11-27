//! macOS's malloc in space-efficient mode for the daemons (CMUX-571, goal
//! ram-baseline).
//!
//! macOS's malloc keeps the pages of the blocks a process frees, dirty, in its
//! physical footprint. `malloc_zone_pressure_relief` does not give them back
//! on macOS 27 (0 bytes on a heap with 21 MB of free blocks), so a later purge
//! cannot help. vmmap of the idle app's two cmux-tui daemons read 53-54 MB of
//! malloc dirty against 31-33 MB allocated each: 21 MB of freed blocks apiece.
//! `MallocSpaceEfficient=1`, read by malloc when a process starts, returns
//! freed pages as blocks are freed: a probe with the same heap shape went from
//! 49.6 to 25.1 MB with it (free blocks 21.7 MB to 0.7 MB).
//!
//! So whoever starts a daemon (`command.envs(child_env())`) sets it for that child only,
//! with a marker, and the daemon, first thing in `main` ([`forget`]), removes
//! both again: its own children (terminal hosts, shells, agents) start with
//! the system default, and a variable the person set themselves is never
//! touched. Linux and Windows compile this to nothing (glibc gets its arena
//! cap, `malloc_arenas`).

/// The variable macOS's malloc reads at process start.
pub const ENV: &str = "MallocSpaceEfficient";
/// Says the variable was set through [`child_env`], so [`forget`] removes it.
pub const MARKER_ENV: &str = "CMUX_MALLOC_SPACE_EFFICIENT";

/// The variables a daemon's spawn adds (`command.envs(child_env())`) so the
/// daemon runs macOS's malloc in space-efficient mode: none when the
/// environment already names a mode, and none off macOS.
pub fn child_env() -> Vec<(&'static str, &'static str)> {
    #[cfg(target_os = "macos")]
    if should_set(std::env::var_os(ENV).as_deref()) {
        return vec![(ENV, "1"), (MARKER_ENV, "1")];
    }
    Vec::new()
}

/// Removes the variable [`child_env`] set (malloc has read it by now), so
/// this process's children start with the system's malloc.
///
/// # Safety
/// Call it first in `main`, before any thread starts: the environment is
/// written without a lock.
pub unsafe fn forget() {
    #[cfg(target_os = "macos")]
    if std::env::var_os(MARKER_ENV).is_some() {
        // SAFETY: the caller runs this before any other thread exists.
        unsafe {
            std::env::remove_var(ENV);
            std::env::remove_var(MARKER_ENV);
        }
    }
}

/// Whether a child should get the variable: only when nothing names a mode.
#[cfg(any(target_os = "macos", test))]
fn should_set(current: Option<&std::ffi::OsStr>) -> bool {
    current.is_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mode_the_environment_names_wins() {
        assert!(should_set(None));
        assert!(!should_set(Some(std::ffi::OsStr::new("0"))));
        assert!(!should_set(Some(std::ffi::OsStr::new("1"))));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_child_gets_the_variable_and_its_marker() {
        if std::env::var_os(ENV).is_some() {
            return;
        }
        assert_eq!(child_env(), vec![(ENV, "1"), (MARKER_ENV, "1")]);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn other_systems_leave_the_child_alone() {
        assert!(child_env().is_empty());
    }
}
