//! Mirrors the Swift suites the rules moved from: MovedTabWorkspaceNameTests,
//! TornOffWorkspaceNameTests' `forLastTab` cases and WorkspaceAutoNameTests.

use super::*;

const LIVE: AutoName = AutoName { enabled: true, variant: Variant::Live };
const PERSIST: AutoName = AutoName { enabled: true, variant: Variant::Persist };

fn s(text: &str) -> Option<String> {
    Some(text.to_owned())
}

fn terminal_tab(title: Option<&str>, user_name: Option<&str>, cwd: Option<&str>) -> Tab {
    Tab {
        kind: TabKind::Terminal,
        user_name: user_name.map(str::to_owned),
        title: title.map(str::to_owned),
        cwd: cwd.map(str::to_owned),
        ..Tab::default()
    }
}

fn page(title: Option<&str>, user_name: Option<&str>) -> Tab {
    Tab {
        kind: TabKind::Page,
        cwd: s("/Users/me/src/cmux"),
        ..terminal_tab(title, user_name, None)
    }
}

fn named(name: &str) -> Named {
    Named { name: name.to_owned(), ..Named::default() }
}

fn titled(name: &str, title: &str) -> Named {
    Named { title: s(title), ..named(name) }
}

fn user(name: &str, revision: u64, allows_legacy_defaults: bool) -> Named {
    Named {
        name_source: NameSource::User,
        name_revision: revision,
        allows_legacy_defaults,
        ..named(name)
    }
}

fn last_tab(name: &str, tab: &Tab) -> Option<String> {
    for_last_tab(&named(name), for_tab(tab))
}

fn terminal(title: Option<&str>, cwd: Option<&str>) -> Front {
    Front::Terminal { tab: terminal_tab(title, None, cwd) }
}

fn chat(user_name: Option<&str>, title: Option<&str>, generated_title: Option<&str>) -> Front {
    Front::Chat {
        user_name: user_name.map(str::to_owned),
        title: title.map(str::to_owned),
        generated_title: generated_title.map(str::to_owned),
    }
}

fn browser(title: &str, off_the_record: bool) -> Front {
    Front::Browser { title: s(title), off_the_record }
}

// MARK: Moved and torn-off tabs

#[test]
fn a_placeholder_title_names_nothing() {
    for title in
        ["about:blank", "About:Blank", "chrome://newtab/", "chrome://newtab", "  about:blank  "]
    {
        assert_eq!(for_tab(&terminal_tab(Some(title), None, None)), None, "{title}");
    }
}

#[test]
fn a_placeholder_title_falls_back_to_the_folder() {
    assert_eq!(
        for_tab(&terminal_tab(Some("about:blank"), None, Some("/Users/me/src/cmux"))),
        s("cmux")
    );
}

#[test]
fn a_page_tab_is_named_by_what_it_shows() {
    assert_eq!(for_tab(&page(Some("Chief"), None)), s("Chief"));
    assert_eq!(for_tab(&page(Some("Settings"), None)), s("Settings"));
    assert_eq!(for_tab(&page(Some("README.md"), Some("Docs"))), s("Docs"));
}

#[test]
fn the_whats_new_tab_names_its_workspace() {
    assert_eq!(for_tab(&page(Some("What’s New"), None)), s("What’s New"));
    assert_eq!(last_tab("workspace-42", &page(Some("What’s New"), None)), s("What’s New"));
    assert_eq!(last_tab("workspace-42", &page(Some("Settings"), None)), s("Settings"));
}

#[test]
fn a_page_tab_with_no_name_of_its_own_names_nothing() {
    for title in [None, Some(""), Some("about:blank"), Some("chrome://newtab/")] {
        assert_eq!(for_tab(&page(title, None)), None, "{title:?}");
        assert_eq!(last_tab("workspace-9", &page(title, None)), None, "{title:?}");
    }
}

#[test]
fn a_user_name_still_wins() {
    assert_eq!(for_tab(&terminal_tab(Some("about:blank"), Some("Planning"), None)), s("Planning"));
}

#[test]
fn the_last_tab_of_an_unnamed_workspace_names_nothing_from_a_placeholder() {
    assert_eq!(last_tab("workspace-4", &terminal_tab(Some("about:blank"), None, None)), None);
    assert_eq!(last_tab("Research", &terminal_tab(Some("about:blank"), None, None)), s("Research"));
}

#[test]
fn a_created_default_name_recorded_as_the_users_takes_the_moved_tabs_name() {
    assert_eq!(for_last_tab(&user("workspace-151", 0, false), s("api")), s("api"));
    assert_eq!(for_last_tab(&user(" workspace-151 ", 0, false), s("api")), s("workspace-151"));
}

#[test]
fn a_modern_user_home_marker_survives_moving_its_last_tab() {
    assert_eq!(for_last_tab(&user("~", 0, false), s("api")), s("~"));
}

#[test]
fn the_last_tab_of_a_workspace_the_user_named_keeps_that_name() {
    assert_eq!(for_last_tab(&named("Sidebar"), s("Fix the sidebar drag")), s("Sidebar"));
    assert_eq!(
        for_last_tab(&named("workspace-40"), s("Fix the sidebar drag")),
        s("Fix the sidebar drag")
    );
    assert_eq!(
        for_last_tab(&titled("workspace-40", "Launch"), s("Fix the sidebar drag")),
        s("Launch")
    );
}

#[test]
fn a_browser_is_named_by_its_page_title_else_its_host() {
    let tab = |page_title: Option<&str>, title: Option<&str>, url: &str| Tab {
        kind: TabKind::Browser,
        page_title: page_title.map(str::to_owned),
        title: title.map(str::to_owned),
        url: s(url),
        ..Tab::default()
    };
    assert_eq!(for_tab(&tab(Some("Docs"), None, "https://example.com")), s("Docs"));
    assert_eq!(
        for_tab(&tab(Some("https://www.example.com/a"), Some("Old"), "https://www.example.com/a")),
        s("Old")
    );
    assert_eq!(for_tab(&tab(None, None, "https://www.example.com/a")), s("example.com"));
    assert_eq!(for_tab(&tab(None, None, "not a url")), None);
}

#[test]
fn a_group_takes_its_name_else_its_first_tab() {
    let tab = terminal_tab(Some("npm test"), None, None);
    assert_eq!(for_group(Some(" Build "), Some(&tab)), s("Build"));
    assert_eq!(for_group(Some("\n"), Some(&tab)), s("npm test"));
    assert_eq!(for_group(None, None), None);
}

#[test]
fn foundation_hosts_and_folders() {
    assert_eq!(url_host("https://user:pw@Example.com:8080/x?y#z"), Some("Example.com"));
    assert_eq!(url_host("//host/path"), Some("host"));
    assert_eq!(url_host("file:///tmp/a"), None);
    assert_eq!(url_host("about:blank"), None);
    assert_eq!(last_path_component("/a/b//"), "b");
    assert_eq!(last_path_component("///"), "/");
    assert_eq!(last_path_component(""), "");
    assert_eq!(last_path_component("plain"), "plain");
}

// MARK: Label (both variants)

#[test]
fn browser_front_tab_shows_its_page_title() {
    assert_eq!(
        LIVE.label(&named("workspace-3"), Some(&browser("Pull requests · cmux", false)), None),
        s("Pull requests · cmux")
    );
}

#[test]
fn browser_split_beside_a_chat_keeps_the_chats_name() {
    let page = browser("browser.md: Widevine and H.264/AAC ship", false);
    let anchor = chat(None, Some("Fix image paste"), None);
    assert_eq!(LIVE.label(&named("workspace-3"), Some(&page), Some(&anchor)), s("Fix image paste"));
    let anchor = terminal(Some("zsh"), Some("/tmp/api"));
    assert_eq!(LIVE.label(&named("workspace-3"), Some(&page), Some(&anchor)), s("api"));
    assert_eq!(LIVE.label(&named("workspace-3"), Some(&page), Some(&chat(None, None, None))), None);
}

#[test]
fn browser_split_never_renames_a_user_named_workspace() {
    let page = browser("Pull requests · cmux", false);
    let mine = Named { name_source: NameSource::User, ..named("#20367: CI red") };
    assert_eq!(LIVE.label(&mine, Some(&page), None), None);
    assert_eq!(LIVE.label(&titled("workspace-3", "Mine"), Some(&page), None), None);
}

#[test]
fn a_chat_shows_its_user_name_else_its_title() {
    assert_eq!(
        LIVE.label(
            &named("workspace-3"),
            Some(&chat(None, Some("Fix the sidebar drag"), None)),
            None
        ),
        s("Fix the sidebar drag")
    );
    assert_eq!(
        LIVE.label(
            &named("workspace-3"),
            Some(&chat(Some("Release notes"), Some("Draft"), None)),
            None
        ),
        s("Release notes")
    );
    assert_eq!(LIVE.label(&named("workspace-3"), Some(&chat(None, None, None)), None), None);
    assert_eq!(
        LIVE.label(&named("workspace-3"), Some(&chat(Some("  "), Some("\n"), None)), None),
        None
    );
}

#[test]
fn an_agent_title_names_the_workspace_unless_the_user_named_it() {
    let front = terminal(Some("Fix the login bug"), None);
    assert_eq!(LIVE.label(&named("workspace-3"), Some(&front), None), s("Fix the login bug"));
    let release = Named { name_source: NameSource::User, ..named("Release") };
    assert_eq!(LIVE.label(&release, Some(&front), None), None);
}

#[test]
fn a_terminal_shows_its_live_title_else_its_folder() {
    let at = |title: &str, cwd: &str| {
        LIVE.label(&named("workspace-3"), Some(&terminal(Some(title), Some(cwd))), None)
    };
    assert_eq!(at("npm run dev", "/Users/me/src/cmux"), s("npm run dev"));
    assert_eq!(at("zsh", "/Users/me/src/cmux"), s("cmux"));
    assert_eq!(at("-bash", "/tmp/api"), s("api"));
    assert_eq!(at("~", "/tmp/api"), s("api"));
}

#[test]
fn multi_line_and_long_names_are_trimmed_to_one_line() {
    let long = "a".repeat(200);
    assert_eq!(
        LIVE.label(&named("workspace-3"), Some(&chat(None, Some("one\ntwo"), None)), None),
        s("one two")
    );
    let label =
        LIVE.label(&named("workspace-3"), Some(&chat(None, Some(&long), None)), None).unwrap();
    assert_eq!(length(&label), MAX_LENGTH);
    assert_eq!(clean(Some(&"é".repeat(90))).map(|name| length(&name)), Some(MAX_LENGTH));
}

#[test]
fn user_named_workspace_keeps_its_name() {
    let front = chat(None, Some("Fix the sidebar drag"), None);
    let api = Named { name_source: NameSource::User, ..named("api") };
    assert_eq!(LIVE.label(&api, Some(&front), None), None);
    assert_eq!(LIVE.label(&titled("workspace-3", "My work"), Some(&front), None), None);
    assert_eq!(
        LIVE.label(&titled("workspace-3", ""), Some(&front), None),
        s("Fix the sidebar drag")
    );
}

#[test]
fn legacy_default_names_still_take_a_front_tab_name() {
    let front = terminal(Some("npm run dev"), None);
    assert_eq!(LIVE.label(&named("~"), Some(&front), None), s("npm run dev"));
    assert_eq!(LIVE.label(&named(""), Some(&front), None), s("npm run dev"));
    assert_eq!(LIVE.label(&titled("~", "My work"), Some(&front), None), None);
    assert_eq!(LIVE.label(&user("~", 1, true), Some(&front), None), None);
    assert_eq!(LIVE.label(&user("~", 0, false), Some(&front), None), None);
}

#[test]
fn no_front_or_setting_off_names_nothing() {
    assert_eq!(LIVE.label(&named("workspace-3"), None, None), None);
    let off = AutoName { enabled: false, variant: Variant::Live };
    assert_eq!(off.label(&named("workspace-3"), Some(&browser("GitHub", false)), None), None);
    assert_eq!(
        off.label(&named("workspace-3"), Some(&terminal(Some("npm run dev"), None)), None),
        None
    );
    let off = AutoName { enabled: false, variant: Variant::Persist };
    assert_eq!(off.label(&named("workspace-3"), Some(&chat(None, Some("Plan"), None)), None), None);
}

#[test]
fn persist_still_shows_the_label_and_an_incognito_title_shows_in_the_row() {
    assert_eq!(
        PERSIST.label(&named("workspace-3"), Some(&chat(None, Some("Plan"), None)), None),
        s("Plan")
    );
    assert_eq!(
        LIVE.label(&named("workspace-3"), Some(&browser("Secret", true)), None),
        s("Secret")
    );
}

// MARK: Persist

const LOCAL: Destination =
    Destination { is_local_machine: true, supports_name_source: false, already_renamed: false };

fn titled_chat() -> Front {
    chat(None, Some("Fix the sidebar drag"), Some("Fix the sidebar drag"))
}

#[test]
fn persist_renames_once_a_chat_has_a_generated_title() {
    let workspace = named("workspace-3");
    assert_eq!(
        PERSIST.persisted_name(&workspace, Some(&titled_chat()), LOCAL),
        s("Fix the sidebar drag")
    );
    let again = Destination { already_renamed: true, ..LOCAL };
    assert_eq!(PERSIST.persisted_name(&workspace, Some(&titled_chat()), again), None);
}

#[test]
fn persist_writes_only_a_generated_chat_title() {
    let workspace = named("workspace-3");
    let prompt_only = chat(None, Some("can you look at why the build fails"), None);
    assert_eq!(PERSIST.persisted_name(&workspace, Some(&prompt_only), LOCAL), None);
    assert_eq!(
        PERSIST.label(&workspace, Some(&prompt_only), None),
        s("can you look at why the build fails")
    );
    assert_eq!(
        PERSIST.persisted_name(
            &workspace,
            Some(&chat(Some("Release notes"), Some("Draft"), None)),
            LOCAL
        ),
        None
    );
    assert_eq!(PERSIST.persisted_name(&workspace, Some(&chat(None, None, None)), LOCAL), None);
    assert_eq!(PERSIST.persisted_name(&workspace, None, LOCAL), None);
    for front in [
        terminal(Some("zsh"), Some("/Users/me/src/cmux")),
        terminal(Some("vim notes.md"), None),
        browser("GitHub", false),
        browser("Secret", true),
    ] {
        assert_eq!(PERSIST.persisted_name(&workspace, Some(&front), LOCAL), None, "{front:?}");
    }
}

#[test]
fn persist_follows_an_automatic_workspace_and_skips_the_current_title() {
    assert_eq!(
        PERSIST.persisted_name(&named("Old generated title"), Some(&titled_chat()), LOCAL),
        s("Fix the sidebar drag")
    );
    assert_eq!(
        PERSIST.persisted_name(&named("Fix the sidebar drag"), Some(&titled_chat()), LOCAL),
        None
    );
}

#[test]
fn persist_never_renames_a_user_named_or_titled_workspace() {
    assert_eq!(PERSIST.persisted_name(&user("api", 1, true), Some(&titled_chat()), LOCAL), None);
    assert_eq!(
        PERSIST.persisted_name(&titled("workspace-3", "Mine"), Some(&titled_chat()), LOCAL),
        None
    );
}

#[test]
fn a_created_default_name_recorded_as_the_users_is_still_unnamed() {
    assert!(!is_user_named(&user("workspace-151", 0, false)));
    let remote_ok = Destination { supports_name_source: true, ..LOCAL };
    assert_eq!(
        PERSIST.persisted_name(&user("workspace-151", 0, true), Some(&titled_chat()), remote_ok),
        s("Fix the sidebar drag")
    );
    assert_eq!(
        LIVE.label(&user("workspace-151", 0, false), Some(&titled_chat()), None),
        s("Fix the sidebar drag")
    );
    assert!(is_user_named(&user("workspace-151", 1, false)));
    assert!(is_user_named(&user("~", 0, false)));
    assert!(is_user_named(&user("api", 0, false)));
    assert!(is_user_named(&user(" workspace-151 ", 0, false)));
}

#[test]
fn persist_names_a_remote_workspace_only_when_the_daemon_supports_name_source() {
    let remote = Destination { is_local_machine: false, ..LOCAL };
    assert_eq!(PERSIST.persisted_name(&named("workspace-3"), Some(&titled_chat()), remote), None);
    let supported = Destination { supports_name_source: true, ..remote };
    assert_eq!(
        PERSIST.persisted_name(&named("workspace-3"), Some(&titled_chat()), supported),
        s("Fix the sidebar drag")
    );
}

#[test]
fn live_variant_and_setting_off_never_rename() {
    assert_eq!(LIVE.persisted_name(&named("workspace-3"), Some(&titled_chat()), LOCAL), None);
    let off = AutoName { enabled: false, variant: Variant::Persist };
    assert_eq!(off.persisted_name(&named("workspace-3"), Some(&titled_chat()), LOCAL), None);
}

#[test]
fn a_rename_is_dropped_when_the_user_named_the_workspace_meanwhile() {
    assert!(PERSIST.confirms_rename(&named("workspace-3")));
    assert!(PERSIST.confirms_rename(&titled("workspace-3", "")));
    assert!(!PERSIST.confirms_rename(&Named { name_source: NameSource::User, ..named("api") }));
    assert!(!PERSIST.confirms_rename(&titled("workspace-3", "Mine")));
    assert!(!PERSIST.confirms_rename(&user("~", 1, true)));
}

#[test]
fn the_default_variant_persists() {
    assert_eq!(Variant::default(), Variant::Persist);
}
