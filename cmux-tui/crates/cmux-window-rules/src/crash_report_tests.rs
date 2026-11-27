use serde_json::json;

use super::*;

fn file(name: &str, modified_ms: Option<i64>) -> Listed {
    Listed { name: name.into(), modified_ms, folder: false }
}

fn writer() -> Writer {
    Writer { bundle_id: "com.cmuxterm.app.next".into(), version: "0.9 412".into() }
}

#[test]
fn a_file_name_part_keeps_letters_digits_dots_and_dashes() {
    assert_eq!(safe("com.cmuxterm.app.next"), "com.cmuxterm.app.next");
    assert_eq!(safe("chromium-gpu process/1"), "chromium-gpu_process_1");
    assert_eq!(safe("ünïcödé-٣"), "ünïcödé-٣");
    assert_eq!(safe(""), "");
}

#[test]
fn a_report_is_named_by_bundle_name_and_local_stamp() {
    let date = Stamp { year: 2026, month: 3, day: 7, hour: 4, minute: 5, second: 6, millis: 9 };
    assert_eq!(stamp(&date), "20260307-040506-009");
    assert_eq!(
        file_name("com.cmuxterm.app.next", "chromium-renderer", &date),
        "com.cmuxterm.app.next-chromium-renderer-20260307-040506-009.json"
    );
    assert_eq!(file_name("a b", "x/y", &Stamp::default()), "a_b-x_y-00000000-000000-000.json");
}

#[test]
fn prune_drops_the_oldest_reports_past_the_limit() {
    let files = vec![
        file("c.json", Some(30)),
        file("a.json", Some(10)),
        file("notes.txt", Some(0)),
        file("b.json", None),
        file(".json", Some(0)),
        file("d.json", Some(40)),
    ];
    // An undated report is the oldest; non-reports never count.
    assert_eq!(prune(&files, 2), vec!["b.json", "a.json"]);
    assert_eq!(prune(&files, 4), Vec::<String>::new());
    assert_eq!(prune(&files, 3), vec!["b.json"]);
    assert_eq!(prune(&[], RETAIN), Vec::<String>::new());
}

#[test]
fn the_system_log_is_the_newest_of_this_executable_since_launch() {
    let files = vec![
        file("cmux-next-2026-11-26-010000.ips", Some(100)),
        file("cmux-next-2026-11-26-020000.ips", Some(300)),
        file("cmux-next-helper-2026.ips", Some(900)),
        file("cmux-next-2026.txt", Some(950)),
        file("other-2026.ips", Some(999)),
    ];
    // `cmux-next-helper-…` starts with `cmux-next-` too, as Swift's prefix check reads it.
    assert_eq!(system_log(&files, "cmux-next", 200), Some("cmux-next-helper-2026.ips".into()));
    assert_eq!(
        system_log(&files[..2], "cmux-next", 200),
        Some("cmux-next-2026-11-26-020000.ips".into())
    );
    assert_eq!(system_log(&files[..2], "cmux-next", 301), None);
    // At the launch instant still counts.
    assert_eq!(
        system_log(&files[..2], "cmux-next", 300),
        Some("cmux-next-2026-11-26-020000.ips".into())
    );
}

#[test]
fn a_tie_keeps_the_first_listed() {
    let files = vec![file("x-1.ips", Some(5)), file("x-2.ips", Some(5))];
    assert_eq!(system_log(&files, "x", 0), Some("x-1.ips".into()));
}

#[test]
fn show_crash_logs_opens_in_order() {
    let system = vec![file("cmux-next-1.ips", Some(1))];
    let reports = vec![file("r.json", Some(1)), file("r.txt", Some(9))];
    assert_eq!(
        log_target(true, true, &system, &reports, "cmux-next"),
        LogTarget::PreviousSystemLog
    );
    assert_eq!(log_target(false, true, &system, &reports, "cmux-next"), LogTarget::PreviousReport);
    assert_eq!(
        log_target(false, false, &system, &reports, "cmux-next"),
        LogTarget::SystemLog { name: "cmux-next-1.ips".into() }
    );
    assert_eq!(
        log_target(false, false, &system, &reports, "other"),
        LogTarget::Report { name: "r.json".into() }
    );
    assert_eq!(log_target(false, false, &[], &reports[1..], "cmux-next"), LogTarget::Folder);
}

#[test]
fn the_version_joins_short_and_build() {
    assert_eq!(version(Some("0.9"), Some("412")), "0.9 412");
    assert_eq!(version(None, Some("412")), "412");
    assert_eq!(version(Some("0.9"), None), "0.9");
    assert_eq!(version(None, None), "unknown");
}

#[test]
fn a_chromium_report_holds_only_what_it_has() {
    let record = Chromium {
        date: "2026-11-26T02:00:00.000Z".into(),
        process_type: "renderer".into(),
        reason: "crashed".into(),
        source: "engine".into(),
        sub_type: None,
        pid: None,
        code: None,
        code_text: None,
        tab: None,
    };
    let (object, name) = chromium_report(&record, &writer());
    assert_eq!(name, "chromium-renderer");
    assert_eq!(
        object,
        json!({
            "kind": "chromium", "date": "2026-11-26T02:00:00.000Z", "process_type": "renderer",
            "reason": "crashed", "source": "engine", "bundle_id": "com.cmuxterm.app.next", "version": "0.9 412",
        })
    );
    let full = Chromium {
        sub_type: Some("gpu".into()),
        pid: Some(42),
        code: Some(11),
        code_text: Some("SIGSEGV".into()),
        tab: Some("tab-1".into()),
        ..record
    };
    let (object, _) = chromium_report(&full, &writer());
    assert_eq!(object["sub_type"], "gpu");
    assert_eq!(object["pid"], 42);
    assert_eq!(object["code"], 11);
    assert_eq!(object["code_text"], "SIGSEGV");
    assert_eq!(object["tab"], "tab-1");
}

fn crash() -> AppCrash {
    AppCrash {
        launched: "L".into(),
        found: "F".into(),
        pid: 7,
        recovery: true,
        survived: false,
        signal: None,
        signal_name: None,
        exception: None,
        pages_held: 2,
        system_report: None,
    }
}

#[test]
fn an_app_report_without_signal_or_exception() {
    assert_eq!(
        app_report(&crash(), &writer()),
        json!({
            "kind": "app", "launched": "L", "found": "F", "pid": 7, "was_restart": true,
            "lived_past_quick_window": false, "bundle_id": "com.cmuxterm.app.next", "version": "0.9 412",
            "browser_pages_held": 2,
        })
    );
}

#[test]
fn an_app_report_names_its_signal_exception_and_system_report() {
    let named = AppCrash {
        signal: Some(11),
        signal_name: Some("SIGSEGV".into()),
        exception: Some(Exception {
            name: "NSRangeException".into(),
            reason: Some("index 3".into()),
            frames: vec!["f0".into()],
        }),
        system_report: Some("/x/cmux-next-1.ips".into()),
        ..crash()
    };
    let object = app_report(&named, &writer());
    assert_eq!(object["signal"], 11);
    assert_eq!(object["signal_name"], "SIGSEGV");
    assert_eq!(object["exception_name"], "NSRangeException");
    assert_eq!(object["exception_reason"], "index 3");
    assert_eq!(object["exception_frames"], json!(["f0"]));
    assert_eq!(object["system_report"], "/x/cmux-next-1.ips");
    // A signal with no name is its number.
    let unnamed = AppCrash { signal: Some(99), ..crash() };
    assert_eq!(app_report(&unnamed, &writer())["signal_name"], "99");
    // An exception with no reason leaves the key out.
    let bare = AppCrash {
        exception: Some(Exception { name: "E".into(), reason: None, frames: vec![] }),
        ..crash()
    };
    let object = app_report(&bare, &writer());
    assert!(object.get("exception_reason").is_none());
    assert_eq!(object["exception_frames"], json!([]));
}

#[test]
fn scrub_hides_the_home_folder() {
    assert_eq!(scrub("/Users/me/x and /Users/me/y", "/Users/me"), "~/x and ~/y");
    assert_eq!(scrub("/Users/me/x", ""), "/Users/me/x");
}

#[test]
fn the_cause_is_the_exception_else_the_signal() {
    assert_eq!(
        cause(Some("E: at /Users/me/a"), Some(11), Some("SIGSEGV"), "/Users/me"),
        Some("E: at ~/a".into())
    );
    assert_eq!(cause(None, Some(11), Some("SIGSEGV"), "/h"), Some("SIGSEGV".into()));
    assert_eq!(cause(None, Some(99), None, "/h"), Some("signal 99".into()));
    assert_eq!(cause(None, None, Some("SIGSEGV"), "/h"), None);
}

#[test]
fn the_notice_cause_is_cut_past_eighty() {
    let eighty = "x".repeat(80);
    assert_eq!(notice_cause(&eighty), eighty);
    let long = "é".repeat(81);
    let cut = notice_cause(&long);
    assert_eq!(cut.chars().count(), 80);
    assert!(cut.ends_with("é…"));
}

#[test]
fn the_crashed_build_prefers_the_marker() {
    assert_eq!(
        crashed_build(Some("0.8"), Some("abc"), Some("0.7"), "0.9", Some("def")),
        CrashedBuild { version: "0.8".into(), commit: Some("abc".into()) }
    );
    // An old marker: macOS's report names the version; a different build gets no commit.
    assert_eq!(
        crashed_build(None, None, Some("0.7"), "0.9", Some("def")),
        CrashedBuild { version: "0.7".into(), commit: None }
    );
    // Neither: this build, with its commit.
    assert_eq!(
        crashed_build(None, None, None, "0.9", Some("def")),
        CrashedBuild { version: "0.9".into(), commit: Some("def".into()) }
    );
    // The marker's version is this build's: its commit.
    assert_eq!(
        crashed_build(Some("0.9"), None, None, "0.9", None),
        CrashedBuild { version: "0.9".into(), commit: None }
    );
}

#[test]
fn the_wire_shapes() {
    let listed: Listed = serde_json::from_value(json!({"name": "a.json"})).unwrap();
    assert_eq!(listed, file("a.json", None));
    let date: Stamp = serde_json::from_value(json!({"year": 2026})).unwrap();
    assert_eq!(date.year, 2026);
    assert_eq!(
        serde_json::to_value(LogTarget::SystemLog { name: "x".into() }).unwrap(),
        json!({"kind": "systemLog", "name": "x"})
    );
    assert_eq!(serde_json::to_value(LogTarget::Folder).unwrap(), json!({"kind": "folder"}));
}
