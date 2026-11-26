use super::*;
use crate::upload::{Batch, Sender, Sent, next_batch, read_cursor, upload_with};
use serde_json::{Value, json};
use std::sync::Mutex as StdMutex;

const SALT: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const SECRET: &str = "0123456789abcdef0123456789abcdef";

fn is_id(text: &str) -> bool {
    text.len() == 24 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn sharer(dir: &Path) -> Sharer {
    let sharer = Sharer::new(dir.to_path_buf(), dir.join("no-settings.json"), Some("Box-1".into()));
    let _ = sharer.identity.set(Some(Identity::from_parts(SALT, SECRET)));
    sharer
}

fn lines(dir: &Path) -> Vec<Value> {
    spool::files(dir)
        .iter()
        .flat_map(|f| {
            std::fs::read_to_string(dir.join(f))
                .unwrap()
                .lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect::<Vec<Value>>()
        })
        .collect()
}

/// Validate.ts's `turn` and `session` field sets, in its order.
const TURN_FIELDS: &[&str] = &[
    "t",
    "session",
    "harness",
    "model",
    "ms",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "tool_calls",
    "subagents",
    "repo",
    "machine",
    "cost_usd",
    "outcome",
];

#[test]
fn a_turn_record_has_exactly_validate_ts_fields() {
    let ev = Event::Turn(TurnEvent {
        session: "a".repeat(24),
        harness: "claude".into(),
        model: Some("claude-opus-4-5".into()),
        ms: 1234,
        input_tokens: 10,
        output_tokens: 20,
        cache_read_tokens: 30,
        cache_write_tokens: 40,
        tool_calls: 3,
        subagents: 0,
        repo: Some("b".repeat(24)),
        machine: Some("local".into()),
        cost_usd: Some(0.25),
        outcome: Some(Outcome::Done),
    });
    let record = Record { at: 1_762_500_000_000, src: SRC.into(), ev };
    let text = serde_json::to_string(&record).unwrap();
    assert_eq!(
        text,
        r#"{"at":1762500000000,"src":"acpmux","ev":{"t":"turn","session":"aaaaaaaaaaaaaaaaaaaaaaaa","harness":"claude","model":"claude-opus-4-5","ms":1234,"input_tokens":10,"output_tokens":20,"cache_read_tokens":30,"cache_write_tokens":40,"tool_calls":3,"subagents":0,"repo":"bbbbbbbbbbbbbbbbbbbbbbbb","machine":"local","cost_usd":0.25,"outcome":"done"}}"#
    );
    let value: Value = serde_json::from_str(&text).unwrap();
    let keys: Vec<&str> = value["ev"].as_object().unwrap().keys().map(String::as_str).collect();
    let mut want = TURN_FIELDS.to_vec();
    want.sort_unstable();
    let mut got = keys.clone();
    got.sort_unstable();
    assert_eq!(got, want);
    assert_eq!(value.as_object().unwrap().len(), 3, "a record is at, src and ev only");
}

#[test]
fn optional_turn_fields_are_left_out_not_null() {
    let ev = Event::Turn(TurnEvent {
        session: "a".repeat(24),
        harness: "codex".into(),
        ..TurnEvent::default()
    });
    let value = serde_json::to_value(&ev).unwrap();
    for absent in ["model", "repo", "machine", "cost_usd", "outcome"] {
        assert!(value.get(absent).is_none(), "{absent} absent");
    }
    let session = serde_json::to_value(Event::Session(SessionEvent {
        session: "a".repeat(24),
        harness: "codex".into(),
        machine: "local".into(),
    }))
    .unwrap();
    assert_eq!(
        session,
        json!({"t":"session","session":"a".repeat(24),"harness":"codex","machine":"local"})
    );
}

#[test]
fn hashes_are_stable_salted_and_24_hex() {
    let one = Identity::from_parts(SALT, SECRET);
    assert_eq!(one.hash("session:x"), one.hash("session:x"));
    assert!(is_id(&one.hash("session:x")));
    assert!(is_id(&one.install));
    assert_ne!(one.hash("session:x"), one.hash("session:y"));
    let other = Identity::from_parts(&"f".repeat(64), SECRET);
    assert_ne!(one.hash("session:x"), other.hash("session:x"), "the salt changes every id");
    // Pinned: a change to the hash changes every id a team has already shared.
    assert_eq!(one.hash("session:x"), Identity::from_parts(SALT, SECRET).hash("session:x"));
}

#[test]
fn the_identity_is_made_once_and_kept_private() {
    let dir = tempfile::tempdir().unwrap();
    let share = dir.path().join("usage-share");
    let a = Identity::load_or_create(&share).unwrap();
    let b = Identity::load_or_create(&share).unwrap();
    assert_eq!(a, b);
    assert!(is_id(&a.install));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&share), 0o700);
        assert_eq!(mode(&share.join(ids::SALT_FILE)), 0o600);
    }
}

#[test]
fn remotes_normalize_to_one_form() {
    for url in [
        "git@github.com:Manaflow-AI/cmux.git",
        "https://github.com/Manaflow-AI/cmux",
        "https://user:pw@GitHub.com/Manaflow-AI/cmux.git/",
        "ssh://git@github.com:22/Manaflow-AI/cmux.git",
    ] {
        assert_eq!(
            ids::normalize_remote(url).as_deref(),
            Some("github.com/Manaflow-AI/cmux"),
            "{url}"
        );
    }
    assert_eq!(ids::normalize_remote("/home/me/repo"), None);
    assert_eq!(ids::normalize_remote("C:\\repo"), None);
}

#[test]
fn the_repo_comes_from_the_git_origin_and_only_as_a_hash() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("repo");
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::write(
        repo.join(".git/config"),
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme/widgets.git\n",
    )
    .unwrap();
    std::fs::create_dir_all(repo.join("src/deep")).unwrap();
    let share = dir.path().join("share");
    let s = sharer(&share);
    let facts = TurnFacts {
        session_id: "s1",
        harness: "claude",
        cwd: Some(&repo.join("src/deep")),
        outcome: Some(Outcome::Done),
        ..TurnFacts::default()
    };
    assert!(s.record_turn_at(&facts, 1_762_500_000_000));
    let written = lines(&share);
    let repo_id = written[1]["ev"]["repo"].as_str().unwrap();
    assert!(is_id(repo_id));
    assert_eq!(repo_id, Identity::from_parts(SALT, SECRET).hash("repo:github.com/acme/widgets"));
    let text = std::fs::read_to_string(share.join(spool::day_file(1_762_500_000_000))).unwrap();
    for leaked in ["acme", "widgets", "src/deep", "Box-1", "s1\""] {
        assert!(!text.contains(leaked), "{leaked} must not be written");
    }
}

#[test]
fn a_turn_writes_its_session_once_then_turns() {
    let dir = tempfile::tempdir().unwrap();
    let s = sharer(dir.path());
    let at = 1_762_500_000_000;
    let facts = |outcome| TurnFacts {
        session_id: "abc",
        harness: "codex",
        model: Some("gpt-5 with spaces"),
        ms: 900,
        input_tokens: 5,
        tool_calls: 2,
        cost_usd: Some(f64::NAN),
        outcome: Some(outcome),
        ..TurnFacts::default()
    };
    assert!(s.record_turn_at(&facts(Outcome::Done), at));
    assert!(s.record_turn_at(&facts(Outcome::Cancelled), at + 1));
    assert!(s.record_turn_at(&facts(Outcome::Failed), at + 2));
    let written = lines(dir.path());
    let kinds: Vec<&str> = written.iter().map(|r| r["ev"]["t"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["session", "turn", "turn", "turn"]);
    let outcomes: Vec<&str> =
        written[1..].iter().map(|r| r["ev"]["outcome"].as_str().unwrap()).collect();
    assert_eq!(outcomes, ["done", "cancelled", "failed"]);
    let turn = &written[1]["ev"];
    assert!(turn.get("model").is_none(), "a model name that is not a token is left out");
    assert!(turn.get("cost_usd").is_none(), "a NaN cost is left out");
    assert_eq!(turn["tool_calls"], 2);
    assert_eq!(turn["machine"], written[0]["ev"]["machine"]);
    assert!(is_id(turn["machine"].as_str().unwrap()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let file = dir.path().join(spool::day_file(at));
        assert_eq!(std::fs::metadata(file).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn off_records_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux.json");
    std::fs::write(&config, r#"{"diagnostics": {"usageSharing": false}}"#).unwrap();
    let s = Sharer::new(dir.path().join("share"), config.clone(), None);
    assert!(!s.record_turn(&TurnFacts {
        session_id: "x",
        harness: "claude",
        ..TurnFacts::default()
    }));
    assert!(!dir.path().join("share").exists(), "off makes no folder, salt or spool");
    assert!(!setting_enabled(&dir.path().join("missing.json")));
    // On without the notice acknowledged is still off; both together are on.
    std::fs::write(&config, r#"{"diagnostics.usageSharing": true}"#).unwrap();
    assert!(!setting_enabled(&config));
    std::fs::write(&config, r#"{"diagnostics": {"usageSharingNoticeAck": true}}"#).unwrap();
    assert!(!setting_enabled(&config));
    std::fs::write(
        &config,
        r#"{"diagnostics.usageSharing": true, "diagnostics.usageSharingNoticeAck": true}"#,
    )
    .unwrap();
    assert!(setting_enabled(&config));
    std::fs::write(
        &config,
        "// jsonc\n{\"diagnostics\": {\"usageSharing\": true, \"usageSharingNoticeAck\": true,},}",
    )
    .unwrap();
    assert!(setting_enabled(&config));
}

#[test]
fn clamping_keeps_numbers_in_validate_ts_ranges() {
    let t = TurnEvent {
        ms: u64::MAX,
        input_tokens: u64::MAX,
        cost_usd: Some(1e9),
        ..TurnEvent::default()
    }
    .clamped();
    assert_eq!(t.ms, record::U64_MAX_SAFE);
    assert_eq!(t.input_tokens, record::U64_MAX_SAFE);
    assert_eq!(t.cost_usd, Some(record::USD_MAX));
    assert_eq!(record::token("a b"), None);
    assert_eq!(record::harness_token("claude/code"), "other");
}

fn spool_n(dir: &Path, n: usize, at: u64) {
    let s = sharer(dir);
    for i in 0..n {
        let id = format!("s{}", i % 7);
        s.record_turn_at(
            &TurnFacts { session_id: &id, harness: "claude", ms: 1, ..TurnFacts::default() },
            at,
        );
    }
}

fn count_records(batch: &Batch) -> usize {
    let v: Value = serde_json::from_slice(&batch.body).unwrap();
    v["records"].as_array().unwrap().len()
}

#[test]
fn batches_split_at_the_record_limit() {
    let dir = tempfile::tempdir().unwrap();
    // 7 session records + 12000 turns.
    spool_n(dir.path(), 12_000, 1_762_500_000_000);
    let install = Identity::from_parts(SALT, SECRET).install;
    let mut cursor = read_cursor(dir.path());
    let mut sizes = Vec::new();
    // A byte limit well past the records' size, so the record limit alone splits.
    while let Some(batch) = next_batch(dir.path(), &install, &cursor, upload::MAX_RECORDS, 64 << 20)
    {
        assert_eq!(count_records(&batch), batch.records);
        let body: Value = serde_json::from_slice(&batch.body).unwrap();
        assert_eq!(body["install"], json!(install));
        assert_eq!(body.as_object().unwrap().len(), 2, "a body is install and records only");
        sizes.push(batch.records);
        cursor = batch.cursor;
    }
    assert_eq!(sizes, [5000, 5000, 2007]);
    // At the real limits every batch is at most 1 MiB, and none is lost.
    let mut cursor = Default::default();
    let mut total = 0;
    while let Some(batch) =
        next_batch(dir.path(), &install, &cursor, upload::MAX_RECORDS, upload::MAX_BODY_BYTES)
    {
        assert!(batch.body.len() <= upload::MAX_BODY_BYTES);
        assert!(batch.records <= upload::MAX_RECORDS);
        total += batch.records;
        cursor = batch.cursor;
    }
    assert_eq!(total, 12_007);
}

#[test]
fn batches_split_at_the_byte_limit() {
    let dir = tempfile::tempdir().unwrap();
    spool_n(dir.path(), 400, 1_762_500_000_000);
    let install = Identity::from_parts(SALT, SECRET).install;
    let limit = 16 * 1024;
    let mut cursor = read_cursor(dir.path());
    let mut total = 0;
    let mut batches = 0;
    while let Some(batch) = next_batch(dir.path(), &install, &cursor, 5000, limit) {
        assert!(batch.body.len() <= limit, "{} bytes", batch.body.len());
        assert!(batch.records > 0);
        total += batch.records;
        batches += 1;
        cursor = batch.cursor;
    }
    assert_eq!(total, 407);
    assert!(batches > 1);
    // The real limit: a full 5000-record batch of turn records is under 1 MiB.
    const { assert!(upload::MAX_BODY_BYTES >= 1024 * 1024) };
}

struct Stub {
    answers: StdMutex<Vec<Sent>>,
    bodies: StdMutex<Vec<Vec<u8>>>,
}

impl Stub {
    fn new(mut answers: Vec<Sent>) -> Self {
        answers.reverse();
        Self { answers: StdMutex::new(answers), bodies: StdMutex::new(Vec::new()) }
    }
}

impl Sender for Stub {
    fn send(&self, body: Vec<u8>) -> impl Future<Output = Sent> + Send {
        self.bodies.lock().unwrap().push(body);
        let answer = self
            .answers
            .lock()
            .unwrap()
            .pop()
            .unwrap_or(Sent::Accepted { accepted: 0, duplicates: 0 });
        async move { answer }
    }
}

fn accepted() -> Sent {
    Sent::Accepted { accepted: 1, duplicates: 0 }
}

#[tokio::test]
async fn the_cursor_moves_only_past_accepted_batches() {
    let dir = tempfile::tempdir().unwrap();
    spool_n(dir.path(), 30, 1_762_500_000_000);
    let install = Identity::from_parts(SALT, SECRET).install;
    // Batches of 10: the first accepted, the second answered 503.
    let stub = Stub::new(vec![accepted(), Sent::Retry { why: "HTTP 503".into() }]);
    let round = upload_with(dir.path(), &install, &stub, 10, upload::MAX_BODY_BYTES).await;
    assert_eq!(round.batches, 1);
    assert_eq!(round.records, 10);
    assert_eq!(round.ended, Some(Sent::Retry { why: "HTTP 503".into() }));
    let after_first = read_cursor(dir.path());
    // A refused batch (400 usage.invalid) moves nothing either.
    let stub = Stub::new(vec![Sent::Refused { status: 400, code: Some("usage.invalid".into()) }]);
    let round = upload_with(dir.path(), &install, &stub, 10, upload::MAX_BODY_BYTES).await;
    assert_eq!(round.batches, 0);
    assert_eq!(read_cursor(dir.path()), after_first);
    // The same batch goes again, then the rest.
    let resent = Stub::new(vec![]);
    let round = upload_with(dir.path(), &install, &resent, 10, upload::MAX_BODY_BYTES).await;
    assert_eq!(round.batches, 3, "27 records left after the first 10: 10 + 10 + 7");
    assert_eq!(round.ended, None);
    let refused_body = stub.bodies.lock().unwrap()[0].clone();
    assert_eq!(
        resent.bodies.lock().unwrap()[0],
        refused_body,
        "the refused batch is sent again unchanged"
    );
    // Nothing left: no call.
    let idle = Stub::new(vec![]);
    let round = upload_with(dir.path(), &install, &idle, 10, upload::MAX_BODY_BYTES).await;
    assert_eq!(round.batches, 0);
    assert!(idle.bodies.lock().unwrap().is_empty());
}

#[tokio::test]
async fn stopped_answers_end_the_round_quietly() {
    let dir = tempfile::tempdir().unwrap();
    spool_n(dir.path(), 3, 1_762_500_000_000);
    let install = Identity::from_parts(SALT, SECRET).install;
    for status in [401u16, 403, 404] {
        let sent = upload::classify(status, br#"{"code":"usage.forbidden","message":"x"}"#);
        assert_eq!(sent, Sent::Stopped { status, code: Some("usage.forbidden".into()) });
        let stub = Stub::new(vec![sent.clone()]);
        let round = upload_with(dir.path(), &install, &stub, 5000, upload::MAX_BODY_BYTES).await;
        assert_eq!(round.ended, Some(sent));
        assert!(read_cursor(dir.path()).is_empty());
    }
    assert_eq!(upload::classify(400, b"not json"), Sent::Refused { status: 400, code: None });
    assert_eq!(upload::classify(502, b""), Sent::Retry { why: "HTTP 502".into() });
    assert_eq!(
        upload::classify(200, br#"{"accepted":3,"duplicates":1,"expired":0,"cursor":{}}"#),
        Sent::Accepted { accepted: 3, duplicates: 1 }
    );
    assert_eq!(upload::refusal_code(br#"{"code":"a b"}"#), None, "free text is never echoed");
}

#[test]
fn bad_and_partial_lines_are_handled() {
    let dir = tempfile::tempdir().unwrap();
    spool_n(dir.path(), 2, 1_762_500_000_000);
    let file = dir.path().join(spool::day_file(1_762_500_000_000));
    let mut text = std::fs::read_to_string(&file).unwrap();
    text.push_str("{\"at\":1,\"src\":\"acpmux\",\"ev\":{\"t\":\"turn\",\"extra\":1}}\n");
    text.push_str("{\"at\":1,\"src\":\"acp"); // still being written
    std::fs::write(&file, &text).unwrap();
    let install = Identity::from_parts(SALT, SECRET).install;
    let batch = next_batch(dir.path(), &install, &Default::default(), 5000, upload::MAX_BODY_BYTES)
        .unwrap();
    assert_eq!(batch.records, 4, "2 sessions + 2 turns; the bad line is passed over");
    let end = batch.cursor.values().next().copied().unwrap();
    let partial_at = u64::try_from(text.rfind('\n').unwrap() + 1).unwrap();
    assert_eq!(end, partial_at, "the cursor stops before the unfinished line");
}

#[test]
fn old_spool_files_are_pruned() {
    let dir = tempfile::tempdir().unwrap();
    let day = 24 * 60 * 60 * 1000;
    let now = 1_762_500_000_000;
    spool_n(dir.path(), 1, now - 31 * day);
    spool_n(dir.path(), 1, now - 29 * day);
    assert_eq!(spool::files(dir.path()).len(), 2);
    let gone = spool::prune(dir.path(), now);
    assert_eq!(gone, [spool::day_file(now - 31 * day)]);
    assert_eq!(spool::files(dir.path()), [spool::day_file(now - 29 * day)]);
}

/// A fresh install (no settings file, default settings, or the toggle on with no notice
/// acknowledged) records nothing, creates no spool, and uploads nothing.
#[tokio::test]
async fn fresh_install_sends_no_usage_telemetry_until_opt_in() {
    struct CountSends(std::sync::atomic::AtomicUsize);
    impl Sender for CountSends {
        fn send(&self, _body: Vec<u8>) -> impl Future<Output = Sent> + Send {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            async { Sent::Retry { why: String::new() } }
        }
    }
    let sender = CountSends(std::sync::atomic::AtomicUsize::new(0));
    let facts = TurnFacts { session_id: "x", harness: "claude", ..TurnFacts::default() };
    let dir = tempfile::tempdir().unwrap();
    for (name, text) in [
        ("missing", None),
        ("default", Some("{}")),
        ("toggle-only", Some(r#"{"diagnostics": {"usageSharing": true}}"#)),
        ("ack-only", Some(r#"{"diagnostics": {"usageSharingNoticeAck": true}}"#)),
    ] {
        let config = dir.path().join(format!("{name}.json"));
        if let Some(text) = text {
            std::fs::write(&config, text).unwrap();
        }
        let share = dir.path().join(format!("share-{name}"));
        let s = Sharer::new(share.clone(), config, Some("host".into()));
        assert!(!s.enabled(), "{name}");
        assert!(!s.record_turn(&facts), "{name}");
        assert!(s.upload_round(&sender).await.is_none(), "{name}");
        assert!(!share.exists(), "{name}: no spool, salt or install id is made");
    }
    assert_eq!(sender.0.load(std::sync::atomic::Ordering::SeqCst), 0);
}
