//! `set-divider-visible` (capability `split-divider-visibility-v1`): hide or
//! show the divider of one split. The flag lives on the split
//! (`divider_hidden` on `Node::Split`), persists with the screen's layout, and
//! reaches the app as `hidden_dividers` in every layout it is sent.

use super::*;

/// Capability naming `set-divider-visible` and `hidden_dividers`.
pub const SPLIT_DIVIDER_VISIBILITY_CAPABILITY: &str = "split-divider-visibility-v1";

/// Internal field of a `pane.split_ratio.set` intent that sets the divider's
/// visibility in place of a ratio. Never accepted from a resource client: the
/// public catalog refuses unknown parameters.
pub(crate) const DIVIDER_HIDDEN_FIELD: &str = "divider_hidden";

/// Rejections of `set-divider-visible`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DividerVisibilityError {
    /// No screen has this split.
    UnknownSplit { split: SplitId },
    /// The split is a viewport column boundary or a row boundary, which the
    /// column projection rebuilds.
    BoundarySplit { split: SplitId },
}

impl DividerVisibilityError {
    pub const BOUNDARY_CODE: &'static str = "divider-visibility-boundary";

    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownSplit { .. } => LayoutRatioError::UNKNOWN_TARGET_CODE,
            Self::BoundarySplit { .. } => Self::BOUNDARY_CODE,
        }
    }
}

impl fmt::Display for DividerVisibilityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownSplit { split } => write!(formatter, "unknown split {split}"),
            Self::BoundarySplit { split } => write!(
                formatter,
                "split {split} is a viewport column or row boundary; its divider cannot be hidden"
            ),
        }
    }
}

impl std::error::Error for DividerVisibilityError {}

impl Mux {
    /// Hide (`visible` false) or show split `split`'s divider. The same value
    /// again changes nothing and sends no event. `transaction` is echoed in
    /// the `layout-changed` event, as `set-split-ratio` echoes its own.
    pub fn set_divider_visible_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        visible: bool,
        transaction: Option<u64>,
    ) -> Result<(), DividerVisibilityError> {
        let hidden = !visible;
        let target = {
            let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            let Some((workspace_index, screen_index, owner)) =
                state.split_screens.get(&split).copied()
            else {
                return Err(DividerVisibilityError::UnknownSplit { split });
            };
            let Some(screen) = state
                .workspaces
                .get(workspace_index)
                .and_then(|workspace| workspace.screens.get(screen_index))
                .filter(|screen| screen.id == owner)
            else {
                return Err(DividerVisibilityError::UnknownSplit { split });
            };
            if screen
                .layout_columns
                .iter()
                .any(|column| column.id == split || column.is_row_split(split))
            {
                return Err(DividerVisibilityError::BoundarySplit { split });
            }
            let Some(current) = screen.root.divider_hidden(split) else {
                return Err(DividerVisibilityError::UnknownSplit { split });
            };
            if current == hidden {
                return Ok(());
            }
            (
                screen.active_pane,
                state
                    .resource_indexes
                    .split_ids
                    .get(&split)
                    .cloned()
                    .ok_or(DividerVisibilityError::UnknownSplit { split })?,
            )
        };
        let selectors = self
            .ordinary_pane_selectors(target.0)
            .ok_or(DividerVisibilityError::UnknownSplit { split })?;
        let fields = Map::from_iter([
            ("split_id".into(), Value::String(target.1.to_string())),
            (DIVIDER_HIDDEN_FIELD.into(), Value::Bool(hidden)),
        ]);
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneSplitRatioSet,
                selectors,
                fields,
            )
            .map_err(|error| {
                self.emit(MuxEvent::Status(format!(
                    "could not persist divider visibility: {error:#}"
                )));
                DividerVisibilityError::UnknownSplit { split }
            })?;
        // The echo names the request's transaction as its decimal form.
        let echo = transaction.map(|transaction| Arc::<str>::from(transaction.to_string()));
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
