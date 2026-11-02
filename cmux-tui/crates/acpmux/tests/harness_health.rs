//! Agent CLI health (hq #1875): `_acpmux/harness/health` reads each harness's
//! installed version, install channel, newest version, sign-in and update
//! command. Fake installs stand in for each channel (npm, a read-only npm
//! prefix, Homebrew, bun, Claude's native installer, a standalone binary, a
//! missing one), and a loopback server stands in for the npm registry and the
//! Homebrew API, so nothing reaches the network.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in CLIs (shell scripts) for the version, sign-in
// and update checks, which launch-deny would skip.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "harness_health/update_outcomes.rs"]
mod update_outcomes;

#[path = "harness_health/inventory_refresh.rs"]
mod inventory_refresh;

#[path = "harness_health/update_plan.rs"]
mod update_plan;

#[path = "harness_health/claude_expiry.rs"]
mod claude_expiry;

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::harness_health::{Settings, latest::Sources};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-health-{name}-{}", std::process::id()));
    if root.exists() {
        // A read-only prefix from an earlier run must be writable to go.
        let _ = std::process::Command::new("chmod").arg("-R").arg("u+w").arg(&root).status();
        let _ = std::fs::remove_dir_all(&root);
    }
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// An executable at `file` that prints `version`, linked from `link`.
fn program(file: &Path, link: &Path, version: &str) {
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(file, format!("#!/bin/sh\necho '{version}'\n")).unwrap();
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    symlink(file, link).unwrap();
}

fn profile(dir: &Path, id: &str, body: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join(format!("{id}.toml")),
        format!("schema = 1\nid = \"{id}\"\nname = \"{id}\"\n{body}"),
    )
    .unwrap();
}

/// The npm registry and Homebrew API: path -> JSON. Records every request.
fn latest_server(answers: Vec<(&'static str, Value)>) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let asked = Arc::new(Mutex::new(Vec::new()));
    let log = asked.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut line = String::new();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            if reader.read_line(&mut line).is_err() {
                continue;
            }
            // The rest of the head, up to the blank line.
            let mut header = String::new();
            while reader.read_line(&mut header).is_ok_and(|n| n > 0) && header.trim() != "" {
                header.clear();
            }
            let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
            log.lock().unwrap().push(path.clone());
            let (status, body) = match answers.iter().find(|(p, _)| *p == path) {
                Some((_, v)) => ("200 OK", v.to_string()),
                None => ("404 Not Found", "{}".to_owned()),
            };
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    (port, asked)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn open(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 1 }
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("no reply in 60 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

/// A hub over the profiles in `user`, with no newest-version lookups.
fn hub_for(root: &Path, user: &Path, home: &Path) -> Arc<Hub> {
    let sources = ProfileSources { managed: vec![], user_dir: Some(user.into()), cmux_json: None };
    std::fs::create_dir_all(root.join("acpmux")).unwrap();
    std::fs::write(root.join("acpmux/config.json"), "{}").unwrap();
    let mut cfg = Config::load_from_with(&root.join("acpmux/config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.health.attach(Settings {
        sources: None,
        cache: None,
        home: home.into(),
        ..Settings::default()
    });
    hub
}

fn row<'a>(reply: &'a Value, id: &str) -> &'a Value {
    reply["harnesses"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["id"] == id))
        .unwrap_or_else(|| panic!("no {id} row in {reply}"))
}

/// Inventory consumers must never receive the diagnostic command/path fields,
/// and reading an empty cache must not run the first health check.
#[tokio::test]
async fn cmux_next_harness_inventory_is_cached_and_omits_private_diagnostics() {
    let root = scratch("inventory-cache");
    let home = root.join("home");
    let user = root.join("profiles");
    let hub = hub_for(&root, &user, &home);
    let cache = root.join("inventory-health.json");
    let private = "private@example.test secret-token";
    let mut cached = json!([{
        "id": "codex", "program": private, "path": private, "channel": "npm",
        "package": private, "version": "1.2.3", "latest": "1.2.4",
        "latestCheckedAt": 1234, "outdated": true, "auth": "signedIn",
        "authDetail": private, "login": private,
        "update": {"argv": [private], "command": private, "elevated": false},
        "problem": private, "checkedAt": 1235,
        "lastAutoUpdate": {"at": 1235, "ok": false, "detail": private}
    }]);
    let mut invalid_id = cached[0].clone();
    invalid_id["id"] = json!(private);
    let mut invalid_version = cached[0].clone();
    invalid_version["id"] = json!("broken");
    invalid_version["version"] = json!(format!("1.2.3 {private}"));
    invalid_version["latest"] = json!(private);
    cached.as_array_mut().unwrap().extend([invalid_id, invalid_version]);
    std::fs::write(&cache, cached.to_string()).unwrap();
    hub.health.attach(Settings { cache: Some(cache), home: home.clone(), ..Settings::default() });
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
        let mut client = Client::open(&hub, origin);
        let hello = client.call(method::INITIALIZE, json!({})).await.unwrap();
        assert!(
            hello
                .pointer("/_meta/acpmux/features")
                .unwrap()
                .as_array()
                .unwrap()
                .contains(&json!("harnessInventory"))
        );
        let reply =
            client.call(method::MUX_HARNESS_HEALTH, json!({"view": "inventory"})).await.unwrap();
        assert_eq!(
            reply,
            json!({"view": "inventory", "cached": true, "harnesses": [{
                "id": "codex", "family": null, "channel": "npm", "version": "1.2.3", "latest": "1.2.4",
                "latestCheckedAt": 1234, "outdated": true, "auth": "signedIn", "checkedAt": 1235
            }, {
                "id": "broken", "family": null, "channel": "npm", "version": null, "latest": null,
                "latestCheckedAt": 1234, "outdated": false, "auth": "signedIn", "checkedAt": 1235
            }]})
        );
        assert!(!reply.to_string().contains(private));
    }
    let mut peer = Client::open(&hub, Origin::Peer);
    assert!(peer.call(method::MUX_HARNESS_HEALTH, json!({"view": "inventory"})).await.is_err());

    let empty_root = scratch("inventory-empty");
    let marker = empty_root.join("version-ran");
    let binary = empty_root.join("bin/agent");
    std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
    std::fs::write(&binary, format!("#!/bin/sh\ntouch '{}'\necho 1.2.3\n", marker.display()))
        .unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
    let profiles = empty_root.join("profiles");
    profile(&profiles, "test", &format!("command = \"{}\"\n", binary.display()));
    let empty = hub_for(&empty_root, &profiles, &empty_root.join("home"));
    let mut local = Client::open(&empty, Origin::Local);
    let reply = local.call(method::MUX_HARNESS_HEALTH, json!({"view": "inventory"})).await.unwrap();
    assert_eq!(reply, json!({"view": "inventory", "cached": true, "harnesses": []}));
    assert!(!marker.exists(), "an inventory read ran the CLI");
    assert!(empty.health.rows().is_empty());
}

#[tokio::test]
async fn cmux_next_harness_inventory_refuses_controls_and_unknown_views() {
    let root = scratch("inventory-controls");
    let hub = hub_for(&root, &root.join("profiles"), &root.join("home"));
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
        let mut client = Client::open(&hub, origin);
        for params in [
            json!({"view": "inventory", "refresh": true}),
            json!({"view": "inventory", "rescan": true}),
            json!({"view": "inventory", "checkLatest": true}),
            json!({"view": "inventory", "autoUpdate": {"id": "codex", "on": true}}),
            json!({"view": "inventory", "machine": "other-host"}),
            json!({"view": "inventory", "command": "echo bad"}),
            json!({"view": "inventroy"}),
            json!({"view": null}),
        ] {
            let error = client
                .call(method::MUX_HARNESS_HEALTH, params)
                .await
                .expect_err("inventory accepted a control");
            assert_eq!(error["code"], -32602);
        }
    }
    assert!(hub.health.rows().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn health_reads_version_channel_newest_signin_and_update_per_install() {
    let root = scratch("installs");
    let home = root.join("home");
    let user = root.join("config").join("harnesses");

    // npm, writable prefix: the ACP adapter behind codex.
    let npm = root.join("npm");
    let codex_file = npm.join("lib/node_modules/@zed-industries/codex-acp/bin/codex-acp.js");
    let codex = npm.join("bin/codex-acp");
    program(&codex_file, &codex, "codex-acp 0.3.1");
    // No `codex` on its PATH: its sign-in is the model probe's answer below.
    profile(
        &user,
        "codex",
        &format!("command = \"{}\"\n[env]\nPATH = \"/usr/bin:/bin\"\n", codex.display()),
    );
    // npm, a prefix this user cannot write: the update needs sudo, shown, never run.
    let npm_ro = root.join("npm-ro");
    let opencode = npm_ro.join("bin/opencode");
    program(&npm_ro.join("lib/node_modules/opencode-ai/bin/opencode"), &opencode, "0.15.0");
    std::fs::set_permissions(
        npm_ro.join("lib/node_modules"),
        std::fs::Permissions::from_mode(0o555),
    )
    .unwrap();
    profile(&user, "opencode", &format!("command = \"{}\"\n", opencode.display()));
    // Homebrew.
    let gemini = root.join("brew/bin/gemini");
    program(&root.join("brew/Cellar/gemini-cli/0.9.0/bin/gemini"), &gemini, "0.9.0");
    profile(&user, "gemini", &format!("command = \"{}\"\n", gemini.display()));
    // bun.
    let pi = home.join(".bun/bin/pi-acp");
    program(
        &home.join(".bun/install/global/node_modules/pi-acp/dist/index.js"),
        &pi,
        "pi-acp v1.0.0",
    );
    profile(&user, "pi", &format!("command = \"{}\"\n", pi.display()));
    // Claude's native installer, signed in by its profile's check.
    let claude = home.join(".local/bin/claude");
    program(&home.join(".local/share/claude/versions/2.0.5"), &claude, "2.0.5 (Claude Code)");
    profile(
        &user,
        "claude",
        &format!(
            "protocol = \"claude-stdio\"\ncommand = \"{}\"\n[auth]\nlogin = \"claude auth login\"\ncheck = [\"/usr/bin/true\"]\n",
            claude.display()
        ),
    );
    // A standalone binary whose check fails.
    let grok = root.join("tools/grok");
    program(&root.join("tools/grok-1.2.3"), &grok, "grok 1.2.3");
    profile(
        &user,
        "grok",
        &format!("command = \"{}\"\n[auth]\ncheck = [\"/usr/bin/false\"]\n", grok.display()),
    );
    // Not installed.
    profile(&user, "gone", &format!("command = \"{}\"\n", root.join("nowhere/gone").display()));

    let (port, asked) = latest_server(vec![
        ("/npm/@zed-industries%2Fcodex-acp/latest", json!({"version": "0.4.0"})),
        ("/npm/opencode-ai/latest", json!({"version": "0.15.0"})),
        ("/npm/pi-acp/latest", json!({"version": "1.0.0"})),
        ("/npm/@anthropic-ai%2Fclaude-code/latest", json!({"version": "2.0.9"})),
        ("/brew/formula/gemini-cli.json", json!({"versions": {"stable": "0.10.1"}})),
    ]);

    let sources = ProfileSources { managed: vec![], user_dir: Some(user.clone()), cmux_json: None };
    std::fs::create_dir_all(root.join("acpmux")).unwrap();
    std::fs::write(root.join("acpmux/config.json"), "{}").unwrap();
    let mut cfg = Config::load_from_with(&root.join("acpmux/config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let cache = root.join("acpmux/harness-health.json");
    hub.health.attach(Settings {
        sources: Some(Sources {
            npm: format!("http://127.0.0.1:{port}/npm"),
            brew: format!("http://127.0.0.1:{port}/brew"),
        }),
        cache: Some(cache.clone()),
        home: home.clone(),
        ..Settings::default()
    });
    // The model probe found codex signed out.
    hub.probe_errors
        .lock()
        .unwrap()
        .insert("codex".into(), "Not signed in: run `codex login`".into());

    let mut app = Client::open(&hub, Origin::LocalApp);
    let reply = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");

    let r = row(&reply, "codex");
    assert_eq!(
        (r["channel"].as_str(), r["package"].as_str()),
        (Some("npm"), Some("@zed-industries/codex-acp")),
        "{r}"
    );
    assert_eq!(
        (r["version"].as_str(), r["latest"].as_str(), r["outdated"].as_bool()),
        (Some("0.3.1"), Some("0.4.0"), Some(true)),
        "{r}"
    );
    assert_eq!(
        r["update"]["argv"],
        json!(["npm", "install", "-g", "--prefix", npm, "@zed-industries/codex-acp@latest"]),
        "{r}"
    );
    assert_eq!(r["update"]["elevated"], false, "{r}");
    assert_eq!(
        (r["auth"].as_str(), r["login"].as_str()),
        (Some("signedOut"), Some("codex login")),
        "{r}"
    );

    let r = row(&reply, "opencode");
    assert_eq!(
        (r["version"].as_str(), r["outdated"].as_bool()),
        (Some("0.15.0"), Some(false)),
        "{r}"
    );
    // SAFETY: geteuid has no preconditions. Root writes any folder.
    if unsafe { libc::geteuid() } != 0 {
        assert_eq!(r["update"]["elevated"], true, "{r}");
        assert_eq!(
            r["update"]["command"],
            format!(
                "sudo npm install -g --prefix {} opencode-ai@latest",
                acpmux::harness_health::channel::quote(npm_ro.to_str().unwrap())
            ),
            "{r}"
        );
    }

    let r = row(&reply, "gemini");
    assert_eq!(
        (r["channel"].as_str(), r["package"].as_str()),
        (Some("brew"), Some("gemini-cli")),
        "{r}"
    );
    assert_eq!(
        (r["version"].as_str(), r["latest"].as_str(), r["outdated"].as_bool()),
        (Some("0.9.0"), Some("0.10.1"), Some(true)),
        "{r}"
    );
    assert_eq!(r["update"]["argv"], json!(["brew", "upgrade", "gemini-cli"]), "{r}");

    let r = row(&reply, "pi");
    assert_eq!(
        (r["channel"].as_str(), r["version"].as_str(), r["outdated"].as_bool()),
        (Some("bun"), Some("1.0.0"), Some(false)),
        "{r}"
    );
    assert_eq!(
        r["update"]["argv"],
        json!([
            "/usr/bin/env",
            "-u",
            "XDG_CONFIG_HOME",
            format!("BUN_INSTALL_GLOBAL_DIR={}", home.join(".bun/install/global").display()),
            format!("BUN_INSTALL_BIN={}", home.join(".bun/bin").display()),
            "bun",
            "add",
            "-g",
            "pi-acp@latest"
        ]),
        "{r}"
    );

    let r = row(&reply, "claude");
    assert_eq!(
        (r["channel"].as_str(), r["version"].as_str(), r["latest"].as_str()),
        (Some("native"), Some("2.0.5"), Some("2.0.9")),
        "{r}"
    );
    assert_eq!(r["update"]["argv"], json!([claude.to_string_lossy(), "update"]), "{r}");
    assert_eq!(
        (r["auth"].as_str(), r["login"].as_str()),
        (Some("signedIn"), Some("claude auth login")),
        "{r}"
    );

    let r = row(&reply, "grok");
    assert_eq!(
        (r["channel"].as_str(), r["version"].as_str(), r["auth"].as_str()),
        (Some("standalone"), Some("1.2.3"), Some("signedOut")),
        "{r}"
    );
    assert!(r["update"].is_null() && r["latest"].is_null(), "{r}");

    let r = row(&reply, "gone");
    assert_eq!(r["channel"], "missing", "{r}");
    assert!(r["problem"].as_str().is_some_and(|p| p.contains("not installed")), "{r}");

    // One request per source, none for the standalone binary.
    let first = asked.lock().unwrap().clone();
    assert_eq!(first.len(), 5, "{first:?}");
    assert!(first.iter().all(|p| !p.contains("grok")), "{first:?}");
    assert!(
        std::fs::read_to_string(&cache).unwrap().contains("@zed-industries/codex-acp"),
        "no saved copy"
    );

    // After an update, `refresh` reads the new version; the newest-version
    // answers are fresh, so no source is asked again.
    std::fs::write(&codex_file, "#!/bin/sh\necho 'codex-acp 0.4.0'\n").unwrap();
    let again =
        app.call(method::MUX_HARNESS_HEALTH, json!({"refresh": true})).await.expect("refresh");
    let r = row(&again, "codex");
    assert_eq!(
        (r["version"].as_str(), r["outdated"].as_bool()),
        (Some("0.4.0"), Some(false)),
        "{r}"
    );
    assert_eq!(asked.lock().unwrap().len(), 5, "asked again: {:?}", asked.lock().unwrap());

    // A plain browser page (Web) reads the rows as last checked, the same rows
    // the app just read, and runs nothing: no refresh, latest check or
    // auto-update choice (the agent pane's dev host, cx-jlzsf). A peer gets none.
    let mut web = Client::open(&hub, Origin::Web);
    let read = web.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("web reads");
    assert_eq!(row(&read, "codex")["version"].as_str(), Some("0.4.0"), "{read}");
    for params in [
        json!({"refresh": true}),
        json!({"rescan": true}),
        json!({"checkLatest": true}),
        json!({"autoUpdate": {"id": "codex", "on": true}}),
    ] {
        web.call(method::MUX_HARNESS_HEALTH, params.clone()).await.expect_err("web ran a check");
    }
    assert_eq!(asked.lock().unwrap().len(), 5, "web asked a source: {:?}", asked.lock().unwrap());
    let mut peer = Client::open(&hub, Origin::Peer);
    peer.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect_err("peer origin");

    let _ = std::process::Command::new("chmod").arg("-R").arg("u+w").arg(&root).status();
    let _ = std::fs::remove_dir_all(&root);
}

/// Installs whose file sits in a `node_modules` folder npm does not own, and
/// programs that only run another one, are not npm installs: a one-click
/// `npm install -g` would add a second copy and leave this one as it was.
/// Sign-in follows the profile's check (with the profile's env) over a stale
/// probe error, and only an error about signing in reads as signed out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn health_reads_node_formulas_wrappers_and_signin_evidence() {
    let root = scratch("evidence");
    let home = root.join("home");
    let user = root.join("config").join("harnesses");
    std::fs::create_dir_all(&home).unwrap();

    // A Homebrew formula that bundles its node package.
    let gemini = root.join("brew/bin/gemini");
    program(
        &root.join(
            "brew/Cellar/gemini-cli/0.9.0/libexec/lib/node_modules/@google/gemini-cli/dist/index.js",
        ),
        &gemini,
        "0.9.0",
    );
    profile(&user, "gemini", &format!("command = \"{}\"\n", gemini.display()));
    // Claude's older local installer, a node_modules folder of its own.
    let claude = home.join(".claude/local/claude");
    program(
        &home.join(".claude/local/node_modules/@anthropic-ai/claude-code/cli.js"),
        &claude,
        "2.0.5 (Claude Code)",
    );
    profile(
        &user,
        "claude",
        &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", claude.display()),
    );
    // A pnpm global install: no npm package of that name, no npm update.
    let codex = root.join("pnpm/codex");
    program(
        &root.join(
            "pnpm/global/5/node_modules/.pnpm/@openai+codex@0.5.0/node_modules/@openai/codex/bin/codex.js",
        ),
        &codex,
        "codex-cli 0.5.0",
    );
    profile(&user, "codex", &format!("command = \"{}\"\n", codex.display()));
    // An interpreter running an adapter: node is not the harness.
    let node = root.join("node/bin/node");
    program(&root.join("node/Cellar/node/22.0.0/bin/node"), &node, "v22.0.0");
    profile(
        &user,
        "wrapped",
        &format!("command = \"{}\"\nargs = [\"/x/adapter.js\"]\n", node.display()),
    );
    // Signed in since the probe failed: the check passes, with the profile's env.
    let tool = root.join("tools/tool");
    program(&root.join("tools/tool-1.0.0"), &tool, "1.0.0");
    profile(
        &user,
        "fresh",
        &format!(
            "command = \"{}\"\n[env]\nHEALTH_MARK = \"yes\"\n[auth]\ncheck = [\"/bin/sh\", \"-c\", \"test \\\"$HEALTH_MARK\\\" = yes\"]\n",
            tool.display()
        ),
    );
    // A probe error that is not about signing in.
    profile(&user, "other", &format!("command = \"{}\"\n", tool.display()));

    let hub = hub_for(&root, &user, &home);
    {
        let mut errors = hub.probe_errors.lock().unwrap();
        errors.insert("fresh".into(), "Please log in again".into());
        errors.insert("other".into(), "failed to read catalog in /x: EACCES".into());
    }
    let mut app = Client::open(&hub, Origin::LocalApp);
    let reply = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");

    let r = row(&reply, "gemini");
    assert_eq!(
        (r["channel"].as_str(), r["package"].as_str(), r["version"].as_str()),
        (Some("brew"), Some("gemini-cli"), Some("0.9.0")),
        "{r}"
    );
    assert_eq!(r["update"]["argv"], json!(["brew", "upgrade", "gemini-cli"]), "{r}");

    let r = row(&reply, "claude");
    assert_eq!(
        (r["channel"].as_str(), r["package"].as_str()),
        (Some("native"), Some("@anthropic-ai/claude-code")),
        "{r}"
    );
    assert_eq!(r["update"]["argv"], json!([claude.to_string_lossy(), "update"]), "{r}");

    let r = row(&reply, "codex");
    assert_eq!(
        (r["channel"].as_str(), r["version"].as_str()),
        (Some("standalone"), Some("0.5.0")),
        "{r}"
    );
    assert!(r["update"].is_null(), "{r}");

    let r = row(&reply, "wrapped");
    assert_eq!(r["channel"], "launcher", "{r}");
    assert!(r["update"].is_null() && r["version"].is_null(), "{r}");

    assert_eq!(row(&reply, "fresh")["auth"], "signedIn", "{reply}");
    assert_eq!(row(&reply, "other")["auth"], "unknown", "{reply}");

    let _ = std::fs::remove_dir_all(&root);
}

/// Waits for harness `id`'s row to pass `done` (an auto-update runs in the background).
async fn wait_row(app: &mut Client, id: &str, done: impl Fn(&Value) -> bool) -> Value {
    for _ in 0..300 {
        let all = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");
        if done(row(&all, id)) {
            return row(&all, id).clone();
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("{id} never got there");
}

/// Auto-update (off by default, per harness): turning it on, or a check that finds an opted-in
/// harness outdated, runs its own updater (never one that needs sudo), then checks again. A failed
/// update is not retried for the same version until auto-update is turned on again. The choice is
/// kept in acpmux's home; a remote WebSocket connection cannot change it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn auto_update_runs_each_opted_in_harnesses_own_updater_then_checks_again() {
    let root = scratch("auto");
    let home = root.join("home");
    let user = root.join("config").join("harnesses");

    // Claude's native installer: `claude update` installs 2.0.9, or fails while `fail` exists.
    // Each run is logged to `runs`.
    let claude_file = home.join(".local/share/claude/versions/current");
    let claude = home.join(".local/bin/claude");
    let runs = root.join("claude-update-runs");
    let fail = root.join("claude-update-fails");
    std::fs::create_dir_all(claude_file.parent().unwrap()).unwrap();
    std::fs::write(
        &claude_file,
        format!(
            "#!/bin/sh\nif [ \"$1\" = update ]; then echo run >> '{1}'; if [ -e '{2}' ]; then echo 'network is down'; exit 1; fi; printf '#!/bin/sh\\necho \"2.0.9 (Claude Code)\"\\n' > '{0}.new' && chmod +x '{0}.new' && mv '{0}.new' '{0}'; echo updated; exit 0; fi\necho '2.0.5 (Claude Code)'\n",
            claude_file.display(),
            runs.display(),
            fail.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&claude_file, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(claude.parent().unwrap()).unwrap();
    symlink(&claude_file, &claude).unwrap();
    profile(
        &user,
        "claude",
        &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", claude.display()),
    );
    // npm, a prefix this user cannot write: its update needs sudo and never runs on its own.
    let npm_ro = root.join("npm-ro");
    let opencode = npm_ro.join("bin/opencode");
    program(&npm_ro.join("lib/node_modules/opencode-ai/bin/opencode"), &opencode, "0.15.0");
    std::fs::set_permissions(
        npm_ro.join("lib/node_modules"),
        std::fs::Permissions::from_mode(0o555),
    )
    .unwrap();
    profile(&user, "opencode", &format!("command = \"{}\"\n", opencode.display()));
    // npm, outdated, auto-update off.
    let npm = root.join("npm");
    let codex = npm.join("bin/codex-acp");
    program(
        &npm.join("lib/node_modules/@zed-industries/codex-acp/bin/codex-acp.js"),
        &codex,
        "codex-acp 0.3.1",
    );
    profile(&user, "codex", &format!("command = \"{}\"\n", codex.display()));

    let (port, _asked) = latest_server(vec![
        ("/npm/@anthropic-ai%2Fclaude-code/latest", json!({"version": "2.0.9"})),
        ("/npm/opencode-ai/latest", json!({"version": "0.16.0"})),
        ("/npm/@zed-industries%2Fcodex-acp/latest", json!({"version": "0.4.0"})),
    ]);
    let hub = hub_for(&root, &user, &home);
    let chosen = root.join("acpmux/harness-auto-update.json");
    hub.health.attach(Settings {
        sources: Some(Sources {
            npm: format!("http://127.0.0.1:{port}/npm"),
            brew: format!("http://127.0.0.1:{port}/brew"),
        }),
        cache: None,
        home: home.clone(),
        auto_update: Some(chosen.clone()),
        ..Settings::default()
    });
    let mut app = Client::open(&hub, Origin::LocalApp);
    let first = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");
    assert_eq!(row(&first, "claude")["autoUpdate"], false, "off by default: {first}");

    std::fs::write(&fail, "").unwrap();
    let on = app
        .call(method::MUX_HARNESS_HEALTH, json!({"autoUpdate": {"id": "claude", "on": true}}))
        .await
        .expect("auto-update on");
    assert_eq!(row(&on, "claude")["autoUpdate"], true, "{on}");
    // Turning it on runs the updater now, not at the next periodic check. This run fails.
    let r = wait_row(&mut app, "claude", |r| r["lastAutoUpdate"]["ok"] == false).await;
    assert_eq!(r["lastAutoUpdate"]["detail"], "network is down", "{r}");
    // Same installed and newest version: the periodic step does not run it again.
    assert_eq!(hub.auto_update_harnesses().await, Vec::<String>::new());
    // SAFETY: geteuid has no preconditions. Root writes any folder, so the sudo case is not one.
    let rooted = unsafe { libc::geteuid() } == 0;
    if !rooted {
        app.call(method::MUX_HARNESS_HEALTH, json!({"autoUpdate": {"id": "opencode", "on": true}}))
            .await
            .expect("auto-update on");
    }
    let mut web = Client::open(&hub, Origin::Web);
    web.call(method::MUX_HARNESS_HEALTH, json!({"autoUpdate": {"id": "codex", "on": true}}))
        .await
        .expect_err("web origin");
    let saved = std::fs::read_to_string(&chosen).expect("choice saved");
    assert!(saved.contains("claude") && !saved.contains("codex"), "{saved}");

    // Turning it on again tries again; only claude runs its updater, then everything is checked again.
    std::fs::remove_file(&fail).unwrap();
    app.call(method::MUX_HARNESS_HEALTH, json!({"autoUpdate": {"id": "claude", "on": true}}))
        .await
        .expect("auto-update on again");
    let r = wait_row(&mut app, "claude", |r| r["version"] == "2.0.9").await;
    assert_eq!(r["outdated"], false, "{r}");
    assert_eq!(r["lastAutoUpdate"]["ok"], true, "{r}");
    assert_eq!(std::fs::read_to_string(&runs).unwrap().lines().count(), 2, "one run per try");
    let after = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");
    let r = row(&after, "opencode");
    assert_eq!(
        (r["version"].as_str(), r["outdated"].as_bool()),
        (Some("0.15.0"), Some(true)),
        "{r}"
    );
    assert!(r["lastAutoUpdate"].is_null(), "a sudo update never runs: {r}");
    let r = row(&after, "codex");
    assert_eq!(
        (r["version"].as_str(), r["autoUpdate"].as_bool()),
        (Some("0.3.1"), Some(false)),
        "{r}"
    );

    // Off again, and kept off.
    let off = app
        .call(method::MUX_HARNESS_HEALTH, json!({"autoUpdate": {"id": "claude", "on": false}}))
        .await
        .expect("auto-update off");
    assert_eq!(row(&off, "claude")["autoUpdate"], false, "{off}");
    assert!(!std::fs::read_to_string(&chosen).unwrap().contains("claude"));

    let _ = std::process::Command::new("chmod").arg("-R").arg("u+w").arg(&root).status();
    let _ = std::fs::remove_dir_all(&root);
}

/// Update Everything (cx-1mbnu): `_acpmux/harness/update {ids}` runs now the updater of each named
/// outdated harness, whatever its auto-update choice, waits for it and checks again; a harness
/// whose update needs sudo is never run (its answer names the command), one already current is ok
/// without a run, and an unknown id is refused. Only the unix socket may ask, for the update and
/// for `_acpmux/sessions/restart_harness` alike: the local app, a WebSocket page and a peer may not.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn harness_update_runs_named_updaters_now_and_never_one_that_needs_sudo() {
    let root = scratch("update");
    let home = root.join("home");
    let user = root.join("config").join("harnesses");

    // Claude's native installer: `claude update` installs 2.0.9; each run is logged to `runs`.
    let claude_file = home.join(".local/share/claude/versions/current");
    let claude = home.join(".local/bin/claude");
    let runs = root.join("claude-update-runs");
    std::fs::create_dir_all(claude_file.parent().unwrap()).unwrap();
    std::fs::write(
        &claude_file,
        format!(
            "#!/bin/sh\nif [ \"$1\" = update ]; then echo run >> '{1}'; printf '#!/bin/sh\\necho \"2.0.9 (Claude Code)\"\\n' > '{0}.new' && chmod +x '{0}.new' && mv '{0}.new' '{0}'; echo updated; exit 0; fi\necho '2.0.5 (Claude Code)'\n",
            claude_file.display(),
            runs.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&claude_file, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(claude.parent().unwrap()).unwrap();
    symlink(&claude_file, &claude).unwrap();
    profile(
        &user,
        "claude",
        &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", claude.display()),
    );
    // npm, a prefix this user cannot write: its update needs sudo.
    let npm_ro = root.join("npm-ro");
    let opencode = npm_ro.join("bin/opencode");
    program(&npm_ro.join("lib/node_modules/opencode-ai/bin/opencode"), &opencode, "0.15.0");
    std::fs::set_permissions(
        npm_ro.join("lib/node_modules"),
        std::fs::Permissions::from_mode(0o555),
    )
    .unwrap();
    profile(&user, "opencode", &format!("command = \"{}\"\n", opencode.display()));

    let (port, _asked) = latest_server(vec![
        ("/npm/@anthropic-ai%2Fclaude-code/latest", json!({"version": "2.0.9"})),
        ("/npm/opencode-ai/latest", json!({"version": "0.16.0"})),
    ]);
    let hub = hub_for(&root, &user, &home);
    hub.health.attach(Settings {
        sources: Some(Sources {
            npm: format!("http://127.0.0.1:{port}/npm"),
            brew: format!("http://127.0.0.1:{port}/brew"),
        }),
        cache: None,
        home: home.clone(),
        // Auto-update is off for every harness: the request runs anyway.
        auto_update: Some(root.join("acpmux/harness-auto-update.json")),
        ..Settings::default()
    });
    let mut local = Client::open(&hub, Origin::Local);
    let first = local.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");
    assert_eq!(
        (
            row(&first, "claude")["outdated"].as_bool(),
            row(&first, "claude")["autoUpdate"].as_bool()
        ),
        (Some(true), Some(false)),
        "{first}"
    );

    // Nobody but the unix socket may run an update or restart chats.
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut other = Client::open(&hub, origin);
        other
            .call(method::MUX_HARNESS_UPDATE, json!({"ids": ["claude"]}))
            .await
            .expect_err("only the unix socket updates a harness");
        other
            .call(method::MUX_SESSIONS_RESTART_HARNESS, json!({}))
            .await
            .expect_err("only the unix socket restarts chats");
    }
    assert!(!runs.exists(), "an update ran for another origin");

    // SAFETY: geteuid has no preconditions. Root writes any folder, so the sudo case is not one.
    let rooted = unsafe { libc::geteuid() } == 0;
    let ids =
        if rooted { json!(["claude", "nope"]) } else { json!(["claude", "opencode", "nope"]) };
    let reply = local.call(method::MUX_HARNESS_UPDATE, json!({"ids": ids})).await.expect("update");
    let result = |id: &str| {
        reply["results"]
            .as_array()
            .and_then(|all| all.iter().find(|r| r["id"] == id))
            .cloned()
            .unwrap_or_else(|| panic!("no {id} result in {reply}"))
    };
    let r = result("claude");
    assert_eq!((r["ok"].as_bool(), r["version"].as_str()), (Some(true), Some("2.0.9")), "{r}");
    assert_eq!(std::fs::read_to_string(&runs).unwrap().lines().count(), 1, "one run");
    if !rooted {
        let r = result("opencode");
        assert_eq!(
            (r["ok"].as_bool(), r["version"].as_str()),
            (Some(false), Some("0.15.0")),
            "{r}"
        );
        assert!(
            r["error"].as_str().is_some_and(|e| e.contains(&format!(
                "sudo npm install -g --prefix {} opencode-ai@latest",
                acpmux::harness_health::channel::quote(npm_ro.to_str().unwrap())
            ))),
            "the sudo command is named, never run: {r}"
        );
    }
    let r = result("nope");
    assert_eq!(r["ok"], false, "{r}");
    // The health rows the answer came from are the new check's.
    let after = local.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");
    assert_eq!(row(&after, "claude")["outdated"], false, "{after}");
    if !rooted {
        assert_eq!(row(&after, "opencode")["version"], "0.15.0", "{after}");
    }

    // Already current: ok, nothing runs again.
    let again = local
        .call(method::MUX_HARNESS_UPDATE, json!({"ids": ["claude"]}))
        .await
        .expect("update again");
    assert_eq!(again["results"], json!([{"id": "claude", "ok": true, "version": "2.0.9"}]));
    assert_eq!(std::fs::read_to_string(&runs).unwrap().lines().count(), 1, "ran again");
    // Never a command from the caller.
    local
        .call(method::MUX_HARNESS_UPDATE, json!({"ids": "claude"}))
        .await
        .expect_err("ids must be a list of ids");
    // No chat runs here: nothing restarts.
    let moved = local
        .call(method::MUX_SESSIONS_RESTART_HARNESS, json!({"harnesses": ["claude"]}))
        .await
        .expect("restart");
    assert_eq!(moved, json!({"restarted": 0, "after_turn": 0, "failed": 0, "errors": []}));

    let _ = std::process::Command::new("chmod").arg("-R").arg("u+w").arg(&root).status();
    let _ = std::fs::remove_dir_all(&root);
}

/// A fake `codex` at `dir/codex`: `codex login status` prints `says` and exits
/// `code`, as Codex does (0 "Logged in using ChatGPT", 1 "Not logged in", and 1
/// for a check it could not make).
fn codex_login(dir: &Path, code: i32, says: &str) {
    std::fs::create_dir_all(dir).unwrap();
    let file = dir.join("codex");
    std::fs::write(
        &file,
        format!(
            "#!/bin/sh\n[ \"$1 $2\" = \"login status\" ] || exit 9\necho '{says}'\nexit {code}\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
}

// cx-ae9eb: a harness found on PATH has no profile check, so its sign-in read
// unknown and the model rail could not tell a signed-out Codex from a working
// one. Codex answers `codex login status`; Claude's own sign-in sources only
// ever prove a sign-in (none found stays unknown, never a guess).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn health_reads_codex_login_status_and_claude_credentials_without_a_check() {
    let root = scratch("builtin-signin");
    let home = root.join("home");
    let user = root.join("config").join("harnesses");
    let adapter = root.join("npm/bin/codex-acp");
    program(&root.join("npm/lib/codex-acp.js"), &adapter, "codex-acp 0.3.1");
    // hq#2569 #2: Codex through a model provider of its own (sr's layout on
    // the capture minis: a bearer token in config.toml), where `codex login
    // status` says "Not logged in" while Codex works; and one whose `env_key`
    // is unset here.
    let codex_home = |name: &str, provider: &str| {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("config.toml"),
            format!("model_provider = \"sr\"\n[model_providers.sr]\nbase_url = \"http://127.0.0.1:31415/v1\"\n{provider}"),
        )
        .unwrap();
        format!("CODEX_HOME = \"{}\"\n", dir.display())
    };
    let sr_home = codex_home("codex-sr-home", "experimental_bearer_token = \"sr-token\"\n");
    let keyless_home =
        codex_home("codex-keyless-home", "env_key = \"ACPMUX_HEALTH_NO_SUCH_KEY\"\n");
    // Each Codex harness runs the adapter with its own `codex` first on PATH.
    for (id, code, says, extra) in [
        ("codex-sr", 1, "Not logged in", sr_home.as_str()),
        ("codex-keyless", 1, "Not logged in", keyless_home.as_str()),
        ("codex-out", 1, "Not logged in", ""),
        ("codex-in", 0, "Logged in using ChatGPT", ""),
        // A check Codex could not make (a custom provider, a bad config) is no sign-out.
        ("codex-unsure", 1, "Error checking login status: bad config", ""),
        // Signed in since its model probe failed to sign in: the fresh answer wins.
        ("codex-back", 0, "Logged in using ChatGPT", ""),
        // A CODEX_HOME acpmux cannot resolve here: the default home says nothing about it.
        (
            "codex-elsewhere",
            1,
            "Not logged in",
            "CODEX_HOME = \"${env:ACPMUX_HEALTH_NO_SUCH_HOME}\"\n",
        ),
    ] {
        let bin = root.join(format!("bin-{id}"));
        codex_login(&bin, code, says);
        profile(
            &user,
            id,
            &format!(
                "command = \"{}\"\n[env]\nPATH = \"{}:/usr/bin:/bin\"\n{extra}",
                adapter.display(),
                bin.display()
            ),
        );
    }
    // A wrapper that runs Codex somewhere else: this Mac's sign-in says nothing about it.
    let bin = root.join("bin-codex-remote");
    codex_login(&bin, 1, "Not logged in");
    profile(
        &user,
        "codex-remote",
        &format!(
            "command = \"/usr/bin/env\"\nargs = [\"codex-acp\"]\n[env]\nPATH = \"{}:/usr/bin:/bin\"\n",
            bin.display()
        ),
    );
    let claude = home.join(".local/bin/claude");
    program(&home.join(".local/share/claude/versions/2.0.5"), &claude, "2.0.5 (Claude Code)");
    let signed = root.join("claude-signed");
    std::fs::create_dir_all(&signed).unwrap();
    std::fs::write(signed.join(".credentials.json"), "{}").unwrap();
    let empty = root.join("claude-empty");
    std::fs::create_dir_all(&empty).unwrap();
    // A gateway token in the Claude home's settings env (sr's layout).
    let gateway = root.join("claude-gateway");
    std::fs::create_dir_all(&gateway).unwrap();
    std::fs::write(
        gateway.join("settings.json"),
        r#"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:31415","ANTHROPIC_AUTH_TOKEN":"t"}}"#,
    )
    .unwrap();
    for (id, dir) in [("claude-in", &signed), ("claude-none", &empty), ("claude-gateway", &gateway)]
    {
        profile(
            &user,
            id,
            &format!(
                "protocol = \"claude-stdio\"\ncommand = \"{}\"\n[env]\nCLAUDE_CONFIG_DIR = \"{}\"\n",
                claude.display(),
                dir.display()
            ),
        );
    }

    let hub = hub_for(&root, &user, &home);
    hub.probe_errors
        .lock()
        .unwrap()
        .insert("codex-back".into(), "Not signed in: run `codex login`".into());
    for id in ["codex-sr", "codex-keyless"] {
        hub.probe_errors
            .lock()
            .unwrap()
            .insert(id.into(), "Not signed in: run `codex login`".into());
    }
    let mut app = Client::open(&hub, Origin::LocalApp);
    let reply = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.expect("health");

    let auth = |id: &str| row(&reply, id)["auth"].as_str().map(str::to_owned);
    assert_eq!(auth("codex-out").as_deref(), Some("signedOut"), "{reply}");
    assert_eq!(row(&reply, "codex-out")["login"], "codex login", "{reply}");
    assert_eq!(auth("codex-in").as_deref(), Some("signedIn"), "{reply}");
    assert_eq!(auth("codex-unsure").as_deref(), Some("unknown"), "{reply}");
    assert_eq!(auth("codex-back").as_deref(), Some("signedIn"), "{reply}");
    assert_eq!(auth("codex-elsewhere").as_deref(), Some("unknown"), "{reply}");
    assert_eq!(auth("codex-remote").as_deref(), Some("unknown"), "{reply}");
    assert_eq!(auth("claude-in").as_deref(), Some("signedIn"), "{reply}");
    assert_eq!(auth("claude-none").as_deref(), Some("unknown"), "{reply}");
    // A provider of its own decides, over `codex login status` and an older
    // probe error: signed in with its token, unknown (never signed out, which
    // `codex login` could not fix) without its key.
    assert_eq!(auth("codex-sr").as_deref(), Some("signedIn"), "{reply}");
    let detail = row(&reply, "codex-sr")["authDetail"].as_str().unwrap_or_default().to_owned();
    assert!(detail.contains("`sr` provider") && !detail.contains("sr-token"), "{reply}");
    assert_eq!(auth("codex-keyless").as_deref(), Some("unknown"), "{reply}");
    assert_eq!(auth("claude-gateway").as_deref(), Some("signedIn"), "{reply}");

    let _ = std::fs::remove_dir_all(&root);
}
