//! Browser profiles, pinned to the Swift: `BrowserProfileTombstoneTests`, the Chromium half of
//! `BrowserProfileProxyTests`, `BrowserToolbarProfileButtonTests.theCascadeNamesWhyATabHasItsProfile`
//! and the doc comments' cases.

use crate::ops;
use crate::profiles::*;
use serde_json::json;

const ID: &str = "12345678-1234-4234-8234-123456789abc";

fn s(text: &str) -> String {
    text.to_owned()
}

fn book() -> ProfileBook {
    ProfileBook::new("Default")
}

fn create(book: &mut ProfileBook, id: &str, name: &str) -> Result<ProfileRecord, ProfileBookError> {
    book.create(id, name, None, None, None)
}

// MARK: - BrowserProfileTombstoneTests

#[test]
fn a_deleted_id_cannot_reenter_while_its_data_is_pending_removal() {
    let mut book = book();
    let original = create(&mut book, ID, "First").unwrap();
    assert_ne!(original.engine_profile(), BrowserProfileId::default_profile());
    book.delete(ID).unwrap();
    assert!(book.record(ID).is_none());
    assert_eq!(book.pending_cleanup(), [s(ID)]);
    assert_eq!(book.engine_profile(Some(ID)), BrowserProfileId::default_profile());

    assert_eq!(create(&mut book, ID, "Second"), Err(ProfileBookError::PendingCleanup));
    assert!(book.record(ID).is_none());
    assert_eq!(book.pending_cleanup(), [s(ID)], "a failed recreation must retain the tombstone");
}

#[test]
fn recreating_the_same_id_after_cleanup_gets_its_own_fresh_store() {
    let mut book = book();
    create(&mut book, ID, "First").unwrap();
    book.delete(ID).unwrap();
    book.finish_cleanup(&[s(ID)]);
    assert!(book.pending_cleanup().is_empty());
    let recreated = create(&mut book, ID, "Second").unwrap();
    assert_eq!(recreated.name, "Second");
    assert_ne!(recreated.engine_profile(), BrowserProfileId::default_profile());
    assert_eq!(book.engine_profile(Some(ID)), recreated.engine_profile());
    assert!(book.pending_cleanup().is_empty());
}

#[test]
fn a_pending_deletion_survives_file_roundtrip_until_cleanup_finishes() {
    let mut book = book();
    create(&mut book, ID, "Private").unwrap();
    book.delete(ID).unwrap();
    let data = serde_json::to_value(&book).unwrap();
    let mut restored = ProfileBook::from_json(data, "Default").unwrap();
    assert_eq!(restored.pending_cleanup(), [s(ID)]);
    assert_eq!(create(&mut restored, ID, "Import Retry"), Err(ProfileBookError::PendingCleanup));
    restored.finish_cleanup(&[s(ID)]);
    assert_eq!(create(&mut restored, ID, "Import Retry").unwrap().name, "Import Retry");
}

#[test]
fn another_id_and_an_existing_live_id_keep_their_normal_behavior() {
    let mut book = book();
    let live = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    create(&mut book, ID, "Deleted").unwrap();
    create(&mut book, live, "Live").unwrap();
    book.delete(ID).unwrap();
    assert_eq!(create(&mut book, live, "Ignored retry").unwrap().name, "Live");
    let fresh = create(&mut book, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "Fresh").unwrap();
    assert_eq!(fresh.name, "Fresh");
    assert_eq!(book.pending_cleanup(), [s(ID)]);
}

/// One cleanup per deleted id: a second pass skips an id still in flight and an id whose store an
/// engine opened, and claims the in-flight one again only after its cleanup released it.
#[test]
fn a_cleanup_claims_each_deleted_id_once_until_it_is_released() {
    let mut claims = CleanupClaims::default();
    let opened = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    let opened_profile = engine_profile(Some(opened));
    let is_open = |profile: &BrowserProfileId| Some(profile) == opened_profile.as_ref();
    assert_eq!(claims.claim(&[s(ID), s(opened)], is_open), [s(ID)]);
    assert_eq!(claims.in_flight.iter().cloned().collect::<Vec<_>>(), [s(ID)]);
    assert!(
        claims.claim(&[s(ID), s(opened)], is_open).is_empty(),
        "an in-flight id gets no second cleanup"
    );
    claims.release(&[s(ID)]);
    assert!(claims.in_flight.is_empty());
    assert_eq!(claims.claim(&[s(ID)], is_open), [s(ID)]);
}

#[test]
fn a_cleanup_claims_an_id_that_names_no_engine_store() {
    let mut claims = CleanupClaims::default();
    assert_eq!(claims.claim(&[s("not an id")], |_| true), [s("not an id")]);
}

/// The daemon-backed create runs the same check as the book's own create.
#[test]
fn require_reusable_refuses_only_a_pending_deletion() {
    let mut book = book();
    create(&mut book, ID, "First").unwrap();
    book.require_reusable(ID).unwrap();
    book.delete(ID).unwrap();
    assert_eq!(book.require_reusable(ID), Err(ProfileBookError::PendingCleanup));
    book.finish_cleanup(&[s(ID)]);
    book.require_reusable(ID).unwrap();
}

/// The import migration runs only the records whose proposed id is valid, in order.
#[test]
fn import_migration_skips_invalid_ids() {
    let other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    assert_eq!(migratable_imports(&[s(ID), s("not an id"), s(other)]), [0, 2]);
    assert_eq!(PENDING_DELETION_REASON, "browser profile is pending deletion");
}

// MARK: - BrowserProfileProxyTests (Chromium)

#[test]
fn chromium_gets_one_fixed_server() {
    for (scheme, server) in [
        (ProxyScheme::Socks5, "socks5://127.0.0.1:1080"),
        (ProxyScheme::Http, "http://127.0.0.1:1080"),
        (ProxyScheme::Https, "https://127.0.0.1:1080"),
    ] {
        let proxy = ProfileProxy::new(scheme, "127.0.0.1", 1080, vec![]);
        assert_eq!(proxy.chromium_server(), server);
        assert_eq!(proxy.chromium_bypass_list(), "");
    }
}

#[test]
fn the_bypass_list_joins_for_chromium() {
    let proxy = ProfileProxy::new(
        ProxyScheme::Http,
        "gw.test",
        8080,
        vec![s("*.corp.test"), s("10.0.0.0/8")],
    );
    assert_eq!(proxy.chromium_bypass_list(), "*.corp.test;10.0.0.0/8");
    assert_eq!(
        ProfileProxy::new(ProxyScheme::Http, "::1", 8080, vec![]).chromium_server(),
        "http://[::1]:8080"
    );
}

#[test]
fn webkit_takes_an_in_range_port_and_bypass_domains_without_their_wildcard() {
    let proxy = ProfileProxy::new(
        ProxyScheme::Http,
        "gw.test",
        8080,
        vec![s("*.corp.test"), s("10.0.0.0/8")],
    );
    assert_eq!(proxy.webkit_port(), Some(8080));
    assert_eq!(proxy.webkit_excluded_domains(), Some(vec![s("corp.test"), s("10.0.0.0/8")]));
    for port in [0, -1, 65536] {
        assert_eq!(ProfileProxy::new(ProxyScheme::Http, "h", port, vec![]).webkit_port(), None);
    }
    assert_eq!(ProfileProxy::new(ProxyScheme::Http, "h", 65535, vec![]).webkit_port(), Some(65535));
    assert_eq!(
        ProfileProxy::new(ProxyScheme::Http, "h", 1, vec![]).webkit_excluded_domains(),
        None
    );
}

#[test]
fn the_proxy_wire_is_swifts_codable_shape() {
    let proxy: ProfileProxy = serde_json::from_value(
        json!({"scheme": "socks5", "host": "127.0.0.1", "port": 1080, "bypass": []}),
    )
    .unwrap();
    assert_eq!(proxy, ProfileProxy::new(ProxyScheme::Socks5, "127.0.0.1", 1080, vec![]));
    assert!(
        serde_json::from_value::<ProfileProxy>(
            json!({"scheme": "ftp", "host": "h", "port": 1, "bypass": []})
        )
        .is_err()
    );
}

// MARK: - Cascade (BrowserToolbarProfileButtonTests.theCascadeNamesWhyATabHasItsProfile)

fn known(id: &str) -> bool {
    ["default", "work", "play"].contains(&id)
}

#[test]
fn the_cascade_names_why_a_tab_has_its_profile() {
    let src = |tab: Option<&str>, workspace: Option<&str>, room: Option<&str>| {
        source(tab, workspace, room, known)
    };
    assert_eq!(src(None, None, None), CascadeSource::BuiltIn);
    assert_eq!(src(Some("default"), None, None), CascadeSource::BuiltIn);
    assert_eq!(src(Some("work"), None, None), CascadeSource::Tab);
    assert_eq!(src(Some("work"), Some("work"), None), CascadeSource::Workspace);
    assert_eq!(src(Some("work"), Some("play"), None), CascadeSource::Tab);
    assert_eq!(src(Some("work"), None, Some("work")), CascadeSource::Space);
    assert_eq!(
        src(Some("work"), Some("play"), Some("work")),
        CascadeSource::Tab,
        "the workspace's default stands before the space's"
    );
    assert_eq!(
        src(Some("default"), Some("gone"), Some("")),
        CascadeSource::BuiltIn,
        "a deleted or blank default names nothing"
    );
    assert_eq!(src(Some("default"), None, Some("work")), CascadeSource::Tab);
}

#[test]
fn a_new_tab_gets_the_first_known_of_explicit_workspace_room_else_default() {
    assert_eq!(resolve(Some("play"), Some("work"), Some("work"), known), "play");
    assert_eq!(resolve(Some("gone"), Some("work"), Some("play"), known), "work");
    assert_eq!(resolve(Some(""), None, Some("play"), known), "play");
    assert_eq!(resolve(None, Some("gone"), Some("gone"), known), "default");
    assert_eq!(resolve(None, None, None, |_| true), "default");
}

#[test]
fn a_tab_shows_a_badge_when_its_profile_differs_from_its_workspaces() {
    assert!(!shows_tab_badge(None, "default"));
    assert!(shows_tab_badge(None, "work"));
    assert!(!shows_tab_badge(Some("work"), "work"));
    assert!(shows_tab_badge(Some("play"), "work"));
}

// MARK: - Record ids

#[test]
fn a_wire_id_is_default_or_a_lowercase_uuid() {
    assert!(is_valid_id("default"));
    assert!(is_valid_id(ID));
    assert!(!is_valid_id(&ID.to_uppercase()));
    assert!(!is_valid_id("Default"));
    assert!(!is_valid_id(""));
    assert!(!is_valid_id("12345678123442348234123456789abc"));
    assert!(!is_valid_id("12345678-1234-4234-8234-123456789abg"));
    assert!(!is_valid_id(" 2345678-1234-4234-8234-123456789abc"));
}

#[test]
fn engine_profiles_map_to_and_from_wire_ids() {
    assert_eq!(engine_profile(Some("default")), Some(BrowserProfileId::default_profile()));
    assert_eq!(
        engine_profile(Some(ID)).map(|profile| profile.uuid_string().to_owned()),
        Some(s("12345678-1234-4234-8234-123456789ABC"))
    );
    assert_eq!(engine_profile(None), None);
    assert_eq!(engine_profile(Some(&ID.to_uppercase())), None, "uppercase is not a wire id");
    assert_eq!(engine_profile(Some("room-1")), None);
    assert_eq!(wire_id(&BrowserProfileId::default_profile()), "default");
    assert_eq!(wire_id(&engine_profile(Some(ID)).unwrap()), ID);
    assert_eq!(
        ProfileRecord::new("junk", "J", 0).engine_profile(),
        BrowserProfileId::default_profile()
    );
}

#[test]
fn the_badge_shows_the_icon_else_the_names_first_letter() {
    let mut record = ProfileRecord::new(ID, "work", 1);
    assert_eq!(record.monogram(), "W");
    record.icon = Some(s(""));
    assert_eq!(record.monogram(), "W");
    record.icon = Some(s("person.fill"));
    assert_eq!(record.monogram(), "person.fill");
    assert_eq!(ProfileRecord::new(ID, "", 1).monogram(), "?");
    assert_eq!(ProfileRecord::new(ID, "\u{e9}t\u{e9}", 1).monogram(), "\u{c9}");
    assert_eq!(ProfileRecord::new(ID, "e\u{301}t\u{e9}", 1).monogram(), "E\u{301}");
    assert_eq!(
        ProfileRecord::new(ID, "\u{1f1eb}\u{1f1f7} trip", 1).monogram(),
        "\u{1f1eb}\u{1f1f7}"
    );
}

#[test]
fn a_record_round_trips_in_swifts_codable_shape() {
    let wire = json!({"id": ID, "name": "Work", "color": "blue", "position": 2,
                      "source": {"browser": "chrome"},
                      "proxy": {"scheme": "http", "host": "h", "port": 80, "bypass": []}});
    let record: ProfileRecord = serde_json::from_value(wire.clone()).unwrap();
    assert_eq!(serde_json::to_value(&record).unwrap(), wire, "nil optionals stay out");
    assert!(
        serde_json::from_value::<ProfileRecord>(json!({"id": ID, "name": "W"})).is_err(),
        "position is required"
    );
}

// MARK: - Validation

#[test]
fn a_name_is_trimmed_and_one_to_sixty_four_characters() {
    assert_eq!(valid_name("  Work\n"), Ok(s("Work")));
    assert_eq!(valid_name("\u{3000}Work\u{2028}"), Ok(s("Work")));
    assert_eq!(valid_name(" \t\n"), Err(ProfileBookError::InvalidName));
    assert_eq!(valid_name(&"a".repeat(64)), Ok("a".repeat(64)));
    assert_eq!(valid_name(&"a".repeat(65)), Err(ProfileBookError::InvalidName));
    // 64 family emoji are 64 characters, many more scalars.
    let families = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}".repeat(64);
    assert_eq!(valid_name(&families), Ok(families.clone()));
}

#[test]
fn a_color_is_none_or_a_group_color() {
    assert_eq!(valid_color(None), Ok(None));
    assert_eq!(valid_color(Some("")), Ok(None));
    assert_eq!(valid_color(Some("purple")), Ok(Some(s("purple"))));
    assert_eq!(valid_color(Some("Purple")), Err(ProfileBookError::InvalidColor));
    assert_eq!(valid_color(Some("#ff0000")), Err(ProfileBookError::InvalidColor));
}

#[test]
fn an_icon_is_a_symbol_one_grapheme_or_an_asset() {
    let digest = "a".repeat(64);
    assert_eq!(valid_icon(None), Ok(None));
    assert_eq!(valid_icon(Some(" \t")), Ok(None));
    assert_eq!(valid_icon(Some(" person.fill ")), Ok(Some(s("person.fill"))));
    assert_eq!(valid_icon(Some("Person2.Fill")), Ok(Some(s("Person2.Fill"))));
    assert_eq!(valid_icon(Some("\u{1f600}")), Ok(Some(s("\u{1f600}"))));
    assert_eq!(valid_icon(Some("\u{1f1eb}\u{1f1f7}")), Ok(Some(s("\u{1f1eb}\u{1f1f7}"))));
    assert_eq!(valid_icon(Some("-")), Ok(Some(s("-"))));
    let image = format!("image:sha256-{digest}");
    assert_eq!(valid_icon(Some(&image)), Ok(Some(image.clone())));
    let svg = format!("svg:sha256-{digest}");
    assert_eq!(valid_icon(Some(&svg)), Ok(Some(svg.clone())));
    assert_eq!(valid_icon(Some("image:sha256-nothex")), Err(ProfileBookError::InvalidIcon));
    assert_eq!(valid_icon(Some("person fill")), Err(ProfileBookError::InvalidIcon));
    assert_eq!(valid_icon(Some(&"a".repeat(65))), Err(ProfileBookError::InvalidIcon));
    assert_eq!(valid_icon(Some("\u{1f600}\u{1f600}")), Err(ProfileBookError::InvalidIcon));
    // Newlines are not trimmed from an icon.
    assert_eq!(valid_icon(Some("\nx")), Err(ProfileBookError::InvalidIcon));
}

// MARK: - Book

#[test]
fn a_new_book_has_only_the_default_profile() {
    let book = book();
    assert_eq!(book.profiles(), [ProfileRecord::new("default", "Default", 0)]);
    assert!(book.contains("default"));
}

#[test]
fn create_validates_and_appends_after_the_last_position() {
    let mut book = book();
    assert_eq!(create(&mut book, "Default", "X"), Err(ProfileBookError::InvalidId));
    assert_eq!(create(&mut book, ID, " "), Err(ProfileBookError::InvalidName));
    assert_eq!(
        book.create(ID, "W", Some("mauve"), None, None),
        Err(ProfileBookError::InvalidColor)
    );
    assert_eq!(book.create(ID, "W", None, Some("a b"), None), Err(ProfileBookError::InvalidIcon));
    let record = book.create(ID, " Work ", Some("blue"), Some(" briefcase "), None).unwrap();
    assert_eq!((record.name.as_str(), record.position), ("Work", 1));
    assert_eq!(record.color.as_deref(), Some("blue"));
    assert_eq!(record.icon.as_deref(), Some("briefcase"));
    let next = create(&mut book, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "Next").unwrap();
    assert_eq!(next.position, 2);
    assert_eq!(
        create(&mut book, "default", "Again").unwrap().name,
        "Default",
        "an existing id is returned"
    );
}

#[test]
fn edits_validate_and_refuse_an_unknown_profile() {
    let mut book = book();
    create(&mut book, ID, "Work").unwrap();
    book.rename(ID, " Play ").unwrap();
    book.set_color(ID, Some("red")).unwrap();
    book.set_icon(ID, Some("\u{1f3ae}")).unwrap();
    let record = book.record(ID).unwrap();
    assert_eq!(record.name, "Play");
    assert_eq!(record.color.as_deref(), Some("red"));
    assert_eq!(record.icon.as_deref(), Some("\u{1f3ae}"));
    book.set_color(ID, Some("")).unwrap();
    book.set_icon(ID, None).unwrap();
    assert_eq!(book.record(ID).unwrap().color, None);
    assert_eq!(book.record(ID).unwrap().icon, None);
    assert_eq!(book.rename(ID, ""), Err(ProfileBookError::InvalidName));
    assert_eq!(
        book.rename("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "X"),
        Err(ProfileBookError::UnknownProfile)
    );
    assert_eq!(
        book.set_color("x", Some("teal")),
        Err(ProfileBookError::InvalidColor),
        "validation comes first"
    );
}

#[test]
fn profiles_order_by_position_then_id_and_move_renumbers() {
    let (a, b) = ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    let mut book = book();
    create(&mut book, b, "B").unwrap();
    create(&mut book, a, "A").unwrap();
    let ids =
        |book: &ProfileBook| book.ordered().into_iter().map(|record| record.id).collect::<Vec<_>>();
    assert_eq!(ids(&book), ["default", b, a]);
    book.move_to(a, 0).unwrap();
    assert_eq!(ids(&book), [a, "default", b]);
    assert_eq!(book.record(a).unwrap().position, 0);
    assert_eq!(book.record(b).unwrap().position, 2);
    book.move_to(a, 99).unwrap();
    assert_eq!(ids(&book), ["default", b, a]);
    book.move_to(a, -5).unwrap();
    assert_eq!(ids(&book), [a, "default", b]);
    assert_eq!(book.move_to(ID, 0), Err(ProfileBookError::UnknownProfile));

    // Equal positions fall back to the id.
    let stored = json!({"profiles": [
        {"id": b, "name": "B", "position": 1},
        {"id": a, "name": "A", "position": 1},
        {"id": "default", "name": "D", "position": 1},
    ]});
    let tied = ProfileBook::from_json(stored, "Default").unwrap();
    assert_eq!(ids(&tied), [a, b, "default"]);
}

#[test]
fn delete_refuses_the_default_and_drops_workspace_defaults() {
    let mut book = book();
    create(&mut book, ID, "Work").unwrap();
    book.workspace_defaults.insert(s("s|1"), s(ID));
    book.workspace_defaults.insert(s("s|2"), s("default"));
    assert_eq!(book.delete("default"), Err(ProfileBookError::DefaultProfile));
    assert_eq!(
        book.delete("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        Err(ProfileBookError::UnknownProfile)
    );
    book.delete(ID).unwrap();
    assert_eq!(book.workspace_defaults.keys().map(String::as_str).collect::<Vec<_>>(), ["s|2"]);
    book.mark_deleted(ID);
    assert_eq!(book.pending_cleanup(), [s(ID)], "queued once");
    book.mark_deleted("default");
    assert!(book.contains("default"));
}

#[test]
fn a_daemon_profile_is_marked_deleted_without_a_local_record() {
    let mut book = book();
    book.mark_deleted(ID);
    assert_eq!(book.pending_cleanup(), [s(ID)]);
    assert_eq!(book.engine_profile(Some(ID)), BrowserProfileId::default_profile());
}

#[test]
fn a_tab_from_another_mac_keeps_its_own_store() {
    let book = book();
    assert_eq!(book.engine_profile(Some(ID)), engine_profile(Some(ID)).unwrap());
    assert_eq!(book.engine_profile(None), BrowserProfileId::default_profile());
    assert_eq!(book.engine_profile(Some("junk")), BrowserProfileId::default_profile());
}

#[test]
fn a_stored_book_tolerates_missing_keys_and_bad_records() {
    let empty = ProfileBook::from_json(json!({}), "Standard").unwrap();
    assert_eq!(empty, ProfileBook::new("Standard"));

    let stored = json!({
        "profiles": [
            {"id": ID, "name": "Work", "position": 1},
            {"id": ID, "name": "Copy", "position": 2},
            {"id": "NOT-VALID", "name": "Bad", "position": 3},
        ],
        "workspace_defaults": {"s|k": ID},
        "pending_cleanup": ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"],
        "imports_migrated": true,
        "records_migrated": null,
    });
    let book = ProfileBook::from_json(stored, "Default").unwrap();
    let ids: Vec<_> = book.profiles().iter().map(|record| record.id.as_str()).collect();
    assert_eq!(ids, ["default", ID], "the default comes back first; repeats and bad ids drop");
    assert_eq!(book.record(ID).unwrap().name, "Work");
    assert_eq!(book.workspace_defaults.get("s|k").map(String::as_str), Some(ID));
    assert!(book.imports_migrated);
    assert!(!book.records_migrated);

    let with_default = json!({"profiles": [{"id": ID, "name": "W", "position": 0},
                                           {"id": "default", "name": "Mine", "position": 1}]});
    let book = ProfileBook::from_json(with_default, "Default").unwrap();
    assert_eq!(book.profiles().len(), 2);
    assert_eq!(book.record("default").unwrap().name, "Mine");

    let only_bad = json!({"profiles": [{"id": "x", "name": "X", "position": 0}]});
    assert_eq!(ProfileBook::from_json(only_bad, "Default").unwrap(), ProfileBook::new("Default"));

    assert!(ProfileBook::from_json(json!({"profiles": [{"id": ID}]}), "Default").is_err());
}

#[test]
fn a_book_writes_swifts_keys() {
    let value = serde_json::to_value(book()).unwrap();
    assert_eq!(
        value,
        json!({"profiles": [{"id": "default", "name": "Default", "position": 0}],
               "workspace_defaults": {}, "pending_cleanup": [],
               "imports_migrated": false, "records_migrated": false})
    );
}

// MARK: - Storage cleanup

#[test]
fn chromium_directories_are_the_profile_and_its_derived_stores() {
    let names: Vec<String> = [
        "Profile-12345678-1234-4234-8234-123456789ABC",
        "Profile-12345678-1234-4234-8234-123456789ABC-m-abc",
        "Profile-12345678-1234-4234-8234-123456789ABCD",
        "Profile-12345678-1234-4234-8234-123456789abc",
        "Profile-8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11",
        "Default",
    ]
    .map(s)
    .to_vec();
    assert_eq!(chromium_directories(ID, &names), names[..2].to_vec());
    assert!(chromium_directories("default", &names).is_empty());
    assert!(chromium_directories("junk", &names).is_empty());
    assert_eq!(chromium_cleanup_ids(&[s("default"), s(ID), s("junk")]), [s(ID)]);
}

// MARK: - Off the record

#[test]
fn an_off_the_record_profile_stays_in_memory_after_it_ends() {
    let profile = BrowserProfileId::parse(ID).unwrap();
    let other = BrowserProfileId::default_profile();
    let mut state = OffTheRecordProfiles::default();
    assert!(!state.is_off_the_record(&profile));
    state.begin(profile.clone());
    assert!(state.contains(&profile) && state.is_off_the_record(&profile));
    assert!(!state.contains(&other));
    assert!(state.end(&profile), "the first end runs the end observers");
    assert!(!state.contains(&profile));
    assert!(state.is_off_the_record(&profile), "a late request still gets an in-memory store");
    assert!(!state.end(&profile), "a second end does nothing");
    assert!(!state.end(&other), "a profile never begun does not end");
    assert!(!state.is_off_the_record(&other));
}

#[test]
fn engine_profile_ids_read_any_case_and_write_uppercase() {
    let profile: BrowserProfileId = serde_json::from_value(json!(ID)).unwrap();
    assert_eq!(
        serde_json::to_value(&profile).unwrap(),
        json!("12345678-1234-4234-8234-123456789ABC")
    );
    assert!(serde_json::from_value::<BrowserProfileId>(json!("default")).is_err());
}

// MARK: - Ops

#[test]
fn profile_ops_answer_in_the_wire_shape() {
    let call = |op: &str, request| ops::call(op, request).unwrap();
    assert_eq!(
        call("browser_rules_profile_resolve", json!({"workspace": "work", "known": ["work"]})),
        json!("work")
    );
    assert_eq!(
        call(
            "browser_rules_profile_source",
            json!({"tabProfile": "work", "room": "work", "known": ["work"]})
        ),
        json!("space")
    );
    assert_eq!(call("browser_rules_profile_source", json!({})), json!("builtIn"));
    assert_eq!(
        call("browser_rules_profile_shows_tab_badge", json!({"workspaceEffective": "work"})),
        json!(true)
    );
    assert_eq!(call("browser_rules_profile_is_valid_id", json!({"id": ID})), json!(true));
    assert_eq!(call("browser_rules_profile_is_valid_id", json!({})), json!(false));
    assert_eq!(
        call("browser_rules_profile_engine_profile", json!({"id": "default"})),
        json!(DEFAULT_ENGINE_UUID)
    );
    assert_eq!(call("browser_rules_profile_engine_profile", json!({"id": "x"})), json!(null));
    assert_eq!(
        call("browser_rules_profile_wire_id", json!({"profile": DEFAULT_ENGINE_UUID})),
        json!("default")
    );
    assert_eq!(
        call(
            "browser_rules_profile_monogram",
            json!({"record": {"id": ID, "name": "zed", "position": 0}})
        ),
        json!("Z")
    );
    assert_eq!(
        call(
            "browser_rules_profile_proxy",
            json!({"proxy": {"scheme": "http", "host": "::1", "port": 0, "bypass": ["*.a.test"]}})
        ),
        json!({"chromiumServer": "http://[::1]:0", "chromiumBypassList": "*.a.test",
               "webKitPort": null, "webKitExcludedDomains": ["a.test"]})
    );
    assert_eq!(
        call("browser_rules_profile_valid_name", json!({"name": " A "})),
        json!({"ok": "A"})
    );
    assert_eq!(
        call("browser_rules_profile_valid_color", json!({"color": "teal"})),
        json!({"error": "invalidColor"})
    );
    assert_eq!(call("browser_rules_profile_valid_icon", json!({})), json!({"ok": null}));
    assert_eq!(
        call(
            "browser_rules_profile_chromium_directories",
            json!({"id": ID, "names": ["Profile-12345678-1234-4234-8234-123456789ABC", "x"]})
        ),
        json!(["Profile-12345678-1234-4234-8234-123456789ABC"])
    );
}

#[test]
fn profile_book_ops_edit_a_stored_book() {
    let call = |op: &str, request| ops::call(op, request).unwrap();
    let created = call(
        "browser_rules_profile_book_edit",
        json!({"book": null, "edit": {"create": {"id": ID, "name": "Work", "color": "blue"}}}),
    );
    assert_eq!(
        created["record"],
        json!({"id": ID, "name": "Work", "color": "blue", "position": 1})
    );
    let book = created["book"].clone();
    let deleted = call(
        "browser_rules_profile_book_edit",
        json!({"book": book, "edit": {"delete": {"id": ID}}}),
    );
    assert_eq!(deleted["record"], json!(null));
    assert_eq!(deleted["book"]["pending_cleanup"], json!([ID]));
    assert_eq!(
        call(
            "browser_rules_profile_book_edit",
            json!({"book": deleted["book"], "edit": {"create": {"id": ID, "name": "Again"}}})
        ),
        json!({"error": "pendingCleanup"})
    );
    assert_eq!(
        call(
            "browser_rules_profile_book_edit",
            json!({"edit": {"create": {"id": "X", "name": "A"}}})
        ),
        json!({"error": "invalidID"})
    );
    assert_eq!(
        call(
            "browser_rules_profile_book_engine_profile",
            json!({"book": deleted["book"], "id": ID})
        ),
        json!(DEFAULT_ENGINE_UUID)
    );
    let ordered = call("browser_rules_profile_book_ordered", json!({"book": book}));
    assert_eq!(ordered.as_array().map(Vec::len), Some(2));
    assert_eq!(
        call("browser_rules_profile_book_read", json!({"defaultName": "Standard"}))["profiles"][0]
            ["name"],
        json!("Standard")
    );
    assert!(matches!(
        ops::call("browser_rules_profile_book_edit", json!({"edit": {"teleport": {}}})),
        Err(ops::OpError::Invalid(_))
    ));
    assert!(matches!(
        ops::call("browser_rules_profile_book_edit", json!({})),
        Err(ops::OpError::Invalid(_))
    ));
}

#[test]
fn profile_cleanup_and_off_the_record_ops_carry_their_state() {
    let call = |op: &str, request| ops::call(op, request).unwrap();
    let claimed = call("browser_rules_profile_cleanup_claim", json!({"pending": [ID]}));
    assert_eq!(claimed, json!({"claims": {"inFlight": [ID]}, "ready": [ID]}));
    let again = call(
        "browser_rules_profile_cleanup_claim",
        json!({"claims": claimed["claims"], "pending": [ID]}),
    );
    assert_eq!(again["ready"], json!([]));
    let open = call(
        "browser_rules_profile_cleanup_claim",
        json!({"pending": [ID], "open": [ID.to_uppercase()]}),
    );
    assert_eq!(open["ready"], json!([]));
    assert_eq!(
        call(
            "browser_rules_profile_cleanup_release",
            json!({"claims": claimed["claims"], "ids": [ID]})
        ),
        json!({"inFlight": []})
    );

    let state = call("browser_rules_profile_off_the_record_begin", json!({"profile": ID}));
    let upper = ID.to_uppercase();
    assert_eq!(state, json!({"active": [upper], "ended": []}));
    let ended =
        call("browser_rules_profile_off_the_record_end", json!({"state": state, "profile": ID}));
    assert_eq!(ended, json!({"state": {"active": [], "ended": [upper]}, "ended": true}));
    assert_eq!(
        call(
            "browser_rules_profile_off_the_record_is",
            json!({"state": ended["state"], "profile": ID})
        ),
        json!({"active": false, "offTheRecord": true})
    );
    assert_eq!(
        ops::call("browser_rules_profile_nope", json!({})),
        Err(ops::OpError::UnknownOp("browser_rules_profile_nope".into()))
    );
}
