//! The palette ranker at scale: a query typed keystroke by keystroke over 100 to 100,000 rows.
//!
//! The macOS palette installs its rows once per version (`cmux_palette_ranker_install`) and
//! sends one request per keystroke (`cmux_palette_ranker_rank`, row limit 400, highlight limit
//! 60). The rows here mix what the palette mixes: registry actions (ids, keywords, aliases,
//! shortcuts), settings (demoted), workspaces (handles, paths), tabs and files (long titles,
//! accents, CJK, emoji), disabled rows and duplicate titles.
//!
//! `allocations_per_keystroke_do_not_grow_with_the_corpus` always runs: it counts heap
//! allocations in one keystroke at 1x and 16x the rows and fails if a keystroke allocates per
//! matched row (beyond the one scored list, which grows by doubling).
//! `rows_scored_per_keystroke_follow_the_shrinking_matches` counts the rows each key of a 12-key
//! query scores at 100,000 rows and fails if key 12 scores more than 2% of them.
//! `narrowed_keystrokes_rank_like_a_full_rescore` types random queries (keys, backspace, paste,
//! clear) and checks every narrowed answer against scoring every row.
//!
//! The timing sweep runs only when asked: `CMUX_STRESS=1`, or a plain `cargo test` whose filter
//! names `stress_sweep`. It prints one `STRESS-PALETTE` JSON line per size:
//!
//!   env CMUX_STRESS=1 cargo test -p cmux-palette-ranker --release --test stress -- --nocapture

use cmux_palette_ranker::ffi::{
    OK, cmux_palette_ranker_free, cmux_palette_ranker_install, cmux_palette_ranker_new,
    cmux_palette_ranker_rank,
};
use cmux_palette_ranker::{Entry, RankRequest, Ranker};
use serde_json::{Value, json};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::time::Instant;

/// Counts allocations made on a thread while its count is switched on.
struct Counting;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator unchanged.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if COUNTING.with(Cell::get) {
            ALLOCATIONS.with(|count| count.set(count.get() + 1));
        }
        // SAFETY: the caller's layout, passed through.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` came from `System.alloc` with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if COUNTING.with(Cell::get) {
            ALLOCATIONS.with(|count| count.set(count.get() + 1));
        }
        // SAFETY: `ptr` came from `System.alloc` with this layout.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// Allocations `work` makes on this thread.
fn allocations_in<T>(work: impl FnOnce() -> T) -> (usize, T) {
    ALLOCATIONS.with(|count| count.set(0));
    COUNTING.with(|on| on.set(true));
    let value = work();
    COUNTING.with(|on| on.set(false));
    (ALLOCATIONS.with(Cell::get), value)
}

/// A fixed-seed xorshift, so every run builds the same rows.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[(self.next() % items.len() as u64) as usize]
    }
}

const VERBS: &[&str] = &[
    "Open",
    "Close",
    "New",
    "Toggle",
    "Show",
    "Hide",
    "Move",
    "Rename",
    "Split",
    "Focus",
    "Reload",
    "Copy",
    "Share",
    "Duplicate",
    "Pin",
    "Restart",
];
const NOUNS: &[&str] = &[
    "Workspace",
    "Window",
    "Tab",
    "Pane",
    "Settings",
    "Sidebar",
    "Terminal",
    "Browser",
    "Chat",
    "Agent",
    "Screen",
    "File",
    "Folder",
    "Notification",
    "Theme",
    "Shortcut",
];
const WORDS: &[&str] = &[
    "main",
    "src",
    "lib",
    "test",
    "palette",
    "ranker",
    "sidebar",
    "config",
    "docs",
    "build",
    "café",
    "naïve",
    "résumé",
    "日本語",
    "検索",
    "한국어",
    "Ünïcödé",
    "🚀",
    "emoji 🎉",
    "straße",
];
const KEYCAPS: &[&[&str]] = &[&["⌘", "P"], &["⇧", "⌘", "P"], &["⌥", "⌘", "T"], &["⌃", "K"]];

/// `count` rows mixed the way the palette mixes them.
fn corpus(count: usize) -> Vec<Value> {
    corpus_seeded(count, 0x9e37_79b9_7f4a_7c15)
}

/// [`corpus`] drawn from another seed.
fn corpus_seeded(count: usize, seed: u64) -> Vec<Value> {
    let mut rng = Rng(seed);
    (0..count)
        .map(|index| {
            let verb = rng.pick(VERBS);
            let noun = rng.pick(NOUNS);
            let word = rng.pick(WORDS);
            match index % 10 {
                // Registry actions: ids, keywords, aliases, shortcuts.
                0..=2 => json!({
                    "title": format!("{verb} {noun}"),
                    "actionID": format!("{}.{}{index}", noun.to_lowercase(), verb.to_lowercase()),
                    "keywords": [word, noun.to_lowercase(), "action"],
                    "aliases": if index % 7 == 0 { json!([format!("{verb} {word}")]) } else { json!([]) },
                    "keycaps": KEYCAPS[index % KEYCAPS.len()],
                    "hasShortcut": index % 3 == 0,
                    "frecencyKey": format!("action:{index}"),
                    "sectionIndex": index % 5,
                    "typingSectionIndex": 16,
                    // Every 50th row disabled.
                    "isEnabled": index % 50 != 0,
                }),
                // Settings: demoted.
                3 => json!({
                    "title": format!("{noun} {word}"),
                    "subtitle": format!("Settings › {noun}"),
                    "demoted": true,
                    "frecencyKey": format!("setting:{index}"),
                    "sectionIndex": 6,
                }),
                // Workspaces: handles and paths.
                4 | 5 => json!({
                    "title": format!("a{} · {word} {noun}", index % 10_000),
                    "subtitle": format!("~/Projects/{word}/{}", noun.to_lowercase()),
                    "keywords": ["workspace"],
                    "handles": [format!("a{}", index % 10_000)],
                    "frecencyKey": format!("workspace:{index}"),
                    "sectionIndex": 7,
                }),
                // Tabs: long titles, some duplicates.
                6 | 7 => json!({
                    "title": if index % 4 == 0 {
                        format!("{verb} {noun} — {}", [word; 40].join(" "))
                    } else {
                        format!("{word} {noun}")
                    },
                    "keywords": ["tab"],
                    "frecencyKey": format!("tab:{index}"),
                    "sectionIndex": 8,
                }),
                // Files.
                _ => json!({
                    "title": format!("{word}/{}_{index}.rs", noun.to_lowercase()),
                    "accessory": format!("{word}/"),
                    "keywords": ["file"],
                    "sectionIndex": 9,
                }),
            }
        })
        .collect()
}

/// Queries typed one key at a time: prefixes of each, 1 to 20 characters.
const TYPED: &[&str] = &[
    "open workspace setti",
    "toggle sidebar theme",
    "a612",
    "src/palette_42.rs",
    "日本語 検索",
    "opne setings windw",
    "zqxjv wkpfh mbgty",
];

fn keystrokes(query: &str) -> impl Iterator<Item = String> + '_ {
    let chars: Vec<char> = query.chars().take(20).collect();
    (1..=chars.len()).map(move |length| chars[..length].iter().collect())
}

fn request(version: i64, query: &str) -> Value {
    json!({
        "operation": "rank",
        "version": version,
        "query": query,
        "now": 1_000_000.0,
        "rowLimit": 400,
        "highlightLimit": 60,
        "frecency": {"entries": {"action:3": {"score": 4.0, "lastUsed": 999_000.0}}},
    })
}

fn installed(entries: &[Value]) -> Ranker {
    let entries: Vec<Entry> =
        serde_json::from_value(Value::Array(entries.to_vec())).expect("entries");
    let mut ranker = Ranker::new();
    ranker.install(1, entries);
    ranker
}

#[test]
fn allocations_per_keystroke_do_not_grow_with_the_corpus() {
    let small = installed(&corpus(1_000));
    let large = installed(&corpus(16_000));
    // One- and two-letter queries match more rows than the row limit at both sizes; each also
    // ranks prefix first and with a user alias, the other orders and passes a keystroke takes.
    for query in ["o", "op", "s", "a6", "e", "ta"] {
        for extra in [
            json!({}),
            json!({"ranksPrefixFirst": true}),
            json!({"aliases": {"window.open0": ["op", "o"]}, "pins": ["window.open0"]}),
        ] {
            let mut request = request(1, query);
            if let (Some(request), Some(extra)) = (request.as_object_mut(), extra.as_object()) {
                request.extend(extra.clone());
            }
            let request: RankRequest = serde_json::from_value(request).expect("request");
            // Warm the rows' lazily split words, which a first keystroke fills once per row.
            small.rank(&request).expect("rank");
            large.rank(&request).expect("rank");
            let (at_small, small_rows) = allocations_in(|| small.rank(&request).expect("rank"));
            let (at_large, large_rows) = allocations_in(|| large.rank(&request).expect("rank"));
            let rows = |sections: &[cmux_palette_ranker::RankedSection]| {
                sections.iter().map(|section| section.rows.len()).sum::<usize>()
            };
            assert_eq!(rows(&large_rows), 400, "{query:?} {extra} fills the row limit at 16x");
            assert!(rows(&small_rows) > 0, "{query:?} {extra} matches at 1x");
            // 16x the rows may add a few doublings of the scored list, never an allocation per
            // matched row.
            assert!(
                at_large <= at_small + 64,
                "{query:?} {extra}: {at_small} allocations at 1,000 rows, {at_large} at 16,000"
            );
        }
    }
}

/// Rows scored by one keystroke of each 12-key query at 100,000 rows. A keystroke that extends
/// the query scores only the rows the shorter query could still lead to, so key 12 scores a
/// few hundred rows where scoring every row costs 100,000 (and 200,000 with the typo pass).
#[test]
fn rows_scored_per_keystroke_follow_the_shrinking_matches() {
    const ROWS: usize = 100_000;
    /// Key 12 may score at most this many rows: 2% of the corpus.
    const KEY_12_BOUND: usize = ROWS / 50;
    let ranker = installed(&corpus(ROWS));
    // Words, a path, and typos that run the typo pass.
    for query in ["toggle sideb", "src/palette_", "opne setings", "zqxjv wkpfh "] {
        let mut per_key = Vec::new();
        for typed in keystrokes(query) {
            let request: RankRequest = serde_json::from_value(request(1, &typed)).expect("request");
            let before = ranker.rows_scored();
            ranker.rank(&request).expect("rank");
            per_key.push(ranker.rows_scored() - before);
        }
        println!("ROWS-SCORED {query:?} per key {per_key:?}");
        assert_eq!(per_key.len(), 12, "{query:?} is 12 keys");
        let key_12 = per_key.last().copied().unwrap_or_default();
        assert!(
            key_12 <= KEY_12_BOUND,
            "{query:?}: key 12 scored {key_12} of {ROWS} rows (bound {KEY_12_BOUND}); per key \
             {per_key:?}"
        );
    }
}

/// Characters and phrases the random typist types: words of the corpus, typos, a handle, an
/// action id, a path, a shortcut, query prefixes, CJK and accents.
const PHRASES: &[&str] = &[
    "open workspace settings",
    "toggle sidebar",
    "opne setings windw",
    "screen sharing",
    "shared files",
    "a612",
    "612",
    "workspace.open",
    "Workspace.Rename",
    "src/palette_42.rs",
    "cmd shift p",
    "⌘P",
    ":12",
    ">run",
    "switch theme",
    "Open Settings...",
    "café naïve",
    "日本語 検索",
    "zqxjv wkpfh",
    "duplicate pane",
];
const CHARACTERS: &[&str] = &[
    "a", "e", "o", "s", "t", "n", "p", "x", "q", "z", " ", ".", ":", ">", "1", "6", "W", "é", "検",
];

/// Rows the generated corpus lacks: gated, scope, hidden-by-typing, stem and ellipsis rows.
fn special_rows() -> Vec<Value> {
    vec![
        json!({"title": "Go to Line", "queryPrefix": ":", "frecencyKey": "special:line"}),
        json!({"title": "Run Command", "queryPrefix": ">", "keywords": ["run"]}),
        json!({"title": "Recent Files", "hidesWhenTyping": true}),
        json!({"title": "Switch Theme…", "entersScope": true, "keywords": ["theme", "themes"]}),
        json!({"title": "Open Settings...", "actionID": "settings.open", "hasShortcut": true}),
        json!({"title": "Screen Sharing", "actionID": "screen.share", "aliases": ["share it"]}),
        json!({"title": "Shared Files", "actionID": "Workspace.Rename", "keycaps": ["⇧", "⌘", "P"]}),
        json!({"title": "Open Workspace", "actionID": "workspace.open", "handles": ["b42"]}),
        json!({"title": "Café Naïve", "subtitle": "naive cafe", "isEnabled": false}),
        json!({"title": "", "keywords": ["empty"]}),
    ]
}

/// A random keystroke's request: options a host sends vary too (prefix-first order, the typo
/// pass, user aliases and pins, hidden rows, learned picks, section order).
fn random_request(rng: &mut Rng, query: &str) -> RankRequest {
    let mut value = request(1, query);
    let Some(object) = value.as_object_mut() else { panic!("request object") };
    if rng.next() % 8 == 0 {
        object.insert("ranksPrefixFirst".into(), json!(true));
    }
    match rng.next() % 6 {
        0 => {
            object.insert("typoPass".into(), json!(true));
        }
        1 => {
            object.insert("typoPass".into(), json!(false));
        }
        _ => {}
    }
    if rng.next() % 3 == 0 {
        object.insert(
            "aliases".into(),
            json!({"window.open0": ["op", "sw"], "settings.open": ["o"]}),
        );
        object.insert("pins".into(), json!(["window.open0"]));
    }
    if rng.next() % 3 == 0 {
        object.insert(
            "frecency".into(),
            json!({
                "entries": {"action:3": {"score": 4.0, "lastUsed": 999_000.0}},
                "hidden": ["tab:6", "action:20", "special:line"],
                "picks": [
                    {"prefix": "o", "key": "action:30", "score": 5.0, "lastUsed": 999_000.0, "last": true},
                    {"prefix": "to", "key": "action:41", "score": 3.0, "lastUsed": 999_000.0, "last": false},
                ],
            }),
        );
    }
    if rng.next() % 4 == 0 {
        object.insert("keepsSectionOrder".into(), json!(true));
        object.insert("sectionOrders".into(), json!([3, 1, 2, 0, 4, 5, 6, 7, 8, 9]));
    }
    serde_json::from_value(value).expect("request")
}

/// One random edit of the query: type the next key of a phrase, a stray key, backspace, paste
/// a phrase onto the end or over the whole query, or clear it.
fn random_edit(rng: &mut Rng, query: &mut Vec<char>, phrase: &mut Vec<char>) {
    match rng.next() % 100 {
        0..=54 => {
            if phrase.is_empty() {
                *phrase = rng.pick(PHRASES).chars().rev().collect();
                if !query.is_empty() && rng.next() % 2 == 0 {
                    query.push(' ');
                }
            }
            query.extend(phrase.pop());
        }
        55..=64 => query.extend(rng.pick(CHARACTERS).chars()),
        65..=79 => {
            for _ in 0..=rng.next() % 3 {
                query.pop();
            }
        }
        80..=87 => {
            if rng.next() % 2 == 0 {
                query.push(' ');
            }
            query.extend(rng.pick(PHRASES).chars());
        }
        88..=93 => *query = rng.pick(PHRASES).chars().collect(),
        _ => query.clear(),
    }
}

/// Random typing (keys, backspace, paste, clear) over seeded corpora: every keystroke's answer
/// equals scoring every row again.
#[test]
fn narrowed_keystrokes_rank_like_a_full_rescore() {
    for seed in [1, 0x5eed, 0xdead_beef] {
        let mut entries = corpus_seeded(1_200, seed);
        entries.extend(special_rows());
        let ranker = installed(&entries);
        let mut rng = Rng(seed ^ 0x2545_f491_4f6c_dd1d);
        let (mut query, mut phrase) = (Vec::new(), Vec::new());
        for step in 0..600 {
            random_edit(&mut rng, &mut query, &mut phrase);
            let typed: String = query.iter().collect();
            let request = random_request(&mut rng, &typed);
            let narrowed = ranker.rank(&request).expect("rank");
            let full = ranker.rank_full(&request).expect("rank");
            assert_eq!(narrowed, full, "seed {seed:#x} step {step}: {typed:?}");
        }
    }
}

#[test]
fn degenerate_corpora_rank() {
    for entries in [
        vec![],
        vec![json!({"title": "x".repeat(100_000)})],
        vec![json!({"title": "🚀".repeat(10_000), "keywords": vec!["検索"; 64]})],
        vec![json!({"title": "Open Settings"}); 5_000],
        vec![json!({"title": ""}); 100],
    ] {
        let ranker = installed(&entries);
        for query in ["o", "open", "x".repeat(20).as_str(), "🚀", "検", "opne"] {
            let request: RankRequest = serde_json::from_value(request(1, query)).expect("request");
            let sections = ranker.rank(&request).expect("rank");
            let rows: usize = sections.iter().map(|section| section.rows.len()).sum();
            assert!(rows <= 400, "{query:?}: {rows} rows");
        }
    }
    // Duplicate titles keep the catalog order.
    let ranker = installed(&vec![json!({"title": "Open Settings"}); 5_000]);
    let request: RankRequest = serde_json::from_value(request(1, "open")).expect("request");
    let indexes: Vec<usize> =
        ranker.rank(&request).expect("rank")[0].rows.iter().map(|row| row.index).collect();
    assert_eq!(indexes, (0..400).collect::<Vec<_>>());
}

fn sweep_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|value| value == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|arg| arg.contains("stress_sweep"))
        && !args.iter().any(|a| a == "--exact")
}

/// Milliseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
    }

    fn at(&self, q: f64) -> f64 {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        if v.is_empty() {
            return 0.0;
        }
        let i = ((v.len() - 1) as f64 * q).round() as usize;
        (v[i] * 1000.0).round() / 1000.0
    }

    fn summary(&self) -> Value {
        json!({ "n": self.0.len(), "p50": self.at(0.5), "p95": self.at(0.95), "max": self.at(1.0) })
    }
}

/// One ranker handle over the C ABI, as the app holds it.
struct Handle(*mut cmux_palette_ranker::ffi::CmuxPaletteRanker);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: a live handle from `cmux_palette_ranker_new`, freed once.
        unsafe { cmux_palette_ranker_free(self.0) }
    }
}

impl Handle {
    fn rank(&self, request: &[u8]) -> usize {
        let mut response = std::ptr::null();
        let mut length = 0;
        // SAFETY: a live handle, a readable request and writable out pointers.
        let code = unsafe {
            cmux_palette_ranker_rank(
                self.0,
                request.as_ptr(),
                request.len(),
                &mut response,
                &mut length,
            )
        };
        assert_eq!(code, OK);
        length
    }
}

#[test]
fn stress_sweep() {
    if !sweep_selected() {
        return;
    }
    for size in [100, 1_000, 10_000, 100_000] {
        let entries = corpus(size);
        let bytes = serde_json::to_vec(&entries).expect("entries json");
        let handle = Handle(cmux_palette_ranker_new());
        let start = Instant::now();
        // SAFETY: a live handle and a readable buffer.
        let code = unsafe { cmux_palette_ranker_install(handle.0, 1, bytes.as_ptr(), bytes.len()) };
        assert_eq!(code, OK);
        let install_ms = start.elapsed().as_secs_f64() * 1000.0;
        let typed: Vec<Vec<u8>> = TYPED
            .iter()
            .flat_map(|query| keystrokes(query))
            .map(|query| serde_json::to_vec(&request(1, &query)).expect("request json"))
            .collect();
        // One warm pass fills lazily split words, as the palette's first keystrokes do.
        for request in &typed {
            handle.rank(request);
        }
        let passes = if size >= 100_000 { 2 } else { 5 };
        let (mut keystroke, mut short, mut long) =
            (Samples::default(), Samples::default(), Samples::default());
        let mut response_bytes = 0;
        let mut by_query: Vec<Samples> = TYPED.iter().map(|_| Samples::default()).collect();
        for _ in 0..passes {
            for (at, query) in TYPED.iter().enumerate() {
                for typed in keystrokes(query) {
                    let request = serde_json::to_vec(&request(1, &typed)).expect("request json");
                    let start = Instant::now();
                    response_bytes = response_bytes.max(handle.rank(&request));
                    keystroke.push(start);
                    let sample = *keystroke.0.last().expect("sample");
                    by_query[at].0.push(sample);
                    let length = typed.chars().count();
                    if length <= 3 {
                        short.0.push(sample);
                    } else if length >= 12 {
                        long.0.push(sample);
                    }
                }
            }
        }
        // The deterministic count: allocations in one keystroke ("o" matches most rows).
        let ranker = installed(&entries);
        let one: RankRequest = serde_json::from_value(request(1, "o")).expect("request");
        ranker.rank(&one).expect("rank");
        let (allocations, _) = allocations_in(|| ranker.rank(&one).expect("rank"));
        let line = json!({
            "size": size,
            "install_ms": (install_ms * 10.0).round() / 10.0,
            "keystroke_ms": keystroke.summary(),
            "keys_1_to_3_ms": short.summary(),
            "keys_12_plus_ms": long.summary(),
            "p50_ms_by_query": TYPED
                .iter()
                .zip(&by_query)
                .map(|(query, samples)| (query.to_string(), json!(samples.at(0.5))))
                .collect::<serde_json::Map<_, _>>(),
            "max_response_bytes": response_bytes,
            "allocations_per_keystroke_o": allocations,
            "cores": std::thread::available_parallelism().map_or(0, |n| n.get()),
            "os": std::env::consts::OS,
        });
        println!("STRESS-PALETTE {line}");
    }
}
