//! `set-layout-sizes` (capability `layout-sizes-batch-v1`, R-DAEMON-STATE DESIGN 2.10.1): the divider values a key
//! resize or a drag's release ends with (a column trade's two widths, an Option or Command drag's widths and ratios)
//! applied as one change. Each value means what its single command means (`set-split-ratio`,
//! `set-viewport-pane-width`); a refused value refuses them all.

use std::fmt;

use serde_json::json;

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
    /// The ratio at `index` is not a number (in-process callers; JSON cannot carry one). An infinite ratio is not
    /// refused: it clamps, as `set-split-ratio` clamps it.
    NanRatio { index: usize },
    /// The commit failed (the store refused it); nothing changed.
    NotPersisted { reason: String },
}

impl LayoutSizesError {
    pub const BAD_COUNT_CODE: &'static str = "invalid-argument";
    pub const OTHER_SCREEN_CODE: &'static str = "layout-sizes-other-screen";
    pub const NAN_RATIO_CODE: &'static str = "invalid-argument";
    pub const NOT_PERSISTED_CODE: &'static str = "layout-sizes-not-persisted";

    /// The single command's error code for a refused value, else the batch's own.
    pub fn code(&self) -> &'static str {
        match self {
            Self::BadCount { .. } => Self::BAD_COUNT_CODE,
            Self::Ratio { error, .. } => error.code(),
            Self::Width { error, .. } => error.code(),
            Self::OtherScreen { .. } => Self::OTHER_SCREEN_CODE,
            Self::NanRatio { .. } => Self::NAN_RATIO_CODE,
            Self::NotPersisted { .. } => Self::NOT_PERSISTED_CODE,
        }
    }

    /// The index of the refused value, when one value was refused.
    pub fn index(&self) -> Option<usize> {
        match self {
            Self::BadCount { .. } | Self::NotPersisted { .. } => None,
            Self::Ratio { index, .. }
            | Self::Width { index, .. }
            | Self::OtherScreen { index }
            | Self::NanRatio { index } => Some(*index),
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
            Self::NanRatio { index } => {
                write!(formatter, "value {index}: the split ratio is not a number")
            }
            Self::NotPersisted { reason } => {
                write!(formatter, "could not persist layout sizes: {reason}")
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
        // The screen's pane that names it to the resource path: the first value's pane, or the active pane of the
        // first ratio's screen. The plan checks that every value is on that screen.
        let pane = match values.first().copied() {
            Some(LayoutSizeValue::PaneWidth { pane, .. }) => pane,
            Some(LayoutSizeValue::SplitRatio { split, .. }) => self
                .with_state(|state| {
                    let (workspace, screen, _) = state.split_screens.get(&split).copied()?;
                    state
                        .workspaces
                        .get(workspace)
                        .and_then(|item| item.screens.get(screen))
                        .map(|screen| screen.active_pane)
                })
                .ok_or(LayoutSizesError::Ratio {
                    index: 0,
                    error: LayoutRatioError::UnknownSplit { split },
                })?,
            None => return Err(LayoutSizesError::BadCount { count: 0 }),
        };
        let not_resizable = || LayoutSizesError::Width {
            index: 0,
            error: ViewportWidthError::PaneNotResizable { pane },
        };
        let selectors = self.ordinary_pane_selectors(pane).ok_or_else(not_resizable)?;
        let wire_values: Vec<Value> = values
            .iter()
            .map(|value| match *value {
                LayoutSizeValue::SplitRatio { split, ratio } => {
                    json!({"split": split, "ratio": ratio})
                }
                LayoutSizeValue::PaneWidth { pane, width } => json!({"pane": pane, "width": width}),
            })
            .collect();
        let fingerprint = json!({
            "operation": "screen.layout_sizes.set",
            "selectors": selectors,
            "fields": {
                "values": wire_values,
                "resize_owner_kind": "control-client",
                "resize_owner": client,
                "resize_transaction": transaction,
            },
        });
        let coalesce = Some(LayoutMutationKey::Resize {
            owner: LayoutResizeOwner::ControlClient(client),
            transaction,
        });
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let commit = match self.resource_set_layout_sizes(
            selectors,
            values.to_vec(),
            coalesce,
            &mutation,
            &fingerprint,
        ) {
            Ok(commit) => commit,
            Err(error) if error.is::<resource_topology::LayoutSizesUnchanged>() => return Ok(()),
            Err(error) => {
                return Err(error.downcast::<LayoutSizesError>().unwrap_or_else(|error| {
                    self.emit(MuxEvent::Status(format!(
                        "could not persist layout sizes: {error:#}"
                    )));
                    LayoutSizesError::NotPersisted { reason: format!("{error:#}") }
                }));
            }
        };
        // The echo names the request's transaction as its decimal form.
        let echo = Some(Arc::<str>::from(transaction.to_string()));
        if let Some(screen) = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit_layout_changed(screen, echo);
        }
        Ok(())
    }
}
