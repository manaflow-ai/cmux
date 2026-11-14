use super::*;

fn rows(n: usize) -> Vec<Value> {
    (0..n)
        .map(|i| {
            let id = format!("s-{i:05}");
            json!({"sessionId": id, "name": id, "updatedAt": (n - i) as u64 / 2})
        })
        .collect()
}

fn changed(app: &mut App, id: &str, at: u64) {
    app.on_notification(
        method::MUX_SESSION_CHANGED,
        json!({"sessionId": id, "kind": "status",
                "session": {"sessionId": id, "name": id, "updatedAt": at}}),
    );
}

/// Each change leaves the list and the selection as a full stable sort would.
#[tokio::test]
async fn a_changed_row_takes_the_place_a_sort_gives_it() {
    let (mut app, _requests) = interaction_tests::app().await;
    app.drafts.clear();
    app.sessions = rows(40);
    app.sort_sessions();
    app.selected = 7;
    let selected = app.selected_id();
    // Rows that cross the selected one both ways, and the selected row itself moving.
    for (n, at) in
        [(3, 100), (39, 0), (20, 10), (0, 10), (12, 5), (30, 19), (7, 200), (7, 0), (33, 300)]
    {
        let id = format!("s-{n:05}");
        changed(&mut app, &id, at);
        assert_eq!(app.sessions.len(), 40);
        let at = |row: &Value| row["updatedAt"].as_u64().unwrap_or(0);
        for pair in app.sessions.windows(2) {
            assert!(at(&pair[0]) >= at(&pair[1]), "out of order after {id}");
        }
        assert_eq!(app.selected_id(), selected, "the selection stays on its row");
    }
    changed(&mut app, "new", 1_000);
    assert_eq!(app.sessions[0]["sessionId"], "new");
    assert_eq!(app.selected_id(), selected);
}

#[tokio::test]
#[ignore = "manual per-event cost measurement"]
async fn update_cost_tui_session_changed() {
    for n in [100, 1_000, 3_000] {
        let (mut app, _requests) = interaction_tests::app().await;
        app.drafts.clear();
        app.sessions = rows(n);
        app.sort_sessions();
        app.selected = n / 2;
        let rounds = 200;
        let started = std::time::Instant::now();
        for round in 0..rounds {
            // A turn's status on a row near the end: it moves to the top.
            let id = format!("s-{:05}", n - 1 - round % 10);
            changed(&mut app, &id, (n + round) as u64);
        }
        let per = started.elapsed().as_secs_f64() * 1e6 / rounds as f64;
        eprintln!("UPDATE-COST tui_session_changed n={n} per_event_us={per:.1}");
    }
}
