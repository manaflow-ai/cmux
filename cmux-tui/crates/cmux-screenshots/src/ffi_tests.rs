use super::*;
use std::ffi::CStr;

fn take(ptr: *mut c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: a string from this library.
    let s = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
    // SAFETY: freed once.
    unsafe { cmux_screenshots_string_free(ptr) };
    Some(s)
}

#[test]
fn small_functions_answer() {
    let url = "CMUX://screenshots";
    // SAFETY: valid bytes.
    assert!(unsafe { cmux_screenshots_page_matches(url.as_ptr(), url.len()) });
    // SAFETY: null is allowed.
    assert!(!unsafe { cmux_screenshots_page_matches(std::ptr::null(), 0) });
    let key = "exportPath";
    // SAFETY: valid bytes.
    assert!(unsafe { cmux_screenshots_looks_like_folder_key(key.as_ptr(), key.len()) });
    assert_eq!(
        take(cmux_screenshots_dropped_name(2026, 11, 26, 9, 5, 3)),
        Some("Dropped Image 2026-11-26 at 09.05.03.png".into())
    );
    let (c, n) = ("a.png", " a.png ");
    // SAFETY: valid bytes.
    assert_eq!(
        take(unsafe { cmux_screenshots_rename_target(c.as_ptr(), c.len(), n.as_ptr(), n.len()) }),
        None
    );
}

#[test]
fn origins_that_take_drops_and_what_an_open_run_hears() {
    for (origin, drops) in [
        ("system", true),
        ("custom", true),
        ("tool", true),
        ("systemPreview", false),
        ("toolHistory", false),
        ("nope", false),
    ] {
        // SAFETY: valid bytes.
        assert_eq!(
            unsafe { cmux_screenshots_origin_accepts_drops(origin.as_ptr(), origin.len()) },
            drops,
            "{origin}"
        );
    }
    // SAFETY: null is allowed.
    assert!(!unsafe { cmux_screenshots_origin_accepts_drops(std::ptr::null(), 0) });
    let told = |persons_run, existing, listing| {
        let answer = cmux_screenshots_open(persons_run, existing, listing);
        (answer.opened, answer.listing, answer.note)
    };
    assert_eq!(told(true, true, true), (0, false, 0));
    assert_eq!(told(false, false, true), (1, false, 1));
    assert_eq!(told(false, true, true), (2, true, 0));
    assert_eq!(told(false, true, false), (2, false, 2));
}

#[test]
fn rule_handle_reads_detect_json() {
    let json = r#"{"kinds":2,"namePrefixes":["Screen Recording"],"extraImageExtensions":["SNAGX"],"depth":1,"folderPrefix":"m_"}"#;
    // SAFETY: valid bytes.
    let rule = unsafe { cmux_screenshots_rule_new(json.as_ptr(), json.len()) };
    assert!(!rule.is_null());
    let movie = "Screen Recording 1.mov";
    // SAFETY: live rule, valid bytes.
    assert_eq!(
        unsafe { cmux_screenshots_rule_item_kind(rule, 1, false, movie.as_ptr(), movie.len(), 2) },
        2
    );
    // SAFETY: as above.
    assert_eq!(
        unsafe { cmux_screenshots_rule_item_kind(rule, 1, true, movie.as_ptr(), movie.len(), 2) },
        0
    );
    // SAFETY: freed once.
    unsafe { cmux_screenshots_rule_free(rule) };
    let bad = "[]";
    // SAFETY: valid bytes.
    let none = unsafe { cmux_screenshots_rule_new(bad.as_ptr(), bad.len()) };
    // A JSON array has no fields: every field takes its default.
    assert!(!none.is_null());
    // SAFETY: freed once.
    unsafe { cmux_screenshots_rule_free(none) };
    let junk = "nope";
    // SAFETY: valid bytes.
    assert!(unsafe { cmux_screenshots_rule_new(junk.as_ptr(), junk.len()) }.is_null());
}

#[test]
fn listing_handle_keeps_order_and_filters() {
    let listing = cmux_screenshots_listing_new();
    let paths = ["/s/a/Shot 10.png", "/s/a/Shot 2.png", "/s/b/Café.png"];
    let items: Vec<CmuxScreenshotsItem> = paths[..2]
        .iter()
        .map(|p| CmuxScreenshotsItem {
            path: p.as_ptr(),
            path_len: p.len(),
            kind: 1,
            size: 1,
            modified: 5.0,
        })
        .collect();
    // SAFETY: live listing, valid items.
    unsafe {
        cmux_screenshots_listing_replace(listing, b"a".as_ptr(), 1, items.as_ptr(), items.len());
    };
    // SAFETY: live listing, valid bytes.
    unsafe {
        cmux_screenshots_listing_upsert(
            listing,
            paths[2].as_ptr(),
            paths[2].len(),
            1,
            1,
            9.0,
            b"b".as_ptr(),
            1,
        );
    };
    // SAFETY: live listing.
    assert_eq!(unsafe { cmux_screenshots_listing_count(listing) }, 3);
    let order: Vec<String> = (0..3)
        .map(|i| {
            let mut len = 0;
            // SAFETY: live listing, writable len.
            let ptr = unsafe { cmux_screenshots_listing_path_at(listing, i, &raw mut len) };
            // SAFETY: lent bytes.
            String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) }).into_owned()
        })
        .collect();
    assert_eq!(order, ["/s/b/Café.png", "/s/a/Shot 2.png", "/s/a/Shot 10.png"]);
    // SAFETY: live listing.
    let counts: serde_json::Value =
        serde_json::from_str(&take(unsafe { cmux_screenshots_listing_counts(listing) }).unwrap())
            .unwrap();
    assert_eq!(counts, serde_json::json!({"a": 2, "b": 1}));
    // SAFETY: null is allowed.
    assert!(unsafe { cmux_screenshots_listing_counts(std::ptr::null()) }.is_null());
    // SAFETY: live listing; past the end gives null.
    assert!(
        unsafe { cmux_screenshots_listing_path_at(listing, 3, std::ptr::null_mut()) }.is_null()
    );
    let mut found = [0usize; 4];
    // SAFETY: live listing, valid bytes, writable buffer.
    let n = unsafe {
        cmux_screenshots_listing_filter(
            listing,
            b"CAFE".as_ptr(),
            4,
            std::ptr::null(),
            0,
            found.as_mut_ptr(),
            4,
        )
    };
    assert_eq!((n, found[0]), (1, 0));
    // SAFETY: as above.
    let n = unsafe {
        cmux_screenshots_listing_filter(
            listing,
            std::ptr::null(),
            0,
            b"a".as_ptr(),
            1,
            found.as_mut_ptr(),
            1,
        )
    };
    assert_eq!((n, found[0]), (2, 1));
    // SAFETY: live listing, valid bytes.
    assert_eq!(
        unsafe { cmux_screenshots_listing_position(listing, paths[0].as_ptr(), paths[0].len()) },
        2
    );
    // SAFETY: as above.
    unsafe { cmux_screenshots_listing_remove(listing, paths[0].as_ptr(), paths[0].len()) };
    // SAFETY: as above.
    assert_eq!(
        unsafe { cmux_screenshots_listing_position(listing, paths[0].as_ptr(), paths[0].len()) },
        -1
    );
    // SAFETY: drops source a.
    unsafe { cmux_screenshots_listing_replace(listing, b"a".as_ptr(), 1, std::ptr::null(), 0) };
    // SAFETY: live listing.
    assert_eq!(unsafe { cmux_screenshots_listing_count(listing) }, 1);
    // SAFETY: freed once.
    unsafe { cmux_screenshots_listing_free(listing) };
}

#[test]
fn newest_picture_and_gate() {
    let names = ["a.png", "b.mov", "c.png"];
    let entries: Vec<CmuxScreenshotsEntry> = names
        .iter()
        .zip([(1, 1.0), (2, 9.0), (1, 3.0)])
        .map(|(n, (k, m))| CmuxScreenshotsEntry {
            kind: 1,
            hidden: false,
            name: n.as_ptr(),
            name_len: n.len(),
            system_kind: k,
            modified: m,
        })
        .collect();
    // SAFETY: valid entries.
    assert_eq!(unsafe { cmux_screenshots_newest_picture(entries.as_ptr(), entries.len()) }, 2);
    // SAFETY: null allowed.
    assert_eq!(unsafe { cmux_screenshots_newest_picture(std::ptr::null(), 0) }, -1);
    let gate = cmux_screenshots_gate_new();
    // SAFETY: live gate, valid bytes.
    unsafe {
        assert!(!cmux_screenshots_gate_may_detect(gate));
        assert!(cmux_screenshots_gate_starts_when_shown(gate, b"p".as_ptr(), 1, true));
        cmux_screenshots_gate_unlock(gate, b"p".as_ptr(), 1);
        assert!(cmux_screenshots_gate_may_detect(gate));
        assert!(cmux_screenshots_gate_is_unlocked(gate, b"p".as_ptr(), 1));
        assert!(!cmux_screenshots_gate_starts_when_shown(gate, b"p".as_ptr(), 1, true));
        cmux_screenshots_gate_free(gate);
    }
}

/// A C-style environment: every folder below `/mac/` exists, one preference is set.
unsafe extern "C" fn pref(
    _: *mut c_void,
    d: *const u8,
    dl: usize,
    k: *const u8,
    kl: usize,
    r: *mut CmuxScreenshotsReply,
) {
    // SAFETY: the library passes readable strings.
    let (d, k) = unsafe { (text(d, dl), text(k, kl)) };
    if d == "com.apple.screencapture" && k == "location" {
        let v = "~/Shots";
        // SAFETY: the reply we were given.
        unsafe { cmux_screenshots_reply_set(r, v.as_ptr(), v.len()) };
    }
}

unsafe extern "C" fn is_dir(_: *mut c_void, p: *const u8, pl: usize) -> bool {
    // SAFETY: the library passes readable strings.
    let p = unsafe { text(p, pl) };
    p == "/mac/home/Shots" || p == "/mac/tmp/TemporaryItems" || p == "/mac/home/Mine"
}

#[test]
fn detect_calls_back_and_returns_json() {
    let env = CmuxScreenshotsEnvironment {
        context: std::ptr::null_mut(),
        preference: Some(pref),
        string_preferences: None,
        text: None,
        is_directory: Some(is_dir),
        real_path: None,
    };
    let (home, tmp, extra) = ("/mac/home", "/mac/tmp", r#"["~/Mine"]"#);
    // SAFETY: a live environment and valid bytes.
    let json = take(unsafe {
        cmux_screenshots_detect(
            &raw const env,
            home.as_ptr(),
            home.len(),
            tmp.as_ptr(),
            tmp.len(),
            true,
            extra.as_ptr(),
            extra.len(),
        )
    })
    .expect("json");
    let value: serde_json::Value = serde_json::from_str(&json).expect("valid json");
    let ids: Vec<&str> =
        value.as_array().expect("array").iter().filter_map(|s| s["id"].as_str()).collect();
    assert_eq!(ids, ["system", "system.preview", "custom./mac/home/Mine"]);
    assert_eq!(value[0]["folder"], "/mac/home/Shots");
    // SAFETY: as above.
    assert_eq!(
        take(unsafe { cmux_screenshots_system_folder(&raw const env, home.as_ptr(), home.len()) })
            .as_deref(),
        Some("/mac/home/Shots")
    );
    // SAFETY: null env.
    assert!(
        unsafe {
            cmux_screenshots_detect(
                std::ptr::null(),
                home.as_ptr(),
                0,
                tmp.as_ptr(),
                0,
                true,
                std::ptr::null(),
                0,
            )
        }
        .is_null()
    );
}

#[test]
fn pane_round_trip() {
    let pane = cmux_screenshots_pane_new(true);
    let sources = r#"[{"id":"d","label":"Desktop","folder":"/u/Desktop","acceptsDrops":false,"rule":{"namePrefixes":["Screenshot"]}},
        {"id":"s","label":"Shots","folder":"/u/Shots","acceptsDrops":true,"rule":{"depth":1}},
        {"label":"no id","folder":"/x"}]"#;
    // SAFETY: live pane, valid bytes.
    let plan =
        take(unsafe { cmux_screenshots_pane_set_sources(pane, sources.as_ptr(), sources.len()) });
    assert_eq!(plan.as_deref(), Some(r#"{"changed":true,"read":["d","s"],"removed":[]}"#));
    // SAFETY: live pane, valid bytes.
    let again =
        take(unsafe { cmux_screenshots_pane_set_sources(pane, sources.as_ptr(), sources.len()) });
    assert_eq!(again.as_deref(), Some(r#"{"changed":false,"read":[],"removed":[]}"#));
    // SAFETY: live pane.
    assert!(!unsafe { cmux_screenshots_pane_start(pane) });
    let folders = r#"["/u/Shots","/u/Shots/a"]"#;
    // SAFETY: live pane, valid bytes.
    assert!(unsafe {
        cmux_screenshots_pane_read_done(
            pane,
            b"s".as_ptr(),
            1,
            true,
            folders.as_ptr(),
            folders.len(),
        )
    });
    // SAFETY: live pane, valid bytes.
    assert!(unsafe {
        cmux_screenshots_pane_read_done(pane, b"d".as_ptr(), 1, false, b"[]".as_ptr(), 2)
    });
    // SAFETY: live pane, valid bytes.
    assert!(!unsafe {
        cmux_screenshots_pane_read_done(pane, b"gone".as_ptr(), 4, true, std::ptr::null(), 0)
    });
    // SAFETY: live pane.
    let state = take(unsafe { cmux_screenshots_pane_state(pane) });
    assert_eq!(
        state.as_deref(),
        Some(
            r#"{"accessMissing":false,"listing":true,"unreadable":["d"],"watched":["/u/Desktop","/u/Shots","/u/Shots/a"]}"#
        )
    );
    // SAFETY: live pane, valid bytes.
    assert_eq!(
        take(unsafe { cmux_screenshots_pane_drop_source(pane, b"d".as_ptr(), 1) }).as_deref(),
        Some("s")
    );
    // SAFETY: live pane, null selection.
    assert_eq!(
        take(unsafe { cmux_screenshots_pane_drop_source(pane, std::ptr::null(), 0) }).as_deref(),
        Some("s")
    );
    let path = "/u/Shots/a/x.png";
    // SAFETY: live pane, valid bytes.
    assert_eq!(
        take(unsafe { cmux_screenshots_pane_source_containing(pane, path.as_ptr(), path.len()) })
            .as_deref(),
        Some("s")
    );
    // SAFETY: live pane, valid bytes.
    assert!(
        unsafe { cmux_screenshots_pane_source_containing(pane, b"/elsewhere".as_ptr(), 10) }
            .is_null()
    );
    let folder = "/u/Shots";
    let names = r#"["a","x.png","x.png"]"#;
    // SAFETY: live pane, valid bytes.
    let look = take(unsafe {
        cmux_screenshots_pane_change(
            pane,
            folder.as_ptr(),
            folder.len(),
            names.as_ptr(),
            names.len(),
        )
    });
    assert_eq!(look.as_deref(), Some(r#"{"paths":["/u/Shots/x.png"],"relist":true,"source":"s"}"#));
    // SAFETY: live pane, valid bytes, null names.
    let rescan = take(unsafe {
        cmux_screenshots_pane_change(pane, folder.as_ptr(), folder.len(), std::ptr::null(), 0)
    });
    assert_eq!(rescan.as_deref(), Some(r#"{"rescan":"s"}"#));
    let file = "/u/Shots/x.png";
    let png = CmuxScreenshotsEntry {
        kind: 1,
        hidden: false,
        name: b"x.png".as_ptr(),
        name_len: 5,
        system_kind: 1,
        modified: 1.0,
    };
    let action = |entry: *const CmuxScreenshotsEntry| {
        // SAFETY: live pane, valid bytes, entry null or live.
        unsafe {
            cmux_screenshots_pane_entry_action(
                pane,
                b"s".as_ptr(),
                1,
                folder.as_ptr(),
                folder.len(),
                file.as_ptr(),
                file.len(),
                entry,
            )
        }
    };
    assert_eq!(action(&raw const png), 2);
    assert_eq!(action(std::ptr::null()), 0);
    let sub = CmuxScreenshotsEntry { kind: 2, name: b"b".as_ptr(), name_len: 1, ..png };
    assert_eq!(action(&raw const sub), 1);
    // SAFETY: live pane.
    unsafe { cmux_screenshots_pane_pause(pane) };
    // SAFETY: live pane.
    let paused = take(unsafe { cmux_screenshots_pane_state(pane) });
    assert_eq!(
        paused.as_deref(),
        Some(r#"{"accessMissing":false,"listing":false,"unreadable":[],"watched":null}"#)
    );
    // SAFETY: live pane, freed once; null does nothing.
    unsafe {
        cmux_screenshots_pane_free(pane);
        cmux_screenshots_pane_free(std::ptr::null_mut());
    }
}

#[test]
fn walk_round_trip() {
    let json = r#"{"depth":1,"folderPrefix":"NSIRD_"}"#;
    // SAFETY: valid bytes.
    let rule = unsafe { cmux_screenshots_rule_new(json.as_ptr(), json.len()) };
    // SAFETY: live rule, valid bytes.
    let walk = unsafe { cmux_screenshots_walk_new(rule, b"/s".as_ptr(), 2) };
    // SAFETY: freed once; the walk holds its own copy.
    unsafe { cmux_screenshots_rule_free(rule) };
    let raw = |name: &'static [u8], kind: u32, system_kind: u32| CmuxScreenshotsEntry {
        kind,
        hidden: false,
        name: name.as_ptr(),
        name_len: name.len(),
        system_kind,
        modified: 0.0,
    };
    // SAFETY: live walk.
    assert_eq!(take(unsafe { cmux_screenshots_walk_next(walk) }).as_deref(), Some("/s"));
    let top = [raw(b"NSIRD_a", 2, 3), raw(b"top.png", 1, 1), raw(b"notes.txt", 1, 3)];
    let mut kinds = [9u32; 3];
    // SAFETY: live walk, 3 entries, 3 slots.
    unsafe {
        cmux_screenshots_walk_listed(walk, true, top.as_ptr(), top.len(), kinds.as_mut_ptr())
    };
    assert_eq!(kinds, [0, 1, 0]);
    // SAFETY: live walk.
    assert_eq!(take(unsafe { cmux_screenshots_walk_next(walk) }).as_deref(), Some("/s/NSIRD_a"));
    // SAFETY: live walk; an unreadable subfolder has no entries.
    unsafe { cmux_screenshots_walk_listed(walk, false, std::ptr::null(), 0, std::ptr::null_mut()) };
    // SAFETY: live walk.
    assert!(unsafe { cmux_screenshots_walk_next(walk) }.is_null());
    // SAFETY: live walk.
    assert_eq!(
        take(unsafe { cmux_screenshots_walk_result(walk) }).as_deref(),
        Some(r#"{"folders":["/s"],"readable":true}"#)
    );
    // SAFETY: live walk, freed once; null does nothing.
    unsafe {
        cmux_screenshots_walk_free(walk);
        cmux_screenshots_walk_free(std::ptr::null_mut());
    }
}
