//! `task.list` ordering and limit semantics.

use std::collections::BTreeSet;

use cmux_tasks_core::ids::Principal;
use cmux_tasks_core::model::{Description, Priority, State, Task};
use cmux_tasks_core::query::{self, ListFilter, Order, TaskView};

fn task(
    number: u64,
    sort_key: &str,
    priority: Priority,
    updated_at: i64,
    title: &str,
    archived: bool,
    mine: bool,
) -> Task {
    Task {
        id: format!("task_{number:02}"),
        number,
        title: title.to_owned(),
        description: Description::default(),
        status: "st_backlog".to_owned(),
        priority,
        assignee: mine.then(|| Principal::user("usr_test")),
        delegate: None,
        labels: BTreeSet::new(),
        project: None,
        parent: None,
        estimate: None,
        due: None,
        sort_key: sort_key.to_owned(),
        attention: None,
        created_by: Principal::user("usr_test"),
        created_at: number as i64,
        updated_at,
        started_at: None,
        completed_at: None,
        canceled_at: None,
        manual_status_at: None,
        archived,
        deleted: false,
    }
}

fn fixture() -> State {
    let mut state = State::new("team", "CMX");
    let tasks = [
        task(0, "a", Priority::Urgent, 100, "Shared task", false, true),
        task(1, "a", Priority::Urgent, 100, "Shared task", false, false),
        task(2, "b", Priority::High, 90, "Shared task", false, false),
        task(3, "c", Priority::None, 80, "Other task", true, false),
        task(4, "c", Priority::None, 80, "Other task", false, true),
        task(5, "d", Priority::Low, 70, "Other task", false, false),
        task(6, "e", Priority::Medium, 60, "Other task", false, false),
        task(7, "f", Priority::None, 50, "Other task", false, false),
    ];
    for task in tasks {
        state.tasks.insert(task.id.clone(), task);
    }
    state
}

fn ids(views: &[TaskView]) -> Vec<&str> {
    views.iter().map(|view| view.task.id.as_str()).collect()
}

fn assert_limits(state: &State, base: ListFilter, expected: &[&str]) {
    let caller = Principal::user("usr_test");
    for limit in [None, Some(0), Some(1), Some(3), Some(usize::MAX)] {
        let mut filter = base.clone();
        filter.limit = limit;
        let result = query::list(state, &caller, &filter);
        let expected_len = limit.map_or(expected.len(), |n| n.min(expected.len()));
        assert_eq!(
            ids(&result),
            expected[..expected_len],
            "order={:?}, filter={base:?}, limit={limit:?}",
            base.order
        );
    }
}

#[test]
fn list_limits_preserve_order_for_all_orders_and_filters() {
    let state = fixture();
    let filters = [
        (
            ListFilter::default(),
            ["task_00", "task_01", "task_02", "task_04", "task_05", "task_06", "task_07"]
                .as_slice(),
        ),
        (ListFilter { archived: true, ..ListFilter::default() }, ["task_03"].as_slice()),
        (ListFilter { mine: true, ..ListFilter::default() }, ["task_00", "task_04"].as_slice()),
        (
            ListFilter { open: true, ..ListFilter::default() },
            ["task_00", "task_01", "task_02", "task_04", "task_05", "task_06", "task_07"]
                .as_slice(),
        ),
        (
            ListFilter { search: Some("shared".to_owned()), ..ListFilter::default() },
            ["task_00", "task_01", "task_02"].as_slice(),
        ),
    ];

    for (mut filter, expected) in filters.iter().cloned() {
        filter.order = Order::Manual;
        assert_limits(&state, filter, expected);
    }
    // Priority has a distinct expected order and preserves the manual tie of
    // urgent tasks 00/01 because their priority and sort key both match.
    assert_limits(
        &state,
        ListFilter { order: Order::Priority, ..ListFilter::default() },
        &["task_00", "task_01", "task_02", "task_06", "task_05", "task_04", "task_07"],
    );
    assert_limits(
        &state,
        ListFilter { order: Order::Updated, ..ListFilter::default() },
        &["task_00", "task_01", "task_02", "task_04", "task_05", "task_06", "task_07"],
    );
    assert_limits(
        &state,
        ListFilter { order: Order::Created, ..ListFilter::default() },
        &["task_07", "task_06", "task_05", "task_04", "task_02", "task_01", "task_00"],
    );

    // Filters combine with every ordering mode, including an archived row and
    // a search that selects the stable manual tie.
    for order in [Order::Manual, Order::Priority, Order::Updated, Order::Created] {
        assert_limits(
            &state,
            ListFilter { order, archived: true, ..ListFilter::default() },
            &["task_03"],
        );
        let open = match order {
            Order::Priority => {
                ["task_00", "task_01", "task_02", "task_06", "task_05", "task_04", "task_07"]
                    .as_slice()
            }
            Order::Created => {
                ["task_07", "task_06", "task_05", "task_04", "task_02", "task_01", "task_00"]
                    .as_slice()
            }
            _ => ["task_00", "task_01", "task_02", "task_04", "task_05", "task_06", "task_07"]
                .as_slice(),
        };
        assert_limits(&state, ListFilter { order, open: true, ..ListFilter::default() }, open);
        let mine = match order {
            Order::Created => ["task_04", "task_00"].as_slice(),
            _ => ["task_00", "task_04"].as_slice(),
        };
        assert_limits(&state, ListFilter { order, mine: true, ..ListFilter::default() }, mine);
        let shared = match order {
            Order::Created => ["task_02", "task_01", "task_00"].as_slice(),
            Order::Priority => ["task_00", "task_01", "task_02"].as_slice(),
            _ => ["task_00", "task_01", "task_02"].as_slice(),
        };
        assert_limits(
            &state,
            ListFilter { order, search: Some("shared".to_owned()), ..ListFilter::default() },
            shared,
        );
    }
}
