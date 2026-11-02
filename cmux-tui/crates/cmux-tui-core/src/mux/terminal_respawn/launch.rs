//! How a respawned terminal starts (cx-6so.49 L2): the shell, directory and
//! environment from its relaunch record, and the seed its new host shows
//! before the shell's first byte.
//!
//! - kind `shell`: the recorded shell when it still exists, else the user's
//!   shell; kind `command`: the user's shell (a command never runs again).
//!   Shell integration is derived from the current bundle, as for any new
//!   terminal.
//! - directory: a restarted keep-layout tab's kept directory, else the
//!   recorded one, each while it is a directory, else `$HOME`.
//! - environment: the daemon's launch environment plus the record's
//!   allowlisted keys (`TERM` only with a usable `TERMINFO`).
//! - seed: the previous screen (the exit replay of the lost incarnation,
//!   else the latest journal checkpoint of the terminal, else nothing),
//!   modes a dead program left on reset, then one dim marker line that
//!   names what it ran (an agent's resume command, else its command line).
//!   When it ran an agent session, the agent's live input frame (its
//!   prompt box, voice bar and footer, which an inline TUI such as Claude
//!   Code, Codex or Muse Code draws at the bottom of the primary screen) is
//!   erased from the previous screen first: it was the dead program's UI,
//!   not output, and the resumed agent draws its own
//!   ([`agent_frame_rows`]).

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
/// The most rows above the cursor an agent's input frame is taken to span.
const MAX_AGENT_FRAME_ROWS: u16 = 12;

/// The launch of one respawn.
pub(in crate::mux) struct RespawnLaunch {
    pub(in crate::mux) options: SurfaceOptions,
    pub(in crate::mux) cell_pixels: (u16, u16),
    pub(in crate::mux) seed: Vec<u8>,
}

impl Mux {
    /// The lost incarnation's screen: its exit replay, else the output
    /// store's snapshot, else the latest journal checkpoint of the terminal
    /// (registries written before the output store).
    pub(in crate::mux) fn previous_screen(
        &self,
        registry: &WorkspaceRegistry,
        plan: &RespawnPlan,
    ) -> Option<TerminalReplay> {
        // terminal.persistence.mode memory, or an incognito terminal: no
        // earlier screen comes from disk.
        if self.output_store.memory_only()
            || self.output_store.is_private_in(registry, &plan.public_id)
        {
            return None;
        }
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
        if let Some(screen) = self.output_store.previous_screen(&plan.public_id) {
            return Some(screen);
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
        // A restarted keep-layout tab: the directory its shell was in at the
        // handoff, a fact newer than the launch record's.
        let kept_cwd = plan.kept.first().and_then(|kept| kept.cwd.clone());
        let cwd = kept_cwd
            .filter(|cwd| Path::new(cwd).is_dir())
            .or_else(|| {
                record.and_then(|record| record.cwd.clone()).filter(|cwd| Path::new(cwd).is_dir())
            })
            .or_else(|| {
                crate::platform::home_dir()
                    .filter(|home| home.is_dir())
                    .map(|home| home.to_string_lossy().into_owned())
            });
        let env = record.map(|record| usable_env(&record.env)).unwrap_or_default();
        let (mut options, creation_cell_pixels) =
            self.terminal_spawn_options(cwd, None, size, &env);
        // An incognito terminal's new shell keeps no history either.
        if self.output_store.is_private(self, &plan.public_id) {
            crate::shell_integration::keep_no_history(&mut options.extra_env);
        }
        let shell = respawn_shell(record);
        let integrated = crate::shell_integration::integrate_default_shell(
            vec![shell],
            options.extra_env.clone(),
        );
        options.command = Some(integrated.command);
        options.extra_env = integrated.env;
        // What it ran: an agent's resume command, else the command line.
        let ran = self.respawn_ran(&plan.terminal_id, record);
        let marker = crate::terminal_respawn_text::marker(ran.as_ref().map(|ran| ran.as_ran()));
        // An agent's live input frame is not replayed.
        let frame = previous
            .as_ref()
            .filter(|_| matches!(ran, Some(prefill::RanText::Agent(_))))
            .and_then(agent_frame_rows);
        let seed = respawn_seed_without_frame(
            previous.map(|previous| previous.bytes),
            frame,
            Some(&marker),
        );
        RespawnLaunch {
            options,
            cell_pixels: geometry.map_or(creation_cell_pixels, |(_, cell_pixels)| cell_pixels),
            seed,
        }
    }
}

/// The shell a respawn starts: the recorded shell of a shell terminal while
/// it exists, else the platform's default shell.
pub(in crate::mux) fn respawn_shell(record: Option<&StoredRelaunch>) -> String {
    record
        .filter(|record| record.kind == RelaunchKind::Shell)
        .and_then(|record| record.shell_path.clone())
        .filter(|shell| Path::new(shell).is_file())
        .unwrap_or_else(crate::platform::default_shell)
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

/// Where a lost agent's live input frame sits on its replayed screen
/// `previous`: how many rows above the cursor it starts (0: on the cursor's
/// row), down to the bottom of the screen. Inline agent TUIs keep the cursor
/// in their prompt box, at the bottom, under the transcript and one blank
/// row: the frame is the block of non-blank rows around the cursor, from
/// the nearest blank row above it (at most [`MAX_AGENT_FRAME_ROWS`] up; with
/// none, from the cursor's row). `None` on the alternate screen (the mode
/// reset leaves it, and a full-screen frame with it) or when the screen
/// cannot be read.
pub(in crate::mux) fn agent_frame_rows(previous: &TerminalReplay) -> Option<u16> {
    let (cols, rows) = (previous.cols.max(1), previous.rows.max(1));
    let mut term = ghostty_vt::Terminal::new(cols, rows, 1_000, Default::default()).ok()?;
    term.vt_write(&previous.bytes);
    if term.active_screen() == ghostty_vt::Screen::Alternate {
        return None;
    }
    let (_, cursor) = term.cursor_position()?;
    let mut blank = |row: u16| {
        term.selection_text((0, row), (cols - 1, row)).is_none_or(|text| text.trim().is_empty())
    };
    if blank(cursor) {
        return Some(0);
    }
    let mut top = cursor;
    while top > 0 && cursor - top < MAX_AGENT_FRAME_ROWS {
        if blank(top - 1) {
            return Some(cursor - top);
        }
        top -= 1;
    }
    Some(0)
}

/// [`respawn_seed`], with the rows from `frame` rows above the replayed
/// cursor to the bottom of the screen erased (an agent's input frame,
/// [`agent_frame_rows`]); the marker line takes the frame's first row.
/// Relative moves keep the erase on the replayed cursor's rows whatever size
/// the new terminal has.
pub(in crate::mux) fn respawn_seed_without_frame(
    previous: Option<Vec<u8>>,
    frame: Option<u16>,
    marker: Option<&str>,
) -> Vec<u8> {
    let budget = crate::surface::VT_REPLAY_MAX_BYTES.saturating_sub(MARKER_HEADROOM_BYTES);
    let previous = previous.filter(|previous| previous.len() <= budget);
    let (mut seed, up) = match (previous, frame) {
        (Some(previous), Some(up)) => (previous, up),
        (previous, _) => return respawn_seed(previous, marker),
    };
    seed.extend_from_slice(b"\r");
    if up > 0 {
        seed.extend_from_slice(format!("\x1b[{up}A").as_bytes());
    }
    seed.extend_from_slice(b"\x1b[J");
    seed.extend_from_slice(MODE_RESET);
    push_marker(&mut seed, marker);
    seed
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
    push_marker(&mut seed, marker);
    seed
}

/// One dim `marker` line (none: nothing).
fn push_marker(seed: &mut Vec<u8>, marker: Option<&str>) {
    if let Some(marker) = marker {
        seed.extend_from_slice(b"\x1b[2m");
        seed.extend(marker.chars().filter(|c| !c.is_control()).collect::<String>().bytes());
        seed.extend_from_slice(b"\x1b[0m\r\n");
    }
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

    /// The rows a terminal of `cols`x`rows` shows after `bytes`, trimmed.
    fn shown(cols: u16, rows: u16, bytes: &[u8]) -> Vec<String> {
        let mut term = ghostty_vt::Terminal::new(cols, rows, 1_000, Default::default()).unwrap();
        term.vt_write(bytes);
        (0..rows)
            .map(|row| term.selection_text((0, row), (cols - 1, row)).unwrap_or_default())
            .map(|text| text.trim_end().to_string())
            .collect()
    }

    /// Muse Code's screen at its host's death (dogfood, Oct 27): transcript,
    /// one blank row, then its input frame with the cursor on the prompt.
    fn muse_screen() -> TerminalReplay {
        let bytes = "Worked for 17m 28s \u{b7} 8:35 PM\r\n\
             \u{25c7} Running command\r\n\
             \r\n\
             \u{2500}\u{2500} Voice input (\u{2325} + v to start) \u{2500}\u{2500}\r\n\
             \u{276f} \r\n\
             \u{2500}\u{2500}\u{2500}\u{2500}\r\n\
             \x20 muse-wonder-1.0 \u{b7} high \u{b7} YOLO\x1b[2A\r\x1b[2C";
        TerminalReplay { cols: 60, rows: 10, bytes: bytes.as_bytes().to_vec() }
    }

    #[test]
    fn an_agents_input_frame_starts_below_the_blank_row_above_its_cursor() {
        assert_eq!(agent_frame_rows(&muse_screen()), Some(1), "the voice bar, one row up");
        // The cursor on a blank row: from that row.
        let blank = TerminalReplay { cols: 20, rows: 4, bytes: b"text\r\n\r\n".to_vec() };
        assert_eq!(agent_frame_rows(&blank), Some(0));
        // No blank row near the cursor: only from its row.
        let dense = (0..30).map(|row| format!("line {row}\r\n")).collect::<String>() + "last";
        let dense = TerminalReplay { cols: 20, rows: 30, bytes: dense.into_bytes() };
        assert_eq!(agent_frame_rows(&dense), Some(0));
        // A full-screen program: the mode reset leaves its screen already.
        let full = TerminalReplay { cols: 20, rows: 4, bytes: b"\x1b[?1049hframe".to_vec() };
        assert_eq!(agent_frame_rows(&full), None);
    }

    #[test]
    fn a_respawned_agent_terminal_keeps_the_transcript_but_not_the_input_frame() {
        let screen = muse_screen();
        let frame = agent_frame_rows(&screen);
        let seed = respawn_seed_without_frame(Some(screen.bytes), frame, Some("restored"));
        let rows = shown(60, 10, &seed);
        let text = rows.join("\n");
        assert!(text.contains("Worked for 17m 28s"), "{text}");
        assert!(text.contains("Running command"), "{text}");
        for chrome in ["Voice input", "\u{276f}", "muse-wonder", "\u{2500}"] {
            assert!(!text.contains(chrome), "{chrome:?} was replayed: {text}");
        }
        assert_eq!(rows[3], "restored", "the marker takes the frame's place: {text}");
        // Without a frame the seed is the plain one.
        assert_eq!(
            respawn_seed_without_frame(Some(b"old".to_vec()), None, Some("restored")),
            respawn_seed(Some(b"old".to_vec()), Some("restored"))
        );
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

    /// Failure-mode table, "unreplayable screen": a previous screen that ends
    /// inside a control string (a Kitty upload the lost program never ended)
    /// does not swallow the reset and the marker line. (Coverage: it held
    /// before this PR too; the parser leaves the string at the reset's ESC.)
    #[test]
    fn a_screen_that_ends_inside_a_control_string_keeps_the_marker_line() {
        let seed =
            respawn_seed(Some(b"text\r\n\x1b_Ga=t,f=100,m=1;AAAA".to_vec()), Some("restored"));
        let rows = shown(40, 5, &seed);
        assert!(rows.iter().any(|row| row == "restored"), "the marker was swallowed: {rows:?}");
    }
}
