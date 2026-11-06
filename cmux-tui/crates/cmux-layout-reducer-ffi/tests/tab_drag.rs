use cmux_layout_reducer_ffi::tab_drag::*;

#[test]
fn wire_index_matches_same_and_cross_pane_rules() {
    assert_eq!(cmux_tab_move_wire_index(-7, 0, 2), 0);
    assert_eq!(cmux_tab_move_wire_index(2, 1, 2), 2);
    assert_eq!(cmux_tab_move_wire_index(3, 1, 2), 4);
    assert_eq!(cmux_tab_move_wire_index(-1, 1, -2), 0);
    assert_eq!(cmux_tab_move_wire_index(-8, 1, -9), -7);
    assert_eq!(cmux_tab_move_wire_index(i64::MAX, 1, 0), i64::MAX);
}

#[test]
fn pane_final_index_removes_then_inserts_and_clamps() {
    let display = [10, 20, 30, 40];
    let pane = [10, 30, 20, 40];
    assert_eq!(
        unsafe {
            cmux_tab_move_pane_final_index(
                display.as_ptr(),
                display.len(),
                20,
                1,
                pane.as_ptr(),
                pane.len(),
            )
        },
        1
    );
    assert_eq!(
        unsafe {
            cmux_tab_move_pane_final_index(
                display.as_ptr(),
                display.len(),
                20,
                -9,
                pane.as_ptr(),
                pane.len(),
            )
        },
        0
    );
    assert_eq!(
        unsafe {
            cmux_tab_move_pane_final_index(
                display.as_ptr(),
                display.len(),
                20,
                99,
                pane.as_ptr(),
                pane.len(),
            )
        },
        3
    );
    assert_eq!(
        unsafe {
            cmux_tab_move_pane_final_index(std::ptr::null(), 1, 20, 0, pane.as_ptr(), pane.len())
        },
        -1
    );
}

#[test]
fn group_index_counts_only_members_before_display_slot() {
    let display = [10, 20, 30, 40, 50];
    let members = [20, 40, 99];
    assert_eq!(
        unsafe {
            cmux_tab_move_group_index(
                display.as_ptr(),
                display.len(),
                members.as_ptr(),
                members.len(),
                30,
                3,
            )
        },
        2
    );
    assert_eq!(
        unsafe {
            cmux_tab_move_group_index(
                display.as_ptr(),
                display.len(),
                members.as_ptr(),
                members.len(),
                20,
                99,
            )
        },
        1
    );
    assert_eq!(
        unsafe {
            cmux_tab_move_group_index(std::ptr::null(), 1, members.as_ptr(), members.len(), 30, 0)
        },
        -1
    );
}

#[test]
fn drop_reveal_maps_outcomes_and_guards() {
    let base = [1, 1, 0, 0, 0, 0, 1, 0, 1];
    assert_eq!(
        cmux_drop_reveal_decide(OUTCOME_STRIP, base[0], base[1], 0, 0, 0, 1, 0, 1),
        DROP_REVEAL_FOCUSES_TAB
    );
    assert_eq!(
        cmux_drop_reveal_decide(OUTCOME_NEW_WORKSPACE, 1, 1, 0, 0, 0, 1, 0, 1),
        DROP_REVEAL_FOCUSES_TAB | DROP_REVEAL_SHOWS_WORKSPACE
    );
    assert_eq!(
        cmux_drop_reveal_decide(OUTCOME_TEAR_OFF, 1, 1, 0, 0, 0, 1, 0, 1),
        DROP_REVEAL_FOCUSES_TAB | DROP_REVEAL_SHOWS_WORKSPACE | DROP_REVEAL_MAKES_KEY
    );
    assert_eq!(
        cmux_drop_reveal_decide(OUTCOME_WORKSPACE, 1, 1, 0, 0, 1, 1, 0, 1),
        DROP_REVEAL_FOCUSES_TAB | DROP_REVEAL_SHOWS_WORKSPACE | DROP_REVEAL_MAKES_KEY
    );
    assert_eq!(cmux_drop_reveal_decide(OUTCOME_STRIP, 1, 0, 0, 0, 0, 1, 0, 1), DROP_REVEAL_NONE);
    assert_eq!(cmux_drop_reveal_decide(OUTCOME_STRIP, 1, 1, 0, 1, 0, 1, 0, 1), DROP_REVEAL_NONE);
    assert_eq!(
        cmux_drop_reveal_decide(OUTCOME_MOVE_WINDOW, 1, 1, 0, 0, 1, 1, 0, 1),
        DROP_REVEAL_NONE
    );
    assert_eq!(cmux_drop_reveal_decide(255, 1, 1, 0, 0, 0, 1, 0, 1), DROP_REVEAL_NONE);
}

#[test]
fn edge_mapping_covers_every_public_case() {
    assert_eq!(cmux_pane_drop_zone_edge(ZONE_LEFT), EDGE_LEFT);
    assert_eq!(cmux_pane_drop_zone_edge(ZONE_RIGHT), EDGE_RIGHT);
    assert_eq!(cmux_pane_drop_zone_edge(ZONE_TOP), EDGE_TOP);
    assert_eq!(cmux_pane_drop_zone_edge(ZONE_BOTTOM), EDGE_BOTTOM);
    assert_eq!(cmux_pane_drop_zone_edge(ZONE_CENTER), EDGE_NONE);

    for edge in [EDGE_LEFT, EDGE_RIGHT, EDGE_TOP, EDGE_BOTTOM] {
        assert_eq!(cmux_tab_drop_edge_pane_edge(edge), edge);
    }
    assert_eq!(cmux_pane_edge_opposite(EDGE_LEFT), EDGE_RIGHT);
    assert_eq!(cmux_pane_edge_opposite(EDGE_RIGHT), EDGE_LEFT);
    assert_eq!(cmux_pane_edge_opposite(EDGE_TOP), EDGE_BOTTOM);
    assert_eq!(cmux_pane_edge_opposite(EDGE_BOTTOM), EDGE_TOP);
    assert_eq!(cmux_pane_edge_drop_zone(EDGE_LEFT), ZONE_LEFT);
    assert_eq!(cmux_pane_edge_drop_zone(EDGE_RIGHT), ZONE_RIGHT);
    assert_eq!(cmux_pane_edge_drop_zone(EDGE_TOP), ZONE_TOP);
    assert_eq!(cmux_pane_edge_drop_zone(EDGE_BOTTOM), ZONE_BOTTOM);
    assert_eq!(cmux_pane_edge_split_axis(EDGE_LEFT), AXIS_HORIZONTAL);
    assert_eq!(cmux_pane_edge_split_axis(EDGE_RIGHT), AXIS_HORIZONTAL);
    assert_eq!(cmux_pane_edge_split_axis(EDGE_TOP), AXIS_VERTICAL);
    assert_eq!(cmux_pane_edge_split_axis(EDGE_BOTTOM), AXIS_VERTICAL);
}

#[test]
fn edge_mapping_rejects_unknown_codes_with_none() {
    for code in [ZONE_NONE, 5, 254] {
        assert_eq!(cmux_pane_drop_zone_edge(code), EDGE_NONE);
    }
    for code in [EDGE_NONE, 4, 254] {
        assert_eq!(cmux_tab_drop_edge_pane_edge(code), EDGE_NONE);
        assert_eq!(cmux_pane_edge_opposite(code), EDGE_NONE);
        assert_eq!(cmux_pane_edge_drop_zone(code), ZONE_NONE);
        assert_eq!(cmux_pane_edge_split_axis(code), AXIS_NONE);
    }
}
