//! `git-seed-hold-v2`: a copy this Mac streams in opens at its head under the machine's hold of
//! the folder's sync barrier, while every tool waits for the whole folder; a copy that ends short
//! or goes quiet leaves the folder failed, never ready.

use cmux_git::sync_barrier::{Probe, probe};

use super::*;

fn service(home: &Home) -> GitSeedService {
    GitSeedService::new(Roots::new([home.path.clone()]))
}

fn hold(service: &GitSeedService, folder: &Path, extra: Value) -> Result<String, SeedRefusal> {
    let mut params = json!({ "folder": folder });
    params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    service.call("git.seed.hold", &params).map(|answer| answer["job"].as_str().unwrap().to_owned())
}

fn status(service: &GitSeedService, job: &str) -> Value {
    service.call("git.seed.status", &json!({ "job": job })).unwrap()
}

fn state(folder: &Path) -> &'static str {
    match probe(folder).unwrap() {
        Probe::Ready(_) => "ready",
        Probe::HeadReady => "head",
        Probe::Syncing => "syncing",
        Probe::Incomplete => "incomplete",
    }
}

/// The barrier's state once it reads `want`, or its last state after 30 s. A released lock can read
/// held for a moment while another test's forked child still holds a copy of its descriptor before
/// it execs, so a test waits out a release (a take never lags). Reading the barrier renews no lease.
fn settles(folder: &Path, want: &str) -> &'static str {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let now = state(folder);
        if now == want || Instant::now() >= deadline {
            return now;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_held_copy_opens_at_its_head_and_reads_ready_only_once_it_ends() {
    let home = Home::new("hold-whole");
    let service = service(&home);
    let folder = home.join("work/notes");
    let job = hold(&service, &folder, json!({ "subpath": "app" })).unwrap();
    assert_eq!(state(&folder), "syncing", "nothing the copy writes reads ready");
    write(&folder.join("CLAUDE.md"), "notes\n");
    write(&folder.join(".claude/agents/a.md"), "a\n");
    // The chat's folder is not there yet: no start may open in it.
    let early = service.call("git.seed.hold.head", &json!({ "job": job })).unwrap();
    assert_eq!(early["head_ready"], false, "{early}");
    write(&folder.join("app/AGENTS.md"), "app\n");
    let head = service.call("git.seed.hold.head", &json!({ "job": job })).unwrap();
    assert_eq!(head["head_ready"], true, "{head}");
    assert_eq!(settles(&folder, "head"), "head");
    assert_eq!(status(&service, &job)["head_ready"], true);
    assert_eq!(status(&service, &job)["phase"], "copy");
    write(&folder.join("src/main.py"), "print('hi')\n");
    let end = service.call("git.seed.hold.end", &json!({ "job": job, "ok": true })).unwrap();
    assert_eq!(end["state"], "done", "{end}");
    assert_eq!(settles(&folder, "ready"), "ready");
}

#[test]
fn a_head_that_would_start_mcp_servers_or_hooks_is_never_marked() {
    for settings in [".mcp.json", ".claude/settings.json", "app/.mcp.json"] {
        let home = Home::new("hold-settings");
        let service = service(&home);
        let folder = home.join("work/notes");
        let job = hold(&service, &folder, json!({ "subpath": "app" })).unwrap();
        write(&folder.join("app/AGENTS.md"), "app\n");
        write(&folder.join(settings), "{}\n");
        let head = service.call("git.seed.hold.head", &json!({ "job": job })).unwrap();
        assert_eq!(head["head_ready"], false, "{settings}");
        assert_eq!(state(&folder), "syncing", "{settings}");
        service.call("git.seed.hold.end", &json!({ "job": job, "ok": true })).unwrap();
        assert_eq!(settles(&folder, "ready"), "ready", "{settings}");
    }
}

#[test]
fn a_copy_that_ends_short_leaves_its_folder_failed() {
    let home = Home::new("hold-short");
    let service = service(&home);
    let folder = home.join("work/notes");
    let job = hold(&service, &folder, json!({})).unwrap();
    write(&folder.join("README.md"), "r\n");
    service.call("git.seed.hold.head", &json!({ "job": job })).unwrap();
    let end = service.call("git.seed.hold.end", &json!({ "job": job, "ok": false })).unwrap();
    assert_eq!(end["state"], "failed", "{end}");
    assert_eq!(end["error_code"], "seed.copy_failed");
    assert_eq!(settles(&folder, "incomplete"), "incomplete");
    let again = service.call("git.seed.hold.end", &json!({ "job": job, "ok": true })).unwrap_err();
    assert_eq!(again.code, "seed.unknown_job", "an ended hold cannot be ended ready");
    assert_eq!(state(&folder), "incomplete");
    // The copy's retry holds the failed folder again, files and all, and repairs it.
    let retry = hold(&service, &folder, json!({ "key": "retry" })).unwrap();
    assert_eq!(settles(&folder, "syncing"), "syncing");
    service.call("git.seed.hold.end", &json!({ "job": retry, "ok": true })).unwrap();
    assert_eq!(settles(&folder, "ready"), "ready");
    // A folder whose sync is whole is the machine's again: no hold stands over it.
    assert_eq!(hold(&service, &folder, json!({})).unwrap_err().code, "seed.folder_not_empty");
}

#[test]
fn a_hold_whose_copy_goes_quiet_expires_failed_and_a_status_read_keeps_it() {
    let home = Home::new("hold-lease");
    let service = service(&home);
    let kept = home.join("work/kept");
    let job = hold(&service, &kept, json!({ "lease_ms": 200 })).unwrap();
    // Reads closer together than the lease keep it past several leases.
    for _ in 0..12 {
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(status(&service, &job)["state"], "running");
    }
    let quiet = home.join("work/quiet");
    let gone = hold(&service, &quiet, json!({ "lease_ms": 100 })).unwrap();
    // Only the barrier is read while the lease runs out: a status read would renew it.
    assert_eq!(settles(&quiet, "incomplete"), "incomplete");
    let answer = status(&service, &gone);
    assert_eq!(answer["state"], "failed", "{answer}");
    assert_eq!(answer["error_code"], "seed.hold_expired");
    let late = service.call("git.seed.hold.head", &json!({ "job": gone })).unwrap_err();
    assert_eq!(late.code, "seed.unknown_job");
    service.call("git.seed.hold.end", &json!({ "job": job, "ok": true })).unwrap();
    assert_eq!(settles(&kept, "ready"), "ready");
}

#[test]
fn a_hold_takes_only_a_new_folder_and_a_retry_gets_its_job() {
    let home = Home::new("hold-place");
    let service = service(&home);
    let used = home.join("work/used");
    write(&used.join("x"), "x\n");
    assert_eq!(hold(&service, &used, json!({})).unwrap_err().code, "seed.folder_not_empty");
    let outside = home.path.parent().unwrap().join("elsewhere");
    let refused = hold(&service, &outside, json!({})).unwrap_err();
    assert_eq!(refused.code, "seed.bad_request");
    assert!(refused.message.contains("outside the folders"), "{}", refused.message);
    let folder = home.join("work/notes");
    let job = hold(&service, &folder, json!({ "key": "send-1" })).unwrap();
    assert_eq!(hold(&service, &folder, json!({ "key": "send-1" })).unwrap(), job);
    write(&folder.join("README.md"), "r\n");
    assert_eq!(
        hold(&service, &folder, json!({ "key": "send-2" })).unwrap_err().code,
        "seed.bad_request",
        "another copy of a held folder is refused"
    );
    service.call("git.seed.hold.head", &json!({ "job": job })).unwrap();
    let nested = folder.join("inner");
    let refused = hold(&service, &nested, json!({})).unwrap_err();
    assert_eq!(refused.code, "seed.bad_request");
    assert!(refused.message.contains("another seed's folder"), "{}", refused.message);
    assert_eq!(
        hold(&service, &folder, json!({ "key": "send-2" })).unwrap_err().code,
        "seed.filling",
        "a held folder at its head says it is filling"
    );
    service.call("git.seed.hold.end", &json!({ "job": job, "ok": true })).unwrap();
    assert_eq!(settles(&folder, "ready"), "ready");

    // A done hold is never a retry: the same key on the folder again (emptied since) takes a
    // new hold, so the old one's ready barrier never stands over the new copy.
    // (The nested hold's refusal made `inner` on its way.)
    for entry in std::fs::read_dir(&folder).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            std::fs::remove_dir_all(&path).unwrap();
        } else {
            std::fs::remove_file(&path).unwrap();
        }
    }
    let again = hold(&service, &folder, json!({ "key": "send-1" })).unwrap();
    assert_ne!(again, job, "a new hold, not the done one");
    assert_eq!(settles(&folder, "syncing"), "syncing");
    // Nor is a hold with no key, even beside another with none.
    assert_eq!(
        hold(&service, &folder, json!({})).unwrap_err().code,
        "seed.bad_request",
        "a keyless hold of a held folder is refused, never handed the running one"
    );
    service.call("git.seed.hold.end", &json!({ "job": again, "ok": true })).unwrap();
    // And over a folder with files a done hold's key is refused, not answered with its job.
    write(&folder.join("README.md"), "r\n");
    assert_eq!(
        hold(&service, &folder, json!({ "key": "send-1" })).unwrap_err().code,
        "seed.folder_not_empty"
    );
}

#[test]
fn the_hold_ops_are_framed_and_advertised_under_their_own_capability() {
    for cmd in GIT_SEED_HOLD_COMMANDS {
        assert_eq!(frame_command(&json!({ "cmd": cmd, "id": 1 }).to_string()), Some(cmd));
    }
    assert_eq!(frame_command(r#"{"cmd":"git.seed.hold.renew"}"#), None);
    let home = Home::new("hold-envelope");
    let service = service(&home);
    let folder = home.join("work/notes");
    let line = json!({ "cmd": "git.seed.hold", "id": 7, "folder": folder }).to_string();
    let answer = answer_line(Some(&service), true, &line);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["id"], 7);
    let job = answer["data"]["job"].as_str().unwrap();
    let denied = answer_line(
        Some(&service),
        false,
        &json!({ "cmd": "git.seed.hold.end", "id": 8, "job": job, "ok": true }).to_string(),
    );
    assert_eq!(denied["error_code"], "seed.permission_denied");
    assert_eq!(state(&folder), "syncing", "a denied end changes nothing");
    service.call("git.seed.hold.end", &json!({ "job": job, "ok": false })).unwrap();
}

#[test]
fn a_write_that_names_its_hold_lands_only_while_the_hold_runs() {
    let home = Home::new("hold-fenced-write");
    let service = service(&home);
    let folder = home.join("work/notes");
    let job = hold(&service, &folder, json!({ "lease_ms": 100 })).unwrap();
    std::fs::create_dir_all(&folder).unwrap();
    let write_one = |name: &str| {
        let request = json!({ "hold": job, "path": folder.join(name) });
        let request = request.as_object().cloned().unwrap();
        held_op(Some(&service), &json!(1), request, |request| {
            assert!(!request.contains_key("hold"), "the op itself never sees the hold");
            std::fs::write(folder.join(name), "x").unwrap();
            Ok(json!({}))
        })
    };
    assert_eq!(write_one("a.md")["ok"], true);
    // The lease runs out; a write sent before it and read after lands nowhere.
    assert_eq!(settles(&folder, "incomplete"), "incomplete");
    let late = write_one("late.md");
    assert_eq!(late["error_code"], "seed.unknown_job", "{late}");
    assert!(!folder.join("late.md").exists());
    // An op that names no hold runs as it is; one naming no running hold never runs.
    let plain = held_op(Some(&service), &json!(2), Default::default(), |_| Ok(json!({})));
    assert_eq!(plain["ok"], true);
    let unknown = json!({ "hold": "nope" }).as_object().cloned().unwrap();
    let refused = held_op(Some(&service), &json!(3), unknown, |_| panic!("never runs"));
    assert_eq!(refused["error_code"], "seed.unknown_job");
}

#[test]
fn a_hold_waits_out_a_write_in_flight_before_its_lease_ends_it() {
    let home = Home::new("hold-write-in-flight");
    let service = service(&home);
    let folder = home.join("work/notes");
    let job = hold(&service, &folder, json!({ "lease_ms": 100 })).unwrap();
    std::fs::create_dir_all(&folder).unwrap();
    let (started, wait_started) = std::sync::mpsc::channel();
    let (finish, wait_finish) = std::sync::mpsc::channel::<()>();
    std::thread::scope(|scope| {
        let request = json!({ "hold": job }).as_object().cloned().unwrap();
        let (service, folder) = (&service, &folder);
        let writer = scope.spawn(move || {
            held_op(Some(service), &json!(1), request, move |_| {
                started.send(()).unwrap();
                wait_finish.recv().unwrap();
                std::fs::write(folder.join("slow.md"), "x").unwrap();
                Ok(json!({}))
            })
        });
        wait_started.recv().unwrap();
        // Well past the lease: the hold may not end while the write is in flight.
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(state(folder), "syncing", "the barrier stays until the write lands");
        finish.send(()).unwrap();
        assert_eq!(writer.join().unwrap()["ok"], true);
    });
    assert_eq!(settles(&folder, "incomplete"), "incomplete");
}
