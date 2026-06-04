//! Capture a tmux pane as a styled terminal-cell snapshot.
//!
//! This is a debugging tool for comparing what a real terminal sees when the
//! same program runs directly in tmux versus inside `cmx attach`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand};
use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
use libghostty_vt::style::{StyleColor, Underline};
use libghostty_vt::{Terminal, TerminalOptions};
use serde::Serialize;

#[derive(Parser, Debug)]
#[command(
    name = "cmx-termshot",
    about = "Capture/compare styled terminal cells from tmux"
)]
struct Cli {
    #[command(subcommand)]
    command: TermshotCommand,
}

#[derive(Subcommand, Debug)]
enum TermshotCommand {
    /// Capture one tmux pane as JSON.
    Capture {
        /// tmux target pane/session, e.g. `my-session` or `%1`.
        #[arg(long)]
        target: String,
        /// Optional crop as `col,row,cols,rows`.
        #[arg(long)]
        crop: Option<Crop>,
        /// Write JSON here instead of stdout.
        #[arg(long)]
        out: Option<PathBuf>,
        /// Pretty-print JSON.
        #[arg(long)]
        pretty: bool,
    },
    /// Capture and compare two tmux panes.
    Compare {
        /// Left/reference tmux target.
        #[arg(long)]
        left: String,
        /// Right/candidate tmux target.
        #[arg(long)]
        right: String,
        /// Optional crop for the left/reference snapshot.
        #[arg(long)]
        left_crop: Option<Crop>,
        /// Optional crop for the right/candidate snapshot.
        #[arg(long)]
        right_crop: Option<Crop>,
        /// Maximum detailed cell diffs to include.
        #[arg(long, default_value_t = 24)]
        max_diffs: usize,
        /// Write JSON here instead of stdout.
        #[arg(long)]
        out: Option<PathBuf>,
        /// Pretty-print JSON.
        #[arg(long)]
        pretty: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Crop {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
}

impl std::str::FromStr for Crop {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let parts = value
            .split(',')
            .map(str::trim)
            .map(str::parse::<u16>)
            .collect::<Result<Vec<_>, _>>()
            .context("crop must be four u16 numbers: col,row,cols,rows")?;
        let [col, row, cols, rows]: [u16; 4] = parts
            .try_into()
            .map_err(|_| anyhow!("crop must have exactly four fields: col,row,cols,rows"))?;
        if cols == 0 || rows == 0 {
            bail!("crop cols and rows must be non-zero");
        }
        Ok(Self {
            col,
            row,
            cols,
            rows,
        })
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
struct CropJson {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
}

impl From<Crop> for CropJson {
    fn from(value: Crop) -> Self {
        Self {
            col: value.col,
            row: value.row,
            cols: value.cols,
            rows: value.rows,
        }
    }
}

#[derive(Debug, Serialize)]
struct Shot {
    target: String,
    cols: u16,
    rows: u16,
    crop: Option<CropJson>,
    text: Vec<String>,
    cells: Vec<Vec<CellShot>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct CellShot {
    text: String,
    fg: ColorShot,
    bg: ColorShot,
    underline_color: ColorShot,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum ColorShot {
    Default,
    Palette { index: u8 },
    Rgb { r: u8, g: u8, b: u8 },
}

#[derive(Debug, Serialize)]
struct CompareReport {
    equal: bool,
    left: String,
    right: String,
    left_size: Size,
    right_size: Size,
    compared_size: Size,
    text_diff_count: usize,
    style_diff_count: usize,
    total_diff_count: usize,
    first_diffs: Vec<CellDiff>,
}

#[derive(Debug, Serialize)]
struct Size {
    cols: u16,
    rows: u16,
}

#[derive(Debug, Serialize)]
struct CellDiff {
    x: u16,
    y: u16,
    diff: String,
    left: CellShot,
    right: CellShot,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        TermshotCommand::Capture {
            target,
            crop,
            out,
            pretty,
        } => {
            let shot = capture_shot(&target, crop)?;
            write_json(&shot, out.as_ref(), pretty)
        }
        TermshotCommand::Compare {
            left,
            right,
            left_crop,
            right_crop,
            max_diffs,
            out,
            pretty,
        } => {
            let left_shot = capture_shot(&left, left_crop)?;
            let right_shot = capture_shot(&right, right_crop)?;
            let report = compare_shots(&left_shot, &right_shot, max_diffs);
            write_json(&report, out.as_ref(), pretty)
        }
    }
}

fn capture_shot(target: &str, crop: Option<Crop>) -> Result<Shot> {
    let (cols, rows) = tmux_pane_size(target)?;
    let raw = tmux_capture_ansi(target)?;
    let vt = normalize_capture_rows(&raw, rows);
    let mut terminal = Terminal::new(TerminalOptions {
        cols,
        rows,
        max_scrollback: 0,
    })
    .context("create capture terminal")?;
    terminal.vt_write(&vt);
    snapshot_terminal(target, &terminal, cols, rows, crop)
}

fn tmux_pane_size(target: &str) -> Result<(u16, u16)> {
    let out = Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-t",
            target,
            "#{pane_width} #{pane_height}",
        ])
        .output()
        .with_context(|| format!("query tmux pane size for {target:?}"))?;
    if !out.status.success() {
        bail!(
            "tmux display-message failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let stdout = String::from_utf8(out.stdout).context("tmux size output was not utf-8")?;
    let mut parts = stdout.split_whitespace();
    let cols = parts
        .next()
        .ok_or_else(|| anyhow!("missing pane width"))?
        .parse::<u16>()
        .context("parse pane width")?;
    let rows = parts
        .next()
        .ok_or_else(|| anyhow!("missing pane height"))?
        .parse::<u16>()
        .context("parse pane height")?;
    Ok((cols, rows))
}

fn tmux_capture_ansi(target: &str) -> Result<Vec<u8>> {
    let out = Command::new("tmux")
        .args(["capture-pane", "-e", "-N", "-p", "-t", target])
        .output()
        .with_context(|| format!("capture tmux pane {target:?}"))?;
    if !out.status.success() {
        bail!(
            "tmux capture-pane failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(out.stdout)
}

fn normalize_capture_rows(raw: &[u8], rows: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(raw.len().saturating_add(rows as usize * 12));
    for (row, line) in raw
        .split(|byte| *byte == b'\n')
        .take(rows as usize)
        .enumerate()
    {
        out.extend_from_slice(format!("\x1b[{};1H", row + 1).as_bytes());
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        out.extend_from_slice(line);
        out.extend_from_slice(b"\x1b[0m");
    }
    out
}

fn snapshot_terminal(
    target: &str,
    terminal: &Terminal<'_, '_>,
    cols: u16,
    rows: u16,
    crop: Option<Crop>,
) -> Result<Shot> {
    let crop = crop.unwrap_or(Crop {
        col: 0,
        row: 0,
        cols,
        rows,
    });
    if crop.col.saturating_add(crop.cols) > cols || crop.row.saturating_add(crop.rows) > rows {
        bail!(
            "crop {},{},{},{} exceeds pane size {}x{}",
            crop.col,
            crop.row,
            crop.cols,
            crop.rows,
            cols,
            rows
        );
    }

    let all_rows = terminal_cells(terminal)?;
    let mut text = Vec::with_capacity(crop.rows as usize);
    let mut cells = Vec::with_capacity(crop.rows as usize);
    for y in crop.row..crop.row.saturating_add(crop.rows) {
        let source_row = all_rows
            .get(y as usize)
            .ok_or_else(|| anyhow!("terminal snapshot missing row {y}"))?;
        let mut row_cells = Vec::with_capacity(crop.cols as usize);
        let mut row_text = String::new();
        for x in crop.col..crop.col.saturating_add(crop.cols) {
            let cell = source_row
                .get(x as usize)
                .ok_or_else(|| anyhow!("terminal snapshot missing cell {x},{y}"))?;
            row_text.push_str(if cell.text.is_empty() {
                " "
            } else {
                &cell.text
            });
            row_cells.push(cell.clone());
        }
        text.push(row_text.trim_end().to_string());
        cells.push(row_cells);
    }

    Ok(Shot {
        target: target.to_string(),
        cols: crop.cols,
        rows: crop.rows,
        crop: Some(crop.into()),
        text,
        cells,
    })
}

fn terminal_cells(terminal: &Terminal<'_, '_>) -> Result<Vec<Vec<CellShot>>> {
    let mut render_state = RenderState::new().context("create render state")?;
    let snapshot = render_state
        .update(terminal)
        .context("update render state")?;
    let mut row_iter = RowIterator::new().context("create row iterator")?;
    let mut row_iteration = row_iter.update(&snapshot).context("update row iterator")?;

    let mut rows = Vec::new();
    while row_iteration.next().is_some() {
        let mut cell_iter = CellIterator::new().context("create cell iterator")?;
        let mut cell_iteration = cell_iter
            .update(&row_iteration)
            .context("update cell iterator")?;

        let mut row = Vec::new();
        while cell_iteration.next().is_some() {
            let graphemes = cell_iteration.graphemes().unwrap_or_default();
            let mut text = graphemes
                .iter()
                .copied()
                .filter(|ch| *ch != '\0')
                .collect::<String>();
            if text.is_empty() {
                text.push(' ');
            }
            let style = cell_iteration.style().unwrap_or_default();
            row.push(CellShot {
                text,
                fg: color_shot(style.fg_color),
                bg: color_shot(style.bg_color),
                underline_color: color_shot(style.underline_color),
                bold: style.bold,
                italic: style.italic,
                faint: style.faint,
                blink: style.blink,
                inverse: style.inverse,
                invisible: style.invisible,
                strikethrough: style.strikethrough,
                overline: style.overline,
                underline: underline_name(style.underline).to_string(),
            });
        }
        rows.push(row);
    }
    Ok(rows)
}

fn color_shot(color: StyleColor) -> ColorShot {
    match color {
        StyleColor::None => ColorShot::Default,
        StyleColor::Palette(index) => ColorShot::Palette { index: index.0 },
        StyleColor::Rgb(rgb) => ColorShot::Rgb {
            r: rgb.r,
            g: rgb.g,
            b: rgb.b,
        },
    }
}

fn underline_name(underline: Underline) -> &'static str {
    match underline {
        Underline::None => "none",
        Underline::Single => "single",
        Underline::Double => "double",
        Underline::Curly => "curly",
        Underline::Dotted => "dotted",
        Underline::Dashed => "dashed",
        _ => "unknown",
    }
}

fn compare_shots(left: &Shot, right: &Shot, max_diffs: usize) -> CompareReport {
    let cols = left.cols.min(right.cols);
    let rows = left.rows.min(right.rows);
    let mut text_diff_count = 0usize;
    let mut style_diff_count = 0usize;
    let mut first_diffs = Vec::new();

    for y in 0..rows {
        for x in 0..cols {
            let left_cell = &left.cells[y as usize][x as usize];
            let right_cell = &right.cells[y as usize][x as usize];
            if left_cell == right_cell {
                continue;
            }
            let text_diff = left_cell.text != right_cell.text;
            if text_diff {
                text_diff_count = text_diff_count.saturating_add(1);
            } else {
                style_diff_count = style_diff_count.saturating_add(1);
            }
            if first_diffs.len() < max_diffs {
                first_diffs.push(CellDiff {
                    x,
                    y,
                    diff: if text_diff {
                        "text_or_width".to_string()
                    } else {
                        "style".to_string()
                    },
                    left: left_cell.clone(),
                    right: right_cell.clone(),
                });
            }
        }
    }

    let dim_extra = usize::from(left.cols != right.cols || left.rows != right.rows);
    let total_diff_count = text_diff_count
        .saturating_add(style_diff_count)
        .saturating_add(dim_extra);
    CompareReport {
        equal: total_diff_count == 0,
        left: left.target.clone(),
        right: right.target.clone(),
        left_size: Size {
            cols: left.cols,
            rows: left.rows,
        },
        right_size: Size {
            cols: right.cols,
            rows: right.rows,
        },
        compared_size: Size { cols, rows },
        text_diff_count,
        style_diff_count,
        total_diff_count,
        first_diffs,
    }
}

fn write_json<T: Serialize>(value: &T, out: Option<&PathBuf>, pretty: bool) -> Result<()> {
    let json = if pretty {
        serde_json::to_string_pretty(value)?
    } else {
        serde_json::to_string(value)?
    };
    if let Some(out) = out {
        fs::write(out, json).with_context(|| format!("write {}", out.display()))?;
    } else {
        println!("{json}");
    }
    Ok(())
}
