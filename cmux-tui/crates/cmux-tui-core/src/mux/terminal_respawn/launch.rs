//! How a respawned terminal starts (cx-6so.49 L2): the shell, directory and
//! environment from its relaunch record, and the seed its new host shows
//! before the shell's first byte.
//!
//! - kind `shell`: the recorded shell when it still exists, else the user's
//!   shell; kind `command`: the user's shell (a command never runs again).
//!   Shell integration is derived from the current bundle, as for any new
//!   terminal.
//! - directory: the recorded one while it is a directory, else `$HOME`.
//! - environment: the daemon's launch environment plus the record's
//!   allowlisted keys (`TERM` only with a usable `TERMINFO`).
//! - seed: the previous screen (the exit replay of the lost incarnation,
//!   else the latest journal checkpoint of the terminal, else nothing),
//!   modes a dead program left on reset, then one dim marker line.

use std::path::Path;

use super::*;
use crate::workspace_registry::relaunch_store::{RelaunchKind, StoredRelaunch};
use crate::workspace_registry::terminal_respawn_store::TerminalReplay;

/// Leave the alternate screen, reset attributes, show the cursor, and turn
/// off mouse reporting, bracketed paste and application cursor keys: a lost
/// full-screen program left them for a shell that did not ask for them.
/// `ESC 7` first: leaving the alternate screen (`?1049l`) restores the
/// current screen's saved cursor, so on the primary screen it must be the
/// cursor the replay just set, not an older one (the marker line otherwise
/// overwrote a row of the previous screen). Each screen keeps its own saved
/// cursor, so after a full-screen program the primary cursor still returns.
const MODE_RESET: &[u8] =
    b"\x1b7\x1b[?1049l\x1b[0m\x1b[?25h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?1l\x1b>";
/// Room the marker line and mode reset need in the seed.
const MARKER_HEADROOM_BYTES: usize = 4 * 1024;

/// The launch of one respawn.
pub(in crate::mux) struct RespawnLaunch {
    pub(in crate::mux) options: SurfaceOptions,
    pub(in crate::mux) cell_pixels: (u16, u16),
    pub(in crate::mux) seed: Vec<u8>,
}

impl Mux {
    /// The lost incarnation's screen: its exit replay, else the latest
    /// journal checkpoint of the terminal.
    pub(in crate::mux) fn previous_screen(
        &self,
        registry: &WorkspaceRegistry,
        plan: &RespawnPlan,
    ) -> Option<TerminalReplay> {
        let public_id = plan.public_id.as_str();
        match registry.terminal_exit_snapshot(public_id) {
            Ok(Some(snapshot)) if snapshot.generation == plan.old_incarnation => {
                return Some(TerminalReplay {
                    cols: snapshot.cols,
                    rows: snapshot.rows,
                    bytes: snapshot.replay_bytes,
                });
            }
            Ok(_) => {}
            Err(error) => eprintln!(
                "cmux-tui: terminal {} exit replay is unreadable: {error:#}",
                plan.terminal_id
            ),
        }
        registry.latest_checkpoint_terminal_replay(public_id).unwrap_or_else(|error| {
            eprintln!(
                "cmux-tui: terminal {} checkpoint replay is unreadable: {error:#}",
                plan.terminal_id
            );
            None
        })
    }

    /// The options, cell size and seed of a respawn. `geometry` is the lost
    /// runtime's size and cell pixels, when this daemon still had it.
    pub(in crate::mux) fn respawn_launch(
        &self,
        plan: &RespawnPlan,
        record: Option<&StoredRelaunch>,
        previous: Option<TerminalReplay>,
        geometry: Option<((u16, u16), (u16, u16))>,
    ) -> RespawnLaunch {
        let size = geometry.map(|(size, _)| size).or_else(|| {
            previous
                .as_ref()
                .filter(|previous| previous.cols > 0 && previous.rows > 0)
                .map(|previous| (previous.cols, previous.rows))
        });
        let cwd = record
            .and_then(|record| record.cwd.clone())
            .filter(|cwd| Path::new(cwd).is_dir())
            .or_else(|| {
                crate::platform::home_dir()
                    .filter(|home| home.is_dir())
                    .map(|home| home.to_string_lossy().into_owned())
            });
        let env = record.map(|record| usable_env(&record.env)).unwrap_or_default();
        let (mut options, creation_cell_pixels) =
            self.terminal_spawn_options(cwd, None, size, &env);
        let shell = record
            .filter(|record| record.kind == RelaunchKind::Shell)
            .and_then(|record| record.shell_path.clone())
            .filter(|shell| Path::new(shell).is_file())
            .unwrap_or_else(crate::platform::default_shell);
        let integrated = crate::shell_integration::integrate_default_shell(
            vec![shell],
            options.extra_env.clone(),
        );
        options.command = Some(integrated.command);
        options.extra_env = integrated.env;
        // A command whose argv this daemon no longer has is only named.
        let program = record
            .filter(|record| record.kind == RelaunchKind::Command)
            .filter(|_| self.terminal_respawns.argv(&plan.terminal_id).is_none())
            .and_then(|record| record.program.as_deref());
        let marker = crate::terminal_respawn_text::marker(program);
        RespawnLaunch {
            options,
            cell_pixels: geometry.map_or(creation_cell_pixels, |(_, cell_pixels)| cell_pixels),
            seed: respawn_seed(previous.map(|previous| previous.bytes), Some(&marker)),
        }
    }
}

/// The record's environment, without `TERM` and `TERMINFO` when the
/// recorded terminfo directory is gone.
fn usable_env(env: &[(String, String)]) -> Vec<(String, String)> {
    let terminfo_usable = env
        .iter()
        .find(|(key, _)| key == "TERMINFO")
        .is_none_or(|(_, path)| Path::new(path).is_dir());
    env.iter()
        .filter(|(key, _)| terminfo_usable || (key != "TERM" && key != "TERMINFO"))
        .cloned()
        .collect()
}

/// The previous screen (dropped whole when it would not fit), the mode reset
/// and one dim `marker` line (none: no line), bounded by
/// `VT_REPLAY_MAX_BYTES`.
pub(in crate::mux) fn respawn_seed(previous: Option<Vec<u8>>, marker: Option<&str>) -> Vec<u8> {
    let budget = crate::surface::VT_REPLAY_MAX_BYTES.saturating_sub(MARKER_HEADROOM_BYTES);
    let mut seed = previous.filter(|previous| previous.len() <= budget).unwrap_or_default();
    let had_screen = !seed.is_empty();
    seed.extend_from_slice(MODE_RESET);
    if had_screen {
        seed.extend_from_slice(b"\r\n");
    }
    if let Some(marker) = marker {
        seed.extend_from_slice(b"\x1b[2m");
        seed.extend(marker.chars().filter(|c| !c.is_control()).collect::<String>().bytes());
        seed.extend_from_slice(b"\x1b[0m\r\n");
    }
    seed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_seed_is_the_screen_then_one_dim_marker_line_within_the_bound() {
        let seed = respawn_seed(Some(b"old screen".to_vec()), Some("restored"));
        let text = String::from_utf8(seed).unwrap_or_default();
        assert!(text.starts_with("old screen\x1b7\x1b[?1049l"), "{text:?}");
        assert!(text.ends_with("\r\n\x1b[2mrestored\x1b[0m\r\n"), "{text:?}");

        let alone = respawn_seed(None, Some("restored"));
        assert!(!alone.starts_with(b"\r\n") && alone.ends_with(b"restored\x1b[0m\r\n"));

        let huge = vec![b'x'; crate::surface::VT_REPLAY_MAX_BYTES];
        let bounded = respawn_seed(Some(huge), Some("restored"));
        assert!(bounded.len() < MARKER_HEADROOM_BYTES, "an oversized screen is dropped whole");

        let quiet = respawn_seed(Some(b"old screen".to_vec()), None);
        assert!(quiet.ends_with(MODE_RESET) || quiet.ends_with(b"\r\n"));
        assert!(!quiet.windows(4).any(|window| window == b"\x1b[2m"), "no marker line");
    }

    #[test]
    fn a_stale_terminfo_drops_term() {
        let env = vec![
            ("TERM".to_string(), "xterm-ghostty".to_string()),
            ("TERMINFO".to_string(), "/definitely/missing/terminfo".to_string()),
            ("CMUX_TAG".to_string(), "dev".to_string()),
        ];
        assert_eq!(usable_env(&env), vec![("CMUX_TAG".to_string(), "dev".to_string())]);
    }
}
