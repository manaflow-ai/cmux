#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[derive(Clone)]
    struct FixtureTopology {
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        revision: u64,
        workspace_order: Vec<WorkspaceUuid>,
        screens: HashMap<WorkspaceUuid, Vec<ScreenUuid>>,
        panes: HashMap<ScreenUuid, Vec<PaneUuid>>,
        surfaces: HashMap<PaneUuid, Vec<SurfaceUuid>>,
        workspace_by_screen: HashMap<ScreenUuid, WorkspaceUuid>,
        screen_by_pane: HashMap<PaneUuid, ScreenUuid>,
        pane_by_surface: HashMap<SurfaceUuid, PaneUuid>,
        legacy_selected_screen: HashMap<WorkspaceUuid, ScreenUuid>,
        legacy_active_pane: HashMap<ScreenUuid, PaneUuid>,
        legacy_zoomed_pane: HashMap<ScreenUuid, PaneUuid>,
        legacy_selected_surface: HashMap<PaneUuid, SurfaceUuid>,
    }

    impl FixtureTopology {
        fn empty() -> Self {
            Self {
                daemon_instance_id: daemon(1),
                session_id: session(2),
                revision: 1,
                workspace_order: Vec::new(),
                screens: HashMap::new(),
                panes: HashMap::new(),
                surfaces: HashMap::new(),
                workspace_by_screen: HashMap::new(),
                screen_by_pane: HashMap::new(),
                pane_by_surface: HashMap::new(),
                legacy_selected_screen: HashMap::new(),
                legacy_active_pane: HashMap::new(),
                legacy_zoomed_pane: HashMap::new(),
                legacy_selected_surface: HashMap::new(),
            }
        }

        fn two_workspaces() -> Self {
            let w1 = workspace(101);
            let w2 = workspace(102);
            let s1 = screen(201);
            let s2 = screen(202);
            let s3 = screen(203);
            let p1 = pane(301);
            let p2 = pane(302);
            let p3 = pane(303);
            let f1 = surface(401);
            let f2 = surface(402);
            let f3 = surface(403);
            let mut topology = Self::empty();
            topology.workspace_order = vec![w1, w2];
            topology.screens.insert(w1, vec![s1, s2]);
            topology.screens.insert(w2, vec![s3]);
            topology.panes.insert(s1, vec![p1, p2]);
            topology.panes.insert(s2, vec![p3]);
            topology.panes.insert(s3, vec![]);
            topology.surfaces.insert(p1, vec![f1, f2]);
            topology.surfaces.insert(p2, vec![f3]);
            topology.surfaces.insert(p3, vec![]);
            topology.workspace_by_screen = HashMap::from([(s1, w1), (s2, w1), (s3, w2)]);
            topology.screen_by_pane = HashMap::from([(p1, s1), (p2, s1), (p3, s2)]);
            topology.pane_by_surface = HashMap::from([(f1, p1), (f2, p1), (f3, p2)]);
            topology.legacy_selected_screen = HashMap::from([(w1, s2), (w2, s3)]);
            topology.legacy_active_pane = HashMap::from([(s1, p2), (s2, p3)]);
            topology.legacy_zoomed_pane = HashMap::from([(s1, p2)]);
            topology.legacy_selected_surface = HashMap::from([(p1, f2), (p2, f3)]);
            topology
        }

        fn move_pane(&mut self, pane: PaneUuid, from: ScreenUuid, to: ScreenUuid) {
            self.panes.get_mut(&from).unwrap().retain(|candidate| *candidate != pane);
            self.panes.get_mut(&to).unwrap().push(pane);
            self.screen_by_pane.insert(pane, to);
            self.revision += 1;
        }

        fn move_surface(&mut self, value: SurfaceUuid, from: PaneUuid, to: PaneUuid) {
            self.surfaces.get_mut(&from).unwrap().retain(|candidate| *candidate != value);
            self.surfaces.get_mut(&to).unwrap().push(value);
            self.pane_by_surface.insert(value, to);
            self.revision += 1;
        }
    }

    impl ProjectionNavigationTopology for FixtureTopology {
        fn daemon_instance_id(&self) -> DaemonInstanceId {
            self.daemon_instance_id
        }

        fn session_id(&self) -> SessionId {
            self.session_id
        }

        fn revision(&self) -> u64 {
            self.revision
        }

        fn workspace_order(&self) -> &[WorkspaceUuid] {
            &self.workspace_order
        }

        fn screen_order(&self, workspace: WorkspaceUuid) -> Option<&[ScreenUuid]> {
            self.screens.get(&workspace).map(Vec::as_slice)
        }

        fn pane_order(&self, screen: ScreenUuid) -> Option<&[PaneUuid]> {
            self.panes.get(&screen).map(Vec::as_slice)
        }

        fn surface_order(&self, pane: PaneUuid) -> Option<&[SurfaceUuid]> {
            self.surfaces.get(&pane).map(Vec::as_slice)
        }

        fn workspace_for_screen(&self, screen: ScreenUuid) -> Option<WorkspaceUuid> {
            self.workspace_by_screen.get(&screen).copied()
        }

        fn screen_for_pane(&self, pane: PaneUuid) -> Option<ScreenUuid> {
            self.screen_by_pane.get(&pane).copied()
        }

        fn pane_for_surface(&self, surface: SurfaceUuid) -> Option<PaneUuid> {
            self.pane_by_surface.get(&surface).copied()
        }

        fn legacy_selected_screen(&self, workspace: WorkspaceUuid) -> Option<ScreenUuid> {
            self.legacy_selected_screen.get(&workspace).copied()
        }

        fn legacy_active_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.legacy_active_pane.get(&screen).copied()
        }

        fn legacy_zoomed_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.legacy_zoomed_pane.get(&screen).copied()
        }

        fn legacy_selected_surface(&self, pane: PaneUuid) -> Option<SurfaceUuid> {
            self.legacy_selected_surface.get(&pane).copied()
        }
    }

    #[test]
    fn operation_wire_names_are_distinct_v2_absolute_setters() {
        let operations = vec![
            ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(1) },
            ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid: workspace(2) },
            ProjectionNavigationOperation::SelectWorkspace { workspace_uuid: Some(workspace(3)) },
            ProjectionNavigationOperation::SelectScreen {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
            },
            ProjectionNavigationOperation::ActivatePane {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: pane(5),
            },
            ProjectionNavigationOperation::SetZoomedPane {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: None,
            },
            ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: pane(5),
                surface_uuid: surface(6),
            },
        ];

        let names = operations
            .iter()
            .map(|operation| serde_json::to_value(operation).unwrap()["type"].clone())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            [
                "assign-workspace",
                "unassign-workspace",
                "select-workspace",
                "select-screen",
                "activate-pane",
                "set-zoomed-pane",
                "select-surface",
            ]
        );
    }

    #[test]
    fn list_promotes_v1_and_imports_canonical_navigation_once() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let logical = uuid(10);
        registry
            .install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: logical,
                generation: 7,
                workspaces: vec![
                    ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(102),
                        selected_screen_uuid: screen(203),
                    },
                    ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    },
                ],
            })
            .unwrap();

        let promoted = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(promoted.len(), 1);
        let state = &promoted[0];
        assert_eq!(state.schema_version, 2);
        assert_eq!(state.generation, 8);
        assert_eq!(state.selected_workspace_uuid, Some(workspace(101)));
        assert_eq!(
            state.workspaces.iter().map(|item| item.workspace_uuid).collect::<Vec<_>>(),
            [workspace(101), workspace(102)]
        );
        assert_eq!(state.workspaces[0].selected_screen_uuid, screen(201));
        assert_eq!(state.workspaces[0].screens[0].active_pane_uuid, pane(302));
        assert_eq!(state.workspaces[0].screens[0].zoomed_pane_uuid, Some(pane(302)));
        assert_eq!(state.workspaces[0].screens[0].panes[0].selected_surface_uuid, surface(402));
        assert_eq!(state.claim_id, None);
        assert!(matches!(
            registry.legacy_access(owner.client_uuid, logical),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));

        let unchanged = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(unchanged[0].generation, 8);
    }

    #[test]
    fn cross_window_swap_is_atomic_and_one_sided_duplicate_rolls_back() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let first = claim(&registry, owner, uuid(10), &topology);
        let second = claim(&registry, owner, uuid(11), &topology);
        let first = mutate_one(
            &registry,
            owner,
            &first,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let second = mutate_one(
            &registry,
            owner,
            &second,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(102) }],
            &topology,
        );

        let rejected = registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                projections: vec![ProjectionNavigationMutation {
                    logical_presentation_id: second.logical_presentation_id,
                    claim_id: second.claim_id.unwrap(),
                    expected_generation: second.generation,
                    operations: vec![ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    }],
                }],
            },
            &topology,
        );
        assert!(matches!(
            conflict(rejected),
            ProjectionNavigationConflict::WorkspaceOwned {
                workspace_uuid,
                owner_logical_presentation_id,
            } if workspace_uuid == workspace(101)
                && owner_logical_presentation_id == first.logical_presentation_id
        ));
        let after_rejection =
            applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(state(&after_rejection, uuid(10)).generation, first.generation);
        assert_eq!(state(&after_rejection, uuid(11)).generation, second.generation);

        let swapped = applied_states(registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                projections: vec![
                    ProjectionNavigationMutation {
                        logical_presentation_id: first.logical_presentation_id,
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        operations: vec![
                            ProjectionNavigationOperation::UnassignWorkspace {
                                workspace_uuid: workspace(101),
                            },
                            ProjectionNavigationOperation::AssignWorkspace {
                                workspace_uuid: workspace(102),
                            },
                        ],
                    },
                    ProjectionNavigationMutation {
                        logical_presentation_id: second.logical_presentation_id,
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: second.generation,
                        operations: vec![
                            ProjectionNavigationOperation::UnassignWorkspace {
                                workspace_uuid: workspace(102),
                            },
                            ProjectionNavigationOperation::AssignWorkspace {
                                workspace_uuid: workspace(101),
                            },
                        ],
                    },
                ],
            },
            &topology,
        ));
        assert_eq!(swapped.len(), 2);
        assert_eq!(swapped[0].workspaces[0].workspace_uuid, workspace(102));
        assert_eq!(swapped[1].workspaces[0].workspace_uuid, workspace(101));
    }

    #[test]
    fn pane_move_keeps_its_surface_but_drops_old_screen_focus_and_zoom() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let focused = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![
                ProjectionNavigationOperation::ActivatePane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(301),
                },
                ProjectionNavigationOperation::SetZoomedPane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: Some(pane(301)),
                },
                ProjectionNavigationOperation::SelectSurface {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(301),
                    surface_uuid: surface(401),
                },
            ],
            &topology,
        );

        topology.move_pane(pane(301), screen(201), screen(202));
        let normalized = applied_states(registry.list(owner, expectation(&topology), &topology));
        let state = state(&normalized, focused.logical_presentation_id);
        let old_screen = screen_state(state, screen(201));
        let new_screen = screen_state(state, screen(202));
        assert_eq!(old_screen.active_pane_uuid, pane(302));
        assert_eq!(old_screen.zoomed_pane_uuid, None);
        assert_eq!(pane_state(new_screen, pane(301)).selected_surface_uuid, surface(401));
    }

    #[test]
    fn surface_move_drops_old_pane_selection_without_transferring_it() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let selected = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(101),
                screen_uuid: screen(201),
                pane_uuid: pane(301),
                surface_uuid: surface(401),
            }],
            &topology,
        );

        topology.move_surface(surface(401), pane(301), pane(302));
        let normalized = applied_states(registry.list(owner, expectation(&topology), &topology));
        let screen =
            screen_state(state(&normalized, selected.logical_presentation_id), screen(201));
        assert_eq!(pane_state(screen, pane(301)).selected_surface_uuid, surface(402));
        assert_eq!(pane_state(screen, pane(302)).selected_surface_uuid, surface(403));
    }

    #[test]
    fn stale_topology_generation_and_claim_are_structured_conflicts() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let first = claimant(1, 2, 3);
        let claimed = claim(&registry, first, uuid(10), &topology);

        let stale_topology = registry.mutate(
            first,
            ProjectionNavigationTopologyExpectation {
                expected_revision: 0,
                ..expectation(&topology)
            },
            mutation(&claimed, Vec::new()),
            &topology,
        );
        assert!(matches!(
            conflict(stale_topology),
            ProjectionNavigationConflict::StaleTopology {
                expected_revision: 0,
                current_revision: 1,
                ..
            }
        ));

        let stale_generation = registry.mutate(
            first,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                projections: vec![ProjectionNavigationMutation {
                    logical_presentation_id: claimed.logical_presentation_id,
                    claim_id: claimed.claim_id.unwrap(),
                    expected_generation: claimed.generation + 1,
                    operations: Vec::new(),
                }],
            },
            &topology,
        );
        assert!(matches!(
            conflict(stale_generation),
            ProjectionNavigationConflict::StaleGeneration { expected, current, .. }
                if expected == claimed.generation + 1 && current == claimed.generation
        ));

        let second = claimant(1, 4, 5);
        let _reclaimed = claim(&registry, second, uuid(10), &topology);
        let lost = registry.mutate(
            first,
            expectation(&topology),
            mutation(&claimed, Vec::new()),
            &topology,
        );
        assert!(matches!(
            conflict(lost),
            ProjectionNavigationConflict::ClaimLost {
                claimed_process_instance_uuid: Some(process),
                ..
            } if process == second.process_instance_uuid
        ));
    }

    #[test]
    fn disconnect_is_indexed_and_preserves_durable_navigation() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        registry.reset_scale_counters();

        registry.release_connection(owner.connection_id).unwrap();

        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);
        let listed =
            applied_states(registry.list(claimant(1, 8, 9), expectation(&topology), &topology));
        assert_eq!(listed[0].workspaces, assigned.workspaces);
        assert_eq!(listed[0].claim_id, None);
        assert_eq!(listed[0].generation, assigned.generation + 1);
    }

    #[test]
    fn one_mutation_touches_one_record_at_thousand_record_scale() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let mut target = None;
        for index in 1..=1_000_u128 {
            let owner = claimant(index, index + 2_000, index + 4_000);
            let claimed = claim(&registry, owner, uuid(index + 10_000), &topology);
            if index == 777 {
                target = Some((owner, claimed));
            }
        }
        registry.reset_scale_counters();
        let (owner, claimed) = target.unwrap();

        let response = registry.mutate(
            owner,
            expectation(&topology),
            mutation(&claimed, Vec::new()),
            &topology,
        );

        assert!(matches!(response, ProjectionNavigationResponse::Applied { .. }));
        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);
        assert!(counters.workspace_owner_lookups <= 1);
    }

    #[test]
    fn semantic_budgets_reject_before_any_record_or_index_changes() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            records_per_client: 1,
            records_global: 1,
            operations_per_record: 1,
            operations_per_batch: 1,
            ..ProjectionNavigationLimits::default()
        });
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let record_limit = registry.claim(owner, uuid(11), expectation(&topology), &topology);
        assert!(matches!(
            conflict(record_limit),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerClient,
                maximum: 1,
                attempted: 2,
            }
        ));

        let operation_limit = registry.mutate(
            owner,
            expectation(&topology),
            mutation(
                &claimed,
                vec![
                    ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    },
                    ProjectionNavigationOperation::SelectWorkspace {
                        workspace_uuid: Some(workspace(101)),
                    },
                ],
            ),
            &topology,
        );
        assert!(matches!(
            conflict(operation_limit),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::OperationsPerRecord,
                maximum: 1,
                attempted: 2,
            }
        ));
        assert_eq!(registry.state_count(), 1);
        assert!(
            applied_states(registry.list(owner, expectation(&topology), &topology))[0]
                .workspaces
                .is_empty()
        );
    }

    fn applied_states(response: ProjectionNavigationResponse) -> Vec<ProjectionNavigationState> {
        match response {
            ProjectionNavigationResponse::Applied { states, .. } => states,
            ProjectionNavigationResponse::Conflict { conflict } => {
                panic!("expected applied response, got {conflict:?}")
            }
        }
    }

    fn conflict(response: ProjectionNavigationResponse) -> ProjectionNavigationConflict {
        match response {
            ProjectionNavigationResponse::Applied { .. } => panic!("expected conflict"),
            ProjectionNavigationResponse::Conflict { conflict } => conflict,
        }
    }

    fn state(
        states: &[ProjectionNavigationState],
        logical_presentation_id: uuid::Uuid,
    ) -> &ProjectionNavigationState {
        states
            .iter()
            .find(|state| state.logical_presentation_id == logical_presentation_id)
            .unwrap()
    }

    fn screen_state(
        state: &ProjectionNavigationState,
        screen_uuid: ScreenUuid,
    ) -> &ProjectionNavigationScreenState {
        state
            .workspaces
            .iter()
            .flat_map(|workspace| &workspace.screens)
            .find(|screen| screen.screen_uuid == screen_uuid)
            .unwrap()
    }

    fn pane_state(
        screen: &ProjectionNavigationScreenState,
        pane_uuid: PaneUuid,
    ) -> &ProjectionNavigationPaneState {
        screen.panes.iter().find(|pane| pane.pane_uuid == pane_uuid).unwrap()
    }

    fn claim(
        registry: &ProjectionNavigationRegistry,
        claimant: ProjectionNavigationClaimant,
        logical_presentation_id: uuid::Uuid,
        topology: &FixtureTopology,
    ) -> ProjectionNavigationState {
        applied_states(registry.claim(
            claimant,
            logical_presentation_id,
            expectation(topology),
            topology,
        ))
        .remove(0)
    }

    fn mutate_one(
        registry: &ProjectionNavigationRegistry,
        claimant: ProjectionNavigationClaimant,
        state: &ProjectionNavigationState,
        operations: Vec<ProjectionNavigationOperation>,
        topology: &FixtureTopology,
    ) -> ProjectionNavigationState {
        applied_states(registry.mutate(
            claimant,
            expectation(topology),
            mutation(state, operations),
            topology,
        ))
        .remove(0)
    }

    fn mutation(
        state: &ProjectionNavigationState,
        operations: Vec<ProjectionNavigationOperation>,
    ) -> ProjectionNavigationMutationBatch {
        ProjectionNavigationMutationBatch {
            projections: vec![ProjectionNavigationMutation {
                logical_presentation_id: state.logical_presentation_id,
                claim_id: state.claim_id.unwrap(),
                expected_generation: state.generation,
                operations,
            }],
        }
    }

    fn expectation(topology: &FixtureTopology) -> ProjectionNavigationTopologyExpectation {
        ProjectionNavigationTopologyExpectation {
            daemon_instance_id: topology.daemon_instance_id,
            session_id: topology.session_id,
            expected_revision: topology.revision,
        }
    }

    fn claimant(client: u128, process: u128, connection: u128) -> ProjectionNavigationClaimant {
        ProjectionNavigationClaimant {
            client_uuid: uuid(client),
            process_instance_uuid: uuid(process),
            connection_id: uuid(connection),
        }
    }

    fn uuid(value: u128) -> uuid::Uuid {
        uuid::Uuid::from_u128(value)
    }

    fn daemon(value: u128) -> DaemonInstanceId {
        uuid(value).to_string().parse().unwrap()
    }

    fn session(value: u128) -> SessionId {
        uuid(value).to_string().parse().unwrap()
    }

    fn workspace(value: u128) -> WorkspaceUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn screen(value: u128) -> ScreenUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn pane(value: u128) -> PaneUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn surface(value: u128) -> SurfaceUuid {
        uuid(value).to_string().parse().unwrap()
    }
}
