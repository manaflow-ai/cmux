//! Parity with the Swift workspace creation glue (Packages/macOS/CmuxNext/Sources: `WorkspaceSpawn`,
//! `WorkspaceCreation`, `WorkspaceSpawner`, `AppActions.newWorkspace`, `NewWorkspaceFocus`,
//! `EmptyWorkspaceRepair`, `CreatingRequests`, `NewTerminalWorkspace`, `AgentTabStore.hostRefusal`,
//! `SidebarMapping.defaultWorkspaceName`, `NewWorkspaceDefaultSlot`), pinned case by case. Each test
//! names the Swift it pins; step B deletes that Swift and calls these ops.

use cmux_app_workspace_creation::env::{
    PANEL_KEY, SURFACE_KEY, WORKSPACE_KEY, placement_environment, terminal_environment, uuid_form,
};
use cmux_app_workspace_creation::half_created::{
    FailedStep, FailureKind, RepairState, begin_populating, failure_end, failure_plan,
    finish_populating,
};
use cmux_app_workspace_creation::naming::{
    ListedWorkspace, default_name_number, default_workspace_name, next_workspace_name,
};
use cmux_app_workspace_creation::new_workspace::{
    MACHINE_NOT_CONNECTED, NewWorkspaceFacts, NewWorkspaceFocus, decide, picks_target,
};
use cmux_app_workspace_creation::ops::{self, OpError};
use cmux_app_workspace_creation::path::{expand_tilde, folder_name};
use cmux_app_workspace_creation::placement::{
    DefaultSlot, NewWorkspacePlacement, SpawnPlacing, spawn_placement,
};
use cmux_app_workspace_creation::request::{
    CreateTerminal, CreatedKind, CreatedObject, CreatedReply, CreatingCommand,
    NewTerminalWorkspace, WorkspaceRef, create_plan, created_objects,
};
use cmux_app_workspace_creation::session_tab::{
    CREATE_ORIGIN, SessionTabFacts, SessionTabRefusal, SessionTabStart, host_refusal,
    session_tab_refusal, session_tab_start, tab_key,
};
use cmux_app_workspace_creation::spawn::{
    AgentTabFacts, InvocationArgs, RoomDefaults, Spawn, TerminalStartFacts, parse_env,
};
use cmux_app_workspace_creation::spawner::{
    CreateFacts, CreateRoute, KeySource, RELEASED_UNSHOWN_SPAN, Reservation, ReservedUse,
    StartFacts, create_route, reserved_use, shows_in_turn, start_plan,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

fn names(list: &[&str]) -> Vec<String> {
    list.iter().map(|name| (*name).to_owned()).collect()
}

/// A daemon on this Mac that hosts the New Tab page and chats.
fn local_tabs() -> AgentTabFacts {
    AgentTabFacts {
        can_host_chat: true,
        has_local_host: true,
        holds_tabs: true,
        daemon_is_local: true,
    }
}

/// A Cloud daemon that holds tabs.
fn remote_tabs() -> AgentTabFacts {
    AgentTabFacts { daemon_is_local: false, ..local_tabs() }
}

fn cmd_n() -> Spawn {
    Spawn { opens_new_tab_page: true, ..Spawn::default() }
}

// MARK: WorkspaceSpawn.init(_: ActionInvocation)

fn invocation(origin: &str) -> InvocationArgs {
    InvocationArgs {
        origin: Some(origin.to_owned()),
        home: "/Users/a".to_owned(),
        ..InvocationArgs::default()
    }
}

#[test]
fn invocation_cwd_expands_tilde_and_names_the_folder() {
    let spawn = Spawn::from_invocation(&InvocationArgs {
        cwd: Some("~/src/app".into()),
        ..invocation("cli")
    });
    assert_eq!(spawn.cwd.as_deref(), Some("/Users/a/src/app"));
    assert_eq!(spawn.name.as_deref(), Some("app"));
}

#[test]
fn invocation_empty_strings_are_absent() {
    let spawn = Spawn::from_invocation(&InvocationArgs {
        cwd: Some(String::new()),
        name: Some(String::new()),
        command: Some(String::new()),
        profile: Some(String::new()),
        ..invocation("cli")
    });
    assert_eq!(spawn, Spawn::default());
}

#[test]
fn invocation_name_wins_over_the_folder() {
    let spawn = Spawn::from_invocation(&InvocationArgs {
        cwd: Some("/w/proj".into()),
        name: Some("mine".into()),
        ..invocation("cli")
    });
    assert_eq!(spawn.name.as_deref(), Some("mine"));
}

#[test]
fn invocation_profile_target_wins_over_the_string() {
    let spawn = Spawn::from_invocation(&InvocationArgs {
        profile_target: Some("room-id".into()),
        profile: Some("room-name".into()),
        ..invocation("cli")
    });
    assert_eq!(spawn.profile.as_deref(), Some("room-id"));
    let spawn = Spawn::from_invocation(&InvocationArgs {
        profile: Some("room-name".into()),
        ..invocation("cli")
    });
    assert_eq!(spawn.profile.as_deref(), Some("room-name"));
}

#[test]
fn invocation_env_keeps_only_string_values() {
    let spawn = Spawn::from_invocation(&InvocationArgs {
        env: Some(r#"{"A":"1","B":2,"C":null,"D":"x"}"#.into()),
        ..invocation("cli")
    });
    assert_eq!(spawn.env, map(&[("A", "1"), ("D", "x")]));
    assert_eq!(parse_env("[1,2]"), None);
    assert_eq!(parse_env("not json"), None);
    assert_eq!(parse_env("{}"), Some(BTreeMap::new()));
}

#[test]
fn invocation_keep_only_when_true() {
    assert!(Spawn::from_invocation(&InvocationArgs { keep: Some(true), ..invocation("cli") }).keep);
    assert!(
        !Spawn::from_invocation(&InvocationArgs { keep: Some(false), ..invocation("cli") }).keep
    );
    assert!(!Spawn::from_invocation(&invocation("cli")).keep);
}

#[test]
fn invocation_opens_new_tab_page_only_for_the_persons_run_without_command() {
    assert!(Spawn::from_invocation(&invocation("user")).opens_new_tab_page);
    assert!(!Spawn::from_invocation(&invocation("cli")).opens_new_tab_page);
    assert!(!Spawn::from_invocation(&invocation("script")).opens_new_tab_page);
    let with_command = InvocationArgs { command: Some("htop".into()), ..invocation("user") };
    assert!(!Spawn::from_invocation(&with_command).opens_new_tab_page);
}

// MARK: WorkspaceSpawn.init(opening:), folderName, expandingTildeInPath

#[test]
fn opening_names_the_folder() {
    let spawn = Spawn::opening(Some("/Users/a/proj/"), None);
    assert_eq!(spawn.cwd.as_deref(), Some("/Users/a/proj/"));
    assert_eq!(spawn.name.as_deref(), Some("proj"));
    assert_eq!(Spawn::opening(None, None), Spawn::default());
    assert_eq!(Spawn::opening(Some("/"), None).name, None);
}

#[test]
fn tilde_and_folder_rules() {
    assert_eq!(expand_tilde("~", "/Users/a"), "/Users/a");
    assert_eq!(expand_tilde("~/x/", "/Users/a"), "/Users/a/x");
    assert_eq!(expand_tilde("~other", "/Users/a"), "~other");
    assert_eq!(folder_name("/a/b/../c/.", None).as_deref(), Some("c"));
    assert_eq!(folder_name("rel/dir", Some("/base")).as_deref(), Some("dir"));
    assert_eq!(folder_name("/a/\n", None), None);
}

// MARK: WorkspaceSpawn.isPlainNewTabPage

#[test]
fn plain_new_tab_page_has_nothing_of_its_own() {
    assert!(cmd_n().is_plain_new_tab_page());
    assert!(!Spawn::default().is_plain_new_tab_page());
    for spawn in [
        Spawn { key: Some("k".into()), ..cmd_n() },
        Spawn { has_first_chat: true, ..cmd_n() },
        Spawn { first_session: Some("s".into()), ..cmd_n() },
        Spawn { command: Some("ls".into()), ..cmd_n() },
        Spawn { browser_profile: Some("p".into()), ..cmd_n() },
        Spawn { cwd: Some("/x".into()), ..cmd_n() },
    ] {
        assert!(!spawn.is_plain_new_tab_page(), "{spawn:?}");
    }
    // A name or an inherited folder keeps it plain.
    assert!(
        Spawn { name: Some("n".into()), inherited_cwd: Some("/i".into()), ..cmd_n() }
            .is_plain_new_tab_page()
    );
}

// MARK: WorkspaceSpawn.startFolder

#[test]
fn start_folder_order() {
    let own =
        Spawn { cwd: Some("/own".into()), inherited_cwd: Some("/inh".into()), ..Spawn::default() };
    assert_eq!(own.start_folder(Some("/room"), true, Some("/d"), "/h").as_deref(), Some("/own"));
    assert_eq!(own.start_folder(None, false, Some("/d"), "/h").as_deref(), Some("/own"));
    let inherited = Spawn { inherited_cwd: Some("/inh".into()), ..Spawn::default() };
    assert_eq!(
        inherited.start_folder(Some("~/room"), true, Some("/d"), "/h").as_deref(),
        Some("/h/room")
    );
    assert_eq!(inherited.start_folder(Some(""), true, Some("/d"), "/h").as_deref(), Some("/inh"));
    assert_eq!(inherited.start_folder(None, true, Some("/d"), "/h").as_deref(), Some("/inh"));
    // A Cloud machine takes neither the room's folder nor the Mac's inherited one.
    assert_eq!(
        inherited.start_folder(Some("/room"), false, Some("/d"), "/h").as_deref(),
        Some("/d")
    );
    assert_eq!(Spawn::default().start_folder(None, false, None, "/h"), None);
}

// MARK: WorkspaceSpawn.rowName

#[test]
fn row_name_only_for_a_window() {
    let named = Spawn { name: Some("mine".into()), ..Spawn::default() };
    assert_eq!(named.row_name(false, || "workspace-9".into()).as_deref(), Some("mine"));
    assert_eq!(named.row_name(true, || "workspace-9".into()).as_deref(), Some("mine"));
    assert_eq!(
        Spawn::default().row_name(true, || "workspace-9".into()).as_deref(),
        Some("workspace-9")
    );
    assert_eq!(Spawn::default().row_name(false, || unreachable!()), None);
}

// MARK: WorkspaceSpawn.showsBeforeDaemon

#[test]
fn shows_before_daemon() {
    assert!(cmd_n().shows_before_daemon(false));
    assert!(Spawn { has_first_chat: true, ..Spawn::default() }.shows_before_daemon(false));
    assert!(
        Spawn { first_session: Some("s".into()), ..Spawn::default() }.shows_before_daemon(false)
    );
    assert!(!Spawn::default().shows_before_daemon(true));
    assert!(!Spawn { command: Some("x".into()), ..cmd_n() }.shows_before_daemon(true));
    assert!(!Spawn { browser_profile: Some("p".into()), ..cmd_n() }.shows_before_daemon(true));
    let own_folder = Spawn { cwd: Some("/x".into()), ..cmd_n() };
    assert!(own_folder.shows_before_daemon(true));
    assert!(!own_folder.shows_before_daemon(false));
}

// MARK: AgentTabStore.canHost / opensFirstPage / showsWorkspaceAtOnce

#[test]
fn agent_tab_facts() {
    let local = local_tabs();
    assert!(local.can_host() && local.opens_first_page(false) && local.shows_workspace_at_once());
    let remote = remote_tabs();
    assert!(remote.can_host());
    assert!(!remote.opens_first_page(false), "only this Mac's daemon hosts the page");
    assert!(remote.opens_first_page(true), "a chat opens on any daemon that holds tabs");
    assert!(!remote.shows_workspace_at_once());
    for broken in [
        AgentTabFacts { can_host_chat: false, ..local },
        AgentTabFacts { has_local_host: false, ..local },
        AgentTabFacts { holds_tabs: false, ..local },
    ] {
        assert!(
            !broken.can_host()
                && !broken.opens_first_page(true)
                && !broken.shows_workspace_at_once()
        );
    }
}

// MARK: WorkspaceCreation.opensPage

#[test]
fn opens_page() {
    assert!(cmd_n().opens_page(&local_tabs()));
    assert!(!cmd_n().opens_page(&remote_tabs()));
    assert!(Spawn { has_first_chat: true, ..Spawn::default() }.opens_page(&remote_tabs()));
    assert!(
        Spawn { first_session: Some("s".into()), ..Spawn::default() }.opens_page(&remote_tabs())
    );
    assert!(!Spawn { command: Some("x".into()), ..cmd_n() }.opens_page(&local_tabs()));
    assert!(!Spawn::default().opens_page(&local_tabs()));
    assert!(!cmd_n().opens_page(&AgentTabFacts { holds_tabs: false, ..local_tabs() }));
}

// MARK: WorkspaceSpawn.terminalStart, terminalEnvironment, placementEnvironment

fn start_facts() -> TerminalStartFacts {
    TerminalStartFacts {
        app: map(&[("TERM_PROGRAM", "cmux"), ("SHARED", "app")]),
        room: Some(RoomDefaults {
            env: map(&[("SHARED", "room"), ("ROOM", "1")]),
            cwd: Some("~/r".into()),
        }),
        local: true,
        daemon_default: Some("/d".into()),
        workspace: "0123456789abcdef0123456789abcdef".into(),
        terminal: "fedcba98-7654-3210-fedc-ba9876543210".into(),
        sends_env: true,
        reaps: true,
        home: "/h".into(),
    }
}

#[test]
fn terminal_env_order_app_room_caller_placement() {
    let spawn = Spawn {
        env: map(&[("SHARED", "caller"), (SURFACE_KEY, "spoof")]),
        keep: true,
        ..Spawn::default()
    };
    let start = spawn.terminal_start(&start_facts());
    let env = start.env.expect("env");
    assert_eq!(env["TERM_PROGRAM"], "cmux");
    assert_eq!(env["ROOM"], "1");
    assert_eq!(env["SHARED"], "caller");
    assert_eq!(env[SURFACE_KEY], "FEDCBA98-7654-3210-FEDC-BA9876543210");
    assert_eq!(env[PANEL_KEY], env[SURFACE_KEY]);
    assert_eq!(env[WORKSPACE_KEY], "01234567-89AB-CDEF-0123-456789ABCDEF");
    assert_eq!(start.keep, Some(true));
    assert_eq!(start.cwd.as_deref(), Some("/h/r"));
}

#[test]
fn terminal_start_on_a_cloud_machine_drops_the_room() {
    let facts = TerminalStartFacts { app: BTreeMap::new(), local: false, ..start_facts() };
    let start = Spawn::default().terminal_start(&facts);
    let env = start.env.expect("env");
    assert!(!env.contains_key("ROOM"));
    assert_eq!(env.len(), 3);
    assert_eq!(start.cwd.as_deref(), Some("/d"));
    assert_eq!(start.keep, None);
}

#[test]
fn terminal_start_without_capabilities() {
    let facts = TerminalStartFacts { sends_env: false, reaps: false, ..start_facts() };
    let start = Spawn { keep: true, ..Spawn::default() }.terminal_start(&facts);
    assert_eq!(start.env, None);
    assert_eq!(start.keep, None);
}

#[test]
fn placement_env_and_uuid_form() {
    let env = placement_environment(None, "term-1");
    assert_eq!(env, map(&[(SURFACE_KEY, "term-1"), (PANEL_KEY, "term-1")]));
    let env = placement_environment(Some("ws"), "t");
    assert_eq!(env[WORKSPACE_KEY], "ws");
    assert_eq!(
        uuid_form("abcdefabcdefabcdefabcdefabcdefab"),
        "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"
    );
    assert_eq!(uuid_form("a-b"), "a-b");
    let env = terminal_environment(&map(&[("A", "1")]), None, &map(&[("A", "2")]), "w", "t");
    assert_eq!(env["A"], "2");
}

// MARK: SidebarMapping.defaultWorkspaceName / nextWorkspaceName

#[test]
fn default_names() {
    assert_eq!(default_workspace_name(&[], &[]), "workspace-1");
    assert_eq!(default_workspace_name(&names(&["a", "b"]), &[]), "workspace-3");
    assert_eq!(default_workspace_name(&names(&["workspace-7"]), &[]), "workspace-8");
    assert_eq!(
        default_workspace_name(&names(&["workspace-1"]), &names(&["workspace-2"])),
        "workspace-3"
    );
    assert_eq!(
        default_workspace_name(&names(&["workspace-2"]), &names(&["workspace-2"])),
        "workspace-3"
    );
    assert_eq!(default_workspace_name(&names(&["workspace-x", "workspace-"]), &[]), "workspace-3");
    assert_eq!(default_name_number("workspace-0012"), Some(12));
    assert_eq!(default_name_number("workspace-+1"), None);
    assert_eq!(default_name_number("workspace-١"), None);
    assert_eq!(default_name_number("workspace-99999999999999999999"), None);
}

#[test]
fn next_name_leaves_home_out() {
    let listed = vec![
        ListedWorkspace { name: "home".into(), kind: Some("home".into()) },
        ListedWorkspace { name: "workspace-1".into(), kind: None },
    ];
    assert_eq!(next_workspace_name(&listed, &[]), "workspace-2");
    assert_eq!(next_workspace_name(&listed, &names(&["workspace-2"])), "workspace-3");
}

// MARK: NewWorkspaceDefaultSlot.anchored, WorkspaceSpawn.placement

fn slot(placement: NewWorkspacePlacement) -> DefaultSlot {
    DefaultSlot {
        placement,
        current: Some("ws-current".into()),
        current_machine: Some("m".into()),
        named: false,
        current_gaps: vec![json!({"after": 1})],
    }
}

#[test]
fn anchored_drops_current_except_after_current() {
    let top = slot(NewWorkspacePlacement::Top);
    assert_eq!(top.anchored(true), top);
    let dropped = top.anchored(false);
    assert_eq!(dropped.current, None);
    assert_eq!(dropped.current_machine.as_deref(), Some("m"));
    assert_eq!(dropped.current_gaps, top.current_gaps);
    let after = slot(NewWorkspacePlacement::AfterCurrent);
    assert!(after.places_after_current());
    assert_eq!(after.anchored(false), after);
    assert_eq!(slot(NewWorkspacePlacement::Bottom).anchored(false).current, None);
}

#[test]
fn spawn_placement_cases() {
    let setting = slot(NewWorkspacePlacement::Top);
    let default = spawn_placement(&setting, SpawnPlacing::default());
    assert_eq!(default.row.as_ref(), Some(&setting));
    assert_eq!(default.rule.as_ref(), Some(&setting));
    let own_slot =
        spawn_placement(&setting, SpawnPlacing { has_slot: true, ..SpawnPlacing::default() });
    assert_eq!(own_slot.row, None);
    assert_eq!(own_slot.rule.as_ref(), Some(&setting));
    let not_from_current = spawn_placement(
        &setting,
        SpawnPlacing { places_from_current: false, ..SpawnPlacing::default() },
    );
    assert_eq!(not_from_current.row.as_ref().and_then(|row| row.current.clone()), None);
    let self_placed = spawn_placement(
        &setting,
        SpawnPlacing { places_by_setting: false, ..SpawnPlacing::default() },
    );
    assert_eq!(self_placed.rule, None);
    assert_eq!(self_placed.row.as_ref().and_then(|row| row.current.clone()), None);
}

// MARK: NewTerminalWorkspace.applied

fn keyed_terminal(key: &str) -> CreateTerminal {
    CreateTerminal {
        workspace: WorkspaceRef::Key(key.into()),
        mutation: Some("m1".into()),
        terminal_id: Some("t1".into()),
        create_workspace: None,
        workspace_name: None,
    }
}

#[test]
fn new_terminal_workspace_applies_to_its_keyed_first_terminal_only() {
    let workspace = NewTerminalWorkspace { key: "k".into(), name: Some("workspace-4".into()) };
    let applied = workspace.applied(&keyed_terminal("k"));
    assert_eq!(applied.create_workspace, Some(true));
    assert_eq!(applied.workspace_name.as_deref(), Some("workspace-4"));
    for request in [
        keyed_terminal("other"),
        CreateTerminal { mutation: None, ..keyed_terminal("k") },
        CreateTerminal { terminal_id: None, ..keyed_terminal("k") },
        CreateTerminal { workspace: WorkspaceRef::Handle(3), ..keyed_terminal("k") },
    ] {
        assert_eq!(workspace.applied(&request), request);
    }
    let unnamed =
        NewTerminalWorkspace { key: "k".into(), name: None }.applied(&keyed_terminal("k"));
    assert_eq!(unnamed.create_workspace, Some(true));
    assert_eq!(unnamed.workspace_name, None);
}

// MARK: WorkspaceCreation.create: one request or two

#[test]
fn create_plan_cases() {
    assert!(create_plan(true, true).one_request);
    assert!(!create_plan(true, true).sends_create_workspace);
    assert!(create_plan(true, false).sends_create_workspace);
    assert!(
        create_plan(false, true).sends_create_workspace,
        "a terminal step that needs the workspace first"
    );
    assert!(create_plan(false, false).sends_create_workspace);
}

// MARK: CreatingRequests createdObjects

fn obj(kind: CreatedKind, id: &str) -> CreatedObject {
    CreatedObject { kind, id: id.into() }
}

#[test]
fn created_objects_cases() {
    let reply = CreatedReply {
        key: Some("ws".into()),
        surface: Some("12".into()),
        terminal_id: Some("t".into()),
        screen: Some("3".into()),
        group_id: Some("g".into()),
    };
    assert_eq!(
        created_objects(CreatingCommand::CreateTerminal, true, &reply),
        vec![
            obj(CreatedKind::Workspace, "ws"),
            obj(CreatedKind::Tab, "12"),
            obj(CreatedKind::Terminal, "t")
        ]
    );
    assert_eq!(
        created_objects(
            CreatingCommand::CreateTerminal,
            false,
            &CreatedReply { surface: None, ..reply.clone() }
        ),
        vec![obj(CreatedKind::Terminal, "t")]
    );
    assert_eq!(
        created_objects(
            CreatingCommand::Surface,
            false,
            &CreatedReply { terminal_id: None, ..reply.clone() }
        ),
        vec![obj(CreatedKind::Tab, "12")]
    );
    assert_eq!(
        created_objects(CreatingCommand::ScreenWithSpec, false, &reply),
        vec![
            obj(CreatedKind::Screen, "3"),
            obj(CreatedKind::Tab, "12"),
            obj(CreatedKind::Terminal, "t")
        ]
    );
    assert_eq!(
        created_objects(CreatingCommand::CreateWorkspace, false, &reply),
        vec![obj(CreatedKind::Workspace, "ws")]
    );
    assert_eq!(
        created_objects(CreatingCommand::BrowserTab, false, &reply),
        vec![obj(CreatedKind::Tab, "12")]
    );
    assert_eq!(
        created_objects(CreatingCommand::CreateTabGroup, false, &reply),
        vec![obj(CreatedKind::TabGroup, "g")]
    );
    assert!(
        created_objects(CreatingCommand::CreateTabGroup, false, &CreatedReply::default())
            .is_empty()
    );
    assert_eq!(serde_json::to_value(CreatedKind::TabGroup).unwrap(), json!("tab-group"));
    assert_eq!(
        serde_json::to_value(CreatedKind::WorkspaceGroup).unwrap(),
        json!("workspace-group")
    );
}

// MARK: AgentTabStore.hostRefusal, WorkspaceCreation.sessionTabRefusal / sessionTab

#[test]
fn host_refusal_cases() {
    let local = Some("mac-host");
    let chief = Some("chief:home");
    assert_eq!(host_refusal(None, local, chief, false), None);
    assert_eq!(host_refusal(Some("chief:home"), local, chief, false), None);
    assert_eq!(host_refusal(Some("chief:other"), local, chief, true), None);
    assert_eq!(
        host_refusal(Some("chief:other"), local, chief, false),
        Some(SessionTabRefusal::RunsOnHost { host: "chief:other".into() })
    );
    assert_eq!(host_refusal(Some("mac-host"), local, chief, true), None);
    assert_eq!(
        host_refusal(Some("mac-host"), local, chief, false),
        Some(SessionTabRefusal::MachineMismatch)
    );
    assert_eq!(
        host_refusal(Some("box"), local, None, true),
        Some(SessionTabRefusal::RunsOnHost { host: "box".into() })
    );
}

#[test]
fn refusal_texts() {
    assert_eq!(
        SessionTabRefusal::AgentTabsUnsupported.message(),
        "cmux on this machine can't hold agent chat tabs yet: update it"
    );
    assert_eq!(
        SessionTabRefusal::MachineMismatch.message(),
        "this chat runs on another machine: it cannot open in this tab"
    );
    assert_eq!(
        SessionTabRefusal::RunsOnHost { host: "box".into() }.message(),
        "this session runs on box: open it without a host, or from that machine's workspace"
    );
}

fn tab_facts() -> SessionTabFacts {
    SessionTabFacts {
        host: None,
        holds_tabs: true,
        daemon_is_local: true,
        local_host: Some("mac-host".into()),
        chief_host: Some("chief:home".into()),
    }
}

#[test]
fn session_tab_refusal_order() {
    assert_eq!(session_tab_refusal(&tab_facts()), None);
    assert_eq!(
        session_tab_refusal(&SessionTabFacts {
            holds_tabs: false,
            daemon_is_local: false,
            ..tab_facts()
        }),
        Some(SessionTabRefusal::AgentTabsUnsupported)
    );
    assert_eq!(
        session_tab_refusal(&SessionTabFacts { daemon_is_local: false, ..tab_facts() }),
        Some(SessionTabRefusal::MachineMismatch)
    );
    assert_eq!(
        session_tab_refusal(&SessionTabFacts { host: Some("box".into()), ..tab_facts() }),
        Some(SessionTabRefusal::RunsOnHost { host: "box".into() })
    );
    // On this Mac a Chief home's record opens.
    assert_eq!(
        session_tab_refusal(&SessionTabFacts { host: Some("chief:x".into()), ..tab_facts() }),
        None
    );
}

#[test]
fn session_tab_start_cases() {
    assert_eq!(session_tab_start(false, &tab_facts()), SessionTabStart::NotConnected);
    assert_eq!(
        session_tab_start(true, &SessionTabFacts { local_host: None, ..tab_facts() }),
        SessionTabStart::NotConnected
    );
    assert_eq!(
        session_tab_start(true, &tab_facts()),
        SessionTabStart::Send { host: "mac-host".into(), origin: CREATE_ORIGIN.into() }
    );
    assert_eq!(
        session_tab_start(true, &SessionTabFacts { host: Some("chief:x".into()), ..tab_facts() }),
        SessionTabStart::Send { host: "chief:x".into(), origin: "cmux-next-agent-tab".into() }
    );
    match session_tab_start(true, &SessionTabFacts { holds_tabs: false, ..tab_facts() }) {
        SessionTabStart::Refused { refusal, message } => {
            assert_eq!(refusal, SessionTabRefusal::AgentTabsUnsupported);
            assert_eq!(message, refusal.message());
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn session_tab_key() {
    assert_eq!(tab_key(Some("tab-res"), "7"), "tab-res");
    assert_eq!(tab_key(None, "7"), "surface:7");
}

// MARK: EmptyWorkspaceRepair.withTerminal, closeHalfCreated, populating

#[test]
fn failure_plans() {
    let refused = failure_plan(FailedStep::CreateWorkspace, FailureKind::Command);
    assert!(refused.refused && !refused.closes);
    let lost = failure_plan(FailedStep::CreateWorkspace, FailureKind::Other);
    assert!(!lost.refused && lost.closes, "a lost reply may have made it");
    for kind in [FailureKind::Command, FailureKind::Other] {
        let terminal = failure_plan(FailedStep::FirstTab, kind);
        assert!(!terminal.refused && terminal.closes);
    }
}

#[test]
fn failure_ends() {
    let closes = failure_plan(FailedStep::FirstTab, FailureKind::Other);
    assert!(failure_end(closes, true).kept_after_failed_close);
    assert!(!failure_end(closes, false).kept_after_failed_close);
    let refused = failure_plan(FailedStep::CreateWorkspace, FailureKind::Command);
    assert!(!failure_end(refused, true).kept_after_failed_close);
    assert!(failure_end(closes, true).throws_step_error);
}

#[test]
fn populating_counts() {
    let one = begin_populating(RepairState::None);
    assert_eq!(one, RepairState::Populating { count: 1 });
    let two = begin_populating(one);
    assert_eq!(two, RepairState::Populating { count: 2 });
    assert_eq!(begin_populating(RepairState::AwaitingPane), RepairState::Populating { count: 1 });
    let end = finish_populating(two, false, true);
    assert_eq!(end.state, RepairState::Populating { count: 1 });
    assert!(!end.clears_kept && !end.records_failure);
    assert_eq!(finish_populating(one, true, false).state, RepairState::AwaitingPane);
    assert_eq!(finish_populating(one, true, true).state, RepairState::AwaitingPane);
    assert_eq!(finish_populating(one, false, false).state, RepairState::Closing);
    let kept = finish_populating(one, false, true);
    assert_eq!(kept.state, RepairState::None);
    assert!(kept.clears_kept && kept.records_failure);
    let idle = finish_populating(RepairState::Other, false, true);
    assert_eq!(idle.state, RepairState::Other);
    assert!(!idle.clears_kept);
}

// MARK: NewWorkspaceFocus, AppActions.newWorkspace

#[test]
fn focus_cases() {
    assert_eq!(
        NewWorkspaceFocus::new(None, None),
        NewWorkspaceFocus { shows: true, activates_app: false }
    );
    assert_eq!(
        NewWorkspaceFocus::new(None, Some(true)),
        NewWorkspaceFocus { shows: true, activates_app: true }
    );
    assert_eq!(
        NewWorkspaceFocus::new(Some(false), Some(true)),
        NewWorkspaceFocus { shows: false, activates_app: false }
    );
    assert!(picks_target(true, true));
    assert!(picks_target(false, false));
    assert!(!picks_target(false, true));
}

fn person_facts() -> NewWorkspaceFacts {
    NewWorkspaceFacts {
        origin: Some("user".into()),
        run_origin: None,
        focus: None,
        activate: None,
        has_machine: false,
        machine_connected: false,
        inherits_window_cwd: true,
        focused_on_home: true,
        has_open_window: true,
        source_window: Some("w1".into()),
        target_window: Some("w1".into()),
        tabs: local_tabs(),
    }
}

#[test]
fn persons_cmd_n_opens_the_page_and_holds_its_keys() {
    let decision = decide(&cmd_n(), &person_facts());
    assert!(decision.by_person && decision.opens_new_tab_page && decision.inherits_cwd);
    assert!(decision.opens_page && decision.holds_page_keys);
    assert!(!decision.holds_terminal_keys && !decision.quiet);
    assert_eq!(decision.refusal, None);
}

#[test]
fn persons_terminal_workspace_holds_terminal_keys() {
    let spawn = Spawn { command: Some("vim".into()), ..Spawn::default() };
    let decision = decide(&spawn, &person_facts());
    assert!(!decision.opens_page && !decision.holds_page_keys && decision.holds_terminal_keys);
    // Another window than the one the person types in holds nothing.
    let elsewhere = NewWorkspaceFacts { target_window: Some("w2".into()), ..person_facts() };
    let decision = decide(&cmd_n(), &elsewhere);
    assert!(decision.opens_page && !decision.holds_page_keys && !decision.holds_terminal_keys);
}

#[test]
fn a_scripts_nested_run_is_not_the_persons() {
    let facts = NewWorkspaceFacts { run_origin: Some("script".into()), ..person_facts() };
    let decision = decide(&cmd_n(), &facts);
    assert!(!decision.by_person && !decision.opens_new_tab_page && !decision.opens_page);
    assert!(!decision.inherits_cwd && !decision.holds_terminal_keys);
    assert!(decision.quiet, "automation's shown create is quiet");
    let unshown = NewWorkspaceFacts { focus: Some(false), ..facts };
    let decision = decide(&cmd_n(), &unshown);
    assert!(!decision.quiet && !decision.picks_target);
}

#[test]
fn cli_run_with_a_machine() {
    let facts = NewWorkspaceFacts {
        origin: Some("cli".into()),
        has_machine: true,
        machine_connected: false,
        ..person_facts()
    };
    let decision = decide(&Spawn::default(), &facts);
    assert_eq!(decision.refusal.as_deref(), Some(MACHINE_NOT_CONNECTED));
    assert!(!decision.quiet && !decision.holds_terminal_keys);
    let connected =
        NewWorkspaceFacts { machine_connected: true, origin: Some("user".into()), ..facts };
    let decision = decide(&Spawn::default(), &connected);
    assert_eq!(decision.refusal, None);
    assert!(!decision.inherits_cwd, "a machine's create never inherits the Mac's folder");
}

#[test]
fn inherit_cwd_needs_the_setting_and_the_home_daemon() {
    for facts in [
        NewWorkspaceFacts { inherits_window_cwd: false, ..person_facts() },
        NewWorkspaceFacts { focused_on_home: false, ..person_facts() },
    ] {
        assert!(!decide(&cmd_n(), &facts).inherits_cwd);
    }
}

#[test]
fn no_open_window_picks_a_target_but_holds_no_keys() {
    let facts = NewWorkspaceFacts {
        has_open_window: false,
        source_window: None,
        target_window: Some("new".into()),
        focus: Some(false),
        ..person_facts()
    };
    let decision = decide(&cmd_n(), &facts);
    assert!(decision.picks_target && !decision.opens_page && !decision.holds_page_keys);
    assert!(!decision.holds_terminal_keys && !decision.quiet);
}

#[test]
fn page_on_a_cloud_daemon_is_a_terminal() {
    let facts = NewWorkspaceFacts { tabs: remote_tabs(), ..person_facts() };
    let decision = decide(&cmd_n(), &facts);
    assert!(!decision.opens_page && decision.holds_terminal_keys);
}

// MARK: WorkspaceSpawner.start, shown; DaemonStore.reservedWorkspaceUse

#[test]
fn reserved_use_cases() {
    let held =
        Reservation { reserved: Some("rk".into()), home_is_other: false, home_reserved: true };
    assert_eq!(reserved_use(false, &held), ReservedUse::NotPlain);
    assert_eq!(reserved_use(true, &held), ReservedUse::Hit { key: "rk".into() });
    let other = Reservation { reserved: None, home_is_other: true, home_reserved: true };
    assert_eq!(reserved_use(true, &other), ReservedUse::Miss { elsewhere: true });
    let none = Reservation { reserved: None, home_is_other: false, home_reserved: true };
    assert_eq!(reserved_use(true, &none), ReservedUse::Miss { elsewhere: false });
    assert_eq!(ReservedUse::Hit { key: "k".into() }.span(), Some("cmdN.reserved.hit"));
    assert_eq!(ReservedUse::Miss { elsewhere: true }.span(), Some("cmdN.reserved.miss.daemon"));
    assert_eq!(ReservedUse::Miss { elsewhere: false }.span(), Some("cmdN.reserved.miss.none"));
    assert_eq!(ReservedUse::NotPlain.span(), None);
    assert_eq!(RELEASED_UNSHOWN_SPAN, "cmdN.reserved.released.unshown");
}

fn window_start() -> StartFacts {
    StartFacts {
        in_window: true,
        connected: true,
        local: true,
        tabs: local_tabs(),
        reservation: Reservation {
            reserved: Some("rk".into()),
            home_is_other: false,
            home_reserved: true,
        },
        workspaces: vec![ListedWorkspace { name: "workspace-1".into(), kind: None }],
        reserved_names: names(&["workspace-2"]),
        browser_shows: false,
    }
}

#[test]
fn plain_cmd_n_takes_the_reservation_and_shows_at_once() {
    let plan = start_plan(&cmd_n(), &window_start());
    assert_eq!(plan.reserved_use, Some(ReservedUse::Hit { key: "rk".into() }));
    assert_eq!(plan.key_source, KeySource::Reserved);
    assert_eq!(plan.key.as_deref(), Some("rk"));
    assert_eq!(plan.name.as_deref(), Some("workspace-3"));
    assert!(plan.claims_window && plan.pending_row && plan.row_opens_page && plan.tries_shown);
    assert!(plan.releases_reserved_unshown);
    assert!(!plan.not_connected);
}

#[test]
fn caller_key_wins_and_never_takes_the_reservation() {
    let spawn = Spawn { key: Some("conductor".into()), ..cmd_n() };
    let plan = start_plan(&spawn, &window_start());
    assert_eq!(plan.reserved_use, Some(ReservedUse::NotPlain));
    assert_eq!((plan.key_source, plan.key.as_deref()), (KeySource::Spawn, Some("conductor")));
    assert!(!plan.releases_reserved_unshown);
}

#[test]
fn a_create_without_a_window_keeps_the_daemons_numbering() {
    let facts = StartFacts { in_window: false, ..window_start() };
    let plan = start_plan(&Spawn::default(), &facts);
    assert_eq!(plan.reserved_use, Some(ReservedUse::NotPlain));
    assert_eq!(plan.key_source, KeySource::Generate);
    assert_eq!(plan.name, None);
    assert!(!plan.claims_window && !plan.pending_row && !plan.tries_shown);
    let named = start_plan(&Spawn { name: Some("n".into()), ..Spawn::default() }, &facts);
    assert_eq!(named.name.as_deref(), Some("n"));
    assert!(!named.pending_row);
}

#[test]
fn no_connection_claims_then_fails() {
    let facts = StartFacts { connected: false, ..window_start() };
    let plan = start_plan(&cmd_n(), &facts);
    assert_eq!(plan.reserved_use, None);
    assert_eq!(plan.key_source, KeySource::Generate);
    assert!(plan.claims_window && plan.not_connected);
    assert!(!plan.pending_row && !plan.tries_shown && !plan.releases_reserved_unshown);
}

#[test]
fn terminal_create_waits_for_the_daemon() {
    let spawn = Spawn { command: Some("make".into()), ..Spawn::default() };
    let plan = start_plan(&spawn, &window_start());
    assert!(plan.pending_row && !plan.row_opens_page && !plan.tries_shown);
    // A first browser that shows its stand-in shows in this turn.
    let browser = StartFacts { browser_shows: true, ..window_start() };
    assert!(start_plan(&spawn, &browser).tries_shown);
}

#[test]
fn cloud_daemon_never_shows_at_once() {
    let facts = StartFacts { local: false, tabs: remote_tabs(), ..window_start() };
    let plan = start_plan(&cmd_n(), &facts);
    assert_eq!(plan.reserved_use, Some(ReservedUse::NotPlain));
    assert!(!plan.tries_shown && !plan.row_opens_page);
    let chat = Spawn { has_first_chat: true, ..Spawn::default() };
    assert!(!shows_in_turn(&chat, false, &remote_tabs(), false));
    assert!(shows_in_turn(&chat, true, &local_tabs(), false));
}

// MARK: WorkspaceSpawner.create

fn create_facts() -> CreateFacts {
    CreateFacts {
        connected: true,
        tabs: local_tabs(),
        workspace_first_tab: true,
        makes_workspace_with_terminal: true,
        start: start_facts(),
    }
}

#[test]
fn create_routes() {
    let page = create_route(&Spawn { input_token: Some("tok".into()), ..cmd_n() }, &create_facts());
    assert_eq!(page.route, CreateRoute::NewTabPage { session_tab: false, stores_page_token: true });
    let session = create_route(
        &Spawn { first_session: Some("s".into()), input_token: Some("tok".into()), ..cmd_n() },
        &create_facts(),
    );
    assert_eq!(
        session.route,
        CreateRoute::NewTabPage { session_tab: true, stores_page_token: false }
    );
    let chat = create_route(
        &Spawn { has_first_chat: true, input_token: Some("tok".into()), ..Spawn::default() },
        &create_facts(),
    );
    assert_eq!(
        chat.route,
        CreateRoute::NewTabPage { session_tab: false, stores_page_token: false }
    );
    let browser =
        create_route(&Spawn { has_first_browser: true, ..Spawn::default() }, &create_facts());
    assert_eq!(browser.route, CreateRoute::BrowserOneRequest);
    let old_daemon = CreateFacts {
        workspace_first_tab: false,
        makes_workspace_with_terminal: false,
        ..create_facts()
    };
    match create_route(&Spawn { has_first_browser: true, ..Spawn::default() }, &old_daemon).route {
        CreateRoute::Terminal { plan } => assert!(plan.sends_create_workspace),
        other => panic!("{other:?}"),
    }
    match create_route(&Spawn::default(), &create_facts()).route {
        CreateRoute::Terminal { plan } => assert!(plan.one_request),
        other => panic!("{other:?}"),
    }
    let offline = create_route(&cmd_n(), &CreateFacts { connected: false, ..create_facts() });
    assert_eq!(offline.route, CreateRoute::NotConnected);
    assert_eq!(offline.start, None);
}

#[test]
fn create_route_carries_the_start_and_the_browser_profile() {
    let spawn =
        Spawn { browser_profile: Some("work".into()), cwd: Some("/w".into()), ..Spawn::default() };
    let plan = create_route(&spawn, &create_facts());
    assert!(plan.sets_browser_profile);
    assert_eq!(plan.start.and_then(|start| start.cwd).as_deref(), Some("/w"));
}

// MARK: ops table

fn op(name: &str, request: Value) -> Value {
    ops::call(name, request).unwrap_or_else(|error| panic!("{name}: {error:?}"))
}

#[test]
fn ops_serve_only_their_prefix() {
    assert!(ops::serves("workspace_creation_default_name"));
    assert!(!ops::serves("workspace_port_links"));
    assert_eq!(
        ops::call("workspace_creation_nope", Value::Null),
        Err(OpError::UnknownOp("workspace_creation_nope".into()))
    );
    assert!(matches!(
        ops::call("workspace_creation_tab_key", json!({"surface": 3})),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn ops_path_naming_env() {
    assert_eq!(
        op("workspace_creation_expand_tilde", json!({"path": "~/x", "home": "/h"})),
        json!({"path": "/h/x"})
    );
    assert_eq!(
        op("workspace_creation_folder_name", json!({"directory": "/a/b/"})),
        json!({"name": "b"})
    );
    assert_eq!(
        op("workspace_creation_folder_name", json!({"directory": "/"})),
        json!({"name": null})
    );
    assert_eq!(
        op(
            "workspace_creation_default_name",
            json!({"workspaces": [{"name": "home", "kind": "home"}, {"name": "workspace-4"}], "reserved": []})
        ),
        json!({"name": "workspace-5"})
    );
    assert_eq!(op("workspace_creation_default_name", Value::Null), json!({"name": "workspace-1"}));
    assert_eq!(
        op("workspace_creation_placement_env", json!({"terminal": "t"})),
        json!({"env": {"CMUX_PANEL_ID": "t", "CMUX_SURFACE_ID": "t"}})
    );
    let env = op(
        "workspace_creation_terminal_env",
        json!({"app": {"A": "app"}, "room": {"A": "room", "R": "1"}, "caller": {"A": "caller"}, "workspace": "w", "terminal": "t"}),
    );
    assert_eq!(env["env"]["A"], "caller");
    assert_eq!(env["env"]["R"], "1");
    assert_eq!(env["env"]["CMUX_WORKSPACE_ID"], "w");
}

#[test]
fn ops_spawn() {
    let spawn = op(
        "workspace_creation_spawn_from_invocation",
        json!({"cwd": "~/p", "origin": "user", "home": "/h", "env": "{\"K\":\"v\"}"}),
    );
    assert_eq!(spawn["cwd"], "/h/p");
    assert_eq!(spawn["name"], "p");
    assert_eq!(spawn["opensNewTabPage"], true);
    assert_eq!(spawn["env"], json!({"K": "v"}));
    let facts = op(
        "workspace_creation_spawn_facts",
        json!({"spawn": {"opensNewTabPage": true}, "local": true, "tabs": {"canHostChat": true, "hasLocalHost": true, "holdsTabs": true, "daemonIsLocal": true}}),
    );
    assert_eq!(
        facts,
        json!({"plainNewTabPage": true, "showsBeforeDaemon": true, "opensPage": true})
    );
    assert_eq!(
        op(
            "workspace_creation_start_folder",
            json!({"spawn": {"inheritedCwd": "/i"}, "roomFolder": "~/r", "local": true, "home": "/h"})
        ),
        json!({"cwd": "/h/r"})
    );
    let start = op(
        "workspace_creation_terminal_start",
        json!({"spawn": {"keep": true}, "facts": {"local": false, "daemonDefault": "/d", "workspace": "w", "terminal": "t", "sendsEnv": false, "reaps": true}}),
    );
    assert_eq!(start, json!({"env": null, "keep": true, "cwd": "/d"}));
    let placement = op(
        "workspace_creation_spawn_placement",
        json!({"setting": {"placement": "top", "current": "c"}, "placing": {"placesFromCurrent": false}}),
    );
    assert_eq!(placement["row"]["current"], Value::Null);
    assert_eq!(placement["rule"]["placement"], "top");
}

#[test]
fn ops_requests() {
    let applied = op(
        "workspace_creation_new_terminal_workspace",
        json!({"workspace": {"key": "k", "name": "n"}, "request": {"workspace": {"key": "k"}, "mutation": "m", "terminalId": "t"}}),
    );
    assert_eq!(applied["createWorkspace"], true);
    assert_eq!(applied["workspaceName"], "n");
    assert_eq!(
        op("workspace_creation_create_plan", json!({"makesWorkspaceWithTerminal": true})),
        json!({"oneRequest": true, "sendsCreateWorkspace": false})
    );
    assert_eq!(
        op(
            "workspace_creation_created_objects",
            json!({"command": "create-terminal", "askedWorkspace": true, "reply": {"key": "k", "terminalId": "t"}})
        ),
        json!({"created": [{"kind": "workspace", "id": "k"}, {"kind": "terminal", "id": "t"}]})
    );
}

#[test]
fn ops_session_tab() {
    assert_eq!(
        op("workspace_creation_session_tab_refusal", json!({"holdsTabs": false})),
        json!({"refusal": {"kind": "agentTabsUnsupported"}, "message": "cmux on this machine can't hold agent chat tabs yet: update it"})
    );
    assert_eq!(
        op(
            "workspace_creation_session_tab_refusal",
            json!({"holdsTabs": true, "daemonIsLocal": true})
        ),
        json!({"refusal": null, "message": null})
    );
    assert_eq!(
        op(
            "workspace_creation_session_tab_start",
            json!({"connected": true, "facts": {"holdsTabs": true, "daemonIsLocal": true, "localHost": "h"}})
        ),
        json!({"kind": "send", "host": "h", "origin": "cmux-next-agent-tab"})
    );
    assert_eq!(
        op("workspace_creation_tab_key", json!({"surface": "9"})),
        json!({"key": "surface:9"})
    );
}

#[test]
fn ops_half_created() {
    let plan = op(
        "workspace_creation_failure_plan",
        json!({"step": "createWorkspace", "kind": "command"}),
    );
    assert_eq!(plan, json!({"refused": true, "closes": false}));
    assert_eq!(
        op(
            "workspace_creation_failure_end",
            json!({"plan": {"refused": false, "closes": true}, "closeFailed": true})
        ),
        json!({"keptAfterFailedClose": true, "throwsStepError": true})
    );
    assert_eq!(
        op("workspace_creation_populating", json!({"state": {"kind": "none"}})),
        json!({"state": {"kind": "populating", "count": 1}, "clearsKept": false, "recordsFailure": false})
    );
    assert_eq!(
        op(
            "workspace_creation_populating",
            json!({"state": {"kind": "populating", "count": 1}, "finish": {"succeeded": true}})
        ),
        json!({"state": {"kind": "awaitingPane"}, "clearsKept": false, "recordsFailure": false})
    );
}

#[test]
fn ops_decisions() {
    let decision = op(
        "workspace_creation_new_workspace",
        json!({"spawn": {"opensNewTabPage": true}, "facts": {"origin": "user", "hasOpenWindow": true, "sourceWindow": "w", "targetWindow": "w", "tabs": {"canHostChat": true, "hasLocalHost": true, "holdsTabs": true, "daemonIsLocal": true}}}),
    );
    assert_eq!(decision["holdsPageKeys"], true);
    assert_eq!(decision["focus"], json!({"shows": true, "activatesApp": false}));
    let plan = op(
        "workspace_creation_start_plan",
        json!({"spawn": {}, "facts": {"inWindow": true, "connected": true, "workspaces": [{"name": "workspace-1"}]}}),
    );
    assert_eq!(plan["name"], "workspace-2");
    assert_eq!(plan["keySource"], "generate");
    assert_eq!(plan["reservedUse"], json!({"kind": "notPlain"}));
    let route = op(
        "workspace_creation_create_route",
        json!({"spawn": {}, "facts": {"connected": true, "makesWorkspaceWithTerminal": true, "start": {"workspace": "w", "terminal": "t"}}}),
    );
    assert_eq!(
        route["route"],
        json!({"kind": "terminal", "plan": {"oneRequest": true, "sendsCreateWorkspace": false}})
    );
}
