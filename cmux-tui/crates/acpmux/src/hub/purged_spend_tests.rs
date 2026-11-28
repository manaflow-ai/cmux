//! `hub/purged_spend.rs`: a purged chat's line carries its tokens by UTC hour, read to the end,
//! and the file drops lines older than two days once it grows.

use super::*;
use crate::usage_stats::Prices;
use serde_json::json;

const SID: &str = "01a18ad5-89bc-7a02-905f-8f4fbef7fed2";

fn ms(text: &str) -> u64 {
    crate::clock_text::rfc3339_ms(text).unwrap()
}

fn models() -> Models {
    let mut m = Models::default();
    let opus = Prices { input: 4.0, output: 20.0, cache_read: 0.2, cache_write: 5.0 };
    m.add("claude-haiku-5-5", Some(opus), Some(200_000));
    m
}

fn source(home: &Path, family: &str) -> (Source, PathBuf) {
    let mut env = BTreeMap::new();
    env.insert("CLAUDE_CONFIG_DIR".to_owned(), home.display().to_string());
    let source = Source {
        family: family.into(),
        agent_session_id: SID.into(),
        cwd: PathBuf::from("/work/repo.x"),
        created_at: ms("2026-11-28T10:55:00Z"),
        argv: None,
        env,
        unprompted: false,
    };
    (source, home.join("projects/-work-repo-x").join(format!("{SID}.jsonl")))
}

fn turn(id: &str, at: &str, input: u64, read: u64, output: u64) -> String {
    json!({"type": "assistant", "isSidechain": false, "timestamp": at,
        "message": {"id": id, "model": "claude-haiku-5-5", "role": "assistant",
            "content": [{"type": "text", "text": "ok"}],
            "usage": {"input_tokens": input, "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": read, "output_tokens": output}}})
    .to_string()
}

fn meta() -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "run-1", "name": "decide-rule",
        "harness": "claude", "cwd": "/work/repo.x", "status": "idle", "createdAt": 7,
        "updatedAt": 8, "family": "claude", "agentSessionId": SID,
        "tags": {"lane.reportsTo": {"value": "coord-a"}},
    }))
    .unwrap()
}

/// Turns in two UTC hours are kept per hour, tokens apart from cache reads, and the line names
/// the chat, its tags and when the counts are whole from.
#[test]
fn a_purged_chats_line_keeps_its_tokens_by_hour() {
    let home = tempfile::tempdir().unwrap();
    let (src, path) = source(home.path(), "claude");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let lines = [
        turn("m1", "2026-11-28T10:58:00Z", 10, 500, 5),
        turn("m2", "2026-11-28T11:02:00Z", 20, 600, 7),
        turn("m3", "2026-11-28T11:40:00Z", 30, 700, 9),
    ];
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    let trackers = StdMutex::new(HashMap::new());
    let now = ms("2026-11-28T11:45:00Z");
    let spend = read_spend(&trackers, None, "run-1", &src, &models(), now).expect("read");
    let ten = ms("2026-11-28T10:00:00Z");
    let eleven = ms("2026-11-28T11:00:00Z");
    assert_eq!(spend.hours.keys().copied().collect::<Vec<_>>(), vec![ten, eleven]);
    assert_eq!(spend.hours[&ten].0["claude-haiku-5-5"], 15);
    assert_eq!(spend.hours[&eleven].0["claude-haiku-5-5"], 66);
    assert_eq!(spend.hours[&eleven].1["claude-haiku-5-5"], 1300);
    assert!(spend.known_since.is_some_and(|at| at <= ten), "{:?}", spend.known_since);

    let line = record(&meta(), now, Some(&spend));
    assert_eq!(line["schema"], SCHEMA);
    assert_eq!(line["sessionId"], "run-1");
    assert_eq!(line["name"], "decide-rule");
    assert_eq!(line["tags"]["lane.reportsTo"], "coord-a");
    assert_eq!(line["purgedAt"], now);
    assert_eq!(line["hours"][eleven.to_string()]["tokensByModel"]["claude-haiku-5-5"], 66);
    assert_eq!(line["hours"][eleven.to_string()]["cacheReadByModel"]["claude-haiku-5-5"], 1300);
}

/// A no-model chat spent nothing, known whole; a chat whose spend could not be read says
/// `hours: null` (unknown), never zero.
#[test]
fn nothing_spent_and_nothing_read_are_told_apart() {
    let home = tempfile::tempdir().unwrap();
    let (src, _) = source(home.path(), NO_MODEL_FAMILY);
    let trackers = StdMutex::new(HashMap::new());
    let spend = read_spend(&trackers, None, "bench", &src, &models(), 1).expect("known");
    let zero = record(&meta(), 1, Some(&spend));
    assert_eq!(zero["hours"], json!({}));
    assert_eq!(zero["knownSince"], 0);
    let unknown = record(&meta(), 1, None);
    assert!(unknown["hours"].is_null() && unknown["knownSince"].is_null());
}

/// Past [`COMPACT_BYTES`] an append drops lines older than [`KEEP_MS`] and keeps the rest.
#[test]
fn a_grown_file_drops_lines_older_than_two_days() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let now = 10 * DAY_MS;
    let pad = "x".repeat(1024);
    let mut text = String::new();
    while text.len() as u64 <= COMPACT_BYTES {
        text += &json!({"purgedAt": now - 3 * DAY_MS, "pad": pad}).to_string();
        text.push('\n');
    }
    text += &json!({"purgedAt": now - DAY_MS, "name": "recent"}).to_string();
    text.push('\n');
    std::fs::write(&path, text).unwrap();
    append(&path, &json!({"purgedAt": now, "name": "new"})).unwrap();
    let kept: Vec<Value> = std::fs::read_to_string(&path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let names: Vec<&str> = kept.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["recent", "new"]);
    // A small file is only appended to.
    append(&path, &json!({"purgedAt": 0, "name": "old"})).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap().lines().count(), 3);
}
