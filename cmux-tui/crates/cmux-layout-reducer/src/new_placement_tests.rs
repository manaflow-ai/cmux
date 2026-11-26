use super::*;

fn planned(kind: Kind, placement: Placement) -> Plan {
    plan(&Request { kind, placement, tab_split: true })
}

/// Each placement asks for its own op, for every kind (one test per placement).
#[test]
fn right_splits_on_the_right() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Right).op, Op::Split { edge: Edge::Right });
    }
}

#[test]
fn left_splits_on_the_left() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Left).op, Op::Split { edge: Edge::Left });
    }
}

#[test]
fn up_splits_above() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Up).op, Op::Split { edge: Edge::Top });
    }
}

#[test]
fn down_splits_below() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Down).op, Op::Split { edge: Edge::Bottom });
    }
}

#[test]
fn column_right_is_a_new_column_after() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::ColumnRight).op, Op::Column { left: false });
    }
}

#[test]
fn column_left_is_a_new_column_before() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::ColumnLeft).op, Op::Column { left: true });
    }
}

#[test]
fn row_is_a_new_row_below() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Row).op, Op::Row);
    }
}

#[test]
fn tab_is_made_in_the_pane_for_every_kind() {
    for kind in Kind::ALL {
        assert_eq!(planned(kind, Placement::Tab), Plan { op: Op::Tab, make: Make::InPlace });
    }
}

#[test]
fn workspace_moves_the_new_tab_there_for_every_kind() {
    for kind in Kind::ALL {
        let plan = planned(kind, Placement::Workspace);
        assert_eq!(plan, Plan { op: Op::Workspace, make: Make::MadeThenMoved });
    }
}

#[test]
fn window_moves_the_new_tab_there_for_every_kind() {
    for kind in Kind::ALL {
        assert_eq!(
            planned(kind, Placement::Window),
            Plan { op: Op::Window, make: Make::MadeThenMoved }
        );
    }
}

/// The whole table: which kind is made in its place where, and which is made and moved.
#[test]
fn each_kind_is_made_in_place_only_where_its_own_create_does_it() {
    use Make::{InPlace as I, MadeThenMoved as M};
    // right, left, up, down, column right, column left, row, tab, workspace, window
    let table = [
        (Kind::Terminal, [I, I, I, I, I, I, I, I, M, M]),
        (Kind::Browser, [I, M, M, I, M, M, M, I, M, M]),
        (Kind::AgentChat, [I, M, M, I, M, M, M, I, M, M]),
        (Kind::NewTabPage, [I, I, I, I, M, M, M, I, M, M]),
    ];
    for (kind, makes) in table {
        for (placement, make) in Placement::ALL.into_iter().zip(makes) {
            assert_eq!(planned(kind, placement).make, make, "{kind:?} at {placement:?}");
        }
    }
}

/// A daemon without `conversation-tab-split-v1`: a chat is made beside the pane and moved.
#[test]
fn a_chat_without_tab_split_is_made_then_moved() {
    for placement in [Placement::Right, Placement::Down] {
        let plan = plan(&Request { kind: Kind::AgentChat, placement, tab_split: false });
        assert_eq!(plan.make, Make::MadeThenMoved, "{placement:?}");
    }
    // Not a chat: the fact changes nothing.
    let page =
        plan(&Request { kind: Kind::NewTabPage, placement: Placement::Right, tab_split: false });
    assert_eq!(page.make, Make::InPlace);
}

/// The wire: the app's names in, the op flattened beside `make` out.
#[test]
fn the_wire_uses_the_apps_names() {
    let request: Request =
        serde_json::from_str(r#"{"kind":"newTabPage","placement":"columnLeft","tabSplit":true}"#)
            .unwrap();
    assert_eq!(request.kind, Kind::NewTabPage);
    assert_eq!(request.placement, Placement::ColumnLeft);
    let answer = serde_json::to_value(plan(&request)).unwrap();
    assert_eq!(
        answer,
        serde_json::json!({"op": "column", "left": true, "make": "made_then_moved"})
    );
    let split = serde_json::to_value(planned(Kind::Terminal, Placement::Up)).unwrap();
    assert_eq!(split, serde_json::json!({"op": "split", "edge": "top", "make": "in_place"}));
    let request: Request =
        serde_json::from_str(r#"{"kind":"agentChat","placement":"down"}"#).unwrap();
    assert!(!request.tab_split, "tabSplit defaults to false");
}
