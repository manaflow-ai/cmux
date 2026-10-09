//! Restoring mux state from the durable registry snapshot: resource state, expected panes, and layout trees.

use super::*;

pub(super) fn expected_panes_by_screen(
    panes: &[RegistryPane],
) -> HashMap<ScreenPublicId, HashSet<PanePublicId>> {
    let mut panes_by_screen: HashMap<ScreenPublicId, HashSet<PanePublicId>> = HashMap::new();
    for pane in panes {
        panes_by_screen.entry(pane.screen_id.clone()).or_default().insert(pane.public_id.clone());
    }
    panes_by_screen
}

pub(super) fn restore_resource_state(
    snapshot: RegistrySnapshot,
    topology: ResourceTopologySnapshot,
) -> anyhow::Result<RestoredResourceState> {
    anyhow::ensure!(
        topology.session_id == snapshot.session_id,
        "resource topology belongs to a different session"
    );
    anyhow::ensure!(
        topology.generation == snapshot.generation,
        "resource topology generation changed during startup"
    );
    anyhow::ensure!(
        topology.revision == snapshot.resource_revision,
        "resource topology revision changed during startup"
    );

    let mut next_id = snapshot.next_numeric_id.max(1);
    let mut allocate = || -> anyhow::Result<u64> {
        let id = next_id;
        next_id =
            next_id.checked_add(1).ok_or_else(|| anyhow::anyhow!("runtime id space exhausted"))?;
        Ok(id)
    };

    let workspace_revision = snapshot.revision;
    let resource_revision = snapshot.resource_revision;
    let mut workspaces = snapshot
        .workspaces
        .into_iter()
        .map(|workspace| Workspace {
            id: workspace.id,
            public_id: workspace.public_id,
            key: workspace.key,
            name: workspace.name,
            screens: Vec::new(),
            active_screen: 0,
        })
        .collect::<Vec<_>>();
    let workspace_index_by_public = workspaces
        .iter()
        .enumerate()
        .map(|(index, workspace)| (workspace.public_id.clone(), index))
        .collect::<HashMap<_, _>>();

    let mut screen_slots = HashMap::new();
    for screen in &topology.screens {
        let old = screen_slots.insert(screen.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate screen {}", screen.public_id);
    }
    let mut pane_slots = HashMap::new();
    for pane in &topology.panes {
        let old = pane_slots.insert(pane.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate pane {}", pane.public_id);
    }
    let mut tab_slots = HashMap::new();
    for tab in &topology.tabs {
        let old = tab_slots.insert(tab.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate tab {}", tab.public_id);
    }

    let mut indexes = PublicSlotIndexes::default();
    for workspace in &workspaces {
        anyhow::ensure!(
            indexes.workspaces.insert(workspace.public_id.clone(), workspace.id).is_none(),
            "duplicate workspace {}",
            workspace.public_id
        );
        indexes.workspace_ids.insert(workspace.id, workspace.public_id.clone());
    }
    for (public_id, slot) in &screen_slots {
        indexes.screens.insert(public_id.clone(), *slot);
        indexes.screen_ids.insert(*slot, public_id.clone());
    }
    for (public_id, slot) in &pane_slots {
        indexes.panes.insert(public_id.clone(), *slot);
        indexes.pane_ids.insert(*slot, public_id.clone());
    }

    let mut browsers_by_id = topology
        .browsers
        .iter()
        .cloned()
        .map(|browser| (browser.public_id.clone(), browser))
        .collect::<HashMap<_, _>>();
    anyhow::ensure!(
        browsers_by_id.len() == topology.browsers.len(),
        "resource topology contains duplicate browser metadata"
    );
    let mut tabs_by_pane = HashMap::<PanePublicId, Vec<RegistryTab>>::new();
    let mut contents = Vec::with_capacity(topology.tabs.len());
    for tab in topology.tabs {
        let browser = match (&tab.content_id, &tab.browser_url, &tab.terminal_id) {
            (ContentPublicId::Terminal(_), None, Some(_)) => None,
            (ContentPublicId::Browser(browser_id), Some(url), None) => {
                let browser = browsers_by_id.remove(browser_id).ok_or_else(|| {
                    anyhow::anyhow!("browser tab {} has no restart metadata", tab.public_id)
                })?;
                anyhow::ensure!(
                    &browser.url == url,
                    "browser tab {} URL disagrees with its restart metadata",
                    tab.public_id
                );
                Some(browser)
            }
            _ => {
                anyhow::bail!("tab {} has inconsistent persisted content metadata", tab.public_id)
            }
        };
        let slot = tab_slots[&tab.public_id];
        let identity = TabResourceIdentity::new(tab.public_id.clone(), tab.content_id.clone());
        anyhow::ensure!(
            indexes.tabs.insert(tab.public_id.clone(), slot).is_none(),
            "duplicate tab {}",
            tab.public_id
        );
        indexes.tab_ids.insert(slot, tab.public_id.clone());
        indexes.content_placements.entry(tab.content_id.clone()).or_default().push(slot);
        indexes.content_ids.insert(slot, tab.content_id.clone());
        contents.push(RestoredResourceContent { slot, identity, name: tab.name.clone(), browser });
        tabs_by_pane.entry(tab.pane_id.clone()).or_default().push(tab);
    }
    anyhow::ensure!(
        browsers_by_id.is_empty(),
        "resource topology contains orphan browser metadata"
    );
    for tabs in tabs_by_pane.values_mut() {
        tabs.sort_by_key(|tab| tab.position);
    }

    let mut panes = HashMap::new();
    for pane in &topology.panes {
        let id = pane_slots[&pane.public_id];
        let pane_tabs = tabs_by_pane.get(&pane.public_id).map(Vec::as_slice).unwrap_or_default();
        let tabs = pane_tabs.iter().map(|tab| tab_slots[&tab.public_id]).collect::<Vec<_>>();
        let active_tab = match pane.active_tab.as_ref() {
            Some(active) => {
                pane_tabs.iter().position(|tab| &tab.public_id == active).ok_or_else(|| {
                    anyhow::anyhow!("pane {} has unknown active tab {}", pane.public_id, active)
                })?
            }
            None if pane_tabs.is_empty() => 0,
            None => anyhow::bail!("pane {} has tabs but no active tab", pane.public_id),
        };
        anyhow::ensure!(
            panes
                .insert(
                    id,
                    Pane {
                        id,
                        public_id: pane.public_id.clone(),
                        name: pane.name.clone(),
                        tabs,
                        active_tab,
                        active_at: pane.creation_ordinal,
                        focused_at: 0,
                    },
                )
                .is_none(),
            "duplicate pane slot {id}"
        );
        let screen = *screen_slots
            .get(&pane.screen_id)
            .ok_or_else(|| anyhow::anyhow!("pane {} has unknown screen", pane.public_id))?;
        indexes.pane_screen.insert(id, screen);
        for tab in pane_tabs {
            indexes.tab_pane.insert(tab_slots[&tab.public_id], id);
        }
    }

    let mut split_slots = HashMap::<SplitPublicId, SplitId>::new();
    let mut screens_by_workspace = HashMap::<WorkspacePublicId, Vec<(usize, Screen)>>::new();
    let panes_by_screen = expected_panes_by_screen(&topology.panes);
    let empty_expected_panes = HashSet::new();
    for screen in &topology.screens {
        let expected_panes =
            panes_by_screen.get(&screen.public_id).unwrap_or(&empty_expected_panes);
        crate::workspace_registry::validate_registry_screen_projection(screen, expected_panes)?;
        let id = screen_slots[&screen.public_id];
        let root =
            restore_layout_node(&screen.layout, &pane_slots, &mut split_slots, &mut allocate)?;
        let active_pane = *pane_slots.get(&screen.active_pane).ok_or_else(|| {
            anyhow::anyhow!("screen {} has unknown active pane", screen.public_id)
        })?;
        let zoomed_pane = screen
            .zoomed_pane
            .as_ref()
            .map(|pane| {
                pane_slots.get(pane).copied().ok_or_else(|| {
                    anyhow::anyhow!("screen {} has unknown zoomed pane {}", screen.public_id, pane)
                })
            })
            .transpose()?;
        let creation_order_auto_layout = screen
            .auto_layout
            .as_ref()
            .map(|panes| {
                panes
                    .iter()
                    .map(|pane| {
                        pane_slots.get(pane).copied().ok_or_else(|| {
                            anyhow::anyhow!(
                                "screen {} auto-layout has unknown pane {}",
                                screen.public_id,
                                pane
                            )
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?;
        let (viewport_splits, viewport_base_width, layout_columns) = restore_registry_viewport(
            &screen.viewport,
            &pane_slots,
            &mut split_slots,
            &mut allocate,
        )?;
        indexes.screen_workspace.insert(
            id,
            workspaces[*workspace_index_by_public.get(&screen.workspace_id).ok_or_else(|| {
                anyhow::anyhow!("screen {} has unknown workspace", screen.public_id)
            })?]
            .id,
        );
        let restored_screen = Screen {
            id,
            public_id: screen.public_id.clone(),
            name: screen.name.clone(),
            root,
            active_pane,
            zoomed_pane,
            creation_order_auto_layout,
            viewport_splits,
            viewport_base_width,
            layout_columns,
            layout_revision: 0,
            layout_undo: Default::default(),
        };
        anyhow::ensure!(
            restored_screen.layout_column_projection_is_consistent(),
            "screen {} has inconsistent viewport projection",
            screen.public_id
        );
        screens_by_workspace
            .entry(screen.workspace_id.clone())
            .or_default()
            .push((screen.position, restored_screen));
    }
    for (workspace_id, mut screens) in screens_by_workspace {
        screens.sort_by_key(|(position, _)| *position);
        let workspace_index = workspace_index_by_public[&workspace_id];
        workspaces[workspace_index].screens =
            screens.into_iter().map(|(_, screen)| screen).collect();
    }
    let mut active_screens = HashMap::new();
    for (workspace, active) in topology.active_screens {
        anyhow::ensure!(
            active_screens.insert(workspace.clone(), active).is_none(),
            "workspace {workspace} has duplicate active-screen metadata"
        );
    }
    anyhow::ensure!(
        active_screens.len() == workspaces.len()
            && workspaces.iter().all(|workspace| active_screens.contains_key(&workspace.public_id)),
        "active-screen metadata does not exactly cover the live workspaces"
    );
    for workspace in &mut workspaces {
        workspace.active_screen = match active_screens[&workspace.public_id].as_ref() {
            Some(active) => {
                workspace.screens.iter().position(|screen| &screen.public_id == active).ok_or_else(
                    || {
                        anyhow::anyhow!(
                            "workspace {} has unknown active screen {}",
                            workspace.public_id,
                            active
                        )
                    },
                )?
            }
            None if workspace.screens.is_empty() => 0,
            None => {
                anyhow::bail!("workspace {} has screens but no active screen", workspace.public_id)
            }
        };
    }
    let active_workspace = match topology.active_workspace.as_ref() {
        Some(active) => workspaces
            .iter()
            .position(|workspace| &workspace.public_id == active)
            .ok_or_else(|| anyhow::anyhow!("unknown active workspace {active}"))?,
        None if workspaces.is_empty() => 0,
        None => anyhow::bail!("session has workspaces but no active workspace"),
    };

    for (public_id, slot) in split_slots {
        indexes.splits.insert(public_id.clone(), slot);
        indexes.split_ids.insert(slot, public_id);
    }
    let workspace_index_by_id =
        workspaces.iter().enumerate().map(|(index, workspace)| (workspace.id, index)).collect();
    let workspace_id_by_key =
        workspaces.iter().map(|workspace| (workspace.key.clone(), workspace.id)).collect();
    Ok(RestoredResourceState {
        state: State {
            workspaces,
            workspace_index_by_id,
            workspace_id_by_key,
            workspace_revision,
            pane_revision: panes.len() as u64,
            resource_revision,
            focus_sequence: 0,
            active_workspace,
            panes,
            surfaces: HashMap::new(),
            terminal_catalog: HashMap::new(),
            terminal_catalog_by_runtime: HashMap::new(),
            terminal_catalog_by_host: HashMap::new(),
            split_screens: HashMap::new(),
            resource_indexes: indexes,
        },
        next_id,
        contents,
    })
}

pub(super) fn restore_layout_node(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            anyhow::ensure!(!splits.contains_key(split), "split {split} appears more than once");
            let id = allocate()?;
            splits.insert(split.clone(), id);
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node(first, panes, splits, allocate)?),
                b: Box::new(restore_layout_node(second, panes, splits, allocate)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}

pub(super) fn restore_layout_node_from_known_splits(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &HashMap<SplitPublicId, SplitId>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            let id = *splits
                .get(split)
                .ok_or_else(|| anyhow::anyhow!("layout has unknown split {split}"))?;
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node_from_known_splits(first, panes, splits)?),
                b: Box::new(restore_layout_node_from_known_splits(second, panes, splits)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}
