use cmux_history::{ActorFilter, HistoryKind, NewVisit, SearchFilter, VisitActor, VisitStore};

fn visit(url: &str, at_ms: i64, actor: Option<VisitActor>) -> NewVisit {
    NewVisit { url: url.to_owned(), title: None, tab: None, actor, at_ms }
}

#[test]
fn existing_database_migrates_legacy_rows_to_person() {
    let path =
        std::env::temp_dir().join(format!("cmux-history-actor-{}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&path);
    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute_batch(
            "CREATE TABLE visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
             visit_time_ms INTEGER NOT NULL, tab TEXT);
             CREATE TABLE removed_visits(backup TEXT NOT NULL, id INTEGER NOT NULL, url TEXT NOT NULL,
             title TEXT, visit_time_ms INTEGER NOT NULL, tab TEXT);
             CREATE TABLE imported_logs(source TEXT PRIMARY KEY, visits INTEGER NOT NULL);",
        ).unwrap();
        connection
            .execute(
                "INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?1, ?2, ?3, NULL)",
                ("https://legacy.example/", "Legacy", 1_i64),
            )
            .unwrap();
    }
    let store = VisitStore::open(&path).unwrap();
    let visit = store.visit(1).unwrap().unwrap();
    assert_eq!(visit.actor, VisitActor::Person);
    assert_eq!(
        store
            .visits_matching_with_actor(
                &SearchFilter::<HistoryKind>::words(Vec::new()),
                10,
                ActorFilter::Mine
            )
            .unwrap()
            .len(),
        1
    );
    drop(store);
    let _ = std::fs::remove_file(path);
}

#[test]
fn actor_filter_excludes_agent_visits_from_ranking_and_lists() {
    let store = VisitStore::open_in_memory().unwrap();
    store.record(&visit("https://person.example/", 10, None)).unwrap();
    store
        .record(&visit(
            "https://agent.example/",
            20,
            Some(VisitActor::Agent { session_id: Some("s1".into()) }),
        ))
        .unwrap();
    let filter = SearchFilter::<HistoryKind>::words(Vec::new());
    let mine = store.visits_matching_with_actor(&filter, 10, ActorFilter::Mine).unwrap();
    assert_eq!(
        mine.iter().map(|row| row.url.as_str()).collect::<Vec<_>>(),
        vec!["https://person.example/"]
    );
    let agents = store.visits_matching_with_actor(&filter, 10, ActorFilter::Agents).unwrap();
    assert_eq!(agents[0].actor, VisitActor::Agent { session_id: Some("s1".into()) });
    assert_eq!(store.summaries(10).unwrap()[0].url, "https://person.example/");
}
