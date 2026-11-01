//! Tests of `idle_census.rs`.
use super::*;
use crate::agent_host::tree::{Identity, Under};

fn under(pid: u32, ppid: u32, args: &str) -> Under {
    Under { pid, ppid, args: args.into() }
}

/// A process running `argv`, its executable argv[0] (a name as if from `/usr/local/bin`).
fn identity(argv: Vec<String>) -> Identity {
    let first = argv.first().cloned().unwrap_or_default();
    let exe = if first.contains('/') { first } else { format!("/usr/local/bin/{first}") };
    Identity { exe: exe.into(), argv, cwd: None }
}

/// [`classify`] with harness 10 run as `claude`, each process's argv its `ps` line split on
/// spaces.
fn census(found: &[Under], servers: &[Sidecar]) -> Census {
    census_of(found, "claude", servers)
}

/// [`census`] with harness 10 run as `leader`; a leader's bare `node` is the one on its
/// `PATH`.
fn census_of(found: &[Under], leader: &str, servers: &[Sidecar]) -> Census {
    let (root, node) = node_on_path();
    let split = |pid| {
        let line =
            if pid == 10 { leader } else { found.iter().find(|p| p.pid == pid)?.args.as_str() };
        let mut who = identity(line.split(' ').map(str::to_owned).collect());
        if pid == 10 && who.argv.first().is_some_and(|w| w == "node") {
            who.exe = node.clone().into();
        }
        Some(who)
    };
    let census = classify(found, 10, servers, Some(&root.to_string_lossy()), split);
    let _ = std::fs::remove_dir_all(root);
    census
}

/// npm's Codex install under `root`: `bin/codex` links to the package's script, and the native
/// program and its helper are in the platform package beside it. The launcher's path, the native
/// programs' folder, and a `codex` outside the install.
fn npm_codex(root: &Path) -> (String, String, String) {
    let modules = root.join("lib/node_modules/@openai");
    let script = modules.join("codex/bin/codex.js");
    let bin = modules.join("codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin");
    let outside = root.join("elsewhere/codex");
    for file in [&script, &bin.join("codex"), &bin.join("codex-code-mode-host"), &outside] {
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, "").unwrap();
    }
    std::fs::create_dir_all(root.join("bin")).unwrap();
    std::os::unix::fs::symlink(&script, root.join("bin/codex")).unwrap();
    let text = |p: &Path| p.to_string_lossy().into_owned();
    (text(&root.join("bin/codex")), text(&bin), text(&outside))
}

/// A new folder holding an executable `node`, and that `node`'s path.
fn node_on_path() -> (PathBuf, String) {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let node = root.join("node");
    std::fs::write(&node, "").unwrap();
    std::fs::set_permissions(&node, std::fs::Permissions::from_mode(0o755)).unwrap();
    (root, node.to_string_lossy().into_owned())
}

#[test]
fn mcp_servers_and_what_runs_under_them_let_a_harness_end() {
    let mut servers = from_json(Some(&json!({
        "cmux": {"command": "/Applications/cmux.app/Contents/Resources/bin/cmux", "args": ["mcp", "serve", "--all-tools"]},
        "fetch": {"command": "npx", "args": ["-y", "@example/fetch"]},
        "py": {"command": "python3"},
        "remote": {"type": "http", "url": "https://example.com/mcp"},
    })));
    assert_eq!(servers.len(), 3, "a server with no command spawns nothing");
    servers[1].resolved = Some("/usr/local/bin/npx".into());
    servers[1].interpreter = Some("/usr/local/bin/node".into());
    let found = [
        under(11, 10, "/Applications/cmux.app/Contents/Resources/bin/cmux mcp serve --all-tools"),
        under(12, 10, "node /usr/local/bin/npx -y @example/fetch"),
        under(13, 12, "node /tmp/_npx/fetch/index.js"),
    ];
    assert!(matches!(census(&found, &servers), Census::Clear));
    for same in [
        "npx -y @example/fetch",
        "/usr/local/bin/npx -y @example/fetch",
        "/usr/local/bin/node /usr/local/bin/npx -y @example/fetch",
    ] {
        let found = [under(12, 10, same)];
        assert!(matches!(census(&found, &servers), Census::Clear), "{same}");
    }
    let mut busy = found.to_vec();
    busy.push(under(14, 10, "/usr/bin/python3 -m http.server 8000"));
    assert!(
        matches!(census(&busy, &servers), Census::Busy { pid: 14, ref comm } if comm == "python3")
    );
    for other in [
        "node /usr/local/bin/npx -y @example/other",
        // An interpreter, but not the one the script's `#!` line runs.
        "/usr/bin/python3.12 /usr/local/bin/npx -y @example/fetch",
        "sh -c npx -y @example/fetch",
        "/tmp/other/cmux mcp serve --all-tools",
        "/Applications/cmux.app/Contents/Resources/bin/cmux mcp serve --all-tools --x",
        "python3 notes.py npx -y @example/fetch",
        "cat /usr/local/bin/npx -y @example/fetch",
        "/tmp/npx -y @example/fetch",
        "/opt/bin/npx -y @example/fetch",
        "node /tmp/npx -y @example/fetch",
        "python3",
        "python3 -c print(1)",
    ] {
        let found = [under(12, 10, other)];
        assert!(matches!(census(&found, &servers), Census::Busy { .. }), "{other}");
    }
    // A server's command line under something other than the harness is not its server.
    let nested = [under(15, 10, "bash"), under(16, 15, "npx -y @example/fetch")];
    assert!(matches!(census(&nested, &servers), Census::Busy { pid: 15, .. }));
}

/// npm's Codex launcher (`node .../bin/codex ARGS`) runs the native binary with the same
/// args, and that binary starts the MCP servers and its own helper. An idle Codex session held
/// all of it (about 180 tasks) forever: the native binary was not a server, so the census
/// kept every such harness up.
#[test]
fn a_launchers_relayed_harness_and_its_helpers_let_it_end() {
    let servers = from_json(Some(&json!({
        "acpmux": {"command": "/home/u/.local/bin/acpmux", "args": ["acpmux-mcp"]},
        "forum": {"command": "/home/u/.local/bin/acpmux", "args": ["forum-mcp"]},
    })));
    let (root, _) = node_on_path();
    let (launcher, bin, outside) = npm_codex(&root);
    let leader = &format!("node {launcher} -c agents.max_depth=16 app-server");
    let native = format!("{bin}/codex -c agents.max_depth=16 app-server");
    let helper = format!("{bin}/codex-code-mode-host");
    let idle = vec![
        under(11, 10, &native),
        under(12, 11, "/home/u/.local/bin/acpmux acpmux-mcp"),
        under(13, 11, "/home/u/.local/bin/acpmux forum-mcp"),
        under(14, 12, "/home/u/.local/bin/acpmux helper"),
        under(15, 11, &helper),
    ];
    assert!(matches!(census_of(&idle, leader, &servers), Census::Clear));

    // What the agent left running still keeps it up: under the relayed harness, under its
    // helper, a relay whose args differ, or one with the same args outside the launcher's npm
    // install (`/tmp/codex`).
    for (extra, busy) in [
        (under(16, 10, &format!("{outside} -c agents.max_depth=16 app-server")), 16),
        (under(16, 11, "/usr/bin/python3 -m http.server 8000"), 16),
        (under(16, 15, "/usr/bin/node /tmp/sandbox.js"), 16),
        (under(16, 10, &format!("{bin}/codex exec run-this")), 16),
        (under(16, 10, "/tmp/elsewhere/codex-code-mode-host"), 16),
        (under(16, 11, &format!("{bin}/other-code-mode-host")), 16),
    ] {
        let mut found = idle.clone();
        found.push(extra);
        assert!(
            matches!(census_of(&found, leader, &servers), Census::Busy { pid, .. } if pid == busy),
            "{:?}",
            found.last()
        );
    }

    // No launcher: a same-named child with the same args is not the harness.
    let direct = format!("{bin}/codex -c agents.max_depth=16 app-server");
    let found = [under(11, 10, &native), under(12, 11, "/home/u/.local/bin/acpmux acpmux-mcp")];
    assert!(matches!(census_of(&found, &direct, &servers), Census::Busy { pid: 11, .. }));
    // A launcher run as a bare name (no script path) relays nothing either.
    let bare = "node codex -c agents.max_depth=16 app-server";
    assert!(matches!(census_of(&found, bare, &servers), Census::Busy { pid: 11, .. }));
    // A helper beside the launcher's script, not beside a relayed program, is not the harness's.
    let found = [under(11, 10, &format!("{launcher}-code-mode-host"))];
    assert!(matches!(census_of(&found, leader, &servers), Census::Busy { pid: 11, .. }));
    let _ = std::fs::remove_dir_all(root);
}

/// The relayed harness and its helpers are told by exact argv and the kernel's executable, as
/// servers are: a child that names itself the native program or a helper (`exec -a`) is
/// neither, a leader is a launcher only when it runs the interpreter its argv names (a bare
/// `node`: the one on the harness's `PATH`), and a launcher whose path has a space in it still
/// relays.
#[test]
fn a_relay_or_helper_is_its_executable_not_its_argv() {
    let (root, node) = node_on_path();
    let path = root.to_string_lossy().into_owned();
    let (launcher, bin, outside) = npm_codex(&root.join("my apps"));
    let acpmux = "/Users/me/my apps/acpmux";
    let servers = from_json(Some(&json!({"forum": {"command": acpmux, "args": ["forum-mcp"]}})));
    let (native, helper) = (format!("{bin}/codex"), format!("{bin}/codex-code-mode-host"));
    let who = |exe: &str, argv: &[&str]| Identity {
        exe: exe.into(),
        argv: argv.iter().map(|w| w.to_string()).collect(),
        cwd: None,
    };
    let launch = |exe: &str, interp: &str| who(exe, &[interp, &launcher, "app-server"]);
    let relayed = who(&native, &[&native, "app-server"]);
    let server = who(acpmux, &[acpmux, "forum-mcp"]);
    let own_helper = who(&helper, &[&helper]);
    let found = [under(11, 10, "codex"), under(12, 11, "acpmux"), under(13, 11, "helper")];
    let census = |leader: &Identity, relay: &Identity, helper: &Identity, path: Option<&str>| {
        classify(&found, 10, &servers, path, |pid| match pid {
            10 => Some(leader.clone()),
            11 => Some(relay.clone()),
            12 => Some(server.clone()),
            13 => Some(helper.clone()),
            _ => None,
        })
    };
    let leader = launch(&node, "node");
    let at = Some(path.as_str());
    assert!(matches!(census(&leader, &relayed, &own_helper, at), Census::Clear));
    // `exec -a`: a dev server that names itself the native program, or a helper.
    let spoofed = who("/usr/bin/python3", &[&native, "app-server"]);
    assert!(matches!(census(&leader, &spoofed, &own_helper, at), Census::Busy { pid: 11, .. }));
    // The same name and args, run from outside the launcher's npm install.
    let stray = who(&outside, &[&outside, "app-server"]);
    assert!(matches!(census(&leader, &stray, &own_helper, at), Census::Busy { pid: 11, .. }));
    let spoofed = who("/tmp/devserver", &[&helper]);
    assert!(matches!(census(&leader, &relayed, &spoofed, at), Census::Busy { pid: 13, .. }));
    // A name in the helper's folder is not enough: the executable must be that file.
    let elsewhere = who(&format!("{bin}/codex"), &[&format!("{bin}/codex-evil")]);
    assert!(matches!(census(&leader, &relayed, &elsewhere, at), Census::Busy { pid: 13, .. }));
    // A leader that names itself the launcher but runs another program, a `node` not on the
    // harness's `PATH`, or any bare name with no `PATH` known relays nothing: its
    // native-looking child is not the harness.
    for (spoofed, path) in [
        (launch("/usr/bin/python3", "node"), at),
        (launch("/tmp/node-evil", "node"), at),
        (launch("/tmp/elsewhere/node", "node"), at),
        (launch(&node, "node"), None),
        (launch("/usr/local/bin/node", "/usr/bin/python3"), at),
    ] {
        let census = census(&spoofed, &relayed, &own_helper, path);
        assert!(matches!(census, Census::Busy { pid: 11, .. }), "{spoofed:?} {path:?}");
    }
    // A leader run by the interpreter's full path relays when that is its executable.
    let full = launch("/usr/local/bin/node", "/usr/local/bin/node");
    assert!(matches!(census(&full, &relayed, &own_helper, None), Census::Clear));
    let _ = std::fs::remove_dir_all(root);
}

/// A native wrapper harness (`sr2 claude ARGS`, `sr codex ARGS`) runs the agent as its child with
/// the same args plus its own, before them (`claude --settings S ARGS`) or after them
/// (`cmux-codex ARGS -c model_provider=...`), and that agent starts the MCP servers. The census
/// took the agent itself for work the harness left running, so no idle wrapped chat ever ended:
/// 54 `sr2 -> claude` and 40 `sr -> cmux-codex` harnesses on one Mac (2026-10-30), about 180 MB
/// and 12 processes each.
#[test]
fn a_native_wrappers_relayed_agent_and_its_servers_let_it_end() {
    let servers = from_json(Some(&json!({
        "cmux": {"command": "/home/u/cmux", "args": ["mcp", "serve"]},
        "forum": {"command": "/home/u/acpmux", "args": ["forum-mcp"]},
    })));
    let args = "-p --session-id S --mcp-config /home/u/.acpmux/run/mcp/S.json";
    let sr2 = &format!("/home/u/.local/bin/sr2 claude {args}");
    let claude =
        format!("/opt/homebrew/bin/claude --autocompact 402663 --settings /tmp/s.json {args}");
    let idle = vec![
        under(11, 10, &claude),
        under(12, 11, "/home/u/cmux mcp serve"),
        under(13, 12, "/home/u/acpmux secret-mcp"),
        under(14, 11, "/home/u/acpmux forum-mcp"),
    ];
    assert!(matches!(census_of(&idle, sr2, &servers), Census::Clear));

    // `sr codex ARGS` runs `cmux-codex ARGS EXTRA` and its helper beside it.
    let sr = "/home/u/bin/sr codex -c agents.max_depth=16 app-server";
    let codex = "/home/u/libexec/cmux-codex/cmux-codex -c agents.max_depth=16 app-server -c x=y";
    let found = [
        under(11, 10, codex),
        under(12, 11, "/home/u/cmux mcp serve"),
        under(13, 11, "/home/u/libexec/cmux-codex/codex-code-mode-host"),
    ];
    assert!(matches!(census_of(&found, sr, &servers), Census::Clear));

    // What the agent left running still keeps it up, as does a child of the wrapper that is not
    // the agent it names with its args: other args, another program, an interpreter, or the
    // agent run again under the relayed one.
    for extra in [
        under(16, 11, "/usr/bin/python3 -m http.server 8000"),
        under(16, 10, "/opt/homebrew/bin/claude -p --session-id OTHER"),
        under(16, 10, &format!("/tmp/devserver {args}")),
        under(16, 10, &format!("/usr/bin/python3 {args}")),
        under(16, 10, &format!("claude {args}")),
        under(16, 11, &claude),
        under(16, 10, "/home/u/.local/bin/sr2-helper"),
        // An agent under its own name has no helpers: its folder is often a shared `bin`.
        under(16, 11, "/opt/homebrew/bin/claude-code-router start"),
    ] {
        let mut found = idle.clone();
        found.push(extra);
        assert!(
            matches!(census_of(&found, sr2, &servers), Census::Busy { pid: 16, .. }),
            "{:?}",
            found.last()
        );
    }

    // A leader that is no wrapper relays nothing: the agent run directly (its first arg is a
    // flag), a wrapper with no args to pass on, or an interpreter running a script.
    for leader in [
        format!("/opt/homebrew/bin/claude {args}"),
        "/home/u/.local/bin/sr2 claude".to_owned(),
        format!("/usr/bin/python3 /tmp/wrap.py claude {args}"),
    ] {
        let census = census_of(&idle, &leader, &servers);
        assert!(matches!(census, Census::Busy { pid: 11, .. }), "{leader}");
    }
}

/// A wrapper and its relayed agent are told by the executable the kernel says each runs, not by
/// argv alone: `exec -a` makes neither.
#[test]
fn a_native_wrapper_or_its_agent_is_its_executable_not_its_argv() {
    let servers = from_json(Some(&json!({"cmux": {"command": "/home/u/cmux", "args": ["mcp"]}})));
    let who = |exe: &str, argv: &[&str]| Identity {
        exe: exe.into(),
        argv: argv.iter().map(|w| w.to_string()).collect(),
        cwd: None,
    };
    let (sr2, claude) = ("/home/u/.local/bin/sr2", "/opt/homebrew/bin/claude");
    let leader = who(sr2, &[sr2, "claude", "-p", "--session-id", "S"]);
    let agent = who(claude, &[claude, "--settings", "x", "-p", "--session-id", "S"]);
    let server = who("/home/u/cmux", &["/home/u/cmux", "mcp"]);
    let found = [under(11, 10, "claude"), under(12, 11, "cmux")];
    let census = |leader: &Identity, agent: &Identity| {
        classify(&found, 10, &servers, None, |pid| match pid {
            10 => Some(leader.clone()),
            11 => Some(agent.clone()),
            12 => Some(server.clone()),
            _ => None,
        })
    };
    assert!(matches!(census(&leader, &agent), Census::Clear));
    let spoofed = who("/usr/bin/python3", &[claude, "--settings", "x", "-p", "--session-id", "S"]);
    assert!(matches!(census(&leader, &spoofed), Census::Busy { pid: 11, .. }));
    let spoofed = who("/usr/bin/python3", &[sr2, "claude", "-p", "--session-id", "S"]);
    assert!(matches!(census(&spoofed, &agent), Census::Busy { pid: 11, .. }));
}

#[test]
fn the_configs_are_the_ones_the_harness_was_started_with() {
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    let (home, dir, cwd) = (root.join("home"), root.join("claude"), root.join("work"));
    for d in [&home, &dir, &cwd] {
        std::fs::create_dir_all(d).unwrap();
    }
    let server = |c: &str| json!({"mcpServers": {"s": {"command": c}}}).to_string();
    std::fs::write(home.join(".claude.json"), server("home-mcp")).unwrap();
    std::fs::write(dir.join(".claude.json"), server("dir-mcp")).unwrap();
    std::fs::write(cwd.join(".mcp.json"), server("project-mcp")).unwrap();
    std::fs::write(cwd.join("extra.json"), server("extra-mcp")).unwrap();
    let launch = |args: &[&str], env: &[(&str, &Path)]| crate::agent::Launch {
        args: args.iter().map(|a| a.to_string()).collect(),
        env: env.iter().map(|(k, v)| (k.to_string(), v.to_string_lossy().into())).collect(),
        cwd: cwd.clone(),
    };
    let names = |l: &crate::agent::Launch| {
        let mut n: Vec<String> = from_launch("claude", l).into_iter().map(|s| s.command).collect();
        n.sort();
        n
    };
    let plain = launch(&["claude", "--mcp-config", "extra.json"], &[("HOME", &home)]);
    assert_eq!(names(&plain), ["extra-mcp", "home-mcp", "project-mcp"]);
    let moved = launch(&["claude"], &[("HOME", &home), ("CLAUDE_CONFIG_DIR", &dir)]);
    assert_eq!(names(&moved), ["dir-mcp", "project-mcp"]);
    let strict = launch(&["claude", "--strict-mcp-config"], &[("HOME", &home)]);
    assert!(names(&strict).is_empty());
    assert!(from_launch("codex", &plain).is_empty());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn codex_and_project_entries_are_read_and_a_bad_file_adds_nothing() {
    let codex = from_toml("[mcp_servers.docs]\ncommand = \"docs-mcp\"\nargs = [\"--stdio\"]\n");
    assert_eq!(codex, vec![sidecar("docs-mcp", &["--stdio".into()]).unwrap()]);
    assert!(from_toml("[mcp_servers").is_empty());
    // A server with an arg that is not a string, or no command.
    let unclear = json!({
        "c": {"command": "srv", "args": ["x", 1]},
        "d": {"command": "srv", "args": "x"},
        "e": {"command": "", "args": ["x"]},
    });
    assert!(from_json(Some(&unclear)).is_empty());
    let project = json!({"projects": {"/w/a": {"mcpServers": {"x": {"command": "x-mcp"}}}}});
    let entry = project.pointer(&format!("/projects/{}", escape("/w/a")));
    assert_eq!(from_json(entry), vec![sidecar("x-mcp", &[]).unwrap()]);
    let acp =
        json!([{"name": "cmux", "command": "/bin/cmux", "args": ["mcp", "serve"], "env": []}]);
    assert_eq!(
        from_json(Some(&acp)),
        vec![sidecar("/bin/cmux", &["mcp".into(), "serve".into()]).unwrap()]
    );
}

/// acpmux's own servers run from `/Applications/cmux NIGHTLY.app`: matched on exact argv, a
/// word with a space in it is that server, and the same words split differently are not.
#[test]
fn a_server_whose_path_has_a_space_is_matched_word_for_word() {
    let acpmux = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";
    let socket = "/Users/me/cmux sockets/cua.sock";
    let servers = from_json(Some(&json!([
        {"name": "forum", "command": acpmux, "args": ["forum-mcp"]},
        {"name": "cua", "command": "/opt/cua", "args": ["mcp", "--socket", socket]},
        {"name": "two", "command": "srv", "args": ["foo bar"]},
    ])));
    assert_eq!(servers.len(), 3);
    let mut servers = servers;
    servers[2].resolved = Some("/usr/local/bin/srv".into());
    let argv: &[(u32, &[&str])] = &[
        (11, &[acpmux, "forum-mcp"]),
        (12, &["/opt/cua", "mcp", "--socket", socket]),
        (13, &["srv", "foo bar"]),
        // The same words as 13, split differently: not that server.
        (14, &["srv", "foo", "bar"]),
        (15, &["/Applications/cmux", "NIGHTLY.app/Contents/Resources/bin/acpmux", "forum-mcp"]),
        (16, &[acpmux, "offer-mcp"]),
    ];
    let words = |pid: u32| -> Option<Vec<String>> {
        argv.iter().find(|(p, _)| *p == pid).map(|(_, a)| a.iter().map(|w| w.to_string()).collect())
    };
    let lookup = |pid: u32| words(pid).map(identity);
    let line = |pid: u32| words(pid).map(|a| a.join(" ")).unwrap_or_default();
    let found: Vec<Under> = [11, 12, 13].into_iter().map(|p| under(p, 10, &line(p))).collect();
    assert!(matches!(classify(&found, 10, &servers, None, lookup), Census::Clear));
    for pid in [14, 15, 16] {
        let found = [under(pid, 10, &line(pid))];
        let census = classify(&found, 10, &servers, None, lookup);
        assert!(matches!(census, Census::Busy { pid: p, .. } if p == pid), "{pid}");
    }
    // A child whose argv cannot be read is never a server.
    let found = [under(11, 10, &line(11))];
    assert!(matches!(classify(&found, 10, &servers, None, |_| None), Census::Busy { pid: 11, .. }));
}

/// Argv is the process's own to rewrite: the executable the kernel says it runs must be the
/// server's program, or for a script an interpreter.
#[test]
fn a_rewritten_argv_does_not_make_a_server() {
    let mut servers = from_json(Some(&json!({
        "cmux": {"command": "/opt/cmux/bin/cmux", "args": ["mcp", "serve"]},
        "fetch": {"command": "/opt/fetch/server.js", "args": ["--stdio"]},
    })));
    servers[1].interpreter = Some("/usr/bin/node".into());
    let who = |exe: &str, argv: &[&str]| Identity {
        exe: exe.into(),
        argv: argv.iter().map(|w| w.to_string()).collect(),
        cwd: None,
    };
    let cases = [
        (who("/opt/cmux/bin/cmux", &["/opt/cmux/bin/cmux", "mcp", "serve"]), true),
        (who("/usr/bin/node", &["node", "/opt/fetch/server.js", "--stdio"]), true),
        // `exec -a`: a dev server that names itself the cmux server.
        (who("/usr/bin/python3", &["/opt/cmux/bin/cmux", "mcp", "serve"]), false),
        // A script's argv, but the executable is no interpreter.
        (who("/opt/devserver", &["node", "/opt/fetch/server.js", "--stdio"]), false),
        // A file named like an interpreter that is not the script's.
        (who("/tmp/node", &["/tmp/node", "/opt/fetch/server.js", "--stdio"]), false),
    ];
    for (identity, server) in cases {
        let found = [under(11, 10, &identity.argv.join(" "))];
        let census = classify(&found, 10, &servers, None, |_| Some(identity.clone()));
        assert_eq!(matches!(census, Census::Clear), server, "{identity:?}");
    }
}

/// A script's interpreter is what its `#!` line runs: a program, or `env`'s name on `PATH`.
#[test]
fn a_scripts_interpreter_comes_from_its_shebang() {
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let node = bin.join("node");
    std::fs::write(&node, "").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&node, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let path = bin.to_string_lossy().into_owned();
    let script = |name: &str, text: &str| {
        let p = root.join(name);
        std::fs::write(&p, text).unwrap();
        p
    };
    let env = script("env.js", "#!/usr/bin/env node\nconsole.log(1)\n");
    let split = script("split.js", "#!/usr/bin/env -S node --no-warnings\n");
    let direct = script("direct.sh", "#!/bin/sh -e\necho\n");
    let plain = script("plain.js", "console.log(1)\n");
    let node = node.to_string_lossy().into_owned();
    assert_eq!(shebang(&env, &path), Some(node.clone()));
    assert_eq!(shebang(&split, &path), Some(node));
    assert_eq!(shebang(&direct, &path), Some("/bin/sh".into()));
    assert_eq!(shebang(&plain, &path), None);
    assert_eq!(shebang(&root.join("missing"), &path), None);
    let servers = resolved(vec![sidecar(&env.to_string_lossy(), &[]).unwrap()], &path, &root);
    assert_eq!(servers[0].interpreter, shebang(&env, &path));
    let _ = std::fs::remove_dir_all(root);
}

/// A server given by a relative path (`./mcp-server`) is the file the harness's own folder
/// holds, not one in acpmux's: the harness spawns it from there. Its folder has a space in it.
#[test]
fn a_relative_server_is_the_one_in_the_harnesss_folder() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    let (work, bin, other) = (root.join("my work"), root.join("bin"), root.join("other"));
    for d in [&work, &bin, &other] {
        std::fs::create_dir_all(d).unwrap();
    }
    let file = |p: &Path, text: &str| {
        std::fs::write(p, text).unwrap();
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p.to_path_buf()
    };
    let server = file(&work.join("mcp-server"), "");
    let elsewhere = file(&other.join("mcp-server"), "");
    file(&work.join("server.js"), "#!/usr/bin/env node\nconsole.log(1)\n");
    let node = file(&bin.join("node"), "");
    let servers = from_json(Some(&json!({
        "direct": {"command": "./mcp-server", "args": ["--stdio"]},
        "script": {"command": "./server.js", "args": ["--port", "0"]},
    })));
    let servers = resolved(servers, &bin.to_string_lossy(), &work);
    let who = |exe: &Path, argv: &[&str], cwd: Option<&Path>| Identity {
        exe: exe.to_path_buf(),
        argv: argv.iter().map(|w| w.to_string()).collect(),
        cwd: cwd.map(Path::to_path_buf),
    };
    let script = ["node", "./server.js", "--port", "0"];
    let cases = [
        (who(&server, &["./mcp-server", "--stdio"], Some(&other)), true),
        (who(&node, &script, Some(&work)), true),
        // The same argv, but the file it runs is in another folder.
        (who(&elsewhere, &["./mcp-server", "--stdio"], Some(&other)), false),
        // The script's argv, but not the interpreter its `#!` line runs.
        (who(&server, &script, Some(&work)), false),
        // The script's argv, run in another folder (`cd /tmp && node ./server.js`), or in a
        // folder that cannot be read: another script.
        (who(&node, &script, Some(&other)), false),
        (who(&node, &script, None), false),
    ];
    for (identity, server) in cases {
        let found = [under(11, 10, &identity.argv.join(" "))];
        let census = classify(&found, 10, &servers, None, |_| Some(identity.clone()));
        assert_eq!(matches!(census, Census::Clear), server, "{identity:?}");
    }
    let _ = std::fs::remove_dir_all(root);
}

/// An orphaned host's record from a daemon before servers carried an interpreter and a folder
/// still loads, with neither known.
#[test]
fn an_older_orphan_exit_record_loads_without_interpreter_or_folder() {
    let record = serde_json::json!({
        "idle_ms": 600000,
        "servers": [{"command": "acpmux", "args": ["mcp"], "resolved": "/usr/local/bin/acpmux"}],
        "path": "/usr/bin",
    });
    let exit: crate::agent_host::OrphanExit =
        serde_json::from_value(record).expect("an older record loads");
    assert_eq!(exit.cwd, std::path::PathBuf::new());
    assert_eq!(exit.servers.len(), 1);
    assert_eq!(exit.servers[0].interpreter, None);
}

/// A profile of Claude Code's stream-json kind under another family name (`claude-sr2`, a
/// wrapper that runs `claude`) reads Claude Code's configs: its user servers (`yab mcp` in
/// `~/.claude.json`) are its MCP servers, not work that keeps the idle harness up.
#[tokio::test]
async fn a_claude_wrapper_profile_reads_claude_codes_configs() {
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    let (home, cwd) = (root.join("home"), root.join("work"));
    for d in [&home, &cwd] {
        std::fs::create_dir_all(d).unwrap();
    }
    let user =
        json!({"mcpServers": {"yab": {"command": "/Applications/yab.app/yab", "args": ["mcp"]}}});
    std::fs::write(home.join(".claude.json"), user.to_string()).unwrap();
    let launch = crate::agent::Launch {
        args: vec!["/Users/me/.local/bin/claude-sr2".into()],
        env: [("HOME".to_string(), home.to_string_lossy().into_owned())].into_iter().collect(),
        cwd: cwd.clone(),
    };
    let read =
        LaunchServers::read(&launch, "claude-sr2".into(), crate::config::HarnessKind::ClaudeStdio)
            .await;
    let LaunchServers::Known { servers, .. } = read else { panic!("the configs were not read") };
    assert_eq!(
        servers.iter().map(|s| s.command.as_str()).collect::<Vec<_>>(),
        ["/Applications/yab.app/yab"]
    );
    // An ACP profile's family still decides (its own configs, none here).
    let acp =
        LaunchServers::read(&launch, "claude-sr2".into(), crate::config::HarnessKind::Acp).await;
    assert!(matches!(acp, LaunchServers::Known { servers, .. } if servers.is_empty()));
    let _ = std::fs::remove_dir_all(root);
}

/// What the census knew of a hosted harness's servers is kept in its session's meta and comes
/// back unchanged after a restart, so the daemon that adopts the host judges the same servers
/// (cmux NIGHTLY, 2026-10-30: about 150 adopted agents never hibernated after a crash).
#[test]
fn a_kept_launch_leaves_the_servers_env_out() {
    let given = json!([{
        "name": "forum", "command": "/opt/cmux/acpmux", "args": ["forum-mcp"],
        "env": [{"name": "ACPMUX_SESSION_TOKEN", "value": "secret-token"}],
    }]);
    let kept = launch_only(Some(&given)).unwrap();
    assert_eq!(kept, json!([{"command": "/opt/cmux/acpmux", "args": ["forum-mcp"]}]));
    assert!(!kept.to_string().contains("secret-token"));
    assert_eq!(from_json(Some(&kept)), from_json(Some(&given)));
    assert_eq!(launch_only(None), None);
}

#[test]
fn the_kept_servers_survive_the_session_file() {
    let stored = StoredLaunch {
        incarnation: "inc-1".into(),
        servers: vec![sidecar("/opt/cmux/acpmux", &["forum-mcp".into()]).unwrap()],
        path: "/usr/bin:/bin".into(),
        cwd: PathBuf::from("/w"),
        given: Some(
            json!([{"name": "cmux", "command": "/opt/cmux/cmux", "args": ["mcp", "serve"]}]),
        ),
    };
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    assert!(serde_json::to_value(&meta).unwrap().get("idleLaunch").is_none());
    meta.idle_launch = Some(stored.clone());
    let back: crate::store::SessionMeta =
        serde_json::from_value(serde_json::to_value(&meta).unwrap()).unwrap();
    assert_eq!(back.idle_launch, Some(stored));
}
