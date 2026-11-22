//! Layout resizes: split ratio and viewport pane width commands, with checked, transaction and in-process transaction variants.

use super::*;

impl Mux {
    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        dir: SplitDir,
        ratio: f32,
    ) -> bool {
        self.set_ratio_checked_as(actor, pane, dir, ratio).is_ok()
    }

    /// Set a pane-addressed split ratio while preserving rejection details.
    pub fn set_ratio_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        dir: SplitDir,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        let split = self
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter())
                    .find(|screen| screen.root.contains(pane))
                    .and_then(|screen| screen.root.deepest_split_for_pane(pane, dir))
            })
            .ok_or(LayoutRatioError::UnknownPaneSplit { pane })?;
        self.set_split_ratio_inner(actor, split, ratio, None, true).map_err(|error| match error {
            LayoutRatioError::UnknownSplit { .. } => LayoutRatioError::UnknownPaneSplit { pane },
            error => error,
        })
    }

    /// Set one split ratio by its stable split-tree node id.
    pub fn set_split_ratio_as(self: &Arc<Self>, actor: &Actor, split: SplitId, ratio: f32) -> bool {
        self.set_split_ratio_checked_as(actor, split, ratio).is_ok()
    }

    /// Set one split ratio while preserving rejection details.
    pub fn set_split_ratio_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(actor, split, ratio, None, false)
    }

    /// Set one split ratio as part of a client-scoped resize transaction.
    pub fn set_split_ratio_in_transaction_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_split_ratio_in_transaction_checked_as(actor, split, ratio, client, transaction)
            .is_ok()
    }

    /// Set one transactional split ratio while preserving rejection details.
    pub fn set_split_ratio_in_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            actor,
            split,
            ratio,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
            false,
        )
    }

    /// Set one in-process transactional split ratio without sharing the
    /// control-client ownership namespace.
    pub fn set_split_ratio_in_process_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            actor,
            split,
            ratio,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
            false,
        )
    }

    pub(super) fn set_split_ratio_inner(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        transaction: Option<(LayoutResizeOwner, u64)>,
        tree_changed: bool,
    ) -> Result<(), LayoutRatioError> {
        let ratio = clamp_split_ratio(ratio);
        let target = {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index, owner)) =
                state.split_screens.get(&split).copied()
            else {
                return Err(LayoutRatioError::UnknownSplit { split });
            };
            if state
                .workspaces
                .get(workspace_index)
                .and_then(|workspace| workspace.screens.get(screen_index))
                .is_none_or(|screen| screen.id != owner)
            {
                return Err(LayoutRatioError::UnknownSplit { split });
            }
            let screen = &state.workspaces[workspace_index].screens[screen_index];
            if screen.layout_columns.iter().any(|column| column.is_row_split(split)) {
                return Err(LayoutRatioError::RowSplitCompatReadonly { split });
            }
            if let Some(index) = screen
                .layout_columns
                .iter()
                .position(|column| column.id == split)
                .filter(|index| *index > 0)
            {
                let width_before =
                    screen.layout_columns[..index].iter().map(|column| column.width).sum::<f32>();
                let width = width_before * (1.0 - ratio) / ratio;
                if !width.is_finite()
                    || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
                {
                    return Err(LayoutRatioError::UnrepresentableViewportWidth {
                        split,
                        ratio,
                        width,
                    });
                }
                if screen.layout_columns[index].width == width {
                    return Ok(());
                }
            } else {
                let Some(current) = screen.root.split_ratio(split) else {
                    return Err(LayoutRatioError::UnknownSplit { split });
                };
                if current == ratio {
                    return Ok(());
                }
            }
            (
                screen.active_pane,
                state
                    .resource_indexes
                    .split_ids
                    .get(&split)
                    .cloned()
                    .ok_or(LayoutRatioError::UnknownSplit { split })?,
            )
        };
        let selectors = self
            .ordinary_pane_selectors(target.0)
            .ok_or(LayoutRatioError::UnknownSplit { split })?;
        let mut fields = Map::from_iter([
            ("split_id".into(), Value::String(target.1.to_string())),
            ("ratio".into(), Value::from(ratio)),
        ]);
        if let Some((owner, transaction)) = transaction {
            let (kind, owner) = match owner {
                LayoutResizeOwner::ControlClient(owner) => ("control-client", owner),
                LayoutResizeOwner::InProcess(owner) => ("in-process", owner),
            };
            fields.insert("resize_owner_kind".into(), Value::String(kind.into()));
            fields.insert("resize_owner".into(), Value::from(owner));
            fields.insert("resize_transaction".into(), Value::from(transaction));
        }
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneSplitRatioSet,
                selectors,
                fields,
            )
            .map_err(|error| {
                self.emit(MuxEvent::Status(format!("could not persist split ratio: {error:#}")));
                LayoutRatioError::UnknownSplit { split }
            })?;
        if tree_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        if let Some(screen) = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        Ok(())
    }

    /// Set the width of the horizontal viewport column containing `pane`.
    pub fn set_viewport_pane_width_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
    ) -> bool {
        self.set_viewport_pane_width_checked_as(actor, pane, width).is_ok()
    }

    /// Set a viewport column width while preserving rejection details.
    pub fn set_viewport_pane_width_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(actor, pane, width, None)
    }

    /// Set a viewport column width as part of a client-scoped resize transaction.
    pub fn set_viewport_pane_width_in_transaction_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_viewport_pane_width_in_transaction_checked_as(
            actor,
            pane,
            width,
            client,
            transaction,
        )
        .is_ok()
    }

    /// Set a transactional viewport width while preserving rejection details.
    pub fn set_viewport_pane_width_in_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            actor,
            pane,
            width,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
        )
    }

    /// Set one in-process transactional viewport width without sharing the
    /// control-client ownership namespace.
    pub fn set_viewport_pane_width_in_process_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            actor,
            pane,
            width,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
        )
    }

    pub(super) fn set_viewport_pane_width_inner(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        transaction: Option<(LayoutResizeOwner, u64)>,
    ) -> Result<(), ViewportWidthError> {
        if !width.is_finite()
            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
        {
            return Err(ViewportWidthError::OutOfRange { width });
        }
        {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            };
            let screen = &state.workspaces[workspace_index].screens[screen_index];
            if !screen.layout_columns_active() {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            }
            let Some(column_index) =
                screen.layout_columns.iter().position(|column| column.root.contains(pane))
            else {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            };
            if (screen.layout_columns[column_index].width - width).abs() < f32::EPSILON {
                return Ok(());
            }
        }
        let selectors = self
            .ordinary_pane_selectors(pane)
            .ok_or(ViewportWidthError::PaneNotResizable { pane })?;
        let mut fields = Map::from_iter([("width".into(), Value::from(width))]);
        if let Some((owner, transaction)) = transaction {
            let (kind, owner) = match owner {
                LayoutResizeOwner::ControlClient(owner) => ("control-client", owner),
                LayoutResizeOwner::InProcess(owner) => ("in-process", owner),
            };
            fields.insert("resize_owner_kind".into(), Value::String(kind.into()));
            fields.insert("resize_owner".into(), Value::from(owner));
            fields.insert("resize_transaction".into(), Value::from(transaction));
        }
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneViewportWidthSet,
                selectors,
                fields,
            )
            .map_err(|error| {
                self.emit(MuxEvent::Status(format!(
                    "could not persist viewport pane width: {error:#}"
                )));
                ViewportWidthError::PaneNotResizable { pane }
            })?;
        if let Some(screen) = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        Ok(())
    }
}
