//! Status bar options and the resolution of configured status segments.

use super::*;

/// Bottom screens-bar options. A hidden bar gives its row back to the
/// panes; transient status messages still overlay the last row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusBarOptions {
    pub visible: bool,
    /// Renders the clickable screens strip.
    pub show_screens: bool,
    /// Renders the right-aligned session label when no message is shown.
    pub show_session: bool,
    /// Segments before the screens strip.
    pub left: Vec<StatusSegment>,
    /// Segments right-aligned before the session label.
    pub right: Vec<StatusSegment>,
    /// Powerline-style separator drawn between left segments and after the
    /// last one; its foreground takes the previous segment's background and
    /// its background the next segment's, tmux `status-left` style.
    pub left_separator: Option<String>,
    /// Mirror of `left_separator` for the right-aligned segments.
    pub right_separator: Option<String>,
    /// Cap style for the active screen chip in the screens strip.
    pub screens_style: ChipStyle,
    /// The screens strip's `+` button.
    pub screens_plus: PlusButton,
}

impl Default for StatusBarOptions {
    fn default() -> Self {
        Self {
            visible: true,
            show_screens: true,
            show_session: true,
            left: Vec::new(),
            right: Vec::new(),
            left_separator: None,
            right_separator: None,
            screens_style: ChipStyle::Block,
            screens_plus: PlusButton::default(),
        }
    }
}

impl StatusBarOptions {
    /// Command segments in draw order: left side first, then right.
    pub fn command_segments(&self) -> Vec<(usize, Vec<String>, Duration)> {
        self.left
            .iter()
            .chain(self.right.iter())
            .enumerate()
            .filter_map(|(index, segment)| match &segment.content {
                StatusSegmentContent::Command { argv, interval } => {
                    Some((index, argv.clone(), *interval))
                }
                StatusSegmentContent::Text(_) => None,
            })
            .collect()
    }
}

/// The maximum number of configured segments per status bar side.
pub const MAX_STATUS_SEGMENTS: usize = 8;

/// The maximum width of one literal status segment, in terminal cells.
pub const MAX_STATUS_SEGMENT_TEXT: usize = 256;

/// One status bar segment: literal text with `{variable}` interpolation, or
/// a command whose last stdout line becomes the segment text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusSegment {
    pub content: StatusSegmentContent,
    pub fg: Option<Color>,
    pub bg: Option<Color>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatusSegmentContent {
    Text(String),
    Command { argv: Vec<String>, interval: Duration },
}

pub(super) fn resolve_status_segments(
    raw: Vec<RawStatusSegment>,
    side: &str,
) -> Vec<StatusSegment> {
    let mut segments = Vec::new();
    for segment in raw {
        if segments.len() >= MAX_STATUS_SEGMENTS {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring status_bar.{side} segments beyond the {MAX_STATUS_SEGMENTS}-segment limit"
            );
            break;
        }
        let content = match (segment.text, segment.run) {
            (Some(_), Some(_)) | (None, None) => {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring status_bar.{side} segment: exactly one of text or run is required"
                );
                continue;
            }
            (Some(text), None) => {
                // Bound per-draw expansion work on the render path.
                let mut bounded = String::new();
                let mut width: usize = 0;
                let mut scalar_count: usize = 0;
                for grapheme in text.graphemes(true) {
                    let grapheme_width = usize::from(grapheme.cell_width());
                    let grapheme_scalars = grapheme.chars().count();
                    if width.saturating_add(grapheme_width) > MAX_STATUS_SEGMENT_TEXT
                        || scalar_count.saturating_add(grapheme_scalars) > MAX_STATUS_SEGMENT_TEXT
                    {
                        break;
                    }
                    bounded.push_str(grapheme);
                    width += grapheme_width;
                    scalar_count += grapheme_scalars;
                }
                StatusSegmentContent::Text(bounded)
            }
            (None, Some(run)) => {
                if run.first().is_none_or(|program| program.is_empty()) {
                    crate::client_log::stderr_log!(
                        "config",
                        "{BIN}: ignoring status_bar.{side} segment without a run program"
                    );
                    continue;
                }
                let interval = segment.interval.unwrap_or(5).clamp(1, 3600);
                StatusSegmentContent::Command { argv: run, interval: Duration::from_secs(interval) }
            }
        };
        segments.push(StatusSegment {
            content,
            fg: segment.fg.as_ref().and_then(ColorValue::to_color),
            bg: segment.bg.as_ref().and_then(ColorValue::to_color),
        });
    }
    segments
}
