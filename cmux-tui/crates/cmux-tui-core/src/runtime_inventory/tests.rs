use super::*;

const HOME: &str = "/Users/ada";

/// A process of the scan. `started` is in seconds for readability.
fn process(
    pid: u32,
    ppid: u32,
    sid: u32,
    started: u64,
    exe: &str,
    args: &[&str],
) -> InventoryProcess {
    InventoryProcess {
        pid,
        ppid,
        pgid: pid,
        sid,
        tty: Some(16_777_216),
        started_ms: started * 1_000,
        exe: Some(exe.to_string()),
        name: exe.rsplit('/').next().unwrap_or(exe).to_string(),
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        args_truncated: false,
        cpu_ns: Some(5),
        memory_bytes: Some(7),
    }
}

fn shell(pid: u32, started: u64) -> InventoryProcess {
    process(pid, 1, pid, started, "/bin/zsh", &["-zsh"])
}

fn scan(processes: Vec<InventoryProcess>) -> ProcessInventory {
    ProcessInventory { processes, truncated: false, unreadable: 0 }
}

fn terminal(surface: SurfaceId, pid: u32) -> CmuxTerminal {
    CmuxTerminal { surface, workspace: Some(format!("w{surface}")), pid }
}

fn runtime(inventory: &RuntimeInventory, pid: u32) -> &Runtime {
    inventory.runtimes.iter().find(|runtime| runtime.pid == pid).expect("runtime is listed")
}

const CODEX: &str = "/Users/ada/.codex/packages/codex";

#[test]
fn an_agent_under_a_cmux_terminal_is_verified_through_its_parent_chain() {
    let processes = vec![
        shell(100, 10),
        process(101, 100, 100, 11, "/usr/bin/env", &["env"]),
        process(102, 101, 100, 12, CODEX, &["codex"]),
    ];
    let inventory = classify(&scan(processes), &[terminal(7, 100)], Some(HOME));
    let codex = runtime(&inventory, 102);
    assert_eq!((codex.vendor, codex.role), (Vendor::Codex, Role::Cli));
    assert_eq!(codex.attribution.status, AttributionStatus::Verified);
    assert_eq!(codex.attribution.source, AttributionSource::TerminalProcessTree);
    assert_eq!(codex.attribution.surface, Some(7));
    assert_eq!(codex.attribution.workspace.as_deref(), Some("w7"));
    assert_eq!(codex.runtime_id, "local:102:12000");
    assert_eq!(codex.executable_path.as_deref(), Some("~/.codex/packages/codex"));
    assert_eq!(inventory.runtimes.len(), 1, "the shell and env are not runtimes");
    assert!(inventory.complete);
}

#[test]
fn a_shared_server_lists_its_known_cmux_clients_and_never_a_total() {
    let processes = vec![
        shell(100, 10),
        process(102, 100, 100, 12, CODEX, &["codex"]),
        shell(200, 20),
        process(202, 200, 200, 22, CODEX, &["codex"]),
        process(300, 1, 300, 5, CODEX, &["codex", "app-server", "--managed-daemon"]),
    ];
    let inventory = classify(&scan(processes), &[terminal(7, 100), terminal(8, 200)], None);
    let server = runtime(&inventory, 300);
    assert_eq!(server.role, Role::SharedServer);
    assert_eq!(server.attribution.status, AttributionStatus::Unattributed);
    assert_eq!(server.known_cmux_clients, vec![7, 8]);
    assert_eq!(server.total_clients, None);
}

#[test]
fn zero_known_cmux_clients_is_not_zero_clients() {
    let processes =
        vec![process(300, 1, 300, 5, CODEX, &["codex", "app-server", "--managed-daemon"])];
    let inventory = classify(&scan(processes), &[], None);
    let server = runtime(&inventory, 300);
    assert!(server.known_cmux_clients.is_empty());
    assert_eq!(server.total_clients, None, "an outside client may still use it");
}

#[test]
fn a_reparented_agent_still_in_the_terminal_session_is_only_probable() {
    let processes =
        vec![shell(100, 10), process(150, 1, 100, 15, "/Users/ada/.local/bin/claude", &["claude"])];
    let inventory = classify(&scan(processes), &[terminal(7, 100)], None);
    let claude = runtime(&inventory, 150);
    assert_eq!(claude.attribution.status, AttributionStatus::Probable);
    assert_eq!(claude.attribution.source, AttributionSource::TerminalSession);
    assert_eq!(claude.attribution.surface, Some(7));
}

#[test]
fn an_agent_that_left_with_setsid_is_unattributed() {
    let processes = vec![
        shell(100, 10),
        process(150, 1, 150, 15, "/opt/homebrew/bin/opencode", &["opencode", "serve"]),
    ];
    let inventory = classify(&scan(processes), &[terminal(7, 100)], None);
    let opencode = runtime(&inventory, 150);
    assert_eq!((opencode.vendor, opencode.role), (Vendor::Opencode, Role::Server));
    assert_eq!(opencode.attribution, Attribution::NONE);
}

#[test]
fn sharing_a_cmux_terminal_tty_is_never_ownership() {
    // #11004: a detached PPID-1 process on the same controlling terminal as
    // a cmux shell, in a session of its own.
    let mut detached = process(150, 1, 140, 15, "/Users/ada/.local/bin/claude", &["claude"]);
    let leader = shell(100, 10);
    detached.tty = leader.tty;
    let inventory = classify(&scan(vec![leader, detached]), &[terminal(7, 100)], None);
    assert_eq!(runtime(&inventory, 150).attribution.status, AttributionStatus::Unattributed);
}

#[test]
fn a_reused_terminal_pid_does_not_adopt_an_older_process() {
    // The terminal's shell exited and pid 100 now names a newer process. A
    // codex that started before it cannot be its child or session member.
    let processes = vec![
        shell(100, 50),
        process(102, 100, 100, 12, CODEX, &["codex"]),
        process(103, 1, 100, 13, CODEX, &["codex"]),
    ];
    let inventory = classify(&scan(processes), &[terminal(7, 100)], None);
    assert_eq!(runtime(&inventory, 102).attribution.status, AttributionStatus::Unattributed);
    assert_eq!(runtime(&inventory, 103).attribution.status, AttributionStatus::Unattributed);
}

#[test]
fn an_incomplete_scan_is_marked_and_nothing_can_be_stopped() {
    let processes = vec![shell(100, 10), process(102, 100, 100, 12, CODEX, &["codex"])];
    let mut cut = scan(processes);
    cut.truncated = true;
    let inventory = classify(&cut, &[terminal(7, 100)], None);
    assert!(!inventory.complete);
    assert!(inventory.runtimes.iter().all(|runtime| !runtime.can_stop_safely));

    let mut unreadable = scan(vec![]);
    unreadable.unreadable = 1;
    assert!(!classify(&unreadable, &[], None).complete);
}

#[test]
fn vendor_adapters_name_roles_launchers_and_versions() {
    let cases = [
        (process(1, 0, 1, 1, CODEX, &["codex", "pid-update-loop"]), Vendor::Codex, Role::Updater),
        (process(2, 0, 2, 1, CODEX, &["codex", "exec", "x"]), Vendor::Codex, Role::Task),
        (process(3, 0, 3, 1, CODEX, &["codex", "app-server"]), Vendor::Codex, Role::Server),
        (
            process(
                4,
                0,
                4,
                1,
                "/opt/node/bin/node",
                &["node", "/opt/lib/node_modules/@openai/codex/bin/codex.js"],
            ),
            Vendor::Codex,
            Role::Launcher,
        ),
        (
            process(
                5,
                0,
                5,
                1,
                "/Users/ada/.local/share/claude/versions/2.1.3",
                &["claude", "-p", "hi"],
            ),
            Vendor::Claude,
            Role::Task,
        ),
        (
            process(6, 0, 6, 1, "/usr/local/bin/claude", &["claude", "mcp", "serve"]),
            Vendor::Claude,
            Role::Server,
        ),
    ];
    for (process, vendor, role) in &cases {
        assert_eq!(recognize(process), Some((*vendor, *role)), "{:?}", process.args);
    }
    let versioned = &cases[4].0;
    assert_eq!(vendor::version(Vendor::Claude, versioned).as_deref(), Some("2.1.3"));
    let node = process(9, 0, 9, 1, "/opt/node/bin/node", &["node", "server.js"]);
    assert_eq!(recognize(&node), None);
}

#[test]
fn arguments_keep_their_shape_and_lose_their_values() {
    let args: Vec<String> = [
        "/Users/ada/.codex/packages/codex",
        "exec",
        "--model=gpt-5",
        "-c",
        "api_key=sk-secret",
        "fix",
        "the bug",
    ]
    .iter()
    .map(|arg| (*arg).to_string())
    .collect();
    assert_eq!(
        redact_args(&args),
        ["codex", "exec", "--model=<redacted>", "-c", "<redacted>", "<redacted>", "<redacted>",]
    );
    let serve: Vec<String> = ["claude", "mcp", "serve"].iter().map(|a| (*a).to_string()).collect();
    assert_eq!(redact_args(&serve), ["claude", "mcp", "serve"]);
}

#[test]
fn home_paths_lose_the_user_name() {
    assert_eq!(redact_path("/Users/ada/.codex/x", Some("/Users/ada/")), "~/.codex/x");
    assert_eq!(redact_path("/Users/adam/x", Some("/Users/ada")), "/Users/adam/x");
    assert_eq!(redact_path("/opt/x", None), "/opt/x");
}
