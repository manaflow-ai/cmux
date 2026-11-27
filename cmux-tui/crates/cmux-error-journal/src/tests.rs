//! Ports of the Swift CmuxNextErrorJournalTests. The journal tests drive [`Journal`] through
//! [`Disk`], an in-memory copy of the app's segment store (numbered segments, append to the
//! newest, compaction writes a new one and removes the older ones, a locked segment cannot be
//! removed), the way the Swift `ErrorJournal` drives the ops.

use crate::entry::{Entry, Event, Level};
use crate::journal::{Journal, Limits, Purpose, WriteMode, Written};
use crate::normalize::template;
use crate::ops::ErrorJournals;
use crate::query::{Order, Query, report_text};
use crate::sources::{self, OsLogRecord, ReportFile};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

const BASE: f64 = 1_800_000_000.0;

fn event(message: &str) -> Event {
    Event::new("app", Level::Error, message, BASE)
}

fn event_at(message: &str, source: &str, level: Level, offset: f64) -> Event {
    Event::new(source, level, message, BASE + offset)
}

// MARK: - The segment store

#[derive(Default)]
struct Segment {
    number: u32,
    data: String,
    locked: bool,
}

#[derive(Default)]
struct Disk {
    segments: Vec<Segment>,
    next: u32,
}

impl Disk {
    fn shared() -> Rc<RefCell<Self>> {
        Rc::new(RefCell::new(Self { segments: Vec::new(), next: 1 }))
    }

    fn put(&mut self, data: &str) {
        let number = self.next;
        self.next += 1;
        self.segments.push(Segment { number, data: data.to_owned(), locked: false });
    }

    fn text(&self) -> String {
        self.segments.iter().map(|segment| segment.data.as_str()).collect()
    }

    fn bytes(&self) -> u64 {
        self.segments.iter().map(|segment| segment.data.len() as u64).sum()
    }

    fn compact(&mut self, data: &str, purpose: Purpose) -> Written {
        self.put(data);
        let newest = self.next - 1;
        let mut error = None;
        self.segments.retain(|segment| {
            if segment.number == newest {
                return true;
            }
            if segment.locked {
                error.get_or_insert_with(|| format!("segment {} is locked", segment.number));
                return true;
            }
            false
        });
        Written {
            mode: WriteMode::Compact,
            purpose,
            written: true,
            bytes: data.len() as u64,
            error,
        }
    }

    fn append(&mut self, data: &str) -> Written {
        let segment = self.segments.last_mut().expect("an append has a newest segment");
        segment.data.push_str(data);
        Written {
            mode: WriteMode::Append,
            purpose: Purpose::Flush,
            written: true,
            bytes: data.len() as u64,
            error: None,
        }
    }
}

/// One `ErrorJournal(directory:)`: opens on the disk's segments and executes the writes it plans.
struct Store {
    disk: Rc<RefCell<Disk>>,
    journal: Journal,
}

impl Store {
    fn open(disk: &Rc<RefCell<Disk>>, limits: Limits) -> Self {
        let mut journal = Journal::new(limits);
        let data = {
            let disk = disk.borrow();
            let segments: Vec<&str> = disk.segments.iter().map(|s| s.data.as_str()).collect();
            let current = disk.segments.last().map(|segment| segment.data.len() as u64);
            journal.open(&segments, current)
        };
        if let Some(data) = data {
            let outcome = disk.borrow_mut().compact(&data, Purpose::Open);
            journal.written(&outcome);
        }
        Self { disk: Rc::clone(disk), journal }
    }

    fn new(disk: &Rc<RefCell<Disk>>) -> Self {
        Self::open(disk, Limits::default())
    }

    fn record(&mut self, event: Event) {
        if self.journal.record(vec![event]).flush_now {
            self.flush();
        }
    }

    fn flush(&mut self) {
        let Some(write) = self.journal.flush() else { return };
        let outcome = match write.mode {
            WriteMode::Append => self.disk.borrow_mut().append(&write.data),
            WriteMode::Compact => self.disk.borrow_mut().compact(&write.data, Purpose::Flush),
        };
        self.journal.written(&outcome);
    }

    fn clear(&mut self, fingerprints: Option<&[String]>) -> usize {
        let (_, data) = self.journal.clear(fingerprints);
        let outcome = self.disk.borrow_mut().compact(&data, Purpose::Clear);
        let after = self.journal.written(&outcome);
        if let Some(restore) = after.restore {
            let outcome = self.disk.borrow_mut().compact(&restore, Purpose::Restore);
            self.journal.written(&outcome);
        }
        after.removed.unwrap_or(0)
    }

    fn entries(&self) -> Vec<Entry> {
        self.journal.entries(&Query::default())
    }

    fn first(&self) -> Entry {
        self.entries().into_iter().next().expect("an entry")
    }
}

fn legacy_entry(fingerprint: &str, template: &str, sample: &str) -> Entry {
    Entry {
        count: 1,
        context: BTreeMap::new(),
        first_ms: 1,
        fingerprint: fingerprint.to_owned(),
        top_frame: None,
        last_ms: 1,
        level: Level::Error,
        sample: sample.to_owned(),
        source: "app".to_owned(),
        template: template.to_owned(),
    }
}

/// A line as an older build wrote it: no redaction stamp.
fn legacy_line(entry: &Entry) -> String {
    format!("{}\n", serde_json::to_string(entry).unwrap())
}

// MARK: - ErrorJournalTests

#[test]
fn occurrences_that_differ_only_in_values_fold_into_one_entry() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event_at(
        "load of /Users/a/one.json failed after 512 ms",
        "app",
        Level::Error,
        0.0,
    ));
    journal.record(event_at(
        "load of /Users/b/two.json failed after 9 ms",
        "app",
        Level::Error,
        5.0,
    ));
    journal.record(event_at(
        "load of /Users/b/two.json failed after 9 ms",
        "app",
        Level::Fault,
        2.0,
    ));
    let entries = journal.entries();
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.count, 3);
    assert_eq!(entry.level, Level::Fault);
    assert_eq!(entry.template, "load of <path> failed after <n> ms");
    assert!(entry.sample.contains("two.json"));
    assert_eq!(entry.first_ms, (BASE * 1000.0) as i64);
    assert_eq!(entry.last_ms, ((BASE + 5.0) * 1000.0) as i64);
}

#[test]
fn different_sources_or_frames_stay_apart() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event("boom"));
    journal.record(event_at("boom", "acpmux", Level::Error, 0.0));
    let mut framed = event("boom");
    framed.top_frame = Some("main.tsx:12".to_owned());
    journal.record(framed);
    assert_eq!(journal.journal.count(), 3);
}

#[test]
fn secrets_never_reach_the_sample_or_the_disk() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    let mut leaky = event(
        "request failed Authorization: Bearer sk-ant-abcdefghijklmnop1234 cookie=sess=xyz https://u:pw@h.example/x?token=s3cret&a=1",
    );
    leaky.context.insert("header".to_owned(), "x-api-key: AKIAABCDEFGHIJKLMNOP".to_owned());
    journal.record(leaky);
    journal.flush();
    let entry = journal.first();
    for secret in
        ["sk-ant-abcdefghijklmnop1234", "sess=xyz", "pw@", "s3cret", "AKIAABCDEFGHIJKLMNOP"]
    {
        assert!(!entry.sample.contains(secret), "sample kept {secret}");
        assert!(!entry.context.get("header").cloned().unwrap_or_default().contains(secret));
    }
    let text = disk.borrow().text();
    assert!(!text.contains("sk-ant-abcdefghijklmnop1234"));
    assert!(!text.contains("s3cret"));
    assert!(text.contains("request failed"));
}

#[test]
fn prefixed_credential_assignments_never_reach_the_journal() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    let values =
        ["ordinarySecret123", "ordinary-api-value", "ordinary-password", "camel-secret-value"];
    journal.record(event(&format!(
        "failed AWS_SECRET_ACCESS_KEY={} MY_API_KEY={} the_password={} secretAccessKey={}",
        values[0], values[1], values[2], values[3]
    )));
    journal.flush();
    let entry = journal.first();
    for value in values {
        assert!(!entry.sample.contains(value), "kept {value}");
    }
}

#[test]
fn complete_cookie_headers_never_reach_the_journal() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event("request failed Cookie: session=first-cookie; csrf=second-cookie"));
    let entry = journal.first();
    for value in ["first-cookie", "second-cookie"] {
        assert!(!entry.sample.contains(value), "kept {value}");
    }
}

#[test]
fn escaped_assignments_and_namespaced_query_secrets_never_reach_the_journal() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    let v = [
        "escaped-password",
        "raw-auth-value",
        "access-secret",
        "signature-secret",
        "encoded-credential-value",
        "quoted-tail-value",
        "embedded-query-value",
        "nested-url-value",
        "nested-query-value",
        "bare-tail-value",
        "bracket-tail-value",
        "question-tail-value",
        "comma-tail-value",
    ];
    let message = [
        r#"provider {\"password\":\""#,
        v[0],
        r#"\"} failed ?auth[token]="#,
        v[1],
        "&access_token[]=",
        v[2],
        "&X-Amz-Signature=",
        v[3],
        "&auth%5Btoken%5D=",
        v[4],
        r#" credential {\"password\":\"prefix\\\""#,
        v[5],
        r#"\"} request failed auth[token]="#,
        v[6],
        " url=https://example.test/?auth[token]=",
        v[7],
        " query=auth[token]=",
        v[8],
        " password=alpha ",
        v[9],
        " auth[password]=queryalpha ",
        v[10],
        " completion_tokens=42",
        " auth[token]=question-left?",
        v[11],
        " completion_tokens=43",
        " auth[token]=comma-left,",
        v[12],
        " completion_tokens=44",
    ]
    .concat();
    journal.record(event(&message));
    let entry = journal.first();
    for value in v {
        assert!(!entry.sample.contains(value), "kept {value}: {}", entry.sample);
    }
}

#[test]
fn legacy_segments_are_redacted_before_they_are_returned_or_rewritten() {
    let disk = Disk::shared();
    let values = ["legacy-secret-value", "legacy-password-value", "legacy-cookie-value"];
    let mut legacy = legacy_entry(
        "legacy-fingerprint",
        &format!("AWS_SECRET_ACCESS_KEY={}", values[0]),
        &format!("Pwd={}", values[1]),
    );
    legacy.top_frame = Some(format!("token={}", values[0]));
    legacy.context.insert("header".to_owned(), format!("Cookie: session={}", values[2]));
    let mut clean =
        legacy_entry("legacy-fingerprint", "newest clean template", "newest clean sample");
    clean.count = 2;
    clean.last_ms = 2;
    disk.borrow_mut().put(&(legacy_line(&legacy) + &legacy_line(&clean)));

    let journal = Store::new(&disk);
    let memory = serde_json::to_string(&journal.first()).unwrap();
    let text = disk.borrow().text();
    for value in values {
        assert!(!memory.contains(value));
        assert!(!text.contains(value));
    }
}

#[test]
fn opening_reads_what_an_earlier_launch_kept() {
    let disk = Disk::shared();
    let mut kept =
        legacy_entry("kept", "kept from an earlier launch", "kept from an earlier launch");
    kept.count = 4;
    kept.last_ms = 2;
    disk.borrow_mut().put(&legacy_line(&kept));
    let entry = Store::new(&disk).first();
    assert_eq!(entry.sample, "kept from an earlier launch");
    assert_eq!(entry.count, 4);
}

#[test]
fn a_journal_this_build_wrote_reopens_without_rewriting_it() {
    let disk = Disk::shared();
    let mut writer = Store::new(&disk);
    for index in 0..200 {
        let mut item = event_at(
            &format!("fetch item{index:x}q failed: password=hunter{index} token=abc{index}"),
            "app",
            Level::Error,
            f64::from(index),
        );
        item.top_frame = Some(format!("Loader.swift:{index}"));
        writer.record(item);
    }
    writer.flush();
    assert_eq!(writer.journal.count(), 200);
    let bytes = disk.borrow().bytes();
    let segments = disk.borrow().segments.len();

    let reader = Store::new(&disk);
    assert_eq!(reader.journal.count(), 200);
    let entry = reader.journal.entries(&Query { limit: 1, ..Query::default() }).remove(0);
    assert!(!entry.sample.contains("hunter"));
    assert_eq!(disk.borrow().bytes(), bytes, "nothing to rewrite");
    assert_eq!(disk.borrow().segments.len(), segments);
}

#[test]
fn migrated_entries_keep_their_fingerprint_continuity() {
    let disk = Disk::shared();
    let legacy =
        legacy_entry("legacy-fingerprint", "password=legacy-value", "password=legacy-value");
    disk.borrow_mut().put(&legacy_line(&legacy));
    let mut journal = Store::new(&disk);
    journal.record(event_at("password=current-value", "app", Level::Error, 1.0));
    assert_eq!(journal.journal.count(), 1);
    assert_eq!(journal.first().count, 2);
}

#[test]
fn migration_merges_entries_that_canonicalize_to_one_fingerprint() {
    let disk = Disk::shared();
    let mut first =
        legacy_entry("legacy-one", "password=first-value", "oldest-marker; password=first-value");
    first.level = Level::Warning;
    first.context.insert("generation".to_owned(), "old".to_owned());
    first.count = 2;
    first.last_ms = 2;
    let mut second =
        legacy_entry("legacy-two", "password=second-value", "newest-marker; password=second-value");
    second.level = Level::Fault;
    second.context.insert("generation".to_owned(), "new".to_owned());
    second.count = 3;
    second.first_ms = 3;
    second.last_ms = 4;
    disk.borrow_mut().put(&(legacy_line(&first) + &legacy_line(&second)));

    let entry = Store::new(&disk).first();
    assert_eq!(entry.count, 5);
    assert_eq!(entry.level, Level::Fault);
    assert_eq!(entry.first_ms, 1);
    assert_eq!(entry.last_ms, 4);
    assert!(entry.sample.contains("newest-marker"));
    assert_eq!(entry.context.get("generation").map(String::as_str), Some("new"));
}

#[test]
fn failed_legacy_segment_deletion_is_reported_and_retried() {
    let disk = Disk::shared();
    let value = "undeletable-legacy-value";
    let legacy = legacy_entry(
        "legacy-fingerprint",
        &format!("password={value}"),
        &format!("password={value}"),
    );
    disk.borrow_mut().put(&legacy_line(&legacy));
    disk.borrow_mut().segments[0].locked = true;

    let mut blocked = Store::new(&disk);
    assert!(blocked.journal.write_error().is_some());

    disk.borrow_mut().segments[0].locked = false;
    blocked.record(event("ordinary follow-up"));
    blocked.flush();
    assert!(blocked.journal.write_error().is_none());
    assert!(!disk.borrow().text().contains(value));
}

#[test]
fn clear_does_not_report_success_when_an_old_segment_cannot_be_deleted() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event("clear failure"));
    journal.flush();
    disk.borrow_mut().segments[0].locked = true;

    assert_eq!(journal.clear(None), 0);
    assert!(journal.journal.write_error().is_some());
    assert_eq!(journal.journal.count(), 1);
    assert_eq!(Store::new(&disk).journal.count(), 1);

    for segment in &mut disk.borrow_mut().segments {
        segment.locked = false;
    }
    assert_eq!(journal.clear(None), 1);
    assert_eq!(Store::new(&disk).journal.count(), 0);
}

#[test]
fn a_new_launch_reads_what_the_last_one_kept() {
    let disk = Disk::shared();
    let mut first = Store::new(&disk);
    first.record(event_at("socket closed 3 times", "app", Level::Error, 0.0));
    first.record(event_at("socket closed 4 times", "app", Level::Error, 1.0));
    first.flush();
    let mut second = Store::new(&disk);
    let entries = second.entries();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].count, 2);
    second.record(event_at("socket closed 5 times", "app", Level::Error, 2.0));
    second.flush();
    assert_eq!(Store::new(&disk).first().count, 3);
}

#[test]
fn compaction_keeps_disk_bounded_and_entries_alive() {
    let limits =
        Limits { segment_bytes: 4096, max_entries: 50, flush_batch: 1, ..Limits::default() };
    let disk = Disk::shared();
    let mut journal = Store::open(&disk, limits.clone());
    for round in 0..200 {
        let kind = ["alpha", "beta", "gamma"][round % 3];
        journal.record(event_at(
            &format!("failure kind {kind}"),
            "app",
            Level::Error,
            round as f64,
        ));
    }
    journal.flush();
    assert!(disk.borrow().bytes() <= 2 * limits.segment_bytes);
    let reopened = Store::open(&disk, limits)
        .journal
        .entries(&Query { order: Order::Count, ..Query::default() });
    assert_eq!(reopened.len(), 3);
    assert_eq!(reopened.iter().map(|entry| entry.count).sum::<u64>(), 200);
    assert_eq!(disk.borrow().segments.len(), 1);
}

#[test]
fn a_storm_of_distinct_errors_becomes_one_counted_entry() {
    let disk = Disk::shared();
    let mut journal =
        Store::open(&disk, Limits { new_fingerprints_per_minute: 3, ..Limits::default() });
    for word in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
        journal.record(event(&format!("unknown key {word}")));
    }
    let entries = journal.journal.entries(&Query { order: Order::Count, ..Query::default() });
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0].template, "too many distinct errors from app");
    assert_eq!(entries[0].count, 3);
}

#[test]
fn the_least_recently_seen_are_evicted_past_the_limit() {
    let disk = Disk::shared();
    let mut journal = Store::open(&disk, Limits { max_entries: 10, ..Limits::default() });
    for index in 0..30 {
        let letter = ["a", "b", "c", "d", "e", "f"][index % 6];
        journal.record(event_at(
            &format!("error {letter}{}", "x".repeat(index)),
            "app",
            Level::Error,
            index as f64,
        ));
    }
    let entries = journal.journal.entries(&Query { limit: 100, ..Query::default() });
    assert!(entries.len() <= 10);
    assert!(entries[0].sample.ends_with(&"x".repeat(29)));
}

#[test]
fn queries_filter_by_source_level_text_and_time() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event_at("page broke", "page:settings", Level::Warning, 0.0));
    journal.record(event_at("pool failed", "acpmux", Level::Error, 10.0));
    journal.record(event_at("pool failed", "acpmux", Level::Error, 11.0));
    journal.record(event_at("crash cmux", "crash", Level::Crash, 20.0));
    let sources = |query: Query| -> Vec<String> {
        journal.journal.entries(&query).into_iter().map(|entry| entry.source).collect()
    };
    assert_eq!(
        sources(Query { sources: vec!["page".to_owned()], ..Query::default() }),
        ["page:settings"]
    );
    assert_eq!(sources(Query { minimum_level: Level::Error, ..Query::default() }).len(), 2);
    assert_eq!(sources(Query { text: Some("POOL".to_owned()), ..Query::default() }).len(), 1);
    assert_eq!(sources(Query { since: Some(BASE + 15.0), ..Query::default() }), ["crash"]);
    assert_eq!(sources(Query { order: Order::Count, ..Query::default() })[0], "acpmux");
    assert_eq!(sources(Query { limit: 1, ..Query::default() }), ["crash"]);
}

#[test]
fn clear_forgets_chosen_or_all_entries() {
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event("one"));
    journal.record(event("two"));
    let fingerprint = journal.first().fingerprint;
    assert_eq!(journal.clear(Some(&[fingerprint])), 1);
    assert_eq!(Store::new(&disk).journal.count(), 1);
    assert_eq!(journal.clear(None), 1);
    assert_eq!(Store::new(&disk).journal.count(), 0);
}

#[test]
fn a_failed_harvest_is_one_journal_warning() {
    // The app records this event when a source throws (ErrorJournal.harvest).
    let disk = Disk::shared();
    let mut journal = Store::new(&disk);
    journal.record(event_at(
        "harvest of broken failed: no permission",
        "journal",
        Level::Warning,
        0.0,
    ));
    let found =
        journal.journal.entries(&Query { sources: vec!["journal".to_owned()], ..Query::default() });
    assert_eq!(found.len(), 1);
}

// MARK: - ErrorSourcesTests

/// One `LogFileErrorSource.collect` over `bytes` (file number `inode`).
fn collect_log(
    bytes: &[u8],
    inode: u64,
    cursor: Option<&str>,
    first_read: u64,
) -> (Vec<Event>, String) {
    let plan = sources::log_plan(cursor, inode, bytes.len() as u64, first_read, 4 << 20);
    if plan.read == 0 {
        return (Vec::new(), plan.cursor);
    }
    let chunk = &bytes[plan.start as usize..(plan.start + plan.read) as usize];
    let complete = chunk.iter().rposition(|&byte| byte == b'\n').map(|last| &chunk[..=last]);
    let text = complete.map(|bytes| String::from_utf8_lossy(bytes).into_owned());
    let complete = text.as_deref().zip(complete.map(|bytes| bytes.len() as u64));
    sources::log_chunk(
        inode,
        plan.start,
        plan.starts_mid_line,
        complete,
        "acpmux",
        "daemon.log",
        BASE,
    )
}

#[test]
fn a_log_source_reads_levels_and_panics_only_once() {
    let mut log = concat!(
        "2026-10-17T03:34:21.050714Z  INFO startup complete; agents may spawn\n",
        "2026-10-17T10:05:20.627500Z  \u{1b}[33mWARN\u{1b}[0m model catalog refresh: the catalog server answered 404\n",
        "2026-10-19T01:21:15.000000Z ERROR pooled session failed to start: agent host did not answer hello within 5s\n",
        "thread 'tokio-rt-worker' panicked at library/core/src/slice/sort/shared/smallsort.rs:860:5:\n",
        "user-provided comparison function does not correctly implement a total order\n",
        "\n",
    )
    .as_bytes()
    .to_vec();
    let (events, cursor) = collect_log(&log, 7, None, 256 << 10);
    let levels: Vec<Level> = events.iter().map(|event| event.level).collect();
    assert_eq!(levels, [Level::Warning, Level::Error, Level::Fault]);
    assert_eq!(events[0].message, "model catalog refresh: the catalog server answered 404");
    assert_eq!(
        events[2].message,
        "panic: user-provided comparison function does not correctly implement a total order"
    );
    assert_eq!(
        events[2].top_frame.as_deref(),
        Some("library/core/src/slice/sort/shared/smallsort.rs:860")
    );
    // 2026-01-01 to 2027-01-01.
    assert!((1_767_225_600.0..1_798_761_600.0).contains(&events[0].date));

    assert!(collect_log(&log, 7, Some(&cursor), 256 << 10).0.is_empty());

    log.extend_from_slice(b"2026-10-19T02:00:00Z  WARN half a line");
    let (partial, partial_cursor) = collect_log(&log, 7, Some(&cursor), 256 << 10);
    assert!(partial.is_empty());
    log.extend_from_slice(b" now done\n");
    let (done, _) = collect_log(&log, 7, Some(&partial_cursor), 256 << 10);
    let messages: Vec<&str> = done.iter().map(|event| event.message.as_str()).collect();
    assert_eq!(messages, ["half a line now done"]);
}

#[test]
fn a_replaced_log_starts_over() {
    let (_, cursor) = collect_log(b"ERROR first\n", 7, None, 256 << 10);
    let (second, _) = collect_log(b"ERROR second\n", 8, Some(&cursor), 256 << 10);
    let messages: Vec<&str> = second.iter().map(|event| event.message.as_str()).collect();
    assert_eq!(messages, ["second"]);
}

#[test]
fn the_first_harvest_reads_only_the_tail() {
    let log = "ERROR old line\n".repeat(100) + "ERROR newest\n";
    let (events, _) = collect_log(log.as_bytes(), 7, None, 20);
    let messages: Vec<&str> = events.iter().map(|event| event.message.as_str()).collect();
    assert_eq!(messages, ["newest"]);
}

#[test]
fn page_console_log_lines_map_to_page_sources() {
    let text = sources::console_log_text(
        "warn",
        "theme missing token=abc123secret\nmore",
        "Error\n    at load (cmux-page://settings/main.js:4:9)",
    );
    assert!(text.starts_with("[warn] theme missing token=<redacted>"), "{text}");
    let event =
        sources::oslog_event(sources::PAGE_CONSOLE_SUBSYSTEM, "settings", false, &text, BASE);
    assert_eq!(event.source, "page:settings");
    assert_eq!(event.level, Level::Warning);
    assert_eq!(event.top_frame.as_deref(), Some("load (cmux-page://settings/main.js:4:9)"));
    assert_eq!(
        sources::oslog_event("com.cmuxterm.app.nightly", "acp", true, "x", BASE).source,
        "app"
    );
    assert_eq!(
        sources::oslog_event("com.apple.WebKit", "Loading", false, "x", BASE).source,
        "system:com.apple.WebKit"
    );
}

#[test]
fn jsc_stack_frames_are_found() {
    assert_eq!(
        sources::console_top_frame("load@cmux-page://home/app.js:10:2\nglobal code").as_deref(),
        Some("load@cmux-page://home/app.js:10:2")
    );
    assert_eq!(sources::console_top_frame(""), None);
}

#[test]
fn crash_reports_become_crash_events_once() {
    let prefixes: Vec<String> =
        ["cmux", "acpmux", "optchat", "cmux-tui"].iter().map(|p| (*p).to_owned()).collect();
    let names = vec!["cmux NIGHTLY-2026-10-18-201500.ips".to_owned(), "Safari-2026.ips".to_owned()];
    let names = sources::crash_report_names(&names, &prefixes);
    assert_eq!(names, ["cmux NIGHTLY-2026-10-18-201500.ips"]);
    let files: Vec<ReportFile> = names
        .iter()
        .map(|name| ReportFile { name: name.clone(), modified: Some(BASE - 60.0) })
        .collect();

    let (reports, cursor) = sources::crash_scan(None, BASE, 7.0 * 86400.0, &files);
    assert_eq!(reports.len(), 1);
    let text = concat!(
        r#"{"app_name":"cmux NIGHTLY","app_version":"1.0.0","bug_type":"309","incident_id":"X"}"#,
        "\n",
        r#"{"exception" : {"codes":"0x1","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"threads":[{"frames":[{"symbol":"GhosttySurface.draw"}]}]}"#,
    );
    let event = sources::crash_event(text, &format!("/reports/{}", reports[0].name), BASE - 60.0);
    assert_eq!(event.message, "crash cmux NIGHTLY EXC_BAD_ACCESS SIGSEGV");
    assert_eq!(event.top_frame.as_deref(), Some("GhosttySurface.draw"));
    assert_eq!(event.level, Level::Crash);

    let (again, _) = sources::crash_scan(Some(&cursor), BASE + 300.0, 7.0 * 86400.0, &files);
    assert!(again.is_empty());
}

#[test]
fn templates_hide_values_but_keep_words() {
    assert_eq!(
        template(
            "session 01a15246-9cfe-7bc2-ad31-c8861e92290d failed in ws_19bb371b at 0x1f",
            1024
        ),
        "session <uuid> failed in <id> at <hex>"
    );
    assert_eq!(
        template("refused \"/tmp/a b\" from https://x.example/a?b=1", 1024),
        "refused \"<str>\" from <url>"
    );
}

// MARK: - ErrorJournalReportTests

fn report_entry(
    sample: &str,
    source: &str,
    level: Level,
    count: u64,
    frame: Option<&str>,
) -> Entry {
    let last_ms = 1_800_000_000_000;
    Entry {
        count,
        context: BTreeMap::new(),
        first_ms: last_ms - 1000,
        fingerprint: "0123456789abcdef".to_owned(),
        top_frame: frame.map(str::to_owned),
        last_ms,
        level,
        sample: sample.to_owned(),
        source: source.to_owned(),
        template: sample.to_owned(),
    }
}

#[test]
fn the_report_lists_header_then_entries() {
    let header = ["cmux 1.0 (42) com.cmuxterm.app.nightly".to_owned(), "macOS 26.0".to_owned()];
    let entries = [
        report_entry("socket closed", "acpmux", Level::Warning, 3, None),
        report_entry("panicked at src/main.rs", "chief", Level::Fault, 1, Some("main.rs:12")),
    ];
    assert_eq!(
        report_text(&header, &entries),
        "cmux 1.0 (42) com.cmuxterm.app.nightly\nmacOS 26.0\n\n\
         2027-01-15T08:00:00Z warning acpmux ×3: socket closed\n\
         2027-01-15T08:00:00Z fault chief ×1: panicked at src/main.rs\n\
         \x20   at main.rs:12\n"
    );
}

#[test]
fn an_empty_report_says_so() {
    assert_eq!(report_text(&["cmux".to_owned()], &[]), "cmux\n\nNo problems recorded.\n");
}

// MARK: - OSLogErrorSourceReadTests

fn record(date: f64, level: &str, subsystem: &str, category: &str, message: &str) -> OsLogRecord {
    OsLogRecord {
        subsystem: subsystem.to_owned(),
        category: category.to_owned(),
        level: level.to_owned(),
        message: message.to_owned(),
        date,
    }
}

#[test]
fn the_unified_log_keeps_errors_and_faults_only() {
    let launch = 1_000.0;
    let mut records: Vec<OsLogRecord> = (0..1_000)
        .map(|index| {
            record(
                launch + f64::from(index) / 100.0,
                "info",
                "org.chromium",
                "net",
                &format!("info {index}"),
            )
        })
        .collect();
    records.push(record(launch + 20.0, "error", "com.cmuxterm.app", "acp", "it failed"));
    records.push(record(launch + 21.0, "fault", "com.apple.WebKit", "Loading", "it broke"));
    let start = sources::oslog_start(None, 7, launch, launch + 30.0);
    let (events, _) = sources::oslog_collect(start, launch + 30.0, 7, &records);
    let messages: Vec<&str> = events.iter().map(|event| event.message.as_str()).collect();
    assert_eq!(messages, ["it failed", "it broke"]);
}

#[test]
fn a_read_of_more_entries_than_it_keeps_gives_the_newest_and_does_not_come_back() {
    let launch = 1_000.0;
    let now = launch + 120.0;
    let records: Vec<OsLogRecord> = (0..5_003)
        .map(|index| {
            record(
                launch + 1.0 + f64::from(index) / 100.0,
                "error",
                "com.cmuxterm.app",
                "acp",
                &format!("error {index}"),
            )
        })
        .collect();
    let start = sources::oslog_start(None, 7, launch, now);
    let (first, cursor) = sources::oslog_collect(start, now, 7, &records);
    assert_eq!(first.len(), 5_000);
    assert_eq!(first.last().map(|event| event.message.as_str()), Some("error 5002"));
    let start = sources::oslog_start(Some(&cursor), 7, launch, now);
    let second: Vec<&OsLogRecord> = records.iter().filter(|record| record.date >= start).collect();
    let second: Vec<OsLogRecord> = second.into_iter().cloned().collect();
    assert!(sources::oslog_collect(start, now, 7, &second).0.is_empty());
}

// MARK: - The ops

fn call(journals: &mut ErrorJournals, op: &str, request: Value) -> Value {
    journals.call(op, request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

#[test]
fn the_ops_drive_a_journal_end_to_end() {
    let mut journals = ErrorJournals::new();
    let opened =
        call(&mut journals, "error_journal_open", json!({ "journal": "j", "segments": [] }));
    assert_eq!(opened, json!({ "write": null }));
    let advice = call(
        &mut journals,
        "error_journal_record",
        json!({ "journal": "j", "events": [
            { "source": "app", "level": "error", "message": "load of /Users/a/b.json failed after 3 ms", "date": BASE }
        ] }),
    );
    assert_eq!(advice, json!({ "flush_now": false, "schedule": true }));
    let flush = call(&mut journals, "error_journal_flush", json!({ "journal": "j" }));
    assert_eq!(flush["write"]["mode"], "compact", "no segment yet: a compaction");
    let data = flush["write"]["data"].as_str().unwrap().to_owned();
    assert!(data.contains("\"redacted_by\""));
    let after = call(
        &mut journals,
        "error_journal_written",
        json!({ "journal": "j", "mode": "compact", "purpose": "flush", "written": true, "bytes": data.len() }),
    );
    assert_eq!(after, json!({}));
    assert_eq!(
        call(&mut journals, "error_journal_count", json!({ "journal": "j" })),
        json!({ "count": 1 })
    );
    let entries = call(
        &mut journals,
        "error_journal_entries",
        json!({ "journal": "j", "query": { "limit": 5 } }),
    );
    assert_eq!(entries["entries"][0]["template"], "load of <path> failed after <n> ms");
    assert_eq!(
        call(&mut journals, "error_journal_write_error", json!({ "journal": "j" })),
        json!({ "error": null })
    );
    let cleared = call(&mut journals, "error_journal_clear", json!({ "journal": "j" }));
    assert_eq!(cleared, json!({ "removed": 1, "data": "" }));
    let after = call(
        &mut journals,
        "error_journal_written",
        json!({ "journal": "j", "mode": "compact", "purpose": "clear", "written": true, "bytes": 0 }),
    );
    assert_eq!(after, json!({ "removed": 1 }));
    assert_eq!(call(&mut journals, "error_journal_close", json!({ "journal": "j" })), json!({}));
    assert!(journals.call("error_journal_count", json!({ "journal": "j" })).is_err());

    // A reopen of what was written reads it back.
    let reopened = call(
        &mut journals,
        "error_journal_open",
        json!({ "journal": "k", "segments": [data], "current_bytes": 1 }),
    );
    assert_eq!(reopened, json!({ "write": null }));
    assert_eq!(
        call(&mut journals, "error_journal_count", json!({ "journal": "k" })),
        json!({ "count": 1 })
    );
}

#[test]
fn the_pure_ops_answer() {
    let mut journals = ErrorJournals::new();
    let redacted =
        call(&mut journals, "error_journal_redact", json!({ "text": "password=hunter2" }));
    assert!(!redacted["text"].as_str().unwrap().contains("hunter2"));
    let digest = call(&mut journals, "error_journal_rules_digest", Value::Null);
    assert!(digest["digest"].is_string());
    assert_eq!(
        call(&mut journals, "error_journal_template", json!({ "message": "took 5 ms" })),
        json!({ "template": "took <n> ms" })
    );
    let fingerprint = call(
        &mut journals,
        "error_journal_fingerprint",
        json!({ "source": "app", "template": "boom" }),
    );
    assert_eq!(fingerprint["fingerprint"].as_str().unwrap().len(), 16);
    let plan = call(&mut journals, "error_journal_log_plan", json!({ "inode": 3, "size": 10 }));
    assert_eq!(plan["start"], 0);
    assert_eq!(plan["cursor"], "3:10");
    let chunk = call(
        &mut journals,
        "error_journal_log_chunk",
        json!({ "inode": 3, "start": 0, "starts_mid_line": false, "complete": "ERROR boom\n",
                "complete_bytes": 11, "source": "chief", "file": "host.log", "now": BASE }),
    );
    assert_eq!(chunk["events"][0]["message"], "boom");
    assert_eq!(chunk["cursor"], "3:11");
    let frame = call(&mut journals, "error_journal_console_top_frame", json!({ "stack": "" }));
    assert_eq!(frame, json!({ "frame": null }));
    let report = call(
        &mut journals,
        "error_journal_report_text",
        json!({ "header": ["cmux"], "entries": [] }),
    );
    assert_eq!(report, json!({ "text": "cmux\n\nNo problems recorded.\n" }));
    assert!(matches!(
        journals.call("error_journal_nope", Value::Null),
        Err(crate::ops::OpError::UnknownOp(_))
    ));
    assert!(ErrorJournals::serves("error_journal_open"));
    assert!(!ErrorJournals::serves("tab_discard_plan"));
}
