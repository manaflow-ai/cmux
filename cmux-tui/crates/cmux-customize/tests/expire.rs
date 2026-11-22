//! Detector: experiment layers expire by themselves. On 2026-11-18 Leo's
//! NIGHTLY still served web layer pr-45206, about 508 commits behind his
//! build, and a hand-installed web-dev.json overlay 5 days old, because
//! nothing turned either off and agents left them for their owner (Leo:
//! "Always do these; experiments shouldn't be left hanging like that").
//! Each test fails without `Customize::expire_stale`.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use cmux_customize::library::expire::{Expiry, MAX_AGE_MS, WEB_DEV_OVERLAY};
use cmux_customize::library::{CodeKind, CodeLayer};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

const HOUR: u64 = 3_600_000;
/// 2026-11-12T08:15:00Z, the stamp below.
const STAMPED: u64 = 1_794_471_300_000;

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        Home { dir: tempfile::tempdir().unwrap() }
    }

    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }

    fn write(&self, path: &str, text: &str) {
        let file = self.config(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }

    fn web_dev(&self) -> Value {
        fs::read_to_string(self.config("web-dev.json"))
            .map_or(json!({}), |text| serde_json::from_str(&text).unwrap())
    }

    /// A hand-installed overlay (`web-overlay.sh install`), stamped
    /// 2026-11-12T08:15Z for ABI `abi`, named on in web-dev.json.
    fn hand_overlay(&self, abi: u32) -> String {
        let overlay = self.dir.path().join("overlay");
        fs::create_dir_all(&overlay).unwrap();
        fs::write(
            overlay.join("manifest.json"),
            json!({"stamp": "20261112T081500Z-4242", "commit": "01192304abcdef", "abi": abi})
                .to_string(),
        )
        .unwrap();
        let path = overlay.to_string_lossy().into_owned();
        self.write("web-dev.json", &json!({"overlay": path, "enabled": true}).to_string());
        path
    }
}

fn key(n: u8) -> String {
    format!("{n:064x}")
}

fn layer(pr: u64, n: u8) -> CodeLayer {
    CodeLayer {
        kind: Default::default(),
        source: String::new(),
        repo: "manaflow-ai/cmux".to_owned(),
        pr,
        title: format!("pr {pr}"),
        head: format!("{n:040x}"),
        base: String::new(),
        web: key(n),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    }
}

fn install(customize: &Customize, n: u8) {
    let dir = customize.layer_dir(&key(n));
    fs::create_dir_all(dir.join("pages")).unwrap();
    fs::write(dir.join("manifest.json"), "{}").unwrap();
}

fn at(now_ms: u64) -> Expiry {
    Expiry { now_ms, ..Expiry::default() }
}

fn on(customize: &Customize, name: &str) -> bool {
    customize.library().unwrap().entries.iter().any(|entry| entry.name == name && entry.on)
}

/// The 2026-11-18 case: a PR layer on for 5 days is turned off on the next
/// read, what was under it comes back, and status and `cmux version` (the
/// same line) say it expired, why, and the one command back.
#[test]
fn a_pr_layer_on_past_its_bound_turns_off_and_says_so() {
    let home = Home::new();
    home.write("web-dev.json", r#"{"server": "http://127.0.0.1:4200/", "token": "t"}"#);
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(45206, 1), vec![], "cli", 1_000).unwrap();

    // Within its bound: nothing happens.
    assert!(customize.expire_stale(&at(1_000 + MAX_AGE_MS), "cli").expired.is_empty());
    assert!(on(&customize, "pr-45206"));

    let now = 1_000 + 5 * 24 * HOUR;
    let out = customize.expire_stale(&at(now), "cli");
    assert!(out.problems.is_empty(), "{:?}", out.problems);
    assert_eq!(out.expired.len(), 1);
    assert_eq!(out.expired[0].why, "on 5 days, past 24 hours");
    assert_eq!(out.expired[0].back, "cmux customize library on pr-45206");
    assert!(!on(&customize, "pr-45206"));
    assert_eq!(home.web_dev(), json!({"server": "http://127.0.0.1:4200/", "token": "t"}));
    let listing = customize.library().unwrap();
    assert_eq!(listing.entries[0].code.as_ref().unwrap().note, "expired: on 5 days, past 24 hours");

    let layers = customize.layers_at(None, now + HOUR);
    assert_eq!(
        layers.line,
        "customize: 0 on; expired: pr-45206 (on 5 days, past 24 hours; back: cmux customize library on pr-45206)"
    );
    // A second pass has nothing left to do.
    assert!(customize.expire_stale(&at(now + HOUR), "cli").expired.is_empty());

    // The way back gives it another 24 hours.
    customize.library_set_on("pr-45206", true, "cli", now + 2 * HOUR).unwrap();
    assert!(customize.layers_at(None, now + 2 * HOUR).expired.is_empty());
    assert!(customize.expire_stale(&at(now + 20 * HOUR), "cli").expired.is_empty());
    assert!(on(&customize, "pr-45206"));
    // A week on, the old record is no longer said.
    customize.library_set_on("pr-45206", false, "cli", now + 3 * HOUR).unwrap();
    assert!(customize.layers_at(None, now + 9 * 24 * HOUR).expired.is_empty());
}

/// `cmux customize try pr:N --minutes 5` (experiments-shelf.md: "`cmux
/// customize try pr:N --minutes 5` should take a PR the same way"): the
/// entry is on for its minutes, then off by itself with web-dev.json exactly
/// as it was, and `library on` keeps it (no time left on it).
#[test]
fn a_code_try_turns_off_when_its_minutes_are_up_and_on_keeps_it() {
    const MINUTE: u64 = 60_000;
    let home = Home::new();
    let before = r#"{"server": "http://127.0.0.1:4200/", "token": "t"}"#;
    home.write("web-dev.json", before);
    let customize = home.customize();
    install(&customize, 2);
    customize.library_use_code(layer(43496, 2), vec![], "cli", 1_000).unwrap();
    customize.library_try_until("pr-43496", 1_000 + 5 * MINUTE, "cli", 1_000).unwrap();
    assert_eq!(customize.next_try_end().unwrap(), Some(1_000 + 5 * MINUTE));
    let listing = customize.library().unwrap();
    assert_eq!(listing.entries[0].until_ms, Some(1_000 + 5 * MINUTE));
    assert_eq!(home.web_dev()["overlay"], json!(customize.layer_dir(&key(2)).to_string_lossy()));

    // Before its time: it stays.
    assert!(customize.expire_stale(&at(1_000 + 4 * MINUTE), "cli").expired.is_empty());
    assert!(on(&customize, "pr-43496"));

    let out = customize.expire_stale(&at(1_000 + 5 * MINUTE), "cli");
    assert!(out.problems.is_empty(), "{:?}", out.problems);
    assert_eq!(out.expired.len(), 1);
    assert_eq!(out.expired[0].why, "tried on for 5 minutes, time up");
    assert_eq!(out.expired[0].back, "cmux customize library on pr-43496");
    assert!(!on(&customize, "pr-43496"));
    assert_eq!(home.web_dev(), serde_json::from_str::<Value>(before).unwrap());
    assert_eq!(customize.next_try_end().unwrap(), None);

    // Its way back keeps it: no time left on it, only the 24-hour bound.
    customize.library_set_on("pr-43496", true, "cli", 1_000 + 6 * MINUTE).unwrap();
    assert_eq!(customize.next_try_end().unwrap(), None);
    assert_eq!(customize.library().unwrap().entries[0].until_ms, None);
    assert!(customize.expire_stale(&at(1_000 + 60 * MINUTE), "cli").expired.is_empty());
    assert!(on(&customize, "pr-43496"));
}

/// The waiter `try` leaves running returns at once when nothing is being
/// tried, and turns a try whose time is up off without waiting.
#[test]
fn the_code_try_waiter_ends_when_no_try_is_on() {
    let home = Home::new();
    let customize = home.customize();
    assert!(customize.run_code_try_timer(None, "cmux").is_empty());

    install(&customize, 3);
    customize.library_use_code(layer(43497, 3), vec![], "cli", 1_000).unwrap();
    // Already past its end (a laptop that slept through it).
    customize.library_try_until("pr-43497", 2_000, "cli", 1_000).unwrap();
    let expired = customize.run_code_try_timer(None, "cmux");
    assert_eq!(expired.len(), 1);
    assert_eq!(expired[0].name, "pr-43497");
    assert!(!on(&customize, "pr-43497"));

    // A try only stamps a code entry.
    assert!(customize.library_try_until("nope", 5_000, "cli", 1_000).is_err());
}

/// A PR that merged or closed turns its layer off at once, whatever its age.
#[test]
fn a_pr_layer_whose_pr_merged_or_closed_turns_off() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    install(&customize, 2);
    install(&customize, 3);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    customize.library_use_code(layer(30, 3), vec![], "cli", 3).unwrap();
    let cmux = || "manaflow-ai/cmux".to_owned();
    let ended = BTreeMap::from([
        ((cmux(), 10), "merged".to_owned()),
        ((cmux(), 20), "closed".to_owned()),
        // A fork's PR 30 merged; this entry is manaflow-ai/cmux's open PR 30.
        (("someone/cmux".to_owned(), 30), "merged".to_owned()),
    ]);
    let out = customize.expire_stale(&Expiry { now_ms: 4, ended, ..Expiry::default() }, "app");
    let why: Vec<(String, String)> =
        out.expired.iter().map(|expired| (expired.name.clone(), expired.why.clone())).collect();
    assert_eq!(
        why,
        vec![
            ("pr-20".to_owned(), "PR closed".to_owned()),
            ("pr-10".to_owned(), "PR merged".to_owned())
        ]
    );
    assert!(on(&customize, "pr-30"), "an open PR within its bound stays on");
    assert!(!on(&customize, "pr-10") && !on(&customize, "pr-20"));
}

/// A hand-installed overlay is no library entry, so nothing turned it off:
/// past its bound it gets `enabled: false` (what `web-overlay.sh off`
/// writes), keeps its path, and `library on web-dev-overlay` turns it back
/// on for another 24 hours.
#[test]
fn a_hand_installed_overlay_past_its_bound_turns_off_and_comes_back() {
    let home = Home::new();
    let customize = home.customize();
    let path = home.hand_overlay(7);
    assert!(customize.expire_stale(&at(STAMPED + 2 * HOUR), "cli").expired.is_empty());

    let now = STAMPED + 5 * 24 * HOUR;
    let out = customize
        .expire_stale(&Expiry { now_ms: now, app_abi: Some(7), ..Expiry::default() }, "cli");
    assert_eq!(out.expired.len(), 1);
    assert_eq!(out.expired[0].name, WEB_DEV_OVERLAY);
    assert_eq!(out.expired[0].why, "installed 5 days ago, past 24 hours");
    assert_eq!(home.web_dev(), json!({"overlay": path, "enabled": false}));
    assert!(customize.layers_at(Some(7), now).line.ends_with(
        "; expired: web-dev-overlay (installed 5 days ago, past 24 hours; back: cmux customize library on web-dev-overlay)"
    ));

    assert_eq!(customize.renew_overlay(now + HOUR).unwrap(), path);
    assert_eq!(home.web_dev(), json!({"overlay": path, "enabled": true}));
    assert!(customize.layers_at(Some(7), now + HOUR).expired.is_empty());
    assert!(customize.expire_stale(&at(now + 10 * HOUR), "cli").expired.is_empty());
    assert_eq!(customize.expire_stale(&at(now + 26 * HOUR), "cli").expired.len(), 1);
}

/// A folder layer a watch keeps rebuilding is in use: each rebuild starts its
/// 24 hours again, so it stays on while someone edits it.
#[test]
fn a_watched_folder_layer_stays_on_while_it_rebuilds() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    install(&customize, 2);
    let dir = |n| CodeLayer { kind: CodeKind::Dir, source: "/src/cmux".to_owned(), ..layer(0, n) };
    customize.library_use_code(dir(1), vec![], "cli", 1_000).unwrap();
    let name = customize.library().unwrap().entries[0].name.clone();

    // Rebuilt by the watch a day and a half later.
    let rebuilt = 1_000 + 36 * HOUR;
    customize.library_update_code(dir(2), "watch", rebuilt).unwrap();
    assert!(customize.expire_stale(&at(rebuilt + HOUR), "cli").expired.is_empty());
    assert!(on(&customize, &name));
    // Left alone past its bound after the last rebuild, it expires.
    assert_eq!(customize.expire_stale(&at(rebuilt + 25 * HOUR), "cli").expired.len(), 1);
}

/// An overlay the app refuses for another web ABI is stale however new.
#[test]
fn a_refused_hand_overlay_turns_off() {
    let home = Home::new();
    let customize = home.customize();
    home.hand_overlay(4);
    let out = customize.expire_stale(
        &Expiry { now_ms: STAMPED + HOUR, app_abi: Some(7), ..Expiry::default() },
        "cli",
    );
    assert_eq!(out.expired[0].why, "refused: abi 4, app 7");
    assert_eq!(home.web_dev()["enabled"], json!(false));
}
