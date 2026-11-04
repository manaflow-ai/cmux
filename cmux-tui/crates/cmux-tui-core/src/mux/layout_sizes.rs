//! `set-layout-sizes` (capability `layout-sizes-batch-v1`, R-DAEMON-STATE DESIGN 2.10.1): the divider values a key
//! resize or a drag's release ends with (a column trade's two widths, an Option or Command drag's widths and ratios)
//! applied as one change. Each value means what its single command means (`set-split-ratio`,
//! `set-viewport-pane-width`); a refused value refuses them all.

use std::fmt;

use super::*;

/// The most values one batch takes.
pub const MAX_LAYOUT_SIZE_VALUES: usize = 64;

/// One value of a batch.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LayoutSizeValue {
    /// `set-split-ratio {split, ratio}`.
    SplitRatio { split: SplitId, ratio: f32 },
    /// `set-viewport-pane-width {pane, width}`: the width of the column holding `pane`.
    PaneWidth { pane: PaneId, width: f32 },
}

/// Why a batch changed nothing.
#[derive(Debug)]
pub enum LayoutSizesError {
    /// No value, or more than [`MAX_LAYOUT_SIZE_VALUES`].
    BadCount { count: usize },
    /// The value at `index` is refused as `set-split-ratio` refuses it.
    Ratio { index: usize, error: LayoutRatioError },
    /// The value at `index` is refused as `set-viewport-pane-width` refuses it.
    Width { index: usize, error: ViewportWidthError },
    /// The value at `index` is on another screen than the first value.
    OtherScreen { index: usize },
}

impl LayoutSizesError {
    pub const BAD_COUNT_CODE: &'static str = "invalid-argument";
    pub const OTHER_SCREEN_CODE: &'static str = "layout-sizes-other-screen";

    /// The single command's error code for a refused value, else the batch's own.
    pub fn code(&self) -> &'static str {
        match self {
            Self::BadCount { .. } => Self::BAD_COUNT_CODE,
            Self::Ratio { error, .. } => error.code(),
            Self::Width { error, .. } => error.code(),
            Self::OtherScreen { .. } => Self::OTHER_SCREEN_CODE,
        }
    }

    /// The index of the refused value, when one value was refused.
    pub fn index(&self) -> Option<usize> {
        match self {
            Self::BadCount { .. } => None,
            Self::Ratio { index, .. } | Self::Width { index, .. } | Self::OtherScreen { index } => {
                Some(*index)
            }
        }
    }
}

impl fmt::Display for LayoutSizesError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadCount { count } => write!(
                formatter,
                "set-layout-sizes takes 1 to {MAX_LAYOUT_SIZE_VALUES} values, not {count}"
            ),
            Self::Ratio { index, error } => write!(formatter, "value {index}: {error}"),
            Self::Width { index, error } => write!(formatter, "value {index}: {error}"),
            Self::OtherScreen { index } => {
                write!(formatter, "value {index} is on another screen than value 0")
            }
        }
    }
}

impl std::error::Error for LayoutSizesError {}

impl Mux {
    /// Applies `values` as one change of the client-scoped resize transaction `transaction` (one undo step with the
    /// values the transaction sent before), or refuses them all.
    pub fn set_layout_sizes_in_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        values: &[LayoutSizeValue],
        client: u64,
        transaction: u64,
    ) -> Result<(), LayoutSizesError> {
        if values.is_empty() || values.len() > MAX_LAYOUT_SIZE_VALUES {
            return Err(LayoutSizesError::BadCount { count: values.len() });
        }
        // Today's behavior, as the app sends a trade: one commit per value, in order.
        for (index, value) in values.iter().enumerate() {
            match *value {
                LayoutSizeValue::SplitRatio { split, ratio } => self
                    .set_split_ratio_in_transaction_checked_as(
                        actor,
                        split,
                        ratio,
                        client,
                        transaction,
                    )
                    .map_err(|error| LayoutSizesError::Ratio { index, error })?,
                LayoutSizeValue::PaneWidth { pane, width } => self
                    .set_viewport_pane_width_in_transaction_checked_as(
                        actor,
                        pane,
                        width,
                        client,
                        transaction,
                    )
                    .map_err(|error| LayoutSizesError::Width { index, error })?,
            }
        }
        Ok(())
    }
}
