//! Feed ingest under scale: bursts of notices across many terminals and
//! workspaces with interleaved reads, the daemon's integration owner at its
//! bound, and the client mirror plus the page's `feed.view.read` over large
//! feeds. What a person waits on: one notification reaching the feed (the
//! daemon copies the local owner, posts, and installs the copy after its
//! commit), one read or ack, and one view read of the visible page.
//!
//! The timing sweep runs only when asked: `CMUX_STRESS=1`, or a plain
//! `cargo test` whose filter names `stress_bench` (nextest's `--exact` run
//! skips it). It prints one `STRESS-FEED` JSON line per scenario and size.
//! The ungated tests count allocations, not time: the cost of one more
//! notice must not grow with how many items the feed already holds.

use std::alloc::{GlobalAlloc, Layout as AllocLayout, System};
use std::cell::Cell;
use std::time::Instant;

use cmux_feed_core::client::{
    FeedItem, IntegrationOwner, Intent, IntentKind, Mirror, Owner, Place, Poster, Priority,
    ViewContext, ViewRequest, items_visited,
};
use cmux_feed_core::{Context, Feed, MAX_ITEMS, Notice};
use serde_json::{Value, json};

// MARK: Allocation counter (per thread, so parallel tests do not mix)

struct Counting;

thread_local! {
    static ALLOCS: Cell<u64> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: AllocLayout) -> *mut u8 {
        let _ = ALLOCS.try_with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: AllocLayout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: AllocLayout, new_size: usize) -> *mut u8 {
        let _ = ALLOCS.try_with(|count| count.set(count.get() + 1));
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// Allocations `work` makes on this thread.
fn allocs<T>(work: impl FnOnce() -> T) -> (T, u64) {
    let before = ALLOCS.with(Cell::get);
    let out = work();
    (out, ALLOCS.with(Cell::get) - before)
}

// MARK: Timing

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("stress_bench")) && !args.iter().any(|a| a == "--exact")
}

/// Microseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1_000_000.0);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 10.0).round() / 10.0
        };
        json!({ "n": v.len(), "p50_us": at(0.5), "p95_us": at(0.95), "max_us": at(1.0) })
    }
}

fn report(scenario: &str, size: usize, fields: Value) {
    let mut line = json!({ "scenario": scenario, "size": size });
    if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
        line.extend(fields.clone());
    }
    println!("STRESS-FEED {line}");
}

// MARK: Corpus

const T0: u64 = 1_800_000_000_000;
const TERMINALS: usize = 64;
const WORKSPACES: usize = 16;

fn notice(n: usize) -> Notice {
    let terminal = n % TERMINALS;
    Notice {
        id: format!("fl_{n:08}"),
        dedupe_key: format!("notify:session:{n}"),
        title: format!("Agent finished task {n}"),
        body: format!("Body of notice {n}: the build passed and the tests are green."),
        level: "info".into(),
        source: "agent".into(),
        context: Context {
            workspace: Some(format!("ws_{:02}", terminal % WORKSPACES)),
            tab: Some(format!("tab_{terminal:03}")),
            terminal: Some(format!("term_{terminal:03}")),
        },
        actor: None,
        at_ms: T0 + n as u64,
        read: false,
        // Every third notice coalesces into its terminal's newest unread item.
        coalesce: n.is_multiple_of(3),
    }
}

/// The daemon's live post (mux/feed_local.rs `commit_notification_effect`):
/// copy the owner, post to the copy, install the copy after the commit.
fn daemon_post(feed: &mut Feed, notice: Notice) {
    let mut next = feed.clone();
    let (_, changes) = next.post(notice).expect("post");
    std::hint::black_box(&changes);
    *feed = next;
}

/// The daemon's `feed-local-read` of one item.
fn daemon_read(feed: &mut Feed, id: &str, at_ms: u64) {
    let mut next = feed.clone();
    if let Ok(changes) = next.read(&[id.to_owned()], at_ms) {
        std::hint::black_box(&changes);
        *feed = next;
    }
}

/// The daemon's tab ack (`ack_notifications_and_feed`).
fn daemon_ack(feed: &mut Feed, terminal: &str, at_ms: u64) {
    let mut next = feed.clone();
    let (changes, _) = next.read_terminal(terminal, at_ms);
    std::hint::black_box(&changes);
    *feed = next;
}

fn agent() -> Poster {
    Poster::new("agent", "Agent")
}

fn client_item(n: usize, now: i64) -> FeedItem {
    let mut item = FeedItem::notice(
        &format!("fi_{n:020}"),
        &format!("Notice {n} — résumé ✅"),
        agent(),
        now - (n as i64) * 7_000,
    );
    item.body = format!("Body {n}");
    item.thread = n.is_multiple_of(5).then(|| format!("thread_{}", n % 97));
    item.context.insert("workspace".into(), json!(format!("ws_{:02}", n % WORKSPACES)));
    item.context.insert("terminal".into(), json!(format!("term_{:03}", n % TERMINALS)));
    if n.is_multiple_of(11) {
        item.kind = "question".into();
        item.priority = Priority::High;
        item.prompt = json!({"question": "Ship?"});
    }
    if n.is_multiple_of(4) {
        item.read_at = Some(item.created_at);
    }
    item
}

fn no_place(_: &FeedItem) -> Option<Place> {
    None
}

fn view(mirror: &Mirror, now: i64, request: Value) -> Value {
    let request: ViewRequest = serde_json::from_value(request).expect("view request");
    ViewContext {
        mirror,
        account: None,
        now,
        github: None,
        github_enabled: false,
        reports_available: false,
        place: &no_place,
    }
    .view(&request)
}

const MIRROR_NOW: i64 = 1_800_000_000_000;

fn mirror_of(size: usize) -> Mirror {
    let mut mirror = Mirror::new("dev_1");
    let items = (0..size).map(|n| client_item(n, MIRROR_NOW)).collect();
    mirror.cloud_snapshot("user_1", items, MIRROR_NOW);
    mirror
}

fn integration_item(n: usize) -> FeedItem {
    let mut item = FeedItem::notice(
        &format!("fi_gh_{n:014}"),
        &format!("PR #{n} needs review"),
        Poster::new("integration", "GitHub"),
        MIRROR_NOW + n as i64,
    );
    item.home = "local:github".into();
    item.dedupe_key = Some(format!("github:pr:{n}"));
    item
}

// MARK: Ungated: counted work stays flat as the feed fills

/// Allocations of one daemon-style post with `held` items already in the
/// local owner (none of them shares the new notice's terminal).
fn post_allocs_at(held: usize) -> u64 {
    let mut feed = Feed::default();
    for n in 0..held {
        let mut notice = notice(n);
        notice.coalesce = false;
        daemon_post(&mut feed, notice);
    }
    let mut next = notice(held + 1_000_000);
    next.coalesce = false;
    next.context.terminal = Some("term_new".into());
    let ((), count) = allocs(|| daemon_post(&mut feed, next));
    count
}

#[test]
fn a_post_costs_the_same_with_a_full_feed() {
    let one = post_allocs_at(1);
    let full = post_allocs_at(MAX_ITEMS);
    let past = post_allocs_at(MAX_ITEMS + 50);
    // The copy, the new item, its row in the changes and a pruned id: a
    // fixed handful, never one per held item.
    assert!(full <= one + 16, "post at {MAX_ITEMS} items: {full} allocs vs {one} at 1");
    assert!(past <= one + 16, "post past the cap: {past} allocs vs {one} at 1");
}

#[test]
fn a_read_and_an_ack_cost_the_same_with_a_full_feed() {
    let cost = |held: usize| {
        let mut feed = Feed::default();
        for n in 0..held {
            let mut notice = notice(n);
            notice.coalesce = false;
            daemon_post(&mut feed, notice);
        }
        let id = format!("fl_{:08}", held - 1);
        let terminal = format!("term_{:03}", (held - 1) % TERMINALS);
        let ((), read) = allocs(|| daemon_read(&mut feed, &id, T0 + 10_000_000));
        // The ack finds the terminal's other unread items (held / 64 of them).
        let ((), ack) = allocs(|| daemon_ack(&mut feed, &terminal, T0 + 10_000_001));
        (read, ack)
    };
    let (read_one, ack_one) = cost(1);
    let (read_full, ack_full) = cost(MAX_ITEMS);
    assert!(read_full <= read_one + 16, "read: {read_full} allocs at {MAX_ITEMS} vs {read_one}");
    // An ack at the cap reads up to MAX_ITEMS / TERMINALS items: it may pay
    // per item it changes, not per item held.
    let touched = (MAX_ITEMS / TERMINALS + 1) as u64;
    assert!(
        ack_full <= ack_one + 16 + touched * 24,
        "ack: {ack_full} allocs at {MAX_ITEMS} vs {ack_one}"
    );
}

#[test]
fn the_integration_owner_pays_per_changed_item_not_per_held_item() {
    let cost = |held: usize| {
        let mut owner = IntegrationOwner::new("dev_1");
        for n in 0..held {
            owner.post(integration_item(n));
        }
        let (_, post) = allocs(|| owner.post(integration_item(held + 1_000_000)));
        let intent = Intent::new(
            "k1",
            IntentKind::Read { items: vec![integration_item(held / 2).id] },
            MIRROR_NOW + 5,
        );
        let (_, read) = allocs(|| owner.commit(&intent));
        (post, read)
    };
    let (post_one, read_one) = cost(1);
    let (post_full, read_full) = cost(MAX_ITEMS + 10);
    assert!(post_full <= post_one + 24, "post: {post_full} allocs at the cap vs {post_one}");
    assert!(read_full <= read_one + 24, "read: {read_full} allocs at the cap vs {read_one}");
}

#[test]
fn a_mirror_event_and_a_paged_view_stay_flat_in_the_mirror_size() {
    let cost = |size: usize| {
        let mut mirror = mirror_of(size);
        let mut changed = client_item(size / 2, MIRROR_NOW);
        changed.read_at = Some(MIRROR_NOW);
        changed.revision += 1;
        let (_, event) =
            allocs(|| mirror.event(Owner::Cloud, vec![changed], Vec::new(), None, MIRROR_NOW));
        let (_, page) = allocs(|| view(&mirror, MIRROR_NOW, json!({"limit": 50})));
        (event, page)
    };
    // Both sizes fill the first page with open requests, so the page holds
    // the same kind of entries.
    let (event_small, page_small) = cost(2_000);
    let (event_big, page_big) = cost(50_000);
    assert!(event_big <= event_small + 16, "event: {event_big} allocs at 50k vs {event_small}");
    // The page builds its 50 entries and nothing per held item: not even the
    // growth of a list of every entry (which adds an allocation per doubling).
    assert!(page_big <= page_small + 2, "view: {page_big} allocs at 50k vs {page_small} at 2k");
}

/// The unfiltered page (built from the ledger order) is the same page the
/// filtered path builds when its filter keeps everything.
#[test]
fn the_unfiltered_page_matches_a_filter_that_keeps_everything() {
    for size in [0usize, 1, 7, 60, 400] {
        let mirror = mirror_of(size);
        for layout in ["list", "needs_you"] {
            for limit in [0usize, 1, 5, 36, 50, 399, 2_000] {
                let fast = view(&mirror, MIRROR_NOW, json!({"layout": layout, "limit": limit}));
                // Every title says "Notice", so this filter keeps every item.
                let slow = view(
                    &mirror,
                    MIRROR_NOW,
                    json!({"layout": layout, "limit": limit, "filter": {"query": "notice"}}),
                );
                assert_eq!(fast["groups"], slow["groups"], "{layout} size {size} limit {limit}");
                assert_eq!(fast["total"], slow["total"], "{layout} size {size} limit {limit}");
            }
        }
    }
}

#[test]
fn degenerate_inputs_post_and_view() {
    // Empty feed: reads and acks of nothing.
    let mut feed = Feed::default();
    daemon_ack(&mut feed, "term_none", T0);
    assert!(feed.read(&["missing".into()], T0).is_err());
    // One huge item, unicode, duplicates.
    let mut huge = notice(1);
    huge.body = "é✅".repeat(200_000);
    daemon_post(&mut feed, huge.clone());
    let mut dup = huge;
    dup.id = "fl_other".into();
    daemon_post(&mut feed, dup);
    assert_eq!(feed.items().len(), 1, "a duplicate dedupe key makes no item");
    let mirror = mirror_of(0);
    let empty = view(&mirror, MIRROR_NOW, json!({"layout": "inbox", "limit": 50}));
    assert_eq!(empty["total"], 0);
}

/// Items one view reads, and how many items it shows (heads and members).
fn visits(mirror: &Mirror, request: Value) -> (u64, u64) {
    let before = items_visited();
    let shown = view(mirror, MIRROR_NOW, request);
    let read = items_visited() - before;
    let mut items = 0u64;
    for group in shown["groups"].as_array().into_iter().flatten() {
        for entry in group["entries"].as_array().into_iter().flatten() {
            items += 1 + entry["members"].as_array().map_or(0, |members| members.len() as u64);
        }
    }
    (read, items)
}

/// The Inbox and a filtered page read what they show, not the feed: the
/// same page reads the same items at 1k and at 100k, and a page that shows
/// threads reads at most each shown item and member twice (the walk passes a
/// shown thread's members once more).
#[test]
fn an_inbox_or_filtered_page_reads_what_it_shows() {
    let small = mirror_of(1_000);
    let big = mirror_of(100_000);
    let inbox = json!({"layout": "inbox", "limit": 50});
    let (inbox_small, _) = visits(&small, inbox.clone());
    let (inbox_big, _) = visits(&big, inbox);
    assert!(
        inbox_big <= inbox_small + 8,
        "Inbox page: {inbox_big} items read at 100k vs {inbox_small} at 1k"
    );
    let pages = [
        json!({"layout": "inbox", "limit": 50, "filter": {"category": "notices"}}),
        json!({"layout": "inbox", "limit": 50, "filter": {"category": "unread"}}),
        json!({"layout": "list", "limit": 50, "filter": {"category": "unread"}}),
        json!({"layout": "list", "limit": 50, "filter": {"category": "needs_you"}}),
        json!({"layout": "needs_you", "limit": 50, "filter": {"connection": "github"}}),
        // Reaches Earlier: Today holds fewer than 2,000 entries.
        json!({"layout": "inbox", "filter": {"category": "notices"}}),
    ];
    for (size, mirror) in [(1_000, &small), (100_000, &big)] {
        for page in &pages {
            let (read, shown) = visits(mirror, page.clone());
            assert!(read <= 2 * shown + 8, "{page} at {size}: {read} items read, {shown} shown");
        }
    }
}

/// A corpus that exercises the Inbox's edges: items over four days and one
/// day ahead (a skewed clock), threads that span Today, Earlier and the
/// future, open and answered requests, read and unread, GitHub items,
/// archived and snoozed items. Every title says "corpus".
fn edge_item(n: usize) -> FeedItem {
    const HOUR: i64 = 3_600_000;
    // From 30 hours ahead to about 4 days back, in 37-minute steps (not
    // minute-aligned for the odd ones).
    let at = MIRROR_NOW + 30 * HOUR - (n as i64) * 37 * 60_000 - (n as i64 % 2) * 1_234;
    let mut item = FeedItem::notice(&format!("fi_e{n:06}"), &format!("Corpus {n}"), agent(), at);
    item.thread = match n % 7 {
        0 | 3 => Some(format!("t{}", n % 4)),
        5 => Some("solo".into()),
        _ => None,
    };
    if n.is_multiple_of(6) {
        item.kind = "confirm".into();
        item.priority = if n.is_multiple_of(12) { Priority::Urgent } else { Priority::Normal };
        if n.is_multiple_of(4) {
            item.state = cmux_feed_core::client::State::Answered;
        }
    }
    if n % 5 == 1 {
        item.read_at = Some(at);
    }
    if n % 9 == 2 {
        item.dedupe_key = Some(format!("github:pr:{n}"));
    }
    if n % 23 == 4 {
        item.archived_at = Some(at);
    }
    if n % 29 == 6 {
        item.snoozed_until = Some(MIRROR_NOW + HOUR);
    }
    item
}

fn assert_index_matches_scan(mirror: &Mirror, label: &str) {
    for layout in ["inbox", "list", "needs_you"] {
        for connection in ["feed", "github"] {
            for category in ["all", "unread", "needs_you", "notices"] {
                for tz in [-720, -540, 0, 330, 840] {
                    for limit in [0usize, 1, 3, 17, 50, 2_000] {
                        let filter = json!({"connection": connection, "category": category});
                        let request = json!({"layout": layout, "limit": limit, "tz_offset_min": tz, "filter": filter});
                        let fast = view(mirror, MIRROR_NOW, request);
                        let mut searched = filter.clone();
                        searched["query"] = json!("corpus");
                        let request = json!({"layout": layout, "limit": limit, "tz_offset_min": tz, "filter": searched});
                        let slow = view(mirror, MIRROR_NOW, request);
                        let at = format!(
                            "{label}: {layout} {connection} {category} tz {tz} limit {limit}"
                        );
                        assert_eq!(fast["total"], slow["total"], "{at}");
                        assert_eq!(fast["groups"], slow["groups"], "{at}");
                    }
                }
            }
        }
    }
}

/// The index answers exactly what the scan of the whole list answers, for
/// every layout, filter, time zone and limit, before and after changes that
/// move items between threads, days, filters and the active list.
#[test]
fn the_indexed_inbox_and_filters_match_the_scan() {
    let mut mirror = Mirror::new("dev_1");
    let items: Vec<FeedItem> = (0..240).map(edge_item).collect();
    mirror.cloud_snapshot("user_1", items, MIRROR_NOW);
    assert_index_matches_scan(&mirror, "snapshot");
    // Read, re-thread, archive, answer, move in time, remove.
    let mut changed = Vec::new();
    for n in (0..240).step_by(5) {
        let mut item = edge_item(n);
        item.revision += 1;
        match n % 4 {
            0 => item.read_at = Some(MIRROR_NOW),
            1 => item.thread = Some("moved".into()),
            2 => item.archived_at = Some(MIRROR_NOW),
            _ => item.created_at -= 3 * 86_400_000,
        }
        if item.is_open_request() && n % 3 == 0 {
            item.state = cmux_feed_core::client::State::Answered;
        }
        changed.push(item);
    }
    let removed = (1..240).step_by(11).map(|n| edge_item(n).id).collect();
    mirror.event(Owner::Cloud, changed, removed, None, MIRROR_NOW);
    assert_index_matches_scan(&mirror, "after an event");
    // A pending read shows applied (and marked) until its settle line.
    let ids: Vec<String> = (2..240).step_by(13).map(|n| edge_item(n).id).collect();
    let intent = Intent::new("k1", IntentKind::Read { items: ids.clone() }, MIRROR_NOW);
    mirror.begin(intent, true, MIRROR_NOW);
    assert!(mirror.is_pending(&ids[0]) && !mirror.is_pending(&edge_item(3).id));
    assert_index_matches_scan(&mirror, "pending read");
    mirror.settle("k1", None, MIRROR_NOW);
    assert!(!mirror.is_pending(&ids[0]));
    let all = Intent::new("k2", IntentKind::MarkAllRead { before: MIRROR_NOW }, MIRROR_NOW);
    mirror.begin(all, true, MIRROR_NOW);
    assert!(mirror.is_pending(&edge_item(3).id));
    assert_index_matches_scan(&mirror, "pending mark all read");
    // Mark All Read goes to both owners: it ends on both settle lines.
    mirror.settle("k2", None, MIRROR_NOW);
    assert!(mirror.is_pending(&edge_item(3).id));
    mirror.settle("k2", None, MIRROR_NOW);
    assert!(!mirror.is_pending(&edge_item(3).id));
    // The snoozed items wake.
    mirror.tick(MIRROR_NOW + 2 * 3_600_000);
    assert_index_matches_scan(&mirror, "after the snoozes woke");
}

// MARK: Gated timing sweep

#[test]
fn stress_bench_local_owner_ingest() {
    if !bench_selected() {
        return;
    }
    for size in [100usize, 1_000, 10_000, 100_000] {
        let mut feed = Feed::default();
        let (mut post, mut read, mut ack) =
            (Samples::default(), Samples::default(), Samples::default());
        let mut post_allocs = 0u64;
        let sample_from = size.saturating_sub(2_000);
        for n in 0..size {
            let started = Instant::now();
            let ((), count) = allocs(|| daemon_post(&mut feed, notice(n)));
            if n >= sample_from {
                post.push(started);
                post_allocs += count;
            }
            if n % 10 == 9 {
                let id = format!("fl_{:08}", n - 4);
                let started = Instant::now();
                daemon_read(&mut feed, &id, T0 + n as u64);
                if n >= sample_from {
                    read.push(started);
                }
            }
            if n % 50 == 49 {
                let terminal = format!("term_{:03}", n % TERMINALS);
                let started = Instant::now();
                daemon_ack(&mut feed, &terminal, T0 + n as u64);
                if n >= sample_from {
                    ack.push(started);
                }
            }
            if n % 100 == 99 {
                // The unread total a badge reads.
                std::hint::black_box(feed.items().filter(|item| item.is_unread()).count());
            }
        }
        let sampled = (size - sample_from).max(1) as u64;
        report(
            "local_post",
            size,
            json!({"held": feed.items().len(), "post": post.summary(), "read": read.summary(), "ack": ack.summary(), "allocs_per_post": post_allocs / sampled}),
        );
    }
}

#[test]
fn stress_bench_integration_owner() {
    if !bench_selected() {
        return;
    }
    for size in [100usize, 1_000, 10_000, 100_000] {
        let mut owner = IntegrationOwner::new("dev_1");
        let (mut post, mut read) = (Samples::default(), Samples::default());
        let sample_from = size.saturating_sub(2_000);
        for n in 0..size {
            let started = Instant::now();
            std::hint::black_box(owner.post(integration_item(n)));
            if n >= sample_from {
                post.push(started);
            }
            if n % 10 == 9 {
                let intent = Intent::new(
                    format!("read_{n}"),
                    IntentKind::Read { items: vec![integration_item(n - 3).id] },
                    MIRROR_NOW + n as i64,
                );
                let started = Instant::now();
                std::hint::black_box(owner.commit(&intent).1);
                if n >= sample_from {
                    read.push(started);
                }
            }
        }
        report(
            "integration_owner",
            size,
            json!({"held": owner.len(), "post": post.summary(), "read": read.summary()}),
        );
    }
}

#[test]
fn stress_bench_mirror_and_view() {
    if !bench_selected() {
        return;
    }
    for size in [100usize, 1_000, 10_000, 100_000] {
        let mut mirror = mirror_of(size);
        let (mut event, mut page, mut inbox, mut full, mut read, mut filtered) = (
            Samples::default(),
            Samples::default(),
            Samples::default(),
            Samples::default(),
            Samples::default(),
            Samples::default(),
        );
        let inbox_request = json!({"layout": "inbox", "limit": 50});
        let filtered_request =
            json!({"layout": "inbox", "limit": 50, "filter": {"category": "notices"}});
        let (inbox_read, _) = visits(&mirror, inbox_request.clone());
        let (filtered_read, _) = visits(&mirror, filtered_request.clone());
        let rounds = 200;
        for round in 0..rounds {
            let n = (round * 7919) % size.max(1);
            let mut changed = client_item(n, MIRROR_NOW);
            changed.title = format!("Edited {round}");
            changed.revision += 1 + round as i64;
            let started = Instant::now();
            std::hint::black_box(mirror.event(
                Owner::Cloud,
                vec![changed],
                Vec::new(),
                None,
                MIRROR_NOW,
            ));
            event.push(started);
            let intent = Intent::new(
                format!("r{round}"),
                IntentKind::Read { items: vec![client_item(n, MIRROR_NOW).id] },
                MIRROR_NOW,
            );
            let started = Instant::now();
            std::hint::black_box(mirror.begin(intent, true, MIRROR_NOW));
            std::hint::black_box(mirror.settle(&format!("r{round}"), None, MIRROR_NOW));
            std::hint::black_box(mirror.counts());
            read.push(started);
            let started = Instant::now();
            std::hint::black_box(view(&mirror, MIRROR_NOW, json!({"limit": 50})));
            page.push(started);
            let started = Instant::now();
            std::hint::black_box(view(&mirror, MIRROR_NOW, inbox_request.clone()));
            inbox.push(started);
            let started = Instant::now();
            std::hint::black_box(view(&mirror, MIRROR_NOW, filtered_request.clone()));
            filtered.push(started);
            if round.is_multiple_of(20) {
                let started = Instant::now();
                std::hint::black_box(view(&mirror, MIRROR_NOW, json!({})));
                full.push(started);
            }
        }
        report(
            "mirror_view",
            size,
            json!({"event": event.summary(), "read_settle": read.summary(), "view_list_50": page.summary(), "view_inbox_50": inbox.summary(), "view_inbox_notices_50": filtered.summary(), "view_default": full.summary(), "inbox_items_read": inbox_read, "inbox_notices_items_read": filtered_read}),
        );
    }
}
