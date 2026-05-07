use cmux_cli_core::compositor::{
    self, Cell, Frame, RgbColor, StyleColor, TerminalCursor, TerminalCursorStyle,
    TerminalGridDefaultColors, TerminalGridSnapshot,
};
use cmux_cli_protocol::{
    NativeTerminalCursorPosition, NativeTerminalCursorStyle, NativeTerminalGridCell,
    NativeTerminalGridSnapshot, NativeTerminalTheme, NativeTerminalThemeSet, TerminalColorReport,
    TerminalRgb,
};
use libghostty_vt::style::RgbColor as GhosttyRgbColor;

use cmux_cli_core::probe;

use crate::render::TabId;
use crate::render::TerminalProbeColors;

pub(crate) fn terminal_probe_colors_from_report(
    report: &TerminalColorReport,
) -> TerminalProbeColors {
    TerminalProbeColors {
        foreground: report.foreground.map(terminal_rgb_to_ghostty),
        background: report.background.map(terminal_rgb_to_ghostty),
    }
}

pub(crate) fn terminal_theme_set_from_report(
    report: &TerminalColorReport,
) -> Option<NativeTerminalThemeSet> {
    if report.foreground.is_none() && report.background.is_none() && report.palette.is_empty() {
        return None;
    }

    Some(NativeTerminalThemeSet {
        default: Some(NativeTerminalTheme {
            palette: report
                .palette
                .iter()
                .map(|(index, color)| (*index, terminal_rgb_label(*color)))
                .collect(),
            foreground: report.foreground.map(terminal_rgb_label),
            background: report.background.map(terminal_rgb_label),
            ..NativeTerminalTheme::default()
        }),
        ..NativeTerminalThemeSet::default()
    })
}

pub(crate) fn terminal_default_colors_from_report(
    report: &TerminalColorReport,
) -> TerminalGridDefaultColors {
    TerminalGridDefaultColors {
        foreground: report.foreground.map(terminal_rgb_to_ghostty),
        background: report.background.map(terminal_rgb_to_ghostty),
        palette: (!report.palette.is_empty()).then(|| {
            let mut palette = default_terminal_color_palette();
            for (index, color) in &report.palette {
                palette[usize::from(*index)] = terminal_rgb_to_ghostty(*color);
            }
            palette
        }),
    }
}

pub(crate) fn active_terminal_theme_set_for_host(
    theme_set: &NativeTerminalThemeSet,
) -> NativeTerminalThemeSet {
    active_terminal_theme_set(theme_set, host_prefers_dark_theme())
}

pub(crate) fn terminal_default_colors_from_theme(
    theme_set: Option<&NativeTerminalThemeSet>,
) -> TerminalGridDefaultColors {
    let fallback = fallback_terminal_default_colors();
    let Some(theme_set) = theme_set else {
        return fallback;
    };
    let prefers_dark = host_prefers_dark_theme();
    let theme = active_theme(theme_set, prefers_dark);
    let colors = TerminalGridDefaultColors {
        foreground: theme
            .and_then(|theme| theme.foreground.as_deref().and_then(parse_hex_rgb))
            .or(fallback.foreground),
        background: theme
            .and_then(|theme| theme.background.as_deref().and_then(parse_hex_rgb))
            .or(fallback.background),
        palette: terminal_palette_from_theme(theme).or(fallback.palette),
    };
    if probe::color_enabled() {
        probe::log_event(
            "native_terminal",
            "terminal_default_colors_selected",
            &[
                ("prefers_dark", prefers_dark.to_string()),
                ("summary", terminal_default_colors_summary(colors)),
            ],
        );
    }
    colors
}

fn active_terminal_theme_set(
    theme_set: &NativeTerminalThemeSet,
    prefers_dark: bool,
) -> NativeTerminalThemeSet {
    NativeTerminalThemeSet {
        default: active_theme(theme_set, prefers_dark).cloned(),
        ..NativeTerminalThemeSet::default()
    }
}

fn active_theme(
    theme_set: &NativeTerminalThemeSet,
    prefers_dark: bool,
) -> Option<&NativeTerminalTheme> {
    if prefers_dark {
        theme_set
            .dark
            .as_ref()
            .or(theme_set.default.as_ref())
            .or(theme_set.light.as_ref())
    } else {
        theme_set
            .light
            .as_ref()
            .or(theme_set.default.as_ref())
            .or(theme_set.dark.as_ref())
    }
}

fn host_prefers_dark_theme() -> bool {
    std::env::var("CMX_FORCE_COLOR_SCHEME")
        .ok()
        .map(|scheme| scheme.eq_ignore_ascii_case("dark"))
        .unwrap_or_else(host_prefers_dark_theme_from_system)
}

#[cfg(target_os = "macos")]
fn host_prefers_dark_theme_from_system() -> bool {
    std::process::Command::new("defaults")
        .args(["read", "-g", "AppleInterfaceStyle"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("Dark"))
}

#[cfg(not(target_os = "macos"))]
fn host_prefers_dark_theme_from_system() -> bool {
    true
}

pub(crate) fn native_terminal_grid_snapshot(
    tab_id: TabId,
    snapshot: TerminalGridSnapshot,
) -> NativeTerminalGridSnapshot {
    NativeTerminalGridSnapshot {
        tab_id,
        cols: snapshot.cols,
        rows: snapshot.rows,
        cells: snapshot
            .cells
            .into_iter()
            .map(|cell| NativeTerminalGridCell {
                text: cell.text,
                width: cell.width,
                fg: ghostty_rgb_to_terminal(cell.fg),
                bg: ghostty_rgb_to_terminal(cell.bg),
                bold: cell.bold,
                italic: cell.italic,
                underline: cell.underline,
                faint: cell.faint,
                blink: cell.blink,
                strikethrough: cell.strikethrough,
            })
            .collect(),
        cursor: snapshot.cursor.map(|cursor| NativeTerminalCursorPosition {
            col: cursor.col,
            row: cursor.row,
            visible: cursor.visible,
            style: match cursor.style {
                TerminalCursorStyle::Block => NativeTerminalCursorStyle::Block,
                TerminalCursorStyle::HollowBlock => NativeTerminalCursorStyle::HollowBlock,
                TerminalCursorStyle::Underline => NativeTerminalCursorStyle::Underline,
                TerminalCursorStyle::Bar => NativeTerminalCursorStyle::Bar,
            },
            color: cursor.color.map(ghostty_rgb_to_terminal),
        }),
    }
}

pub(crate) fn native_terminal_pty_replay_from_grid_snapshot(
    snapshot: TerminalGridSnapshot,
    alternate_screen: bool,
) -> Vec<u8> {
    let cursor = snapshot.cursor;
    let mut frame = Frame::new(snapshot.cols, snapshot.rows);
    let cols = usize::from(snapshot.cols);
    if cols == 0 || snapshot.rows == 0 {
        return native_terminal_cursor_tail(cursor);
    }

    for (index, cell) in snapshot.cells.into_iter().enumerate() {
        let row = index / cols;
        let col = index % cols;
        if row >= frame.cells.len() || col >= frame.cells[row].len() {
            break;
        }
        frame.cells[row][col] = Cell {
            grapheme: cell.text,
            width: cell.width,
            is_continuation: cell.width == 0,
            fg: StyleColor::Rgb(cell.fg),
            bg: StyleColor::Rgb(cell.bg),
            bold: cell.bold,
            italic: cell.italic,
            underline: cell.underline,
            faint: cell.faint,
            strikethrough: cell.strikethrough,
            reverse: false,
            blink: cell.blink,
        };
    }

    // Client-side libghostty cannot safely replay arbitrary recent PTY history
    // after a resize or blank-screen probe: that history can include obsolete
    // prompts and earlier geometry. Draw the authoritative server grid instead.
    let mut out = Vec::new();
    if alternate_screen {
        out.extend_from_slice(b"\x1b[?1049h");
    }
    out.extend_from_slice(&compositor::emit_ansi(&frame));
    out.extend_from_slice(&native_terminal_cursor_tail(cursor));
    out
}

fn native_terminal_cursor_tail(cursor: Option<TerminalCursor>) -> Vec<u8> {
    let Some(cursor) = cursor else {
        return b"\x1b[?25h".to_vec();
    };
    if !cursor.visible {
        return b"\x1b[?25l".to_vec();
    }

    let mut out = Vec::new();
    out.extend_from_slice(match cursor.style {
        TerminalCursorStyle::Block | TerminalCursorStyle::HollowBlock => b"\x1b[2 q",
        TerminalCursorStyle::Underline => b"\x1b[4 q",
        TerminalCursorStyle::Bar => b"\x1b[6 q",
    });
    out.extend_from_slice(b"\x1b[?25h");
    out.extend_from_slice(
        format!(
            "\x1b[{};{}H",
            u32::from(cursor.row) + 1,
            u32::from(cursor.col) + 1
        )
        .as_bytes(),
    );
    out
}

fn terminal_rgb_to_ghostty(color: TerminalRgb) -> GhosttyRgbColor {
    GhosttyRgbColor {
        r: color.r,
        g: color.g,
        b: color.b,
    }
}

fn ghostty_rgb_to_terminal(color: GhosttyRgbColor) -> TerminalRgb {
    TerminalRgb {
        r: color.r,
        g: color.g,
        b: color.b,
    }
}

fn terminal_rgb_label(color: TerminalRgb) -> String {
    format!("#{:02X}{:02X}{:02X}", color.r, color.g, color.b)
}

fn terminal_default_colors_summary(colors: TerminalGridDefaultColors) -> String {
    let palette = colors
        .palette
        .map(|palette| {
            [
                0usize, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 81, 118, 135, 166,
            ]
            .into_iter()
            .map(|index| format!("{index}={}", rgb_label(palette[index])))
            .collect::<Vec<_>>()
            .join(",")
        })
        .unwrap_or_else(|| "-".to_string());
    format!(
        "fg={} bg={} palette={}",
        colors
            .foreground
            .map(rgb_label)
            .unwrap_or_else(|| "-".to_string()),
        colors
            .background
            .map(rgb_label)
            .unwrap_or_else(|| "-".to_string()),
        palette,
    )
}

fn rgb_label(color: RgbColor) -> String {
    format!("#{:02X}{:02X}{:02X}", color.r, color.g, color.b)
}

fn terminal_palette_from_theme(theme: Option<&NativeTerminalTheme>) -> Option<[RgbColor; 256]> {
    let theme = theme?;
    let mut palette = default_terminal_color_palette();
    for (index, value) in &theme.palette {
        apply_palette_color(&mut palette, usize::from(*index), Some(value.as_str()));
    }
    apply_palette_color(&mut palette, 0, theme.black.as_deref());
    apply_palette_color(&mut palette, 1, theme.red.as_deref());
    apply_palette_color(&mut palette, 2, theme.green.as_deref());
    apply_palette_color(&mut palette, 3, theme.yellow.as_deref());
    apply_palette_color(&mut palette, 4, theme.blue.as_deref());
    apply_palette_color(&mut palette, 5, theme.magenta.as_deref());
    apply_palette_color(&mut palette, 6, theme.cyan.as_deref());
    apply_palette_color(&mut palette, 7, theme.white.as_deref());
    apply_palette_color(&mut palette, 8, theme.bright_black.as_deref());
    apply_palette_color(&mut palette, 9, theme.bright_red.as_deref());
    apply_palette_color(&mut palette, 10, theme.bright_green.as_deref());
    apply_palette_color(&mut palette, 11, theme.bright_yellow.as_deref());
    apply_palette_color(&mut palette, 12, theme.bright_blue.as_deref());
    apply_palette_color(&mut palette, 13, theme.bright_magenta.as_deref());
    apply_palette_color(&mut palette, 14, theme.bright_cyan.as_deref());
    apply_palette_color(&mut palette, 15, theme.bright_white.as_deref());
    Some(palette)
}

fn fallback_terminal_default_colors() -> TerminalGridDefaultColors {
    TerminalGridDefaultColors {
        foreground: Some(RgbColor {
            r: 253,
            g: 255,
            b: 241,
        }),
        background: Some(RgbColor {
            r: 39,
            g: 40,
            b: 34,
        }),
        palette: Some(monokai_terminal_color_palette()),
    }
}

fn monokai_terminal_color_palette() -> [RgbColor; 256] {
    let mut palette = default_terminal_color_palette();
    let ansi = [
        (0x27, 0x28, 0x22),
        (0xf9, 0x26, 0x72),
        (0xa6, 0xe2, 0x2e),
        (0xe6, 0xdb, 0x74),
        (0x66, 0xd9, 0xef),
        (0xae, 0x81, 0xff),
        (0xa1, 0xef, 0xe4),
        (0xfd, 0xff, 0xf1),
        (0x75, 0x71, 0x5e),
        (0xf9, 0x26, 0x72),
        (0xa6, 0xe2, 0x2e),
        (0xe6, 0xdb, 0x74),
        (0x66, 0xd9, 0xef),
        (0xae, 0x81, 0xff),
        (0xa1, 0xef, 0xe4),
        (0xff, 0xff, 0xff),
    ];
    for (index, (r, g, b)) in ansi.into_iter().enumerate() {
        palette[index] = RgbColor { r, g, b };
    }
    palette
}

fn default_terminal_color_palette() -> [RgbColor; 256] {
    let mut palette = [RgbColor { r: 0, g: 0, b: 0 }; 256];
    let ansi = [
        (0x00, 0x00, 0x00),
        (0xcd, 0x00, 0x00),
        (0x00, 0xcd, 0x00),
        (0xcd, 0xcd, 0x00),
        (0x00, 0x00, 0xee),
        (0xcd, 0x00, 0xcd),
        (0x00, 0xcd, 0xcd),
        (0xe5, 0xe5, 0xe5),
        (0x7f, 0x7f, 0x7f),
        (0xff, 0x00, 0x00),
        (0x00, 0xff, 0x00),
        (0xff, 0xff, 0x00),
        (0x5c, 0x5c, 0xff),
        (0xff, 0x00, 0xff),
        (0x00, 0xff, 0xff),
        (0xff, 0xff, 0xff),
    ];
    for (index, (r, g, b)) in ansi.into_iter().enumerate() {
        palette[index] = RgbColor { r, g, b };
    }

    let levels = [0, 95, 135, 175, 215, 255];
    for red in 0..6 {
        for green in 0..6 {
            for blue in 0..6 {
                let index = 16 + 36 * red + 6 * green + blue;
                palette[index] = RgbColor {
                    r: levels[red],
                    g: levels[green],
                    b: levels[blue],
                };
            }
        }
    }

    for gray in 0..24 {
        let level = 8 + gray * 10;
        palette[232 + gray] = RgbColor {
            r: level as u8,
            g: level as u8,
            b: level as u8,
        };
    }
    palette
}

fn apply_palette_color(palette: &mut [RgbColor; 256], index: usize, value: Option<&str>) {
    if let Some(color) = value.and_then(parse_hex_rgb) {
        palette[index] = color;
    }
}

fn parse_hex_rgb(value: &str) -> Option<RgbColor> {
    let raw = value.trim().strip_prefix('#')?;
    if raw.len() != 6 {
        return None;
    }
    let parsed = u32::from_str_radix(raw, 16).ok()?;
    Some(RgbColor {
        r: ((parsed >> 16) & 0xff) as u8,
        g: ((parsed >> 8) & 0xff) as u8,
        b: (parsed & 0xff) as u8,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn rgb(r: u8, g: u8, b: u8) -> RgbColor {
        RgbColor { r, g, b }
    }

    #[test]
    fn pty_replay_from_grid_snapshot_draws_current_cells_and_cursor() {
        let snapshot = TerminalGridSnapshot {
            cols: 3,
            rows: 2,
            cells: vec![
                cmux_cli_core::compositor::TerminalGridCell {
                    text: "A".into(),
                    width: 1,
                    fg: rgb(253, 255, 241),
                    bg: rgb(39, 40, 34),
                    bold: true,
                    italic: false,
                    underline: false,
                    faint: false,
                    blink: false,
                    strikethrough: false,
                },
                cmux_cli_core::compositor::TerminalGridCell {
                    text: "界".into(),
                    width: 2,
                    fg: rgb(249, 38, 114),
                    bg: rgb(39, 40, 34),
                    bold: false,
                    italic: true,
                    underline: true,
                    faint: false,
                    blink: false,
                    strikethrough: false,
                },
                cmux_cli_core::compositor::TerminalGridCell {
                    text: " ".into(),
                    width: 0,
                    fg: rgb(249, 38, 114),
                    bg: rgb(39, 40, 34),
                    bold: false,
                    italic: false,
                    underline: false,
                    faint: false,
                    blink: false,
                    strikethrough: false,
                },
                cmux_cli_core::compositor::TerminalGridCell {
                    text: " ".into(),
                    width: 1,
                    fg: rgb(253, 255, 241),
                    bg: rgb(39, 40, 34),
                    bold: false,
                    italic: false,
                    underline: false,
                    faint: false,
                    blink: false,
                    strikethrough: false,
                },
                cmux_cli_core::compositor::TerminalGridCell {
                    text: "B".into(),
                    width: 1,
                    fg: rgb(166, 226, 46),
                    bg: rgb(39, 40, 34),
                    bold: false,
                    italic: false,
                    underline: false,
                    faint: false,
                    blink: false,
                    strikethrough: true,
                },
                cmux_cli_core::compositor::TerminalGridCell {
                    text: " ".into(),
                    width: 1,
                    fg: rgb(253, 255, 241),
                    bg: rgb(39, 40, 34),
                    bold: false,
                    italic: false,
                    underline: false,
                    faint: false,
                    blink: false,
                    strikethrough: false,
                },
            ],
            cursor: Some(TerminalCursor {
                col: 1,
                row: 1,
                visible: true,
                style: TerminalCursorStyle::Bar,
                color: None,
            }),
        };

        let ansi = native_terminal_pty_replay_from_grid_snapshot(snapshot, true);
        let rendered = String::from_utf8(ansi).expect("utf8 ansi");

        assert!(rendered.starts_with("\x1b[?1049h\x1b[?25l\x1b[H"));
        assert!(rendered.contains("\x1b[38;2;253;255;241m"));
        assert!(rendered.contains("\x1b[48;2;39;40;34m"));
        assert!(rendered.contains("\x1b[1mA"));
        assert!(rendered.contains("\x1b[3m\x1b[4m界"));
        assert!(rendered.contains("\x1b[9mB"));
        assert!(rendered.contains("\x1b[6 q\x1b[?25h\x1b[2;2H"));
    }

    #[test]
    fn terminal_default_colors_include_ghostty_theme_palette() {
        let mut palette_overrides = BTreeMap::new();
        palette_overrides.insert(135, "#AF5FFF".to_string());
        let theme_set = NativeTerminalThemeSet {
            dark: Some(NativeTerminalTheme {
                palette: palette_overrides,
                foreground: Some("#FDFFF1".into()),
                background: Some("#272822".into()),
                magenta: Some("#AE81FF".into()),
                bright_magenta: Some("#BE96FF".into()),
                ..NativeTerminalTheme::default()
            }),
            ..NativeTerminalThemeSet::default()
        };

        let colors = terminal_default_colors_from_theme(Some(&theme_set));

        assert_eq!(
            colors.foreground,
            Some(RgbColor {
                r: 253,
                g: 255,
                b: 241,
            })
        );
        assert_eq!(
            colors.background,
            Some(RgbColor {
                r: 39,
                g: 40,
                b: 34,
            })
        );
        let palette = colors.palette.expect("theme palette");
        assert_eq!(
            palette[5],
            RgbColor {
                r: 174,
                g: 129,
                b: 255,
            }
        );
        assert_eq!(
            palette[13],
            RgbColor {
                r: 190,
                g: 150,
                b: 255,
            }
        );
        assert_eq!(
            palette[135],
            RgbColor {
                r: 175,
                g: 95,
                b: 255,
            }
        );
    }

    #[test]
    fn terminal_default_colors_fallback_to_readable_monokai_when_theme_is_missing() {
        let colors = terminal_default_colors_from_theme(None);

        assert_eq!(
            colors.foreground,
            Some(RgbColor {
                r: 253,
                g: 255,
                b: 241,
            })
        );
        assert_eq!(
            colors.background,
            Some(RgbColor {
                r: 39,
                g: 40,
                b: 34,
            })
        );
        let palette = colors.palette.expect("fallback palette");
        assert_eq!(
            palette[1],
            RgbColor {
                r: 249,
                g: 38,
                b: 114,
            }
        );
        assert_eq!(
            palette[2],
            RgbColor {
                r: 166,
                g: 226,
                b: 46,
            }
        );
        assert_eq!(
            palette[7],
            RgbColor {
                r: 253,
                g: 255,
                b: 241,
            }
        );
    }

    #[test]
    fn terminal_theme_set_uses_reported_host_palette() {
        let mut palette = BTreeMap::new();
        palette.insert(
            118,
            TerminalRgb {
                r: 95,
                g: 215,
                b: 0,
            },
        );
        palette.insert(
            135,
            TerminalRgb {
                r: 175,
                g: 95,
                b: 255,
            },
        );
        let report = TerminalColorReport {
            foreground: Some(TerminalRgb {
                r: 253,
                g: 255,
                b: 241,
            }),
            background: Some(TerminalRgb {
                r: 39,
                g: 40,
                b: 34,
            }),
            palette,
        };

        let theme_set = terminal_theme_set_from_report(&report).expect("reported theme");
        let theme = theme_set.default.expect("default theme");

        assert_eq!(theme.foreground.as_deref(), Some("#FDFFF1"));
        assert_eq!(theme.background.as_deref(), Some("#272822"));
        assert_eq!(theme.palette.get(&118).map(String::as_str), Some("#5FD700"));
        assert_eq!(theme.palette.get(&135).map(String::as_str), Some("#AF5FFF"));
    }

    #[test]
    fn active_terminal_theme_set_collapses_to_host_selected_theme() {
        let theme_set = NativeTerminalThemeSet {
            light: Some(NativeTerminalTheme {
                foreground: Some("#111111".into()),
                background: Some("#FAF9F0".into()),
                ..NativeTerminalTheme::default()
            }),
            dark: Some(NativeTerminalTheme {
                foreground: Some("#EEEEEE".into()),
                background: Some("#101010".into()),
                ..NativeTerminalTheme::default()
            }),
            ..NativeTerminalThemeSet::default()
        };

        let light = active_terminal_theme_set(&theme_set, false);
        let dark = active_terminal_theme_set(&theme_set, true);

        assert_eq!(
            light.default.and_then(|theme| theme.background).as_deref(),
            Some("#FAF9F0")
        );
        assert_eq!(
            dark.default.and_then(|theme| theme.background).as_deref(),
            Some("#101010")
        );
        assert!(light.light.is_none());
        assert!(light.dark.is_none());
    }

    #[test]
    fn terminal_default_colors_do_not_invent_palette_for_old_reports() {
        let report = TerminalColorReport {
            foreground: Some(TerminalRgb { r: 1, g: 2, b: 3 }),
            background: Some(TerminalRgb { r: 4, g: 5, b: 6 }),
            palette: BTreeMap::new(),
        };

        let colors = terminal_default_colors_from_report(&report);

        assert_eq!(colors.foreground, Some(RgbColor { r: 1, g: 2, b: 3 }));
        assert_eq!(colors.background, Some(RgbColor { r: 4, g: 5, b: 6 }));
        assert_eq!(colors.palette, None);
    }

    #[test]
    fn terminal_default_colors_preserve_extended_ghostty_palette() {
        let theme_set = NativeTerminalThemeSet {
            dark: Some(NativeTerminalTheme {
                foreground: Some("#FDFFF1".into()),
                background: Some("#272822".into()),
                magenta: Some("#AE81FF".into()),
                ..NativeTerminalTheme::default()
            }),
            ..NativeTerminalThemeSet::default()
        };

        let colors = terminal_default_colors_from_theme(Some(&theme_set));
        let palette = colors.palette.expect("theme palette");
        assert_eq!(
            palette[81],
            RgbColor {
                r: 95,
                g: 215,
                b: 255,
            }
        );
        assert_eq!(
            palette[118],
            RgbColor {
                r: 135,
                g: 255,
                b: 0,
            }
        );
        assert_eq!(
            palette[135],
            RgbColor {
                r: 175,
                g: 95,
                b: 255,
            }
        );
        assert_eq!(
            palette[166],
            RgbColor {
                r: 215,
                g: 95,
                b: 0,
            }
        );
    }
}
