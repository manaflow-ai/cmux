//! `usage_view.rs`: a whole pass reads its candidates (the live chats and the kept order's rows
//! of the last day), and finds the same chats a walk of every session finds.

use super::*;
use crate::config::Config;
use serde_json::json;
use std::collections::BTreeMap;

fn meta(id: &str, family: &str, sid: Option<&str>, status: &str, at: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": at,
        "family": family, "agentSessionId": sid,
    }))
    .unwrap()
}

fn ids(sources: &[(String, Source)]) -> Vec<String> {
    let mut ids: Vec<String> = sources.iter().map(|(id, _)| id.clone()).collect();
    ids.sort();
    ids
}

/// Decision 288 (c): one hub with an open Claude chat, open chats of two other families, a
/// Claude chat closed today, one closed two days ago, one closed two days ago and dated today
/// by a record, one closed two days ago with a draft set today (a date no record carries), and
/// one with no agent session id. The pass's sources are what a walk of every session finds, and
/// a prune by them drops the same chats.
#[tokio::test]
async fn a_pass_reads_the_chats_a_walk_of_every_session_reads() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let two_days = now - 2 * DAY_MS;
    let chats = [
        meta("open-claude", "claude", Some("s1"), "idle", now - 1_000),
        meta("open-codex", "codex", Some("s2"), "idle", two_days),
        meta("open-gemini", "gemini", Some("s3"), "idle", now - 2_000),
        meta("closed-today", "claude", Some("s4"), "closed", now - 3_600_000),
        meta("closed-old", "claude", Some("s5"), "closed", two_days),
        meta("closed-old-dated", "claude", Some("s6"), "closed", two_days - 1),
        meta("closed-old-draft", "claude", Some("s7"), "closed", two_days - 2),
        meta("no-sid", "claude", None, "idle", now - 3_000),
    ];
    for meta in chats {
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    // The order is built first: the writes below reach it as a read's patch, not a new sort.
    let _ = hub.kept_order_for_test();
    let built = hub.list_order_rebuilds_for_test();
    let session = |id: &str| hub.session_by_id(id).unwrap();
    hub.append(&session("closed-old-dated"), "mux", "tags", json!({"tags": {}}));
    hub.set_composer_draft(&session("closed-old-draft"), "a draft").unwrap();

    let now = crate::store::now_ms();
    let candidates = hub.usage_candidates(now);
    assert_eq!(hub.list_order_rebuilds_for_test(), built, "the candidates came from a patch");
    let read = hub.usage_sources(&candidates, now).await;
    let walked = hub.usage_sources(&hub.sessions(), now).await;
    assert_eq!(ids(&read), ids(&walked), "the pass reads what a walk of every session reads");
    assert_eq!(
        ids(&read),
        ["closed-old-dated", "closed-old-draft", "closed-today", "open-claude", "open-codex"],
    );
    assert!(
        !candidates.iter().any(|s| s.id == "closed-old"),
        "a chat closed two days ago is no candidate"
    );

    let every: Vec<String> = hub.session_handles().iter().map(|s| s.id.clone()).collect();
    let gone = |sources: &[(String, Source)]| {
        let mut trackers: HashMap<String, ()> = every.iter().map(|id| (id.clone(), ())).collect();
        let stats: HashSet<String> = every.iter().cloned().collect();
        let mut gone = prune_unlisted(&mut trackers, &stats, sources);
        gone.sort();
        gone
    };
    assert_eq!(gone(&read), gone(&walked), "a prune by the pass drops the walk's chats");
    assert_eq!(gone(&read), ["closed-old", "no-sid", "open-gemini"]);
}

/// A whole pass runs over its candidates and reads each of them it should, once.
#[tokio::test]
async fn a_whole_pass_counts_the_chats_it_read() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..3 {
        let live = meta(&format!("live-{n}"), "claude", Some("s"), "idle", now - n);
        let old = meta(&format!("old-{n}"), "claude", Some("s"), "closed", now - 2 * DAY_MS - n);
        for meta in [live, old] {
            hub.store.save(&meta).unwrap();
            hub.insert_test_session(meta);
        }
    }
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (1, 3));
    // Inside `REFRESH_EVERY_MS` with no turn ended: no pass.
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (1, 3));
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (2, 3));
}

/// Stats a pass found for chat `id`, as if one did.
fn stats_found(hub: &Hub, id: &str) {
    let stats: UsageStats =
        serde_json::from_value(json!({"autocompact": "unknown", "updatedAt": 1})).unwrap();
    hub.usage_stats.stats.lock().unwrap().insert_for_test(id, stats);
}

fn every_row_generation(hub: &Hub) -> u64 {
    hub.events.summary_generation.load(Ordering::SeqCst)
}

/// Decision 293 (i): a chat closed today and aged past the day before the next pass is no
/// candidate of that pass, yet its stats go as on base: its own row is told (its `summary_gen`
/// rises and it takes a list position), and no other closed row goes stale.
#[tokio::test]
async fn a_chat_aged_out_between_passes_tells_its_own_row_only() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let chat = meta("aging", "claude", Some("s1"), "closed", now - 3_600_000);
    hub.store.save(&chat).unwrap();
    let session = hub.insert_test_session(chat);
    stats_found(&hub, "aging");
    hub.refresh_usage_stats().await;
    assert!(hub.usage_stats.stats.lock().unwrap().get("aging").is_some(), "read today: kept");
    assert_eq!(hub.usage_passes_for_test(), (1, 1));

    hub.edit_test_meta(&session, |m| m.updated_at = now - 2 * DAY_MS);
    let head = hub.events.list_head();
    let (own, every) = (session.summary_gen.load(Ordering::SeqCst), every_row_generation(&hub));
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (2, 0), "no chat to read");
    assert!(hub.usage_stats.stats.lock().unwrap().get("aging").is_none(), "its stats went");
    assert!(session.summary_gen.load(Ordering::SeqCst) > own, "its own row was told");
    assert_eq!(every_row_generation(&hub), every, "no other closed row went stale");
    let told = hub.events.list_since(head).unwrap().rows;
    assert!(
        told.iter().any(|(_, key, _)| *key == crate::hub::row_log::RowKey::Own("aging".into())),
        "it took a list position: {told:?}"
    );
}

/// Decision 293 (ii): stats of a chat in no map (purged) go with every closed row stale, as on
/// base: no row of its own is left to tell.
#[tokio::test]
async fn a_purged_chats_stats_make_every_closed_row_stale() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    stats_found(&hub, "purged");
    let every = every_row_generation(&hub);
    hub.refresh_usage_stats().await;
    assert!(hub.usage_stats.stats.lock().unwrap().get("purged").is_none());
    assert!(every_row_generation(&hub) > every, "every closed row went stale");
}

/// Decision 292: a pass on a hub whose list order is not sorted yet (a deferred start before
/// its logs are read) sorts it once; the next pass and the next page read patch it.
#[tokio::test]
async fn a_pass_before_the_order_is_sorted_sorts_it_once() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..4 {
        let chat = meta(&format!("c{n}"), "claude", Some("s"), "closed", now - n * 1_000);
        hub.store.save(&chat).unwrap();
        hub.insert_test_session(chat);
    }
    hub.unsort_list_order_for_test();
    assert_eq!(hub.list_order_rebuilds_for_test(), 0, "not sorted yet");
    hub.refresh_usage_stats().await;
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "the pass sorted it");
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "the next pass patched it");
    let _ = hub.own_rows_from(None, 20);
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "a page read patched it");
    assert_eq!(hub.usage_passes_for_test(), (2, 4));
}

/// Session Info's usage read (`_acpmux/sessions {usage: true}`, `acpmux ls -w`) with a cache
/// already filled: it answers with what is cached at once and the pass runs behind it, never
/// waiting on a slow read (hq#13932). A cold read, with nothing cached yet, still waits for its
/// pass. The pass's read is a stub that takes `SLOW` longer than its own.
#[tokio::test(flavor = "multi_thread")]
async fn a_warm_usage_read_answers_before_its_slow_pass() {
    const SLOW: u64 = 400;
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..3 {
        let live = meta(&format!("live-{n}"), "claude", Some("s"), "idle", now - n);
        hub.store.save(&live).unwrap();
        hub.insert_test_session(live);
    }
    hub.slow_usage_reads_for_test(SLOW);
    let cold = std::time::Instant::now();
    hub.read_usage_for_list().await;
    let cold = cold.elapsed();
    assert_eq!(hub.usage_passes_for_test(), (1, 3), "a cold read waits for its pass");
    assert!(cold >= Duration::from_millis(SLOW), "the cold read waited: {cold:?}");

    hub.usage_pass_due_for_test();
    let warm = std::time::Instant::now();
    hub.read_usage_for_list().await;
    let warm = warm.elapsed();
    eprintln!("usage read with a {SLOW} ms pass: cold {cold:?}, warm {warm:?}");
    assert!(warm < Duration::from_millis(SLOW / 4), "the warm read waited for its pass: {warm:?}");
    // The pass the warm read started runs behind it.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while hub.usage_passes_for_test().0 < 2 && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(hub.usage_passes_for_test(), (2, 3), "the revalidation ran behind the read");
}

/// A chat's cached stats carry its tags: its turn's end and a change the chat index's file watch
/// saw in its transcript each leave them stale, one write whatever is cached, and a stale entry
/// is still what a row draws until the read behind it writes the new one.
#[tokio::test]
async fn a_chats_stats_go_stale_by_its_turn_and_its_transcript() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let chat = meta("c", "claude", Some("s1"), "idle", crate::store::now_ms());
    hub.store.save(&chat).unwrap();
    let session = hub.insert_test_session(chat);
    let key = ChatKey { harness: AdapterKind::ClaudeCode, session_id: "s1".into() };
    let other = ChatKey { harness: AdapterKind::ClaudeCode, session_id: "s2".into() };
    let write = || {
        let stats: UsageStats =
            serde_json::from_value(json!({"autocompact": "unknown", "updatedAt": 1})).unwrap();
        let tags = vec![UsageTag::Chat("c".into()), UsageTag::Transcript(key.clone())];
        let mut cache = hub.usage_stats.stats();
        let now = cache.cache.stamp();
        cache.insert_at("c".into(), stats, tags, now);
    };
    let fresh = || hub.usage_stats.stats().fresh("c").is_some();
    let kept = || hub.usage_stats.stats().get("c").is_some();
    write();
    assert!(fresh());

    hub.usage_transcripts_changed(std::iter::once(&ChatChange::Removed { key: other }));
    assert!(fresh(), "another chat's transcript leaves it fresh");
    hub.usage_stats.dirty.store(false, Ordering::SeqCst);
    hub.usage_transcripts_changed(std::iter::once(&ChatChange::Removed { key: key.clone() }));
    assert!(!fresh() && kept(), "its transcript changed: stale, still served");
    assert!(hub.usage_stats.dirty.load(Ordering::SeqCst), "the next read starts a pass");
    assert!(hub.usage_stats_of(&session, &session.meta()).is_some(), "the row draws it");

    write();
    assert!(fresh(), "read again: fresh");
    hub.refresh_usage_stats_of(&session);
    assert!(!fresh() && kept(), "its turn ended: stale, still served");
}

/// A cold list read that stops waiting for its slow first pass ([`READ_WAIT`]) still leaves the
/// rows that pass's stats changed told: a closed chat's row cached before the pass found its
/// stats is built anew with them. Before, the read dropped the pass's future at its wait, the
/// pass's blocking read wrote the stats anyway, and the row tells that ran after it never ran:
/// the closed row kept its bytes with no `usageStats` while `_acpmux/usage` had them, until
/// something else (`acpmux info` marking it read) changed the row.
#[tokio::test]
async fn a_cold_read_that_stops_waiting_still_tells_the_rows_its_pass_changed() {
    const SID: &str = "01a18ad5-89bc-7a02-905f-8f4fbef7fed2";
    let home = tempfile::tempdir().unwrap();
    let transcript = home.path().join("projects/-work-repo").join(format!("{SID}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    let record = json!({"type": "assistant", "isSidechain": false,
        "timestamp": "2026-10-30T00:00:01Z",
        "message": {"id": "m1", "model": "claude-opus-5-5", "role": "assistant",
            "content": [{"type": "text", "text": "hi"}],
            "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0, "output_tokens": 5}}});
    std::fs::write(&transcript, format!("{record}\n")).unwrap();

    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let mut chat = meta("closed", "claude", Some(SID), "closed", now - 3_600_000);
    chat.cwd = "/work/repo".into();
    chat.session_env.insert("CLAUDE_CONFIG_DIR".into(), home.path().display().to_string());
    hub.store.save(&chat).unwrap();
    let session = hub.insert_test_session(chat);

    hub.slow_usage_reads_for_test(READ_WAIT.as_millis() as u64 + 500);
    hub.read_usage_for_list().await;
    // The list this read serves builds the closed row now, before the pass found anything.
    assert!(!hub.own_row_text(&session, false).contains("usageStats"), "no stats yet");

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while hub.usage_stats.stats().get("closed").is_none() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(hub.usage_stats.stats().get("closed").is_some(), "the pass found its stats");
    let mut row = hub.own_row_text(&session, false);
    while !row.contains("usageStats") && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
        row = hub.own_row_text(&session, false);
    }
    assert!(row.contains("usageStats"), "the closed row draws the stats its pass found: {row}");
}

/// A chat on a Claude Code wrapper profile (`family = "claude-sr2"`) is read as Claude Code,
/// from Claude Code's own transcript; Chief's is not.
#[tokio::test]
async fn a_claude_sr2_chat_is_read_as_claude_code() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for meta in [
        meta("sr2", "claude-sr2", Some("s1"), "idle", now - 1_000),
        meta("sr2-pipe", "claude-sr2-pipe", Some("s2"), "closed", now - 2_000),
        meta("chief", "chief", Some("s3"), "idle", now - 3_000),
    ] {
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    let read = hub.usage_sources(&hub.sessions(), now).await;
    assert_eq!(ids(&read), ["sr2", "sr2-pipe"]);
    assert!(read.iter().all(|(_, s)| s.family == "claude"), "read from Claude Code's transcript");
    assert_eq!(transcript_family("claude"), Some("claude"));
    assert_eq!(transcript_family("codex"), Some("codex"));
    assert_eq!(transcript_family("codex-review-box"), Some("codex"));
    assert_eq!(transcript_family("codexy"), None);
    assert_eq!(transcript_family("claudette"), None);
    assert_eq!(transcript_family("gemini"), None);
}

/// A chat on a profile that declares `no_model = true` (the `benchecho` bench agent
/// `acpmux cli-agent` wraps) reads zero tokens, stamped by the pass, with no agent session id
/// or transcript; a chat on a profile that declares nothing still reads as unmeasured (no
/// stats), and a no-model chat closed two days ago is not read.
#[tokio::test]
async fn a_no_model_profiles_chat_reads_zero_tokens_not_null() {
    let dir = tempfile::tempdir().unwrap();
    let toml = "schema = 1\nid = \"benchecho\"\nname = \"Bench Echo\"\nprotocol = \"acp\"\n\
                command = \"acpmux\"\nargs = [\"cli-agent\", \"--\", \"bench-echo-agent\"]\n\
                no_model = true\n";
    std::fs::write(dir.path().join("benchecho.toml"), toml).unwrap();
    let echo = toml.replace("benchecho", "echo").replace("no_model = true\n", "");
    std::fs::write(dir.path().join("echo.toml"), echo).unwrap();
    #[cfg(unix)]
    for file in ["benchecho.toml", "echo.toml"] {
        // A group-writable profile is refused, whatever the umask that wrote it.
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(dir.path().join(file), perms).unwrap();
    }
    let sources = crate::config::profiles::ProfileSources {
        user_dir: Some(dir.path().to_path_buf()),
        ..Default::default()
    };
    let loaded = crate::config::profiles::load(&sources);
    assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
    let mut cfg = Config::default();
    for (id, (profile, meta)) in loaded.profiles {
        cfg.harnesses.insert(id.clone(), profile);
        cfg.profile_meta.insert(id, meta);
    }
    // The built-in Chief (`cmux-tui chief acp`) only posts prompts into the Chief
    // conversation; its model turns are metered on their own optchat chats.
    let chief = crate::config::CHIEF_PROFILE.to_string();
    cfg.harnesses.insert(chief.clone(), cfg.harnesses["echo"].clone());
    cfg.discovered.insert(chief.clone());
    assert!(cfg.runs_no_model(&chief) && cfg.runs_no_model("benchecho"));
    assert!(cfg.profile_meta["benchecho"].no_model);
    assert!(!cfg.profile_meta["echo"].no_model, "never inferred from `cli-agent`");
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for (id, harness, status, at) in [
        ("bench", "benchecho", "idle", now - 1_000),
        ("bench-old", "benchecho", "closed", now - 2 * DAY_MS),
        ("echo", "echo", "idle", now - 1_000),
        ("chief-chat", crate::config::CHIEF_PROFILE, "idle", now - 1_000),
    ] {
        let mut m = meta(id, harness, None, status, at);
        m.harness = harness.into();
        hub.store.save(&m).unwrap();
        hub.insert_test_session(m);
    }
    hub.refresh_usage_stats().await;
    let stats = |id: &str| {
        let session = hub.session_by_id(id).unwrap();
        hub.usage_stats_of(&session, &session.meta())
    };
    let bench = stats("bench").expect("a no-model chat has stats");
    assert_eq!(bench.tokens_by_model_previous_utc_hour, Some(Default::default()));
    assert_eq!(bench.tokens_by_model1h, Some(Default::default()));
    assert_eq!((bench.tokens24h, bench.calls24h), (Some(0), Some(0)));
    assert!(bench.updated_at >= now, "stamped by this pass");
    let chief_stats = stats("chief-chat").expect("the built-in Chief chat has stats");
    assert_eq!(chief_stats.tokens_by_model_previous_utc_hour, Some(Default::default()));
    assert!(stats("echo").is_none(), "a profile that declares nothing stays unmeasured");
    assert!(stats("bench-old").is_none(), "closed two days ago: not read");
    let rows = crate::cli::harness::list_rows(&*hub.config.read().await);
    let no_model = |id: &str| {
        let row = rows.iter().find(|r| r.id == id).unwrap();
        serde_json::to_value(row).unwrap()["noModel"].clone()
    };
    assert_eq!(no_model("benchecho"), json!(true));
    assert_eq!(no_model(crate::config::CHIEF_PROFILE), json!(true));
    assert_eq!(no_model("echo"), json!(false), "always written: the capability marker");
}

/// A Claude chat started and not yet prompted has written no transcript: it reads zero tokens
/// (spent nothing), not null (unmeasured). A chat with a turn, or one holding a resumed
/// conversation, whose transcript is not found still reads as unmeasured.
#[tokio::test]
async fn an_unprompted_chat_reads_zero_tokens_not_null() {
    let home = tempfile::tempdir().unwrap();
    // An empty Claude Code home: no chat's transcript is there.
    let mut cfg = Config::default();
    let mut profile = cfg.harnesses.get("claude").cloned().unwrap_or_else(|| {
        serde_json::from_value(json!({ "argv": ["claude-agent-acp"] })).unwrap()
    });
    profile.env.insert("CLAUDE_CONFIG_DIR".into(), home.path().display().to_string());
    cfg.harnesses.insert("claude".into(), profile);
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for (id, turns, resumed) in [("waiting", 0, false), ("ran", 1, false), ("resumed", 0, true)] {
        let mut m = meta(id, "claude", Some(&format!("sid-{id}")), "idle", now - 1_000);
        m.turn_count = turns;
        if resumed {
            m.previous_agent_session_ids = vec!["sid-before".into()];
        }
        hub.store.save(&m).unwrap();
        hub.insert_test_session(m);
    }
    let read = hub.usage_sources(&hub.sessions(), now).await;
    let unprompted: Vec<&str> =
        read.iter().filter(|(_, s)| s.unprompted).map(|(id, _)| id.as_str()).collect();
    assert_eq!(unprompted, ["waiting"]);
    hub.refresh_usage_stats().await;
    let stats = |id: &str| {
        let session = hub.session_by_id(id).unwrap();
        hub.usage_stats_of(&session, &session.meta())
    };
    let waiting = stats("waiting").expect("an unprompted chat has stats");
    assert_eq!((waiting.tokens24h, waiting.calls24h), (Some(0), Some(0)));
    assert_eq!(waiting.tokens_by_model_previous_utc_hour, Some(Default::default()));
    assert!(waiting.updated_at >= now, "stamped by this pass");
    assert!(stats("ran").is_none(), "a turn ran and its transcript is not found: unmeasured");
    assert!(stats("resumed").is_none(), "a resumed conversation's spend is not known zero");
}

/// Every turn's end reads its chat's usage: the catalog's prices are built once for the catalog
/// in use, not again per read, and are the ones a fresh build gives.
#[tokio::test]
async fn the_usage_prices_are_built_once_per_catalog() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let first = hub.usage_models();
    let again = hub.usage_models();
    assert!(Arc::ptr_eq(&first, &again));
    let fresh = Models::from_catalog(&hub.catalog.current());
    assert_eq!(format!("{first:?}").len(), format!("{fresh:?}").len());
}

/// A reviewer on codex-review-box (`family = "codex-review-box"`) is read as Codex, from the
/// home its profile keeps for that chat alone (`ACPMUX_CODEX_HOMES_PER_CHAT`): the box binds
/// `<folder>/<chat id>/sessions` of the host's, so its rollout is there and nowhere else.
#[tokio::test]
async fn a_codex_review_box_chat_is_read_from_its_own_codex_home() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let chat = meta("review-1", "codex-review-box", Some("019a-sid"), "idle", now - 1_000);
    hub.store.save(&chat).unwrap();
    hub.insert_test_session(chat);
    let read = hub.usage_sources(&hub.sessions(), now).await;
    assert_eq!(ids(&read), ["review-1"]);
    assert_eq!(read[0].1.family, "codex", "read from Codex's rollout");

    let root = tempfile::tempdir().unwrap();
    let mut env = BTreeMap::new();
    env.insert(CODEX_HOMES_PER_CHAT.to_owned(), root.path().display().to_string());
    env.insert("CODEX_HOME".to_owned(), "/home/u/.codex".to_owned());
    for bad in ["", ".", "..", "a/b", "a\\b"] {
        let mut kept = env.clone();
        per_chat_codex_home(&mut kept, bad);
        assert_eq!(kept["CODEX_HOME"], "/home/u/.codex", "{bad:?} is no folder name");
    }
    per_chat_codex_home(&mut env, "review-1");
    let home = root.path().join("review-1");
    assert_eq!(env["CODEX_HOME"], home.display().to_string());

    // What Codex in the box wrote under its bound sessions folder is what the reader counts.
    let (y, m, d) = crate::usage_stats::civil_from_days(now / DAY_MS);
    let day = home.join(format!("sessions/{y:04}/{m:02}/{d:02}"));
    std::fs::create_dir_all(&day).unwrap();
    let at = crate::server::iso(now - 500);
    let lines = [
        json!({"timestamp": at, "type": "turn_context", "payload": {"model": "gpt-6-astra"}}),
        json!({"timestamp": at, "type": "event_msg", "payload": {"type": "token_count",
            "info": {"total_token_usage": {"total_tokens": 1100},
                "last_token_usage": {"input_tokens": 1000, "cached_input_tokens": 400,
                    "output_tokens": 100, "total_tokens": 1100},
                "model_context_window": 258_400}}}),
    ];
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(day.join("rollout-2026-11-25T18-00-00-019a-sid.jsonl"), text).unwrap();
    let source = Source {
        family: "codex".into(),
        agent_session_id: "019a-sid".into(),
        created_at: now - 1_000,
        env,
        ..Default::default()
    };
    let stats = Tracker::default()
        .refresh(&source, now, &crate::usage_stats::Models::default())
        .expect("the rollout is found");
    assert_eq!(stats.tokens24h, Some(1100));
    let by_model = stats.tokens_by_model1h.expect("the reviewer's hour is measured");
    assert_eq!(by_model.get("gpt-6-astra"), Some(&1100));
}

/// The saved trackers sit beside the session store, one per chat by its plain id; a sweep
/// removes those of chats no pass reads and leaves every other file.
#[test]
fn saved_trackers_sit_beside_the_store_and_go_with_their_chats() {
    let home = tempfile::tempdir().unwrap();
    // 0700 whatever the umask: the store refuses a group-writable ancestor.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let store = crate::store::LocalStore::new(home.path().join("sessions"), 1 << 20).unwrap();
    let dir = crate::store::Store::usage_tracker_dir(&store).unwrap();
    assert_eq!(dir, home.path().join("usage-trackers"));
    assert!(
        crate::store::Store::usage_tracker_dir(&crate::store::MemoryStore::default()).is_none()
    );
    assert_eq!(saved_path(&dir, "chat-1"), Some(dir.join("chat-1.json")));
    assert_eq!(saved_path(&dir, "../chat-1"), None);
    assert_eq!(saved_path(&dir, ""), None);

    std::fs::create_dir_all(&dir).unwrap();
    for name in ["kept.json", "gone.json", "notes.txt", "kept.json.tmp"] {
        std::fs::write(dir.join(name), b"{}").unwrap();
    }
    let listed: HashSet<&str> = ["kept"].into_iter().collect();
    assert_eq!(sweep_saved(&dir, &listed), 1);
    let mut left: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, ["kept.json", "kept.json.tmp", "notes.txt"]);
    assert_eq!(sweep_saved(&home.path().join("none"), &listed), 0);
}
