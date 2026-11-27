//! Rejections of a split ratio change (`set-split-ratio`, `set-ratio`).

use super::*;

#[derive(Debug, Clone, PartialEq)]
pub enum LayoutRatioError {
    UnknownPaneSplit { pane: PaneId },
    UnknownSplit { split: SplitId },
    UnrepresentableViewportWidth { split: SplitId, ratio: f32, width: f32 },
    RowSplitCompatReadonly { split: SplitId },
}

impl LayoutRatioError {
    pub const UNKNOWN_TARGET_CODE: &'static str = "layout-ratio-target-missing";
    pub const OUT_OF_RANGE_CODE: &'static str = "layout-ratio-out-of-range";

    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownPaneSplit { .. } | Self::UnknownSplit { .. } => Self::UNKNOWN_TARGET_CODE,
            Self::UnrepresentableViewportWidth { .. } => Self::OUT_OF_RANGE_CODE,
            // `rows-v1`: the split is a synthetic split of a column's row chain.
            Self::RowSplitCompatReadonly { .. } => "row-split-compat-readonly",
        }
    }
}

impl fmt::Display for LayoutRatioError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownPaneSplit { pane } => write!(formatter, "unknown pane/split {pane}"),
            Self::UnknownSplit { split } => write!(formatter, "unknown split {split}"),
            Self::UnrepresentableViewportWidth { split, ratio, width } => write!(
                formatter,
                "split {split} ratio {ratio} implies viewport width {width}; width must be between {MIN_VIEWPORT_PANE_WIDTH} and {MAX_VIEWPORT_PANE_WIDTH}"
            ),
            Self::RowSplitCompatReadonly { split } => {
                write!(formatter, "split {split} joins two rows; resize rows with set-row-heights")
            }
        }
    }
}

impl std::error::Error for LayoutRatioError {}
