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

fn agent(session: &str) -> Option<VisitActor> {
    Some(VisitActor::Agent { session_id: Some(session.into()) })
}

#[test]
fn removed_agent_visit_restores_with_its_actor() {
    let store = VisitStore::open_in_memory().unwrap();
    let id = store.record(&visit("https://agent.example/", 10, agent("s2"))).unwrap();
    assert_eq!(store.remove_visit(id, "b1").unwrap(), 1);
    assert_eq!(store.restore("b1").unwrap(), 1);
    let restored = store
        .visits_matching_with_actor(
            &SearchFilter::<HistoryKind>::words(Vec::new()),
            10,
            ActorFilter::All,
        )
        .unwrap();
    assert_eq!(restored.len(), 1);
    assert_eq!(restored[0].actor, VisitActor::Agent { session_id: Some("s2".into()) });
}

#[test]
fn title_updates_never_land_on_agent_visits() {
    let store = VisitStore::open_in_memory().unwrap();
    let person = store.record(&visit("https://same.example/", 10, None)).unwrap();
    let agent_id = store.record(&visit("https://same.example/", 20, agent("s3"))).unwrap();
    assert_eq!(store.update_title("https://same.example/", "Mine").unwrap(), 1);
    assert_eq!(store.visit(person).unwrap().unwrap().title.as_deref(), Some("Mine"));
    assert_eq!(store.visit(agent_id).unwrap().unwrap().title, None);
}

#[test]
fn import_keeps_agent_actor_and_reads_legacy_sources_as_person() {
    let dir =
        std::env::temp_dir().join(format!("cmux-history-actor-import-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let now = 1_000_000_i64;
    let current = dir.join("current.sqlite");
    {
        let source = VisitStore::open(&current).unwrap();
        source.record(&visit("https://agent.example/", now - 10, agent("s4"))).unwrap();
        source.record(&visit("https://person.example/", now - 5, None)).unwrap();
    }
    let legacy = dir.join("legacy.sqlite");
    {
        let connection = rusqlite::Connection::open(&legacy).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
                 visit_time_ms INTEGER NOT NULL, tab TEXT);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO visits(url, visit_time_ms) VALUES ('https://legacy.example/', ?1)",
                [now - 1],
            )
            .unwrap();
    }
    let store = VisitStore::open_in_memory().unwrap();
    assert_eq!(store.import_at(&current, now).unwrap(), 2);
    assert_eq!(store.import_at(&legacy, now).unwrap(), 1);
    let all = store
        .visits_matching_with_actor(
            &SearchFilter::<HistoryKind>::words(Vec::new()),
            10,
            ActorFilter::All,
        )
        .unwrap();
    let actor_of = |url: &str| all.iter().find(|row| row.url == url).unwrap().actor.clone();
    assert_eq!(
        actor_of("https://agent.example/"),
        VisitActor::Agent { session_id: Some("s4".into()) }
    );
    assert_eq!(actor_of("https://person.example/"), VisitActor::Person);
    assert_eq!(actor_of("https://legacy.example/"), VisitActor::Person);
    let _ = std::fs::remove_dir_all(dir);
}
