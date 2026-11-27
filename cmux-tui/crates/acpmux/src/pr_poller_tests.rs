//! The poller against a fake GitHub that counts requests: N chats on one pull request cost one
//! read, 304s are not charged, the budget bounds every call, and a REST failure falls back to
//! `gh pr view`. `n_watchers_cost_one_poll` is the harness of the design doc's number.

use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

const HEAD: &str = "4db9066b0c2a4e7f9d1e2b3c4d5e6f708192a3b4";

/// A fake GitHub: one pull request whose check runs are `running` until `finish` is called.
#[derive(Default)]
struct Fake {
    gets: AtomicU64,
    views: AtomicU64,
    done: std::sync::atomic::AtomicBool,
    /// Every REST read fails (a `gh` that takes no `--include`).
    rest_broken: bool,
    remaining: Option<u64>,
}

impl Fake {
    fn finish(&self) {
        self.done.store(true, Ordering::SeqCst);
    }

    fn body(&self, path: &str) -> (String, Value) {
        let done = self.done.load(Ordering::SeqCst);
        if path.ends_with("/pulls/7") {
            return (
                "p1".into(),
                json!({
                    "number": 7, "html_url": "https://github.com/o/r/pull/7", "state": "open",
                    "merged": false, "head": {"sha": HEAD}, "base": {"ref": "main"},
                    "mergeable": true, "labels": [], "body": "text",
                }),
            );
        }
        if path.contains("/check-runs") {
            let run = if done {
                json!({"name": "build", "status": "completed", "conclusion": "success"})
            } else {
                json!({"name": "build", "status": "in_progress", "conclusion": null})
            };
            return (format!("c{done}"), json!({"total_count": 1, "check_runs": [run]}));
        }
        if path.contains("/status") {
            return ("s1".into(), json!({"statuses": []}));
        }
        ("m1".into(), json!([{"body": "hi", "user": {"login": "a"}}]))
    }
}

impl Fetch for Fake {
    fn get<'a>(&'a self, path: &'a str, etag: Option<&'a str>) -> Fut<'a, Result<Reply, String>> {
        Box::pin(async move {
            self.gets.fetch_add(1, Ordering::SeqCst);
            if self.rest_broken {
                return Err("unknown flag: --include".to_owned());
            }
            let (tag, body) = self.body(path);
            let remaining = self.remaining;
            let reset = remaining.map(|_| 4_000_000_000);
            if etag == Some(tag.as_str()) {
                return Ok(Reply {
                    status: 304,
                    etag: Some(tag),
                    remaining,
                    reset,
                    ..Reply::default()
                });
            }
            Ok(Reply {
                status: 200,
                etag: Some(tag),
                body: body.to_string().into_bytes(),
                remaining,
                reset,
                last_page: None,
            })
        })
    }

    fn view<'a>(&'a self, _repo: &'a str, number: u64) -> Fut<'a, Result<Value, String>> {
        Box::pin(async move {
            self.views.fetch_add(1, Ordering::SeqCst);
            Ok(
                json!({"number": number, "state": "OPEN", "headRefOid": HEAD, "statusCheckRollup": []}),
            )
        })
    }
}

fn key() -> Key {
    Key::new("O/R", 7)
}

/// GitHub requests per refresh of a pull request with one page of everything.
const READS_PER_REFRESH: u64 = 4;

#[tokio::test(start_paused = true)]
async fn n_watchers_cost_one_poll() {
    // Before: each chat's MCP server ran its own `gh pr view` per look, so N chats looking
    // once cost N calls. After: one refresh for all of them.
    for n in [1_u64, 5, 20, 50] {
        let poller = Arc::new(Poller::new(Fake::default(), Config::default()));
        let mut joins = Vec::new();
        for _ in 0..n {
            let p = poller.clone();
            joins
                .push(tokio::spawn(async move { p.status(&key(), FRESH).await.map(|a| a.source) }));
        }
        let mut fetched = 0;
        for j in joins {
            if j.await.unwrap().unwrap() == Source::Fetched {
                fetched += 1;
            }
        }
        let c = poller.counters();
        println!(
            "status, {n} chats: before {n} gh calls, after {} requests ({} charged)",
            c.requests, c.charged
        );
        assert_eq!(fetched, 1, "one caller fetched, the rest shared it");
        assert_eq!(c.refreshes, 1);
        assert_eq!(c.requests, READS_PER_REFRESH);
        assert_eq!(c.cache_hits, n - 1);
    }
}

#[tokio::test(start_paused = true)]
async fn n_waiters_share_one_poll_an_interval() {
    // N chats wait on one PR for 10 minutes of CI. Before: each polled its own `gh pr view`
    // every 30 s, 20 polls each. After: one shared poll an interval, mostly 304s.
    for n in [1_u64, 5, 20] {
        let fake = Arc::new(Fake::default());
        let poller = Arc::new(Poller::new(FakeRef(fake.clone()), Config::default()));
        let mut joins = Vec::new();
        for _ in 0..n {
            let p = poller.clone();
            joins.push(tokio::spawn(async move {
                p.wait(&key(), Until::Settled, Instant::now() + Duration::from_secs(1800)).await
            }));
        }
        tokio::time::sleep(Duration::from_secs(600)).await;
        fake.finish();
        for j in joins {
            let (answer, timed_out) = j.await.unwrap().unwrap();
            assert!(!timed_out);
            assert!(settled(&answer.pr));
        }
        let c = poller.counters();
        let before = n * (600 / 30 + 1);
        println!(
            "wait 10 min, {n} chats: before {before} gh calls, after {} requests, {} charged, {} not modified, {} refreshes",
            c.requests, c.charged, c.not_modified, c.refreshes
        );
        // One refresh an interval for every waiter together (plus the one that saw it settle).
        assert!(c.refreshes <= 600 / 30 + 2, "{c:?}");
        // After the first refresh only the changed check runs are charged.
        assert!(c.charged <= READS_PER_REFRESH + 1, "{c:?}");
    }
}

/// An `Arc<Fake>` as a fetcher, so the test can flip it while the poller holds it.
struct FakeRef(Arc<Fake>);

impl Fetch for FakeRef {
    fn get<'a>(&'a self, path: &'a str, etag: Option<&'a str>) -> Fut<'a, Result<Reply, String>> {
        self.0.get(path, etag)
    }
    fn view<'a>(&'a self, repo: &'a str, number: u64) -> Fut<'a, Result<Value, String>> {
        self.0.view(repo, number)
    }
}

#[tokio::test(start_paused = true)]
async fn not_modified_is_not_charged() {
    let poller = Poller::new(Fake::default(), Config::default());
    poller.status(&key(), FRESH).await.unwrap();
    tokio::time::sleep(FRESH).await;
    let again = poller.status(&key(), FRESH).await.unwrap();
    assert_eq!(again.source, Source::Fetched);
    let c = poller.counters();
    assert_eq!(c.requests, 2 * READS_PER_REFRESH);
    assert_eq!(c.charged, READS_PER_REFRESH);
    assert_eq!(c.not_modified, READS_PER_REFRESH);
}

#[tokio::test(start_paused = true)]
async fn a_spent_budget_answers_stale_and_never_calls() {
    let cfg = Config { capacity: 4.0, refill_per_hour: 0.0, ..Config::default() };
    let poller = Poller::new(Fake::default(), cfg);
    let other = Key::new("o/r", 8);
    // No answer kept and no budget: refused, with no request.
    poller.status(&key(), FRESH).await.unwrap();
    let requests = poller.counters().requests;
    let refused = poller.status(&other, FRESH).await.unwrap_err();
    assert!(refused.message.contains("budget"), "{refused:?}");
    assert!(refused.retry_after.is_some());
    tokio::time::sleep(FRESH).await;
    let stale = poller.status(&key(), FRESH).await.unwrap();
    assert_eq!(stale.source, Source::Stale);
    assert!(stale.note.unwrap().contains("budget"));
    assert_eq!(poller.counters().requests, requests);
}

#[tokio::test(start_paused = true)]
async fn githubs_floor_holds_every_fetch() {
    let fake = Fake { remaining: Some(10), ..Fake::default() };
    let poller = Poller::new(fake, Config::default());
    poller.status(&key(), FRESH).await.unwrap();
    tokio::time::sleep(FRESH).await;
    let held = poller.status(&key(), FRESH).await.unwrap();
    assert_eq!(held.source, Source::Stale);
    assert_eq!(poller.counters().requests, READS_PER_REFRESH);
}

#[tokio::test(start_paused = true)]
async fn a_broken_rest_read_falls_back_to_pr_view() {
    let poller = Poller::new(Fake { rest_broken: true, ..Fake::default() }, Config::default());
    let a = poller.status(&key(), FRESH).await.unwrap();
    assert_eq!(a.pr["headRefOid"], HEAD);
    assert_eq!(poller.fetch.views.load(Ordering::SeqCst), 1);
    assert_eq!(poller.counters().charged, 1);
}

#[tokio::test(start_paused = true)]
async fn a_wait_times_out_at_its_deadline() {
    let poller = Poller::new(Fake::default(), Config::default());
    let start = Instant::now();
    let (answer, timed_out) =
        poller.wait(&key(), Until::Settled, start + Duration::from_secs(95)).await.unwrap();
    assert!(timed_out);
    assert!(!settled(&answer.pr));
    assert_eq!(Instant::now() - start, Duration::from_secs(95));
}

#[test]
fn rest_answers_take_the_pr_view_shape() {
    let pull = json!({
        "number": 7, "html_url": "https://github.com/o/r/pull/7", "state": "closed",
        "merged": true, "merged_at": "2026-11-23T00:00:00Z", "merge_commit_sha": "abcdef12",
        "head": {"sha": HEAD}, "base": {"ref": "main"}, "mergeable": null,
        "labels": [{"name": "hold"}], "body": "HOLD: wait",
    });
    let v = view_shape(&pull, vec![], vec![]);
    assert_eq!(v["state"], "MERGED");
    assert_eq!(v["mergeCommit"]["oid"], "abcdef12");
    assert_eq!(v["mergeable"], "UNKNOWN");
    let (text, s) = crate::acpmux_mcp::pr_state(&v);
    assert_eq!(s["status"], "ok");
    assert!(text.starts_with("#7 merged as abcdef12"), "{text}");
}

#[test]
fn include_output_parses() {
    let out = b"HTTP/2.0 304 Not Modified\r\nEtag: W/\"abc\"\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: 1700000000\r\nLink: <https://api.github.com/x?per_page=100&page=2>; rel=\"next\", <https://api.github.com/x?per_page=100&page=5>; rel=\"last\"\r\n\r\n";
    let r = parse_include(out).unwrap();
    assert_eq!(r.status, 304);
    assert_eq!(r.etag.as_deref(), Some("W/\"abc\""));
    assert_eq!(r.remaining, Some(4999));
    assert_eq!(r.reset, Some(1_700_000_000));
    assert_eq!(r.last_page, Some(5));
    assert!(r.body.is_empty());
    let ok = parse_include(b"HTTP/2.0 200 OK\nEtag: x\n\n{\"a\":1}").unwrap();
    assert_eq!(ok.body, b"{\"a\":1}");
    assert!(parse_include(b"unknown flag").is_none());
}

/// A lane VM's `gh` has no login (`gh auth login`): `pr_state` failed every call there (76 of 76
/// in 48 h, cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md). Its reads go through
/// the broker's `lane-gh call get` instead, whose answers carry no headers.
#[tokio::test]
#[cfg(unix)] // a shell-script stand-in for lane-gh
#[cfg(unix)]
async fn a_lane_vms_reads_go_through_the_broker() {
    assert!(no_login(
        "gh api gave no HTTP answer: To get started with GitHub CLI, please run:  gh auth login"
    ));
    assert!(!no_login("gh api gave no HTTP answer: HTTP 502"));
    let (repo, rest, query) =
        broker_path("repos/o/r/commits/abc/check-runs?per_page=100&page=2").unwrap();
    assert_eq!((repo.as_str(), rest.as_str()), ("o/r", "commits/abc/check-runs"));
    assert_eq!((query["per_page"].as_str(), query["page"].as_str()), ("100", "2"));
    assert!(broker_path("user").is_none());

    let dir = std::env::temp_dir().join(format!("pr-poller-broker-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let program = dir.join("lane-gh");
    // Answers as the broker does: the call's args echoed into data, a total_count of 250.
    std::fs::write(
        &program,
        "#!/bin/sh\nprintf '{\"ok\":true,\"status\":200,\"data\":{\"total_count\":250,\"args\":\"%s %s %s\"}}' \"$1\" \"$2\" \"$3\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&program, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .unwrap();
    let reply =
        broker_get(&program, "repos/o/r/commits/abc/check-runs?per_page=100&page=1").await.unwrap();
    assert_eq!((reply.status, reply.last_page), (200, Some(3)));
    let body: Value = serde_json::from_slice(&reply.body).unwrap();
    assert_eq!(body["args"], "call get o/r", "{body}");
    // GitHub's own refusal through the broker is its status, as `gh api --include` gives it.
    std::fs::write(&program, "#!/bin/sh\necho '{\"ok\":false,\"status\":404,\"data\":{\"message\":\"Not Found\"}}'; exit 1\n").unwrap();
    assert_eq!(broker_get(&program, "repos/o/r/pulls/9").await.unwrap().status, 404);
    // A broker that answers no status is the call's error, with its words.
    std::fs::write(&program, "#!/bin/sh\necho '{\"ok\":false,\"error\":\"refused: lease\"}'\n")
        .unwrap();
    let e = broker_get(&program, "repos/o/r/pulls/9").await.unwrap_err();
    assert!(e.contains("refused: lease"), "{e}");
    // Once set, every read of the fetcher goes there.
    let fetch = GhFetch::new();
    fetch.broker.set(program.clone()).unwrap();
    assert_eq!(fetch.get("repos/o/r/pulls/9", None).await.unwrap_err(), e);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A fake GitHub of repository reads: `repos/o/r/actions/runs/1` answers with ETag `r1`;
/// `repos/o/r/issues/404` answers 404; `fail` makes every read a transport failure.
#[derive(Default)]
struct Reads {
    gets: AtomicU64,
    fail: std::sync::atomic::AtomicBool,
    remaining: Option<u64>,
}

impl Fetch for Reads {
    fn get<'a>(&'a self, path: &'a str, etag: Option<&'a str>) -> Fut<'a, Result<Reply, String>> {
        Box::pin(async move {
            self.gets.fetch_add(1, Ordering::SeqCst);
            if self.fail.load(Ordering::SeqCst) {
                return Err("connection reset".to_owned());
            }
            if path.ends_with("/issues/404") {
                return Ok(Reply { status: 404, body: b"{}".to_vec(), ..Reply::default() });
            }
            let remaining = self.remaining;
            let reset = remaining.map(|_| 4_000_000_000);
            if etag == Some("r1") {
                return Ok(Reply {
                    status: 304,
                    etag: Some("r1".into()),
                    remaining,
                    reset,
                    ..Reply::default()
                });
            }
            Ok(Reply {
                status: 200,
                etag: Some("r1".into()),
                body: json!({"id": 1, "path": path}).to_string().into_bytes(),
                remaining,
                reset,
                last_page: None,
            })
        })
    }

    fn view<'a>(&'a self, _repo: &'a str, _number: u64) -> Fut<'a, Result<Value, String>> {
        Box::pin(async move { Err("not used".to_owned()) })
    }
}

const RUN: &str = "repos/O/R/actions/runs/1";

#[tokio::test(start_paused = true)]
async fn n_readers_of_one_path_cost_one_read() {
    // Before: every agent's `gh api repos/...` was its own call (gh_quota.py's per-host Python
    // cache aside). After: one GET however many read it within `fresh`.
    for n in [1_u64, 5, 20, 50] {
        let poller = Arc::new(Poller::new(Reads::default(), Config::default()));
        let mut joins = Vec::new();
        for _ in 0..n {
            let p = poller.clone();
            joins.push(tokio::spawn(async move {
                p.get(RUN, Duration::from_secs(30)).await.map(|a| a.source)
            }));
        }
        let mut fetched = 0;
        for j in joins {
            if j.await.expect("join").expect("answer") == Source::Fetched {
                fetched += 1;
            }
        }
        assert_eq!(poller.fetch.gets.load(Ordering::SeqCst), 1, "{n} readers");
        assert_eq!(fetched, 1);
        assert_eq!(poller.counters().cache_hits, n - 1);
    }
}

#[tokio::test(start_paused = true)]
async fn a_reread_past_fresh_is_a_free_304() {
    let poller = Poller::new(Reads::default(), Config::default());
    let first = poller.get(RUN, Duration::from_secs(30)).await.expect("first");
    tokio::time::advance(Duration::from_secs(31)).await;
    let second = poller.get(RUN, Duration::from_secs(30)).await.expect("second");
    assert_eq!(second.source, Source::Fetched);
    assert_eq!(second.pr, first.pr);
    let c = poller.counters();
    assert_eq!((c.requests, c.charged, c.not_modified), (2, 1, 1));
}

#[tokio::test(start_paused = true)]
async fn the_path_is_the_key_whatever_its_case_or_prefix() {
    let poller = Poller::new(Reads::default(), Config::default());
    poller.get(RUN, Duration::from_secs(30)).await.expect("first");
    for same in ["/repos/o/r/actions/runs/1", "https://api.github.com/repos/O/r/actions/runs/1"] {
        let a = poller.get(same, Duration::from_secs(30)).await.expect(same);
        assert_eq!(a.source, Source::Cache, "{same}");
    }
    assert_eq!(poller.fetch.gets.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_spent_budget_answers_kept_bodies_stale_and_refuses_new_ones() {
    let cfg = Config { capacity: 1.0, refill_per_hour: 1.0, ..Config::default() };
    let poller = Poller::new(Reads::default(), cfg);
    poller.get(RUN, Duration::from_secs(30)).await.expect("first");
    tokio::time::advance(Duration::from_secs(60)).await;
    let kept = poller.get(RUN, Duration::from_secs(30)).await.expect("kept");
    assert_eq!(kept.source, Source::Stale);
    assert!(kept.note.as_deref().unwrap_or_default().contains("budget is spent"));
    let other = poller.get("repos/o/r/issues/5", Duration::from_secs(30)).await;
    let refusal = other.expect_err("nothing kept");
    assert!(refusal.retry_after.is_some());
    assert_eq!(poller.fetch.gets.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_failed_read_answers_kept_stale_but_a_4xx_refuses_and_drops_it() {
    let poller = Poller::new(Reads::default(), Config::default());
    poller.get(RUN, Duration::from_secs(30)).await.expect("first");
    poller.fetch.fail.store(true, Ordering::SeqCst);
    tokio::time::advance(Duration::from_secs(31)).await;
    let kept = poller.get(RUN, Duration::from_secs(30)).await.expect("stale");
    assert_eq!(kept.source, Source::Stale);
    assert_eq!(kept.note.as_deref(), Some("connection reset"));
    poller.fetch.fail.store(false, Ordering::SeqCst);
    let gone = poller.get("repos/o/r/issues/404", Duration::from_secs(30)).await;
    let refusal = gone.expect_err("404");
    assert!(refusal.message.contains("HTTP 404"));
    assert_eq!(refusal.retry_after, None);
}

#[test]
fn read_path_takes_repository_reads_only() {
    assert_eq!(
        read_path("/repos/Man/Cmux/pulls/1?per_page=5").as_deref(),
        Ok("repos/man/cmux/pulls/1?per_page=5")
    );
    for bad in [
        "",
        "graphql",
        "search/issues?q=x",
        "user",
        "repos/o/r",
        "repos/o/r/",
        "repos/../r/x",
        "repos/o/r/a/../../b",
        "repos/o/r/a b",
        "repos/o/r/x#y",
        "repos/o$/r/x",
    ] {
        assert!(read_path(bad).is_err(), "{bad}");
    }
}

#[tokio::test(start_paused = true)]
async fn github_s_floor_holds_reads_too() {
    let reads = Reads { remaining: Some(10), ..Reads::default() };
    let poller = Poller::new(reads, Config::default());
    poller.get(RUN, Duration::from_secs(30)).await.expect("first");
    let other = poller.get("repos/o/r/issues/9", Duration::from_secs(30)).await;
    assert!(other.is_err(), "under GitHub's floor nothing new is fetched");
    assert_eq!(poller.fetch.gets.load(Ordering::SeqCst), 1);
}
