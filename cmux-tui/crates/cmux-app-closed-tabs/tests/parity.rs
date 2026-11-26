//! Parity with the Swift this crate replaces (swift-out step A), case by case: each test names
//! the Swift it pins (ClosedTabsFeed, DaemonClosedHistory, DaemonClosedItem, HistoryService's
//! closed rows, NewTabClosed, CloseUndoToasts, UndoToastRateLimit, StateResources' ClosedItem).
//! They run on Linux; the Swift copy stays until step B (#59016) calls these ops and deletes it.

use cmux_app_closed_tabs::feed::{self, FeedMachine};
use cmux_app_closed_tabs::history::{self, Words};
use cmux_app_closed_tabs::item::{
    self, AgentSession, ClosedItem, Group, Kind, Member, Screen, Tab,
};
use cmux_app_closed_tabs::listing::{self, EntryRef, Machine, Registry};
use cmux_app_closed_tabs::new_tab::{self, PageKind, Source, SourceItem};
use cmux_app_closed_tabs::ops::{self, OpError};
use cmux_app_closed_tabs::reading::{self, HistoryKind};
use cmux_app_closed_tabs::records;
use cmux_app_closed_tabs::reopen::{self, AfterReply, ReopenFailure, Reopened, ShowSelect};
use cmux_app_closed_tabs::undo::{self, ClosingPart, Message, RateLimit, RecentItem, ShownToast};
use cmux_window_rules::closed::{self, Expected, ExpectedTab, ItemKind, ToastShow, UndoState};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

// MARK: fixtures

fn tab(kind: &str) -> Tab {
    Tab::of(kind)
}

fn terminal(cwd: &str) -> Tab {
    Tab { cwd: Some(cwd.to_owned()), ..tab("terminal") }
}

fn browser(url: &str) -> Tab {
    Tab { url: Some(url.to_owned()), ..tab("browser") }
}

fn blank() -> Tab {
    Tab { url: Some("about:blank".to_owned()), empty: true, ..tab("browser") }
}

fn page(id: &str) -> Tab {
    Tab { url: Some("about:blank".to_owned()), page: Some(id.to_owned()), ..tab("browser") }
}

fn with_tabs(id: &str, kind: Kind, at: u64, tabs: Vec<Tab>) -> ClosedItem {
    ClosedItem {
        closed_at_ms: at,
        screens: vec![Screen { name: None, tabs }],
        ..ClosedItem::new(id, kind)
    }
}

fn closed_tab(id: &str, at: u64, tab: Tab) -> ClosedItem {
    with_tabs(id, Kind::Tab, at, vec![tab])
}

fn machine(id: &str, local: bool, items: Vec<ClosedItem>) -> Machine {
    Machine {
        machine: id.to_owned(),
        local,
        serves: true,
        items,
        workspace_windows: BTreeMap::new(),
    }
}

fn installs() -> Vec<String> {
    vec!["install-a".to_owned()]
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

fn call(op: &str, request: Value) -> Value {
    ops::call(op, request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

// MARK: StateResources' ClosedItem decode

#[test]
fn item_decodes_the_daemon_wire_shape_with_a_decimal_string_close_time() {
    let item: ClosedItem = serde_json::from_value(json!({
        "id": "closed_1", "kind": "tab", "workspace_id": "ws_1", "pane_id": "pane_1",
        "index": 2, "closed_at_ms": "1700000000123",
        "screens": [{"tabs": [{"kind": "browser", "url": "https://a.test/",
                               "browser_profile_id": "p", "agent_session": {"session": "s"}}]}],
    }))
    .unwrap();
    assert_eq!(item.closed_at_ms, 1_700_000_000_123);
    assert_eq!(item.workspace_id.as_deref(), Some("ws_1"));
    assert_eq!(item.pane_id.as_deref(), Some("pane_1"));
    assert_eq!(item.index, 2);
    let tab = &item.screens[0].tabs[0];
    assert_eq!(tab.browser_profile_id.as_deref(), Some("p"));
    assert_eq!(tab.agent_session, Some(AgentSession { session: Some("s".into()), harness: None }));
}

#[test]
fn item_close_time_reads_a_number_and_null_and_a_bad_string_as_zero() {
    let read = |value: Value| -> ClosedItem {
        serde_json::from_value(json!({"id": "c", "kind": "tab", "closed_at_ms": value})).unwrap()
    };
    assert_eq!(read(json!(42)).closed_at_ms, 42);
    assert_eq!(read(Value::Null).closed_at_ms, 0);
    assert_eq!(read(json!("12x")).closed_at_ms, 0);
    assert_eq!(read(json!("-0")).closed_at_ms, 0);
    assert_eq!(read(json!("+7")).closed_at_ms, 7);
    let missing: ClosedItem = serde_json::from_value(json!({"id": "c", "kind": "tab"})).unwrap();
    assert_eq!(missing.closed_at_ms, 0);
}

#[test]
fn item_close_time_refuses_a_negative_or_fractional_number() {
    for value in [json!(-1), json!(1.5), json!(true)] {
        let decoded: Result<ClosedItem, _> =
            serde_json::from_value(json!({"id": "c", "kind": "tab", "closed_at_ms": value}));
        assert!(decoded.is_err(), "{value}");
    }
}

#[test]
fn parse_decimal_is_swifts_uint64_radix_10() {
    assert_eq!(item::parse_decimal("0"), Some(0));
    assert_eq!(item::parse_decimal("18446744073709551615"), Some(u64::MAX));
    assert_eq!(item::parse_decimal("18446744073709551616"), None);
    assert_eq!(item::parse_decimal("-1"), None);
    assert_eq!(item::parse_decimal("-"), None);
    assert_eq!(item::parse_decimal("+"), None);
    assert_eq!(item::parse_decimal(""), None);
    assert_eq!(item::parse_decimal(" 1"), None);
    assert_eq!(item::parse_decimal("1_000"), None);
}

#[test]
fn item_tabs_flatten_every_member_and_ignore_the_mirrored_top_level() {
    let mut item = with_tabs("c", Kind::Workspace, 1, vec![terminal("/top")]);
    assert_eq!(item.tab_count(), 1);
    item.members = vec![
        Member {
            screens: Some(vec![Screen { name: None, tabs: vec![terminal("/a")] }]),
            name: None,
        },
        Member { screens: None, name: Some("empty".into()) },
        Member {
            screens: Some(vec![Screen { name: None, tabs: vec![terminal("/b"), terminal("/c")] }]),
            name: Some("two".into()),
        },
    ];
    let cwds: Vec<_> = item.tabs().iter().map(|tab| tab.cwd.clone().unwrap()).collect();
    assert_eq!(cwds, ["/a", "/b", "/c"]);
    assert_eq!(item.member_names(), [None, Some("empty"), Some("two")]);
    item.members = vec![Member { screens: None, name: None }];
    assert_eq!(item.tab_count(), 0);
}

#[test]
fn item_null_members_screens_pinned_and_empty_decode_as_absent() {
    let item: ClosedItem = serde_json::from_value(json!({
        "id": "c", "kind": "screen", "members": null, "screens": null, "index": null,
    }))
    .unwrap();
    assert!(item.members.is_empty());
    assert!(item.screens.is_empty());
    let tab: Tab =
        serde_json::from_value(json!({"kind": "terminal", "pinned": null, "empty": null})).unwrap();
    assert!(!tab.pinned);
    assert!(!tab.empty);
}

// MARK: DaemonClosedItem

#[test]
fn shown_tab_skips_a_blank_tab_and_falls_back_to_the_first() {
    let item = with_tabs("c", Kind::Screen, 1, vec![blank(), terminal("/x")]);
    assert_eq!(reading::shown_tab(&item).unwrap().cwd.as_deref(), Some("/x"));
    let only_blank = with_tabs("c", Kind::Screen, 1, vec![blank(), blank()]);
    assert!(reading::shown_tab(&only_blank).unwrap().empty);
    assert!(reading::shown_tab(&ClosedItem::new("c", Kind::Tab)).is_none());
}

#[test]
fn closed_kind_reads_the_shown_tab_for_a_tab_and_the_container_otherwise() {
    assert_eq!(
        reading::closed_kind(&closed_tab("c", 1, tab("conversation"))),
        HistoryKind::ConversationTab
    );
    assert_eq!(
        reading::closed_kind(&closed_tab("c", 1, browser("https://a"))),
        HistoryKind::BrowserTab
    );
    assert_eq!(reading::closed_kind(&closed_tab("c", 1, terminal("/"))), HistoryKind::TerminalTab);
    assert_eq!(reading::closed_kind(&closed_tab("c", 1, tab("other"))), HistoryKind::TerminalTab);
    assert_eq!(reading::closed_kind(&ClosedItem::new("c", Kind::Tab)), HistoryKind::TerminalTab);
    assert_eq!(
        reading::closed_kind(&with_tabs("c", Kind::Screen, 1, vec![tab("conversation")])),
        HistoryKind::Screen
    );
    assert_eq!(
        reading::closed_kind(&ClosedItem::new("c", Kind::Workspace)),
        HistoryKind::Workspace
    );
    assert_eq!(reading::closed_kind(&ClosedItem::new("c", Kind::Window)), HistoryKind::Workspace);
}

#[test]
fn agent_session_is_a_tabs_only() {
    let agent = Tab {
        agent_session: Some(AgentSession {
            session: Some("s1".into()),
            harness: Some("claude".into()),
        }),
        ..browser("about:blank")
    };
    let session = reading::closed_agent_session(&closed_tab("c", 1, agent.clone())).unwrap();
    assert_eq!(session.session_id.as_deref(), Some("s1"));
    assert_eq!(session.harness.as_deref(), Some("claude"));
    assert!(reading::closed_agent_session(&with_tabs("c", Kind::Screen, 1, vec![agent])).is_none());
}

#[test]
fn worth_reopening_needs_a_real_tab_unless_a_group_or_a_window() {
    assert!(!reading::is_worth_reopening(&closed_tab("c", 1, blank())));
    assert!(!reading::is_worth_reopening(&ClosedItem::new("c", Kind::Workspace)));
    assert!(reading::is_worth_reopening(&with_tabs(
        "c",
        Kind::Workspace,
        1,
        vec![blank(), terminal("/")]
    )));
    assert!(reading::is_worth_reopening(&ClosedItem::new("c", Kind::Window)));
    let group = ClosedItem {
        group: Some(Group { id: "g".into(), name: "G".into(), ..Group::default() }),
        ..ClosedItem::new("c", Kind::Workspace)
    };
    assert!(reading::is_worth_reopening(&group));
}

#[test]
fn real_text_drops_empty_and_about_blank() {
    assert_eq!(reading::real_text(None), None);
    assert_eq!(reading::real_text(Some("")), None);
    assert_eq!(reading::real_text(Some("about:blank")), None);
    assert_eq!(reading::real_text(Some("about:blank#x")), Some("about:blank#x"));
    assert_eq!(reading::real_text(Some("name")), Some("name"));
}

// MARK: DaemonClosedHistory.entries, entry, groupEntry, isServed

#[test]
fn entries_are_newest_first_across_machines_and_stable_on_ties() {
    let machines = vec![
        machine(
            "local",
            true,
            vec![closed_tab("a", 10, terminal("/")), closed_tab("b", 30, terminal("/"))],
        ),
        machine(
            "m2",
            false,
            vec![closed_tab("c", 20, terminal("/")), closed_tab("d", 30, terminal("/"))],
        ),
    ];
    let order: Vec<_> =
        listing::all_entries(&machines).iter().map(|entry| entry.item.id.clone()).collect();
    assert_eq!(order, ["b", "d", "c", "a"]);
    let at = listing::all_entries(&machines)[1].at;
    assert_eq!(at, EntryRef { machine: 1, item: 1 });
}

#[test]
fn entries_skip_a_machine_that_does_not_serve_and_filter_kinds() {
    let mut quiet = machine("m2", false, vec![closed_tab("q", 99, terminal("/"))]);
    quiet.serves = false;
    let machines = vec![
        machine(
            "local",
            true,
            vec![closed_tab("a", 1, terminal("/")), ClosedItem::new("w", Kind::Window)],
        ),
        quiet,
    ];
    let all: Vec<_> = listing::all_entries(&machines).iter().map(|e| e.item.id.clone()).collect();
    assert_eq!(all, ["a", "w"]);
    let windows: Vec<_> =
        listing::entries(&machines, &[Kind::Window]).iter().map(|e| e.item.id.clone()).collect();
    assert_eq!(windows, ["w"]);
    assert!(listing::is_served(&machines));
    assert!(!listing::is_served(&machines[1..]));
    assert!(!listing::is_served(&[]));
}

#[test]
fn entry_finds_the_newest_with_the_id_and_group_entry_the_newest_group_delete() {
    let group = |id: &str, at: u64| ClosedItem {
        closed_at_ms: at,
        group: Some(Group { id: "g1".into(), name: "G".into(), ..Group::default() }),
        ..ClosedItem::new(id, Kind::Workspace)
    };
    let machines = vec![
        machine("local", true, vec![group("old", 1), closed_tab("x", 5, terminal("/"))]),
        machine("m2", false, vec![group("new", 3), closed_tab("x", 9, terminal("/"))]),
    ];
    assert_eq!(listing::entry(&machines, "x").unwrap().at, EntryRef { machine: 1, item: 1 });
    assert!(listing::entry(&machines, "nope").is_none());
    assert_eq!(listing::group_entry(&machines, "g1").unwrap().item.id, "new");
    assert!(listing::group_entry(&machines, "g2").is_none());
}

// MARK: DaemonClosedHistory.newest (Cmd-Shift-T) and ownerFacts

#[test]
fn newest_prefers_this_windows_close_over_a_newer_one_of_another_live_window() {
    let mut local = machine(
        "local",
        true,
        vec![
            ClosedItem {
                workspace_id: Some("ws_mine".into()),
                ..closed_tab("mine", 10, terminal("/"))
            },
            ClosedItem {
                workspace_id: Some("ws_other".into()),
                ..closed_tab("other", 20, terminal("/"))
            },
        ],
    );
    local.workspace_windows.insert("ws_mine".into(), "w1".into());
    local.workspace_windows.insert("ws_other".into(), "w2".into());
    let machines = vec![local];
    let registry: Registry = [("w1".to_owned(), true), ("w2".to_owned(), true)].into();
    let pick = listing::newest(&machines, &installs(), &registry, Some("w1")).unwrap();
    assert_eq!(pick.item.id, "mine");
    let pick = listing::newest(&machines, &installs(), &registry, Some("w2")).unwrap();
    assert_eq!(pick.item.id, "other");
}

#[test]
fn newest_takes_a_close_no_live_window_owns() {
    let machines = vec![machine("local", true, vec![closed_tab("orphan", 5, terminal("/"))])];
    let pick = listing::newest(&machines, &installs(), &Registry::new(), Some("w1")).unwrap();
    assert_eq!(pick.item.id, "orphan");
    assert!(listing::newest(&[], &installs(), &Registry::new(), Some("w1")).is_none());
}

#[test]
fn owner_facts_read_the_window_record_only_on_this_macs_daemon() {
    let item = ClosedItem {
        window: Some("install-a/w9".into()),
        workspace_id: Some("ws".into()),
        ..ClosedItem::new("c", Kind::Workspace)
    };
    let mut local = machine("local", true, vec![item.clone()]);
    local.workspace_windows.insert("ws".into(), "w3".into());
    let remote = machine("m2", false, vec![item]);
    let machines = vec![local, remote];
    let registry: Registry = [("w9".to_owned(), false)].into();
    let entries = listing::all_entries(&machines);
    let facts = listing::owner_facts(&entries[0], &installs(), &registry);
    assert_eq!(facts.kind, ItemKind::Workspace);
    assert!(facts.local);
    assert_eq!(facts.recorded_window.as_deref(), Some("w9"));
    assert_eq!(facts.recorded_open, Some(false));
    assert_eq!(facts.workspace_window.as_deref(), Some("w3"));
    let facts = listing::owner_facts(&entries[1], &installs(), &registry);
    assert!(!facts.local);
    assert_eq!(facts.recorded_window, None);
    assert_eq!(facts.recorded_open, None);
    assert_eq!(facts.workspace_window, None);
}

#[test]
fn owner_facts_ignore_another_installs_record() {
    let item =
        ClosedItem { window: Some("install-b/w9".into()), ..ClosedItem::new("c", Kind::Window) };
    let machines = vec![machine("local", true, vec![item])];
    let entries = listing::all_entries(&machines);
    let facts = listing::owner_facts(&entries[0], &installs(), &Registry::new());
    assert_eq!(facts.recorded_window, None);
    assert_eq!(facts.kind, ItemKind::Window);
}

// MARK: newestOnce, closes

#[test]
fn newest_once_lists_a_page_closed_again_once() {
    let a = closed_tab("a", 30, browser("https://same.test/"));
    let b = closed_tab("b", 20, terminal("/x"));
    let c = closed_tab("c", 10, browser("https://same.test/"));
    let once = listing::newest_once(&[(&a, "local"), (&b, "local"), (&c, "local")]);
    assert_eq!(once, [0, 1]);
    let other_machine = listing::newest_once(&[(&a, "local"), (&c, "m2")]);
    assert_eq!(other_machine, [0, 1]);
    assert!(listing::newest_once(&[]).is_empty());
}

#[test]
fn closes_of_a_page_row_are_every_close_of_it_and_else_the_row_alone() {
    let a = closed_tab("a", 30, browser("https://same.test/"));
    let b = closed_tab("b", 20, terminal("/x"));
    let c = closed_tab("c", 10, browser("https://same.test/"));
    let closed = [(&a, "local"), (&b, "local"), (&c, "local")];
    assert_eq!(listing::closes((&a, "local"), &closed), [Some(0), Some(2)]);
    let lone = closed_tab("z", 5, terminal("/z"));
    assert_eq!(listing::closes((&lone, "local"), &closed), [None]);
}

// MARK: HistoryService.daemonClosedText, closedEntries

#[test]
fn text_title_chain_group_then_names_then_page_agent_url_cwd_untitled() {
    let words =
        Words { pages: [("diff".to_owned(), "Diff".to_owned())].into(), ..Words::default() };
    let group = ClosedItem {
        name: Some("ignored".into()),
        group: Some(Group { id: "g".into(), name: "Team".into(), ..Group::default() }),
        ..ClosedItem::new("c", Kind::Workspace)
    };
    assert_eq!(history::text(&group, &words).0, "Group \u{201c}Team\u{201d}");
    let unnamed = ClosedItem {
        group: Some(Group { id: "g".into(), name: String::new(), ..Group::default() }),
        ..ClosedItem::new("c", Kind::Workspace)
    };
    assert_eq!(history::text(&unnamed, &words).0, "Group \u{201c}Unnamed Group\u{201d}");

    let named = ClosedItem { name: Some("ws-name".into()), ..closed_tab("c", 1, terminal("/x")) };
    assert_eq!(history::text(&named, &words), ("ws-name".to_owned(), Some("/x".to_owned())));

    let blank_name = ClosedItem {
        name: Some("about:blank".into()),
        ..closed_tab("c", 1, Tab { name: Some("tab-name".into()), ..terminal("/x") })
    };
    assert_eq!(history::text(&blank_name, &words).0, "tab-name");

    assert_eq!(history::text(&closed_tab("c", 1, page("diff")), &words), ("Diff".to_owned(), None));
    assert_eq!(history::text(&closed_tab("c", 1, page("raw")), &words).0, "raw");

    let agent = Tab { agent_session: Some(AgentSession::default()), ..blank() };
    assert_eq!(history::text(&closed_tab("c", 1, agent), &words), ("Agent".to_owned(), None));

    let site = closed_tab("c", 1, Tab { cwd: Some("/w".into()), ..browser("https://a.test/") });
    assert_eq!(
        history::text(&site, &words),
        ("https://a.test/".to_owned(), Some("https://a.test/".to_owned()))
    );
    assert_eq!(history::text(&closed_tab("c", 1, terminal("/w")), &words).0, "/w");
    assert_eq!(
        history::text(&ClosedItem::new("c", Kind::Tab), &words),
        ("Terminal".to_owned(), None)
    );
}

#[test]
fn words_group_replaces_only_the_first_placeholder() {
    let words = Words { group_title: "%@ / %@".into(), ..Words::default() };
    assert_eq!(words.group("A"), "A / %@");
}

#[test]
fn history_ids_round_trip_and_trackers_have_none() {
    assert_eq!(history::history_id("closed_1"), "daemon:closed_1");
    assert_eq!(history::daemon_id("daemon:closed_1"), Some("closed_1"));
    assert_eq!(history::daemon_id("tracker:1"), None);
    assert_eq!(history::entry_id("closed_1"), "closed:daemon:closed_1");
}

#[test]
fn closed_rows_skip_blank_items_list_a_page_once_and_honour_the_limit() {
    let machines = vec![
        machine(
            "local",
            true,
            vec![
                closed_tab("a", 40, browser("https://same.test/")),
                closed_tab("blank", 35, blank()),
                closed_tab("b", 30, terminal("/x")),
                closed_tab("c", 20, browser("https://same.test/")),
            ],
        ),
        machine("studio", false, vec![closed_tab("d", 10, terminal("/y"))]),
    ];
    let rows = history::closed_rows(&machines, None, &Words::default());
    let ids: Vec<_> = rows.iter().map(|row| row.id.clone()).collect();
    assert_eq!(ids, ["closed:daemon:a", "closed:daemon:b", "closed:daemon:d"]);
    assert_eq!(rows[0].machine_name, None);
    assert_eq!(rows[2].machine_name.as_deref(), Some("studio"));
    assert!(rows.iter().all(|row| row.is_available));
    assert_eq!(rows[0].closed.id, "daemon:a");
    assert_eq!(rows[0].closed.kind, HistoryKind::BrowserTab);
    assert_eq!(rows[0].closed.url.as_deref(), Some("https://same.test/"));
    assert_eq!(rows[1].closed.cwd.as_deref(), Some("/x"));
    assert_eq!(rows[2].at, EntryRef { machine: 1, item: 0 });
    let limited = history::closed_rows(&machines, Some(1), &Words::default());
    assert_eq!(limited.len(), 1);
    assert!(history::closed_rows(&machines, Some(0), &Words::default()).is_empty());
}

#[test]
fn closed_rows_never_carry_a_page_tabs_placeholder_address() {
    let machines = vec![machine("local", true, vec![closed_tab("p", 1, page("settings"))])];
    let rows = history::closed_rows(&machines, None, &Words::default());
    assert_eq!(rows[0].closed.url, None);
    assert_eq!(rows[0].detail, None);
    assert_eq!(rows[0].title, "settings");
}

// MARK: NewTabClosed

fn source(id: &str, at: u64, title: &str, item: SourceItem) -> Source {
    Source {
        id: id.to_owned(),
        time_ms: at,
        title: title.to_owned(),
        detail: None,
        is_available: true,
        closed: Some(item),
    }
}

fn source_item(kind: HistoryKind, url: Option<&str>, cwd: Option<&str>) -> SourceItem {
    SourceItem {
        kind,
        url: url.map(str::to_owned),
        cwd: cwd.map(str::to_owned),
        agent_session: None,
    }
}

#[test]
fn new_tab_kind_reads_a_browser_with_an_agent_chat_as_an_agent() {
    let mut item = source_item(HistoryKind::BrowserTab, None, None);
    assert_eq!(new_tab::kind(&item), PageKind::Browser);
    item.agent_session = Some(Default::default());
    assert_eq!(new_tab::kind(&item), PageKind::Agent);
    assert_eq!(
        new_tab::kind(&source_item(HistoryKind::ConversationTab, None, None)),
        PageKind::Agent
    );
    assert_eq!(
        new_tab::kind(&source_item(HistoryKind::TerminalTab, None, None)),
        PageKind::Terminal
    );
    assert_eq!(new_tab::kind(&source_item(HistoryKind::Screen, None, None)), PageKind::Screen);
    assert_eq!(
        new_tab::kind(&source_item(HistoryKind::Workspace, None, None)),
        PageKind::Workspace
    );
}

#[test]
fn new_tab_items_are_newest_first_closed_only_and_at_most_eight() {
    let mut sources: Vec<Source> = (0..12)
        .map(|n| {
            source(&format!("s{n}"), n, "t", source_item(HistoryKind::TerminalTab, None, None))
        })
        .collect();
    sources.push(Source {
        closed: None,
        ..source("visit", 100, "v", source_item(HistoryKind::TerminalTab, None, None))
    });
    let items = new_tab::items(&sources, "/Users/me");
    assert_eq!(items.len(), new_tab::MAXIMUM_PUSHED);
    assert_eq!(items[0].id, "s11");
    assert_eq!(items[7].id, "s4");
}

#[test]
fn new_tab_detail_is_the_address_else_the_folder_with_a_tilde_else_the_rows() {
    let home = "/Users/me";
    let site = source(
        "a",
        3,
        "x",
        source_item(HistoryKind::BrowserTab, Some("https://a.test/p"), Some("/Users/me/w")),
    );
    let folder =
        source("b", 2, "x", source_item(HistoryKind::TerminalTab, None, Some("/Users/me/w")));
    let mut neither = source("c", 1, "x", source_item(HistoryKind::Workspace, None, None));
    neither.detail = Some("row detail".into());
    neither.is_available = false;
    let items = new_tab::items(&[site, folder, neither], home);
    assert_eq!(items[0].detail.as_deref(), Some("https://a.test/p"));
    assert_eq!(items[1].detail.as_deref(), Some("~/w"));
    assert_eq!(items[2].detail.as_deref(), Some("row detail"));
    assert!(!items[2].available);
    assert_eq!(items[0].closed_at, 3);
}

#[test]
fn new_tab_title_shortens_a_title_that_is_only_the_address_or_folder() {
    assert_eq!(new_tab::title("https://a.test/", Some("https://a.test/"), None), "a.test");
    assert_eq!(
        new_tab::title("https://a.test/x/y", Some("https://a.test/x/y"), None),
        "a.test/x/y"
    );
    assert_eq!(new_tab::title("https://a.test", Some("https://a.test"), None), "a.test");
    assert_eq!(new_tab::title("Page", Some("https://a.test/"), None), "Page");
    assert_eq!(new_tab::title("about:blank", Some("about:blank"), None), "about:blank");
    assert_eq!(new_tab::title("/Users/me/proj", None, Some("/Users/me/proj")), "proj");
    assert_eq!(new_tab::title("/Users/me/proj/", None, Some("/Users/me/proj/")), "proj");
    assert_eq!(new_tab::title("/", None, Some("/")), "/");
    assert_eq!(new_tab::title("name", None, Some("/x")), "name");
}

#[test]
fn host_and_path_drop_user_port_brackets_and_decode() {
    assert_eq!(
        new_tab::host_and_path("https://user:pw@host.test:8443/a%20b?q=1#f"),
        Some(("host.test".to_owned(), "/a b".to_owned()))
    );
    assert_eq!(
        new_tab::host_and_path("http://[::1]:3000/x"),
        Some(("::1".to_owned(), "/x".to_owned()))
    );
    assert_eq!(new_tab::host_and_path("http://h?x"), Some(("h".to_owned(), String::new())));
    assert_eq!(new_tab::host_and_path("mailto:a@b"), None);
    assert_eq!(new_tab::host_and_path("file:///tmp/x"), None);
    assert_eq!(new_tab::host_and_path("1http://h/"), None);
    assert_eq!(new_tab::host_and_path("no colon"), None);
}

#[test]
fn percent_decode_keeps_text_that_does_not_decode_to_utf8() {
    assert_eq!(new_tab::percent_decode("a%2Fb"), "a/b");
    assert_eq!(new_tab::percent_decode("%E2%9C%93"), "\u{2713}");
    assert_eq!(new_tab::percent_decode("%FF"), "%FF");
    assert_eq!(new_tab::percent_decode("100%"), "100%");
    assert_eq!(new_tab::percent_decode("%zz"), "%zz");
}

#[test]
fn last_path_component_and_tilde_follow_nsstring() {
    assert_eq!(new_tab::last_path_component(""), "");
    assert_eq!(new_tab::last_path_component("///"), "/");
    assert_eq!(new_tab::last_path_component("a"), "a");
    assert_eq!(new_tab::last_path_component("/a/b//"), "b");
    assert_eq!(new_tab::abbreviate_tilde("/Users/me", "/Users/me"), "~");
    assert_eq!(new_tab::abbreviate_tilde("/Users/me/x", "/Users/me/"), "~/x");
    assert_eq!(new_tab::abbreviate_tilde("/Users/meme", "/Users/me"), "/Users/meme");
    assert_eq!(new_tab::abbreviate_tilde("/tmp", ""), "/tmp");
}

// MARK: recordID, CloudInstallIDs.windowID, releaseWindow

#[test]
fn record_ids_and_window_ids() {
    assert_eq!(records::record_id(Some("i"), "w"), Some("i/w".to_owned()));
    assert_eq!(records::record_id(None, "w"), None);
    let installs = ids(&["old", "new"]);
    assert_eq!(records::window_id("new/w1", &installs), Some("w1".to_owned()));
    assert_eq!(records::window_id("old/w/x", &installs), Some("w/x".to_owned()));
    assert_eq!(records::window_id("other/w1", &installs), None);
    assert_eq!(records::window_id("neww1", &installs), None);
    assert_eq!(records::window_id("new/", &installs), Some(String::new()));
}

#[test]
fn reopened_window_id_is_swifts_split_max_one_last() {
    assert_eq!(records::reopened_window_id("i/w"), Some("w".to_owned()));
    assert_eq!(records::reopened_window_id("i/w/x"), Some("w/x".to_owned()));
    assert_eq!(records::reopened_window_id("abc/"), Some("abc".to_owned()));
    assert_eq!(records::reopened_window_id("/w"), Some("w".to_owned()));
    assert_eq!(records::reopened_window_id("i//w"), Some("/w".to_owned()));
    assert_eq!(records::reopened_window_id("w"), Some("w".to_owned()));
    assert_eq!(records::reopened_window_id(""), None);
    assert_eq!(records::reopened_window_id("///"), None);
}

#[test]
fn released_window_is_a_local_window_item_of_this_install() {
    let window =
        ClosedItem { window: Some("install-a/w1".into()), ..ClosedItem::new("c", Kind::Window) };
    assert_eq!(records::released_window(&window, true, &installs()), Some("w1".to_owned()));
    assert_eq!(records::released_window(&window, false, &installs()), None);
    let workspace = ClosedItem { kind: Kind::Workspace, ..window };
    assert_eq!(records::released_window(&workspace, true, &installs()), None);
    let unrecorded = ClosedItem::new("c", Kind::Window);
    assert_eq!(records::released_window(&unrecorded, true, &installs()), None);
}

// MARK: DaemonClosedHistory.reopen, show, delete, clear

#[test]
fn reopen_start_names_the_pane_and_page_history_on_this_mac_only() {
    let item = ClosedItem { pane_id: Some("pane".into()), ..closed_tab("c", 1, terminal("/")) };
    let start = reopen::start(&item, true);
    assert_eq!(start.pane.as_deref(), Some("pane"));
    assert!(start.expect_page_history);
    assert!(!reopen::start(&item, false).expect_page_history);
}

#[test]
fn after_reply_a_group_is_done_whatever_its_kind() {
    let item = ClosedItem {
        group: Some(Group { id: "g".into(), name: "G".into(), ..Group::default() }),
        ..ClosedItem::new("c", Kind::Workspace)
    };
    assert_eq!(reopen::after_reply(&item, &Reopened::default(), true), AfterReply::Done);
}

#[test]
fn after_reply_a_window_reopens_its_record_or_refuses_with_its_id() {
    let item = ClosedItem::new("closed_w", Kind::Window);
    let reopened = Reopened { window: Some("install-a/w7".into()), ..Reopened::default() };
    assert_eq!(
        reopen::after_reply(&item, &reopened, false),
        AfterReply::ReopenWindow { window: Some("w7".into()), refuse: "w7".into() }
    );
    assert_eq!(
        reopen::after_reply(&item, &Reopened::default(), false),
        AfterReply::ReopenWindow { window: None, refuse: "closed_w".into() }
    );
}

#[test]
fn after_reply_a_tab_selects_in_its_shown_pane_else_shows() {
    let item = closed_tab("c", 1, terminal("/"));
    let reopened = Reopened {
        tab_ids: ids(&["t1", "t2"]),
        workspace_id: Some("ws".into()),
        ..Reopened::default()
    };
    assert_eq!(
        reopen::after_reply(&item, &reopened, true),
        AfterReply::SelectTab { tab: "t1".into() }
    );
    assert_eq!(reopen::after_reply(&item, &reopened, false), AfterReply::Show { kind: Kind::Tab });
    let no_tabs = Reopened { workspace_id: Some("ws".into()), ..Reopened::default() };
    assert_eq!(reopen::after_reply(&item, &no_tabs, true), AfterReply::Show { kind: Kind::Tab });
}

#[test]
fn after_reply_a_workspace_reveals_it_or_refuses_with_the_item_id() {
    let item = ClosedItem::new("closed_ws", Kind::Workspace);
    let reopened = Reopened { workspace_id: Some("ws".into()), ..Reopened::default() };
    assert_eq!(
        reopen::after_reply(&item, &reopened, false),
        AfterReply::RevealWorkspace { workspace: Some("ws".into()), refuse: "ws".into() }
    );
    assert_eq!(
        reopen::after_reply(&item, &Reopened::default(), false),
        AfterReply::RevealWorkspace { workspace: None, refuse: "closed_ws".into() }
    );
    let screen = ClosedItem::new("s", Kind::Screen);
    assert_eq!(
        reopen::after_reply(&screen, &reopened, true),
        AfterReply::Show { kind: Kind::Screen }
    );
}

#[test]
fn show_selects_the_first_screen_or_tab_and_needs_a_workspace() {
    let reopened = Reopened {
        tab_ids: ids(&["t1"]),
        screen_ids: ids(&["s1", "s2"]),
        workspace_id: Some("ws".into()),
        window: None,
    };
    assert_eq!(
        reopen::show(Kind::Screen, &reopened),
        Some(ShowSelect::Screen { screen: "s1".into() })
    );
    assert_eq!(reopen::show(Kind::Tab, &reopened), Some(ShowSelect::Tab { tab: "t1".into() }));
    assert_eq!(reopen::show(Kind::Workspace, &reopened), Some(ShowSelect::Nothing));
    assert_eq!(reopen::show(Kind::Window, &reopened), Some(ShowSelect::Nothing));
    let bare = Reopened { workspace_id: Some("ws".into()), ..Reopened::default() };
    assert_eq!(reopen::show(Kind::Tab, &bare), Some(ShowSelect::Nothing));
    assert_eq!(reopen::show(Kind::Tab, &Reopened { workspace_id: None, ..reopened }), None);
}

#[test]
fn tabs_arrived_needs_every_reopened_tab_in_the_store() {
    assert!(reopen::tabs_arrived(&[], &[]));
    assert!(reopen::tabs_arrived(&ids(&["a"]), &ids(&["b", "a"])));
    assert!(!reopen::tabs_arrived(&ids(&["a", "c"]), &ids(&["a"])));
}

#[test]
fn reopen_failure_of_a_gone_workspace_refuses_and_anything_else_is_an_error() {
    let workspace = ClosedItem::new("c", Kind::Workspace);
    assert_eq!(
        reopen::reopen_failure(&workspace, Some(reopen::NOT_FOUND)),
        ReopenFailure::NoRecentlyClosedWorkspace
    );
    assert_eq!(reopen::reopen_failure(&workspace, Some("internal")), ReopenFailure::Error);
    assert_eq!(reopen::reopen_failure(&workspace, None), ReopenFailure::Error);
    let group = ClosedItem {
        group: Some(Group { id: "g".into(), name: "G".into(), ..Group::default() }),
        ..workspace
    };
    assert_eq!(reopen::reopen_failure(&group, Some(reopen::NOT_FOUND)), ReopenFailure::Error);
    let tab = closed_tab("c", 1, terminal("/"));
    assert_eq!(reopen::reopen_failure(&tab, Some(reopen::NOT_FOUND)), ReopenFailure::Error);
}

#[test]
fn delete_releases_a_local_window_and_not_found_counts_as_done() {
    let window =
        ClosedItem { window: Some("install-a/w1".into()), ..ClosedItem::new("c", Kind::Window) };
    let plan = reopen::delete(&window, true, &installs());
    assert_eq!(plan.release_window.as_deref(), Some("w1"));
    assert!(plan.empty_trash);
    let remote = reopen::delete(&window, false, &installs());
    assert_eq!(remote.release_window, None);
    assert!(!remote.empty_trash);
    assert!(reopen::delete_failure_is_done(Some("resource.not_found")));
    assert!(!reopen::delete_failure_is_done(Some("resource.busy")));
    assert!(!reopen::delete_failure_is_done(None));
}

#[test]
fn since_ms_clamps_negative_and_drops_fractions() {
    assert_eq!(reopen::since_ms(-5.0), 0);
    assert_eq!(reopen::since_ms(0.0), 0);
    assert_eq!(reopen::since_ms(1.2345), 1234);
    assert_eq!(reopen::since_ms(1_700_000_000.5), 1_700_000_000_500);
    assert_eq!(reopen::since_ms(f64::NAN), 0);
}

#[test]
fn clear_releases_local_windows_closed_since_and_clears_every_serving_machine() {
    let window = |id: &str, at: u64, w: &str| ClosedItem {
        closed_at_ms: at,
        window: Some(format!("install-a/{w}")),
        ..ClosedItem::new(id, Kind::Window)
    };
    let mut quiet = machine("m3", false, vec![]);
    quiet.serves = false;
    let machines = vec![
        machine(
            "local",
            true,
            vec![
                window("a", 1000, "old"),
                window("b", 5000, "new"),
                closed_tab("t", 6000, terminal("/")),
            ],
        ),
        machine("m2", false, vec![window("c", 9000, "remote")]),
        quiet,
    ];
    let plan = reopen::clear(&machines, Some(2.0), &installs());
    assert_eq!(plan.since_ms, Some(2000));
    assert_eq!(plan.release_windows, ids(&["new"]));
    assert_eq!(plan.machines, [0, 1]);
    assert_eq!(plan.empty_trash, [0]);
    let all = reopen::clear(&machines, None, &installs());
    assert_eq!(all.since_ms, None);
    assert_eq!(all.release_windows, ids(&["new", "old"]));
    let exactly = reopen::clear(&machines, Some(5.0), &installs());
    assert_eq!(exactly.release_windows, ids(&["new"]));
}

// MARK: ClosedTabsFeed.signature

#[test]
fn feed_signature_lists_connected_loaded_machines_revision_then_closed_ids() {
    let machines = vec![
        FeedMachine {
            machine: "local".into(),
            connected: true,
            loaded: true,
            tab_list_revision: 7,
            closed: ids(&["a", "b"]),
        },
        FeedMachine {
            machine: "m2".into(),
            connected: true,
            loaded: false,
            tab_list_revision: 1,
            closed: ids(&["x"]),
        },
        FeedMachine {
            machine: "m3".into(),
            connected: false,
            loaded: true,
            tab_list_revision: 1,
            closed: ids(&["y"]),
        },
        FeedMachine {
            machine: "m4".into(),
            connected: true,
            loaded: true,
            tab_list_revision: 0,
            closed: vec![],
        },
    ];
    assert_eq!(feed::signature(&machines), ids(&["local:7", "a", "b", "m4:0"]));
    assert!(feed::signature(&[]).is_empty());
    let previous = feed::signature(&machines);
    assert!(!feed::changed(&previous, &machines));
    let mut bumped = machines;
    bumped[0].tab_list_revision = 8;
    assert!(feed::changed(&previous, &bumped));
}

// MARK: CloseUndoToasts

#[test]
fn daemon_item_ids_are_every_serving_machines_in_order() {
    let mut quiet = machine("m2", false, vec![closed_tab("q", 1, terminal("/"))]);
    quiet.serves = false;
    let machines = vec![
        machine(
            "local",
            true,
            vec![closed_tab("b", 1, terminal("/")), closed_tab("a", 2, terminal("/"))],
        ),
        quiet,
        machine("m3", false, vec![closed_tab("c", 3, terminal("/"))]),
    ];
    assert_eq!(undo::daemon_item_ids(&machines), ids(&["b", "a", "c"]));
}

#[test]
fn added_are_the_unseen_ids_in_order_and_seen_becomes_the_current_set() {
    let mut seen: BTreeSet<String> = ids(&["a", "b"]).into_iter().collect();
    let added = undo::added(&mut seen, &ids(&["c", "a", "d"]));
    assert_eq!(added, ids(&["c", "d"]));
    assert_eq!(seen, ids(&["a", "c", "d"]).into_iter().collect::<BTreeSet<_>>());
    assert!(undo::added(&mut seen, &ids(&["a"])).is_empty());
    assert_eq!(undo::added(&mut seen, &ids(&["c"])), ids(&["c"]));
}

#[test]
fn recorded_items_carry_kind_pane_and_tab_count_and_a_gone_item_is_other() {
    let item = ClosedItem {
        pane_id: Some("p1".into()),
        ..with_tabs("a", Kind::Tab, 1, vec![terminal("/"), terminal("/")])
    };
    let machines = vec![machine("local", true, vec![item])];
    let items = undo::recorded_items(&machines, &ids(&["a", "gone"]));
    assert_eq!(items[0].kind, ItemKind::Tab);
    assert_eq!(items[0].pane.as_deref(), Some("p1"));
    assert_eq!(items[0].tabs, 2);
    assert_eq!(items[1].kind, ItemKind::Other);
    assert_eq!(items[1].pane, None);
    assert_eq!(items[1].tabs, 0);
}

#[test]
fn recent_keeps_the_newest_eight_and_a_missing_match_is_false() {
    let mut recent = Vec::new();
    let items: Vec<_> = (0..10).map(|n| undo::recorded_item(&format!("i{n}"), None)).collect();
    undo::push_recent(&mut recent, &items, &[true, true]);
    assert_eq!(recent.len(), undo::RECENT_LIMIT);
    assert_eq!(recent[0].id, "i2");
    assert!(!recent[0].matched);
    assert_eq!(recent[7].id, "i9");
    let mut short = vec![RecentItem { id: "x".into(), matched: true, ..RecentItem::default() }];
    undo::push_recent(&mut short, &items[..1], &[true]);
    assert_eq!(short.len(), 2);
    assert!(short[1].matched);
}

#[test]
fn rate_limit_allows_one_new_toast_per_id_per_gap() {
    let mut limit = RateLimit::default();
    assert_eq!(limit.minimum_gap_ms, 30_000);
    assert!(limit.allows("tab-closed", 1_000));
    assert!(!limit.allows("tab-closed", 30_999));
    assert!(limit.allows("other", 2_000));
    assert!(limit.allows("tab-closed", 31_000));
    assert!(!limit.allows("tab-closed", 31_001));
}

#[test]
fn rate_limit_of_zero_is_off_and_a_refusal_does_not_count() {
    let mut off = RateLimit::new(0);
    assert!(off.allows("t", 5));
    assert!(off.allows("t", 5));
    let mut limit = RateLimit::new(100);
    assert!(limit.allows("t", 0));
    assert!(!limit.allows("t", 50));
    assert!(limit.allows("t", 100));
}

#[test]
fn toast_joins_the_shown_toast_of_its_window_else_asks_the_limit() {
    let mut limit = RateLimit::default();
    let shown = ShownToast { window: "w1".into(), tabs: 2, dismissed: false };
    assert_eq!(undo::toast(&mut limit, 1, Some(&shown), "w1", 0), ToastShow::Join { tabs: 3 });
    assert!(limit.last_shown.is_empty(), "a join is not counted");
    assert_eq!(undo::toast(&mut limit, 1, Some(&shown), "w2", 0), ToastShow::New { tabs: 1 });
    assert_eq!(undo::toast(&mut limit, 4, None, "w1", 10), ToastShow::Drop);
    let dismissed = ShownToast { dismissed: true, ..shown };
    assert_eq!(
        undo::toast(&mut limit, 1, Some(&dismissed), "w1", 40_000),
        ToastShow::New { tabs: 1 }
    );
}

#[test]
fn joinable_needs_the_same_window_and_not_dismissed() {
    let shown = ShownToast { window: "w".into(), tabs: 5, dismissed: false };
    assert_eq!(undo::joinable(Some(&shown), "w"), Some(5));
    assert_eq!(undo::joinable(Some(&shown), "v"), None);
    assert_eq!(undo::joinable(None, "w"), None);
}

#[test]
fn message_counts_several_tabs_and_names_one() {
    assert_eq!(undo::message(3, "x"), Message::Tabs { count: 3 });
    assert_eq!(undo::message(1, "Docs"), Message::Tab { title: "Docs".into() });
    assert_eq!(undo::message(1, ""), Message::Untitled);
    assert_eq!(undo::message(0, "t"), Message::Tab { title: "t".into() });
}

#[test]
fn reopen_order_is_last_closed_first_and_a_join_reopens_the_newest_close_first() {
    assert_eq!(undo::reopen_order(&ids(&["a", "b", "c"])), ids(&["c", "b", "a"]));
    let closes = vec![ids(&["a1", "a2"]), ids(&["b1"]), ids(&["c1", "c2"])];
    assert_eq!(undo::joined_reopen_order(&closes), ids(&["c2", "c1", "b1", "a2", "a1"]));
    assert!(undo::joined_reopen_order(&[]).is_empty());
}

#[test]
fn announce_takes_each_tabs_place_in_its_pane_and_titles_only_one_tab() {
    let parts = vec![
        ClosingPart {
            tabs: ids(&["t3", "t1", "gone"]),
            pane_tabs: ids(&["t1", "t2", "t3"]),
            pane: Some("p1".into()),
        },
        ClosingPart { tabs: ids(&["u1"]), pane_tabs: ids(&["u0", "u1"]), pane: None },
    ];
    let announce = undo::announce(&parts);
    assert_eq!(
        announce.tabs,
        [
            ExpectedTab { id: "t3".into(), index: 2 },
            ExpectedTab { id: "t1".into(), index: 0 },
            ExpectedTab { id: "u1".into(), index: 1 },
        ]
    );
    assert_eq!(announce.panes, ids(&["p1"]));
    assert!(!announce.titled);
    let one =
        undo::announce(&[ClosingPart { tabs: ids(&["t"]), pane_tabs: ids(&["t"]), pane: None }]);
    assert!(one.titled);
}

#[test]
fn waiting_sorts_and_joins_panes_and_counts_tabs() {
    let state = UndoState {
        expected: vec![Expected {
            token: 1,
            tabs: vec![
                ExpectedTab { id: "a".into(), index: 0 },
                ExpectedTab { id: "b".into(), index: 1 },
            ],
            panes: ids(&["p2", "p1"]),
            costly: true,
            items: vec![],
            recorded: 1,
        }],
    };
    let waiting = undo::waiting(&state);
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].pane, "p1,p2");
    assert_eq!(waiting[0].tabs, 2);
    assert_eq!(waiting[0].daemon_tabs, 1);
}

#[test]
fn the_whole_undo_flow_announce_record_settle_toast_reopen() {
    // CloseUndoToasts: expectGroup, then daemonItemsChanged, then show, then the Undo.
    let parts = vec![ClosingPart {
        tabs: ids(&["t1", "t2"]),
        pane_tabs: ids(&["t1", "t2", "t3"]),
        pane: Some("p1".into()),
    }];
    let announce = undo::announce(&parts);
    let mut state = UndoState::default();
    closed::expect(&mut state, 1, announce.tabs, announce.panes, true);
    let item = ClosedItem {
        pane_id: Some("p1".into()),
        ..with_tabs("c1", Kind::Tab, 1, vec![terminal("/"), terminal("/")])
    };
    let machines = vec![machine("local", true, vec![item])];
    let mut seen = BTreeSet::new();
    let added = undo::added(&mut seen, &undo::daemon_item_ids(&machines));
    let items = undo::recorded_items(&machines, &added);
    let recorded = closed::record(&mut state, &items);
    assert_eq!(recorded.matched, [true]);
    assert_eq!(recorded.settled.len(), 1);
    let settled = &recorded.settled[0];
    assert!(settled.shows);
    let mut limit = RateLimit::default();
    assert_eq!(undo::toast(&mut limit, settled.tabs, None, "w", 0), ToastShow::New { tabs: 2 });
    assert_eq!(undo::message(settled.tabs, ""), Message::Tabs { count: 2 });
    assert_eq!(undo::reopen_order(&settled.items), ids(&["c1"]));
    assert!(undo::waiting(&state).is_empty());
}

// MARK: ops

#[test]
fn ops_serve_only_closed_tabs_and_refuse_unknown_and_bad_requests() {
    assert!(ops::serves("closed_tabs_entries"));
    assert!(!ops::serves("browser_rules_link_action"));
    assert_eq!(
        ops::call("closed_tabs_nope", Value::Null),
        Err(OpError::UnknownOp("closed_tabs_nope".into()))
    );
    assert!(matches!(
        ops::call("closed_tabs_entry", json!({"machines": []})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        ops::call("closed_tabs_undo_toast", json!({"tabs": "x", "now": 0})),
        Err(OpError::Invalid(_))
    ));
}

fn wire_machines() -> Value {
    json!([
        {"machine": "local", "local": true, "serves": true, "items": [
            {"id": "a", "kind": "tab", "closed_at_ms": "10", "pane_id": "p1",
             "screens": [{"tabs": [{"kind": "terminal", "cwd": "/x"}]}]},
            {"id": "w", "kind": "window", "closed_at_ms": 30, "window": "install-a/w1"},
        ]},
        {"machine": "studio", "serves": true, "items": [
            {"id": "b", "kind": "tab", "closed_at_ms": "20",
             "screens": [{"tabs": [{"kind": "browser", "url": "https://a.test/"}]}]},
        ]},
    ])
}

#[test]
fn ops_list_and_look_up_entries() {
    let machines = wire_machines();
    assert_eq!(
        call("closed_tabs_entries", json!({"machines": machines})),
        json!([{"machine": 0, "item": 1}, {"machine": 1, "item": 0}, {"machine": 0, "item": 0}])
    );
    assert_eq!(
        call("closed_tabs_entries", json!({"machines": machines, "kinds": ["tab"]})),
        json!([{"machine": 1, "item": 0}, {"machine": 0, "item": 0}])
    );
    assert_eq!(
        call("closed_tabs_entry", json!({"machines": machines, "id": "b"})),
        json!({"machine": 1, "item": 0})
    );
    assert_eq!(call("closed_tabs_entry", json!({"machines": machines, "id": "z"})), Value::Null);
    assert_eq!(
        call("closed_tabs_group_entry", json!({"machines": machines, "id": "g"})),
        Value::Null
    );
    assert_eq!(
        call("closed_tabs_is_served", json!({"machines": machines})),
        json!({"served": true})
    );
    assert_eq!(call("closed_tabs_is_served", Value::Null), json!({"served": false}));
    assert_eq!(
        call(
            "closed_tabs_newest",
            json!({"machines": machines, "installs": ["install-a"], "registry": {"w1": true}, "window": "w1"})
        ),
        json!({"machine": 0, "item": 1})
    );
}

#[test]
fn ops_newest_once_and_closes_take_placed_items() {
    let item = |id: &str| json!({"id": id, "kind": "tab", "screens": [{"tabs": [{"kind": "browser", "url": "https://s/"}]}]});
    let closed =
        json!([{"item": item("a"), "machine": "local"}, {"item": item("b"), "machine": "local"}]);
    assert_eq!(call("closed_tabs_newest_once", json!({"closed": closed})), json!([0]));
    assert_eq!(
        call(
            "closed_tabs_closes",
            json!({"target": {"item": item("a"), "machine": "local"}, "closed": closed})
        ),
        json!([0, 1])
    );
}

#[test]
fn ops_read_text_and_history_rows() {
    let item = json!({"id": "a", "kind": "tab", "screens": [{"tabs": [{"kind": "browser", "url": "https://a.test/", "agent_session": {"session": "s", "harness": "codex"}}]}]});
    let reading = call("closed_tabs_reading", json!({"item": item}));
    assert_eq!(reading["kind"], "browserTab");
    assert_eq!(reading["agentSession"], json!({"sessionID": "s", "harness": "codex"}));
    assert_eq!(reading["worthReopening"], true);
    assert_eq!(reading["shownTab"]["url"], "https://a.test/");
    assert_eq!(
        call("closed_tabs_text", json!({"item": item, "words": {"agentTitle": "Chat"}})),
        json!({"title": "Chat", "detail": "https://a.test/"})
    );
    let rows = call("closed_tabs_history_rows", json!({"machines": wire_machines(), "limit": 2}));
    let rows = rows.as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], "closed:daemon:w");
    assert_eq!(rows[0]["closed"]["kind"], "workspace");
    assert_eq!(rows[1]["machineName"], "studio");
    assert_eq!(rows[1]["timeMs"], 20);
    assert_eq!(
        call("closed_tabs_history_id", json!({"id": "a"})),
        json!({"historyID": "daemon:a"})
    );
    assert_eq!(call("closed_tabs_daemon_id", json!({"historyID": "daemon:a"})), json!({"id": "a"}));
    assert_eq!(call("closed_tabs_daemon_id", json!({"historyID": "x"})), json!({"id": null}));
}

#[test]
fn ops_new_tab_items_in_the_pages_json_shape() {
    let reply = call(
        "closed_tabs_new_tab_items",
        json!({"home": "/Users/me", "sources": [
            {"id": "closed:daemon:a", "timeMs": 5, "title": "https://a.test/",
             "closed": {"kind": "browserTab", "url": "https://a.test/"}},
            {"id": "visit", "timeMs": 9, "title": "v"},
        ]}),
    );
    assert_eq!(
        reply,
        json!([{"id": "closed:daemon:a", "kind": "browser", "title": "a.test",
                "detail": "https://a.test/", "closedAt": 5, "available": true}])
    );
}

#[test]
fn ops_records() {
    assert_eq!(
        call("closed_tabs_record_id", json!({"install": "i", "window": "w"})),
        json!({"record": "i/w"})
    );
    assert_eq!(call("closed_tabs_record_id", json!({"window": "w"})), json!({"record": null}));
    assert_eq!(
        call("closed_tabs_window_id", json!({"recorded": "i/w", "installs": ["i"]})),
        json!({"window": "w"})
    );
    assert_eq!(
        call("closed_tabs_reopened_window_id", json!({"record": "i//w"})),
        json!({"window": "/w"})
    );
}

#[test]
fn ops_reopen_steps() {
    let tab = json!({"id": "c", "kind": "tab", "pane_id": "p"});
    assert_eq!(
        call("closed_tabs_reopen_start", json!({"item": tab, "local": true})),
        json!({"pane": "p", "expectPageHistory": true})
    );
    assert_eq!(
        call(
            "closed_tabs_reopen_after_reply",
            json!({"item": tab, "reopened": {"tabIDs": ["t"]}, "paneShown": true})
        ),
        json!({"step": "selectTab", "tab": "t"})
    );
    assert_eq!(
        call("closed_tabs_reopen_after_reply", json!({"item": tab, "reopened": {}})),
        json!({"step": "show", "kind": "tab"})
    );
    let window = json!({"id": "cw", "kind": "window"});
    assert_eq!(
        call(
            "closed_tabs_reopen_after_reply",
            json!({"item": window, "reopened": {"window": "i/w"}})
        ),
        json!({"step": "reopenWindow", "window": "w", "refuse": "w"})
    );
    let workspace = json!({"id": "cws", "kind": "workspace"});
    assert_eq!(
        call("closed_tabs_reopen_after_reply", json!({"item": workspace})),
        json!({"step": "revealWorkspace", "workspace": null, "refuse": "cws"})
    );
    assert_eq!(
        call(
            "closed_tabs_reopen_show",
            json!({"kind": "screen", "reopened": {"workspaceID": "ws", "screenIDs": ["s"]}})
        ),
        json!({"select": "screen", "screen": "s"})
    );
    assert_eq!(call("closed_tabs_reopen_show", json!({"kind": "tab"})), Value::Null);
    assert_eq!(
        call(
            "closed_tabs_reopen_failure",
            json!({"item": workspace, "code": "resource.not_found"})
        ),
        json!({"failure": "noRecentlyClosedWorkspace"})
    );
    assert_eq!(
        call("closed_tabs_reopen_failure", json!({"item": tab})),
        json!({"failure": "error"})
    );
    assert_eq!(
        call("closed_tabs_tabs_arrived", json!({"tabs": ["a"], "storeTabs": ["a", "b"]})),
        json!({"arrived": true})
    );
}

#[test]
fn ops_delete_and_clear() {
    let window = json!({"id": "cw", "kind": "window", "window": "install-a/w1"});
    assert_eq!(
        call(
            "closed_tabs_delete",
            json!({"item": window, "local": true, "installs": ["install-a"]})
        ),
        json!({"releaseWindow": "w1", "emptyTrash": true})
    );
    assert_eq!(
        call("closed_tabs_delete_failure", json!({"code": "resource.not_found"})),
        json!({"done": true})
    );
    assert_eq!(call("closed_tabs_delete_failure", Value::Null), json!({"done": false}));
    assert_eq!(
        call(
            "closed_tabs_clear",
            json!({"machines": wire_machines(), "since": 0.0234375, "installs": ["install-a"]})
        ),
        json!({"sinceMs": 23, "releaseWindows": ["w1"], "machines": [0, 1], "emptyTrash": [0]})
    );
}

#[test]
fn ops_feed_signature() {
    assert_eq!(
        call(
            "closed_tabs_feed_signature",
            json!({"machines": [
                {"machine": "local", "connected": true, "loaded": true, "tabListRevision": 3, "closed": ["a"]},
                {"machine": "m2", "connected": false, "loaded": true, "tabListRevision": 1, "closed": ["b"]},
            ]})
        ),
        json!(["local:3", "a"])
    );
}

#[test]
fn ops_undo_glue_carries_its_state_through_the_reply() {
    assert_eq!(
        call("closed_tabs_undo_added", json!({"seen": ["a"], "ids": ["a", "b"]})),
        json!({"added": ["b"], "seen": ["a", "b"]})
    );
    assert_eq!(
        call(
            "closed_tabs_undo_recorded_items",
            json!({"machines": wire_machines(), "ids": ["a", "gone"]})
        ),
        json!([{"id": "a", "kind": "tab", "pane": "p1", "tabs": 1},
               {"id": "gone", "kind": "other", "pane": null, "tabs": 0}])
    );
    assert_eq!(
        call(
            "closed_tabs_undo_recent",
            json!({"recent": [], "items": [{"id": "a", "pane": "p", "tabs": 2}], "matched": [true]})
        ),
        json!({"recent": [{"id": "a", "pane": "p", "tabs": 2, "matched": true}]})
    );
    let first = call("closed_tabs_undo_toast", json!({"tabs": 1, "window": "w", "now": 0}));
    assert_eq!(first["show"], "new");
    assert_eq!(first["tabs"], 1);
    let second = call(
        "closed_tabs_undo_toast",
        json!({"limit": first["limit"], "tabs": 1, "window": "w", "now": 10}),
    );
    assert_eq!(second["show"], "drop");
    let joined = call(
        "closed_tabs_undo_toast",
        json!({"limit": first["limit"], "tabs": 2, "shown": {"window": "w", "tabs": 1}, "window": "w", "now": 10}),
    );
    assert_eq!(joined["show"], "join");
    assert_eq!(joined["tabs"], 3);
    assert_eq!(
        call("closed_tabs_undo_message", json!({"tabs": 2})),
        json!({"message": "tabs", "count": 2})
    );
    assert_eq!(
        call("closed_tabs_undo_message", json!({"tabs": 1})),
        json!({"message": "untitled"})
    );
    assert_eq!(
        call("closed_tabs_undo_reopen_order", json!({"closes": [["a", "b"], ["c"]]})),
        json!(["c", "b", "a"])
    );
    assert_eq!(
        call(
            "closed_tabs_undo_announce",
            json!({"parts": [{"tabs": ["t"], "paneTabs": ["s", "t"], "pane": "p"}]})
        ),
        json!({"tabs": [{"id": "t", "index": 1}], "panes": ["p"], "titled": true})
    );
    assert_eq!(
        call(
            "closed_tabs_undo_waiting",
            json!({"state": {"expected": [{"token": 1, "tabs": [{"id": "t", "index": 0}], "panes": ["b", "a"], "recorded": 0}]}})
        ),
        json!([{"pane": "a,b", "tabs": 1, "daemonTabs": 0}])
    );
}
