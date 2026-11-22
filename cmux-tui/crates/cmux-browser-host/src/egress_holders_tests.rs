use super::*;

fn holder(path: &str, args: &[&str], env: &[&str]) -> Holder {
    Holder {
        pid: 1,
        path: path.to_string(),
        args: args.iter().map(|a| a.to_string()).collect(),
        env: env.iter().map(|e| e.to_string()).collect(),
    }
}

const NODE: &str = "/opt/homebrew/bin/node";

/// A dev server without a debugger is allowed on every port.
#[test]
fn a_plain_dev_server_is_allowed() {
    let node = holder(NODE, &["node", "server.js"], &["PATH=/usr/bin"]);
    assert_eq!(holder_refusal(&node, 5173, false), None);
    let python = holder("/usr/bin/python3", &["python3", "-m", "http.server"], &[]);
    assert_eq!(holder_refusal(&python, 8000, false), None);
}

/// `--inspect` and its forms open a code-execution port: that port is
/// refused (the default 9229 when no port is given), the dev server's own
/// port stays allowed.
#[test]
fn an_inspector_port_from_args_is_refused() {
    for (args, port) in [
        (&["node", "--inspect", "server.js"][..], 9229),
        (&["node", "--inspect=9333", "server.js"][..], 9333),
        (&["node", "--inspect-brk=127.0.0.1:9444", "a.js"][..], 9444),
        (&["node", "--inspect-wait=[::1]:9555", "a.js"][..], 9555),
        (&["node", "--inspect", "--inspect-port=9666", "a.js"][..], 9666),
        (&["node", "--inspect-port", "9777", "a.js"][..], 9777),
        (&["node", "--debug=5858", "a.js"][..], 5858),
        (&["bun", "--inspect", "a.ts"][..], 6499),
    ] {
        let h = holder(NODE, args, &[]);
        assert!(holder_refusal(&h, port, false).is_some(), "{args:?} on {port}");
        assert_eq!(holder_refusal(&h, 5173, false), None, "{args:?} keeps its dev port");
    }
}

/// `--inspect=0` or a host without a port leaves the inspector port
/// unknown: every port of that process is refused.
#[test]
fn an_unknown_inspector_port_refuses_every_port_of_the_process() {
    let h = holder(NODE, &["node", "--inspect=0", "server.js"], &[]);
    assert!(holder_refusal(&h, 5173, false).is_some());
    let h = holder(NODE, &["node", "--remote-debugging-port=0"], &[]);
    assert!(holder_refusal(&h, 5173, false).is_some());
}

/// Electron and Chromium apps launched with a remote debugging port.
#[test]
fn a_remote_debugging_port_from_args_is_refused() {
    let h = holder("/opt/x/app", &["app", "--remote-debugging-port=9222"], &[]);
    assert!(holder_refusal(&h, 9222, false).is_some());
    assert_eq!(holder_refusal(&h, 3000, false), None);
    let h = holder("/opt/x/app", &["app", "--remote-debugging-port", "9223"], &[]);
    assert!(holder_refusal(&h, 9223, false).is_some());
}

/// The environment opens an inspector too: NODE_OPTIONS (what `next dev
/// --inspect` passes to its children) and BUN_INSPECT.
#[test]
fn an_inspector_from_the_environment_is_refused() {
    let h = holder(
        NODE,
        &["node", "server.js"],
        &["NODE_OPTIONS=--max-old-space-size=4096 --inspect=9230"],
    );
    assert!(holder_refusal(&h, 9230, false).is_some());
    assert_eq!(holder_refusal(&h, 3000, false), None);
    let h =
        holder("/usr/local/bin/bun", &["bun", "a.ts"], &["BUN_INSPECT=ws://localhost:6500/abc"]);
    assert!(holder_refusal(&h, 6500, false).is_some());
    let h = holder("/usr/local/bin/bun", &["bun", "a.ts"], &["BUN_INSPECT=1"]);
    assert!(holder_refusal(&h, 3000, false).is_some(), "unknown port");
}

/// A node, bun or deno process opens its inspector on the default port
/// without any flag (SIGUSR1): the default inspector ports are refused for
/// those runtimes, and stay allowed for others.
#[test]
fn runtimes_are_refused_on_their_default_inspector_ports() {
    for path in [NODE, "/usr/local/bin/bun", "/usr/local/bin/deno", "/x/node22"] {
        let h = holder(path, &["x", "server.js"], &[]);
        assert!(holder_refusal(&h, 9229, false).is_some(), "{path}");
        assert!(holder_refusal(&h, 6499, false).is_some(), "{path}");
    }
    let h = holder("/usr/bin/python3", &["python3"], &[]);
    assert_eq!(holder_refusal(&h, 9229, false), None);
}

/// A Chromium-family app (Electron: VS Code, Cursor, Slack; CEF) and cmux
/// services are refused by what they are, on any port.
#[test]
fn chromium_family_and_cmux_services_are_refused() {
    let code = holder("/Applications/Visual Studio Code.app/Contents/MacOS/Code", &["Code"], &[]);
    assert!(holder_refusal(&code, 3000, true).is_some());
    assert_eq!(holder_refusal(&code, 3000, false), None, "the family flag decides");
    for path in [
        "/x/cmux-tui",
        "/x/acpmux",
        "/Applications/cmux.app/Contents/MacOS/cmux",
        "/x/Google Chrome",
    ] {
        assert!(holder_refusal(&holder(path, &[], &[]), 3000, false).is_some(), "{path}");
    }
}

/// macOS: an executable belongs to the Chromium family when its app bundle
/// (or, for a helper app, the app whose Frameworks hold it) ships Electron
/// Framework or Chromium Embedded Framework. Docker's backend sits in an app
/// without one and stays allowed.
#[test]
fn bundles_with_electron_or_cef_frameworks_are_chromium_family() {
    let root = std::env::temp_dir().join(format!("cmux-egress-bundles-{}", std::process::id()));
    let mk = |rel: &str| std::fs::create_dir_all(root.join(rel)).unwrap();
    mk("Code.app/Contents/Frameworks/Electron Framework.framework");
    mk("Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS");
    mk("Code.app/Contents/MacOS");
    mk("Cef.app/Contents/Frameworks/Chromium Embedded Framework.framework");
    mk("Cef.app/Contents/MacOS");
    mk("Docker.app/Contents/MacOS");
    mk("Docker.app/Contents/Frameworks");
    let at = |rel: &str| root.join(rel).display().to_string();
    let family = |rel: &str| bundle_is_chromium_family(&at(rel));
    assert!(family("Code.app/Contents/MacOS/Code"));
    assert!(family(
        "Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
    ));
    assert!(family("Cef.app/Contents/MacOS/Cef"));
    assert!(!family("Docker.app/Contents/MacOS/com.docker.backend"));
    assert!(!family("bin/node"));
    let _ = std::fs::remove_dir_all(&root);
}

/// `KERN_PROCARGS2`: argc, the exec path, padding, argv, then the
/// environment.
#[test]
fn procargs2_parses_args_and_env() {
    let mut data = 2i32.to_le_bytes().to_vec();
    data.extend(b"/opt/homebrew/bin/node\0\0\0\0node\0--inspect=9333\0PATH=/usr/bin\0NODE_OPTIONS=--x\0\0\0");
    let (args, env) = parse_procargs2(&data).unwrap();
    assert_eq!(args, ["node", "--inspect=9333"]);
    assert_eq!(env, ["PATH=/usr/bin", "NODE_OPTIONS=--x"]);
    assert!(parse_procargs2(&[1, 0]).is_none());
}

/// Node reads NODE_OPTIONS with double quotes, and option names with `_`
/// as well as `-`; `--inspect-brk-node` opens an inspector too.
#[test]
fn quoted_and_underscored_inspector_options_are_read() {
    let h = holder(NODE, &["node", "a.js"], &[r#"NODE_OPTIONS=--inspect="127.0.0.1:9333""#]);
    assert!(holder_refusal(&h, 9333, false).is_some(), "quoted");
    let h = holder(NODE, &["node", "--inspect_brk=9334", "a.js"], &[]);
    assert!(holder_refusal(&h, 9334, false).is_some(), "underscore");
    let h = holder(NODE, &["node", "--inspect-brk-node=9335", "a.js"], &[]);
    assert!(holder_refusal(&h, 9335, false).is_some(), "brk-node");
    let h = holder("/opt/x/browser", &["browser", "-remote-debugging-port=9336"], &[]);
    assert!(holder_refusal(&h, 9336, false).is_some(), "single dash");
}

/// A deleted runtime binary (Linux names it `node (deleted)`) is still a
/// runtime on its default inspector port.
#[test]
fn a_deleted_runtime_keeps_its_default_inspector_ports() {
    let h = holder("/usr/bin/node (deleted)", &["node"], &[]);
    assert!(holder_refusal(&h, 9229, false).is_some());
}

/// BUN_INSPECT over a Unix socket opens no TCP port: the dev server stays
/// allowed.
#[test]
fn bun_inspect_over_a_unix_socket_opens_no_port() {
    let h = holder("/usr/local/bin/bun", &["bun", "a.ts"], &["BUN_INSPECT=ws+unix:///tmp/b.sock"]);
    assert_eq!(holder_refusal(&h, 3000, false), None);
}

/// `process.title` writes over the argument area and pads it with NULs:
/// the environment after the padding is still read.
#[test]
fn procargs2_reads_the_environment_after_an_overwritten_title() {
    let mut data = 3i32.to_le_bytes().to_vec();
    data.extend(b"/opt/homebrew/bin/node\0\0next-server\0\0\0\0\0NODE_OPTIONS=--inspect=9333\0\0");
    let (args, env) = parse_procargs2(&data).unwrap();
    assert_eq!(args, ["next-server", "", ""]);
    assert_eq!(env, ["NODE_OPTIONS=--inspect=9333"]);
}

/// Chromium browsers that ship V8 in their own framework (Arc, Dia,
/// Vivaldi, Opera), and their helpers under the framework, are Chromium
/// family.
#[test]
fn bundles_with_a_v8_snapshot_in_a_framework_are_chromium_family() {
    let root = std::env::temp_dir().join(format!("cmux-egress-arc-{}", std::process::id()));
    let resources = "Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/Resources";
    std::fs::create_dir_all(root.join(resources)).unwrap();
    std::fs::write(root.join(resources).join("v8_context_snapshot.arm64.bin"), b"").unwrap();
    let helper = "Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper.app/Contents/MacOS";
    std::fs::create_dir_all(root.join(helper)).unwrap();
    std::fs::create_dir_all(root.join("Arc.app/Contents/MacOS")).unwrap();
    let family = |rel: &str| bundle_is_chromium_family(&root.join(rel).display().to_string());
    assert!(family("Arc.app/Contents/MacOS/Arc"));
    assert!(family(&format!("{helper}/Browser Helper")));
    let _ = std::fs::remove_dir_all(&root);
}

/// Only an app's own executables (in some `X.app/Contents/MacOS/`) count as
/// Chromium family: a non-V8 tool shipped in an Electron app's Resources
/// (Rancher Desktop's port forwarder) does not.
#[test]
fn tools_in_an_electron_apps_resources_are_not_chromium_family() {
    let root = std::env::temp_dir().join(format!("cmux-egress-rancher-{}", std::process::id()));
    for rel in [
        "Rancher.app/Contents/Frameworks/Electron Framework.framework",
        "Rancher.app/Contents/Resources/resources/darwin/lima/bin",
        "Rancher.app/Contents/MacOS",
    ] {
        std::fs::create_dir_all(root.join(rel)).unwrap();
    }
    let family = |rel: &str| bundle_is_chromium_family(&root.join(rel).display().to_string());
    assert!(family("Rancher.app/Contents/MacOS/Rancher Desktop"));
    assert!(!family("Rancher.app/Contents/Resources/resources/darwin/lima/bin/limactl"));
    let _ = std::fs::remove_dir_all(&root);
}
