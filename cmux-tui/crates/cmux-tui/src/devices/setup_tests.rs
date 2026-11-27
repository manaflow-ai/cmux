//! `cmux device setup|start` with a fake Mac (no ssh): every remote script it sends is recorded
//! and answered from the fake's state.

use std::cell::RefCell;
use std::path::Path;
use std::process::Child;

use acpmux::cli::hosts::{Remote, RemoteOut};
use serde_json::{Value, json};

use super::super::model::{Device, Kind, Role, Sources, State, Via};
use super::super::network::{NetworkKind, NetworkStatus};
use super::*;

const NIGHTLY_ACPMUX: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";

/// One Mac's state as the scripts see it.
#[derive(Clone)]
struct Mac {
    os: &'static str,
    arch: &'static str,
    user: &'static str,
    console: &'static str,
    version: String,
    running: bool,
    plist: Option<String>,
    signed_in: bool,
    redeem: &'static str,
    grants: (bool, bool),
    shared: bool,
    /// What the acpmux LaunchAgent runs, when there is one.
    daemon: Option<String>,
    /// Whether the installed app's acpmux points the LaunchAgent at its bundle.
    daemon_app: bool,
    /// Whether the Mac joined (`~/.local/bin/acpmux` is there).
    joined: bool,
}

impl Default for Mac {
    fn default() -> Self {
        Self {
            os: "Darwin",
            arch: "arm64",
            user: "me",
            console: "me",
            version: String::new(),
            running: false,
            plist: None,
            signed_in: true,
            redeem: "ok",
            grants: (true, true),
            shared: true,
            daemon: None,
            daemon_app: true,
            joined: false,
        }
    }
}

/// A fake [`Remote`] holding a [`Mac`].
struct FakeMac {
    mac: RefCell<Mac>,
    sent: RefCell<Vec<(String, Option<Vec<u8>>)>>,
    reachable: bool,
}

fn ok(stdout: impl Into<String>) -> RemoteOut {
    RemoteOut { ok: true, stdout: stdout.into(), stderr: String::new() }
}

fn failed(stdout: &str, stderr: &str) -> RemoteOut {
    RemoteOut { ok: false, stdout: stdout.into(), stderr: stderr.into() }
}

impl FakeMac {
    fn new(mac: Mac) -> Self {
        Self { mac: RefCell::new(mac), sent: RefCell::default(), reachable: true }
    }

    fn scripts(&self) -> Vec<String> {
        self.sent.borrow().iter().map(|(s, _)| s.clone()).collect()
    }

    fn sent_script(&self, script: &str) -> Vec<Option<Vec<u8>>> {
        self.sent.borrow().iter().filter(|(s, _)| s == script).map(|(_, i)| i.clone()).collect()
    }
}

impl Remote for FakeMac {
    fn host(&self) -> &str {
        "me@studio-mac"
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> anyhow::Result<RemoteOut> {
        self.sent.borrow_mut().push((script.to_owned(), stdin.map(<[u8]>::to_vec)));
        if !self.reachable {
            return Ok(failed("", "ssh: connect to host studio-mac port 22: Connection refused"));
        }
        let mut mac = self.mac.borrow_mut();
        let input = stdin.map(|b| String::from_utf8_lossy(b).into_owned()).unwrap_or_default();
        Ok(if script == PROBE {
            if mac.os != "Darwin" {
                ok(format!("os={}\nuid=1000\nuser={}\n", mac.os, mac.user))
            } else {
                ok(format!(
                    "os=Darwin\nuid=501\narch={}\nuser={}\nconsole={}\nversion={}\nrunning={}\n",
                    mac.arch,
                    mac.user,
                    mac.console,
                    mac.version,
                    u8::from(mac.running)
                ))
            }
        } else if script == INSTALL {
            if mac.running {
                failed("error=cmux NIGHTLY is running", "")
            } else {
                mac.version = "2100".into();
                ok("installed=2100\n")
            }
        } else if script == KEEPALIVE {
            let same = mac.plist.as_deref() == Some(input.as_str());
            mac.plist = Some(input);
            let load = if mac.console == mac.user { "bootstrapped" } else { "next-login" };
            ok(format!("file={}\nload={load}\n", if same { "same" } else { "written" }))
        } else if script == KEEPALIVE_CHECK {
            ok(match mac.plist.as_deref() {
                None => "file=missing\n",
                Some(p) if p == input => "file=same\n",
                Some(_) => "file=differs\n",
            })
        } else if script == START {
            mac.running = true;
            ok("ready=1\n")
        } else if script == WHOAMI {
            if mac.signed_in {
                ok("rc=0\n{\"email\":\"me@example.com\"}\n")
            } else {
                ok("rc=3\n{\"ok\":false,\"error\":{\"code\":\"not_signed_in\"}}\n")
            }
        } else if script == REDEEM {
            match mac.redeem {
                "ok" if input == "code-123\n" => {
                    mac.signed_in = true;
                    ok("rc=0\n{\"ok\":true}\n")
                }
                "unknown" => ok("rc=2\ncmux: unknown command \"handoff\"\n"),
                _ => ok("rc=1\nthe code expired\n"),
            }
        } else if script == SHARE_STATUS {
            ok(json!({"state": "running", "host": {
                "permissions": {"accessibility": mac.grants.0, "screen_recording": mac.grants.1},
                "screen": {"shared": mac.shared}}})
            .to_string())
        } else if script == DAEMON {
            let bundled = !mac.version.is_empty() && mac.daemon_app;
            let program = if bundled {
                NIGHTLY_ACPMUX
            } else if mac.joined {
                "/Users/me/.local/bin/acpmux"
            } else {
                return Ok(failed(
                    "error=no acpmux here installs its LaunchAgent: cmux NIGHTLY is too old and the Mac has not joined\n",
                    "",
                ));
            };
            let changed = mac.daemon.as_deref() != Some(program);
            mac.daemon = Some(program.to_owned());
            let gui = mac.console == mac.user;
            let state = if gui { "running" } else { "atNextLogin" };
            ok(format!(
                "by={}\nservice={}\nprogram={program}\nloaded={}\n",
                if bundled { "app" } else { "join" },
                json!({"manager": "launchd", "changed": changed, "state": state}),
                u8::from(gui)
            ))
        } else if script == DAEMON_CHECK {
            let loaded = mac.daemon.is_some() && mac.console == mac.user;
            ok(format!(
                "program={}\nloaded={}\n",
                mac.daemon.clone().unwrap_or_default(),
                u8::from(loaded)
            ))
        } else if script == OPEN_SETTINGS {
            ok("")
        } else {
            failed("", "unexpected script")
        })
    }

    fn push(&self, _: &Path, _: &str) -> anyhow::Result<()> {
        anyhow::bail!("setup never pushes files")
    }

    fn spawn(&self, _: &str) -> anyhow::Result<Child> {
        anyhow::bail!("setup never spawns")
    }
}

/// The asking side, with a fixed feed.
struct Asker {
    feed: String,
    mint: Result<String, AskError>,
    team: Option<String>,
    /// The agents permission; `None`: this cmux has no `remote-host agents` verb.
    agents: RefCell<Option<bool>>,
    /// The app's answer to `remote.confirm {"action":"allow_agents","on":true}`.
    allow: Result<Value, Value>,
    /// How many times the setter ran.
    allow_calls: RefCell<u32>,
}

impl Default for Asker {
    fn default() -> Self {
        Self {
            feed: feed(2100),
            mint: Ok("code-123".into()),
            team: Some("7WLXT3NR37".into()),
            agents: RefCell::new(Some(false)),
            allow: Ok(json!({"ok": true, "agents_may_share": true})),
            allow_calls: RefCell::new(0),
        }
    }
}

impl Asking for Asker {
    fn feed(&self) -> Result<String, String> {
        Ok(self.feed.clone())
    }
    fn team_id(&self) -> Option<String> {
        self.team.clone()
    }
    fn mint_handoff(&self) -> Result<String, AskError> {
        self.mint.clone()
    }
    fn agents_allowed(&self) -> Result<bool, AskError> {
        (*self.agents.borrow()).ok_or(AskError::Unsupported)
    }
    fn allow_agents(&self) -> Result<Value, Value> {
        *self.allow_calls.borrow_mut() += 1;
        if self.allow.as_ref().is_ok_and(|v| v["agents_may_share"] == json!(true)) {
            *self.agents.borrow_mut() = Some(true);
        }
        self.allow.clone()
    }
}

/// A world of one Mac (`studio-mac`) and this asking side, recording its audit lines.
struct FakeWorld {
    mac: FakeMac,
    asker: Asker,
    audit: RefCell<Vec<(String, Value)>>,
}

impl FakeWorld {
    fn new(mac: Mac) -> Self {
        Self { mac: FakeMac::new(mac), asker: Asker::default(), audit: RefCell::default() }
    }
}

/// A [`Remote`] borrowed from the world, so every run talks to the same fake Mac.
struct Borrowed<'a>(&'a FakeMac);

impl Remote for Borrowed<'_> {
    fn host(&self) -> &str {
        self.0.host()
    }
    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> anyhow::Result<RemoteOut> {
        self.0.exec(script, stdin)
    }
    fn push(&self, local: &Path, remote: &str) -> anyhow::Result<()> {
        self.0.push(local, remote)
    }
    fn spawn(&self, script: &str) -> anyhow::Result<Child> {
        self.0.spawn(script)
    }
}

impl World for FakeWorld {
    fn lookup(&self, target: &str) -> Result<(String, String), String> {
        if target == "studio-mac" {
            Ok(("studio-mac".into(), "me@studio-mac".into()))
        } else {
            Err(format!("no device named {target}"))
        }
    }
    fn remote<'a>(&'a self, _route: &'a str) -> Box<dyn Remote + 'a> {
        Box::new(Borrowed(&self.mac))
    }
    fn asking(&self) -> &dyn Asking {
        &self.asker
    }
    fn record(&self, event: &str, fields: Value) {
        self.audit.borrow_mut().push((event.to_owned(), fields));
    }
}

fn item(build: u64, channel: Option<&str>, url: &str) -> String {
    let channel =
        channel.map(|c| format!("<sparkle:channel>{c}</sparkle:channel>")).unwrap_or_default();
    format!(
        "<item><title>NIGHTLY {build}</title><sparkle:version>{build}</sparkle:version>{channel}\
         <enclosure url=\"{url}\" sparkle:edSignature=\"x\" length=\"{len}\" type=\"application/octet-stream\"/></item>",
        len = build * 10
    )
}

fn feed(newest: u64) -> String {
    let base = "https://files-next.cmux.com/nightly-next/";
    format!(
        "<rss><channel>{}{}{}</channel></rss>",
        item(newest - 100, None, &format!("{base}cmux-{}.dmg", newest - 100)),
        item(newest, Some("cmux-next"), &format!("{base}cmux-{newest}.dmg")),
        item(newest + 50, Some("cmux-next-dev"), &format!("{base}cmux-{}.dmg", newest + 50)),
    )
}

fn setup(mac: &FakeMac, asker: &Asker) -> Run {
    run_device("studio-mac", mac, asker, Mode::Setup, false, &mut |_| {})
}

fn state(run: &Run, step: &str) -> StepState {
    run.lines.iter().find(|l| l.step == step).unwrap_or_else(|| panic!("no {step}: {run:?}")).state
}

fn detail<'a>(run: &'a Run, step: &str) -> &'a str {
    &run.lines.iter().find(|l| l.step == step).unwrap().detail
}

#[test]
fn the_feed_pick_is_the_newest_nightly_channel_item_never_a_dev_ring_one() {
    let picked = pick(&feed(2100)).unwrap();
    assert_eq!(picked.build, 2100, "the cmux-next-dev item (2150) is a Dev-ring build");
    assert_eq!(picked.url, "https://files-next.cmux.com/nightly-next/cmux-2100.dmg");
    assert_eq!(picked.length, 21000);
    let stable = format!(
        "{}{}",
        item(
            5,
            Some("cmux-next-stable"),
            "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/a.dmg"
        ),
        item(4, None, "https://files-next.cmux.com/nightly-next/b.dmg")
    );
    assert_eq!(pick(&stable).unwrap().build, 5);
    let canary = item(9, Some("canary"), "https://files-next.cmux.com/nightly-next/c.dmg");
    assert!(pick(&canary).is_err(), "no Nightly item at all");
}

#[test]
fn the_feed_pick_refuses_a_dmg_outside_the_nightly_prefixes() {
    let evil = format!(
        "{}{}",
        item(7, None, "https://evil.example/nightly-next/next/x.dmg"),
        item(6, None, "https://files-next.cmux.com/nightly-next/y.dmg")
    );
    let error = pick(&evil).unwrap_err();
    assert!(error.contains("is not a nightly-next download"), "{error}");
}

#[test]
fn a_fresh_mac_gets_the_app_the_login_item_a_start_and_a_sign_in() {
    let mac = FakeMac::new(Mac { signed_in: false, ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "reach"), StepState::Ok);
    assert_eq!(state(&run, "app"), StepState::Changed);
    assert_eq!(state(&run, "login-item"), StepState::Changed);
    assert_eq!(state(&run, "start"), StepState::Changed);
    assert_eq!(state(&run, "sign-in"), StepState::Changed);
    assert_eq!(state(&run, "share"), StepState::Ok);
    assert_eq!(run.changed, ["app none->2100", "daemon", "login-item", "started", "signed in"]);
    assert!(run.failed().is_empty());
    // The install got the URL, length and Team ID on stdin; the script text carries no data.
    let install = mac.sent_script(INSTALL);
    let stdin = String::from_utf8(install[0].clone().unwrap()).unwrap();
    assert_eq!(
        stdin,
        "https://files-next.cmux.com/nightly-next/cmux-2100.dmg\n21000\n7WLXT3NR37\n"
    );
    // The handoff code went only on the redeem script's stdin.
    let redeem = mac.sent_script(REDEEM);
    assert_eq!(redeem, [Some(b"code-123\n".to_vec())]);
    assert!(mac.scripts().iter().all(|s| !s.contains("code-123")));
    let order: Vec<_> = run.lines.iter().map(|l| l.step).collect();
    assert_eq!(order, ["reach", "app", "daemon", "login-item", "start", "sign-in", "share"]);
}

#[test]
fn an_older_app_that_is_not_running_is_updated() {
    let mac = FakeMac::new(Mac { version: "2000".into(), ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "app"), StepState::Changed);
    assert_eq!(run.changed.first().map(String::as_str), Some("app 2000->2100"));
    assert_eq!(mac.sent_script(INSTALL).len(), 1);
}

#[test]
fn an_older_app_that_runs_is_never_replaced_only_reported() {
    let mac = FakeMac::new(Mac { version: "2000".into(), running: true, ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "app"), StepState::Warn);
    assert_eq!(detail(&run, "app"), "running 2000, Sparkle updates it to 2100");
    assert_eq!(state(&run, "start"), StepState::Ok);
    for script in mac.scripts() {
        for word in ["hdiutil", "ditto", "kill", "quit", "osascript"] {
            assert!(!script.contains(word), "sent {word} to a running app:\n{script}");
        }
    }
    assert!(mac.sent_script(INSTALL).is_empty());
    assert!(mac.sent_script(START).is_empty());
}

#[test]
fn a_current_app_is_ok() {
    let mac = FakeMac::new(Mac { version: "2100".into(), running: true, ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "app"), StepState::Ok);
    assert_eq!(detail(&run, "app"), "NIGHTLY 2100 is current");
}

#[test]
fn the_launch_agent_is_written_once_then_ok_on_a_rerun() {
    let mac = FakeMac::new(Mac { version: "2100".into(), ..Mac::default() });
    let first = setup(&mac, &Asker::default());
    assert_eq!(state(&first, "login-item"), StepState::Changed);
    let second = setup(&mac, &Asker::default());
    assert_eq!(state(&second, "login-item"), StepState::Ok);
    assert!(!second.changed.contains(&"login-item".to_owned()));
    let plist = mac.mac.borrow().plist.clone().unwrap();
    assert_eq!(plist, keepalive_plist());
    assert!(plist.contains("<key>RunAtLoad</key>\n\t<true/>"));
    assert!(plist.contains("<integer>300</integer>"));
    assert!(plist.contains(KEEPALIVE_LABEL));
    assert!(plist.contains("open -g -j -a '/Applications/cmux NIGHTLY.app'"));
    assert!(!plist.contains("kill"), "the keepalive never kills anything");
    assert!(KEEPALIVE.contains("launchctl bootstrap \"gui/$uid\""));
}

#[test]
fn no_gui_session_warns_and_starts_nothing() {
    let mac = FakeMac::new(Mac { version: "2100".into(), console: "root", ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "start"), StepState::Warn);
    assert_eq!(detail(&run, "start"), "nobody is logged in on studio-mac; it starts at next login");
    assert!(detail(&run, "login-item").contains("next login"));
    assert!(mac.sent_script(START).is_empty());
    assert_eq!(state(&run, "sign-in"), StepState::Skip);
}

#[test]
fn a_missing_grant_is_named_and_its_settings_pane_opened() {
    let mac = FakeMac::new(Mac {
        version: "2100".into(),
        running: true,
        grants: (true, false),
        shared: false,
        ..Mac::default()
    });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "share"), StepState::Warn);
    let text = detail(&run, "share");
    assert!(text.contains("Share This Mac is off"), "{text}");
    assert!(text.contains("missing Screen Recording"), "{text}");
    assert!(!text.contains("Accessibility"), "{text}");
    assert_eq!(mac.sent_script(OPEN_SETTINGS), [Some(b"screen-recording\n".to_vec())]);
    // Setup never turns sharing on.
    assert!(mac.scripts().iter().all(|s| !s.contains("share on")));
}

#[test]
fn a_route_that_is_not_a_mac_is_skipped() {
    let mac = FakeMac::new(Mac { os: "Linux", ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(run.lines.len(), 1);
    assert_eq!(state(&run, "reach"), StepState::Skip);
    assert_eq!(detail(&run, "reach"), "not a Mac (Linux)");
    assert!(run.failed().is_empty());
    // `--all` counts it as skipped, not set up (#43385 review F3).
    assert_eq!(run.not_a_mac().map(|l| l.detail.as_str()), Some("not a Mac (Linux)"));
    let mac = FakeMac::new(Mac::default());
    assert!(setup(&mac, &Asker::default()).not_a_mac().is_none());
}

/// #43385 review F1 at 0a493be7: the feed has only arm64 builds, so an Intel Mac is skipped
/// before the app step, and nothing on it is installed or replaced.
#[test]
fn an_intel_mac_is_skipped_before_anything_is_installed() {
    let mac = FakeMac::new(Mac { arch: "x86_64", version: "2000".into(), ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "reach"), StepState::Skip);
    assert_eq!(
        detail(&run, "reach"),
        "not an Apple silicon Mac (x86_64): cmux NIGHTLY is arm64 only"
    );
    assert!(run.lines.iter().all(|l| l.step == "reach" || l.step == "agents"), "{run:?}");
    assert!(run.not_a_mac().is_some());
    assert!(mac.scripts().iter().all(|s| s != INSTALL && s != KEEPALIVE && s != START));
}

/// #43385 review F1: the feed is the one nightly.yml publishes cmux NIGHTLY to
/// (`NIGHTLY_NEXT_FEED_BASE`), never the retired cmux NEXT-identity feed under `/next/`, and the
/// DMG prefixes and the INSTALL script's allowlist both take that feed's R2 downloads.
#[test]
fn the_feed_is_the_one_the_nightly_publisher_writes() {
    let workflow = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.github/workflows/nightly.yml"),
    )
    .expect("nightly.yml");
    let base = workflow
        .lines()
        .find_map(|l| l.trim().strip_prefix("NIGHTLY_NEXT_FEED_BASE: "))
        .expect("NIGHTLY_NEXT_FEED_BASE in nightly.yml")
        .trim();
    assert_eq!(FEED, format!("{base}/appcast-arm64.xml"));
    let download = format!("{base}/cmux-NIGHTLY-2100-arm64.dmg");
    let feed = item(2100, None, &download);
    assert_eq!(pick(&feed).unwrap().url, download);
    assert!(INSTALL.contains(&format!("{base}/*.dmg")), "INSTALL's allowlist refuses {download}");
}

#[test]
fn an_unreachable_mac_fails_reach_with_the_fix() {
    let mut mac = FakeMac::new(Mac::default());
    mac.reachable = false;
    let run = setup(&mac, &Asker::default());
    assert_eq!(run.failed(), ["reach"]);
    let line = &run.lines[0];
    assert!(line.detail.contains("Connection refused"), "{line:?}");
    assert!(line.fix.contains("cmux device add studio-mac"), "{line:?}");
}

#[test]
fn sign_in_without_the_handoff_verb_asks_for_a_newer_cmux() {
    let mac = FakeMac::new(Mac {
        version: "2100".into(),
        running: true,
        signed_in: false,
        ..Mac::default()
    });
    let asker = Asker { mint: Err(AskError::Unsupported), ..Asker::default() };
    let run = setup(&mac, &asker);
    assert_eq!(state(&run, "sign-in"), StepState::Warn);
    assert_eq!(
        detail(&run, "sign-in"),
        "sign in on studio-mac: sign-in handoff needs a newer cmux"
    );
    assert!(mac.sent_script(REDEEM).is_empty());

    let old_target = FakeMac::new(Mac {
        version: "2100".into(),
        running: true,
        signed_in: false,
        redeem: "unknown",
        ..Mac::default()
    });
    let run = setup(&old_target, &Asker::default());
    assert_eq!(
        detail(&run, "sign-in"),
        "sign in on studio-mac: sign-in handoff needs a newer cmux"
    );
}

#[test]
fn start_runs_reach_login_item_and_start_only() {
    let mac = FakeMac::new(Mac { version: "1".into(), ..Mac::default() });
    let run = run_device("studio-mac", &mac, &Asker::default(), Mode::Start, false, &mut |_| {});
    let order: Vec<_> = run.lines.iter().map(|l| l.step).collect();
    assert_eq!(order, ["reach", "daemon", "login-item", "start"]);
    assert!(mac.sent_script(INSTALL).is_empty(), "start never installs");
    assert_eq!(state(&run, "start"), StepState::Changed);
}

// Leo, 2026-11-16: "if you've connected to a headlessly running mini why would it need
// anything?": the kept-alive thing on the Mac is the daemon (acpmux's LaunchAgent, run from
// the app's bundle), not the app; the app keepalive stays beside it.
#[test]
fn setup_keeps_the_daemon_alive_under_launchd_from_the_apps_bundle_once() {
    let mac = FakeMac::new(Mac::default());
    let first = setup(&mac, &Asker::default());
    assert_eq!(state(&first, "daemon"), StepState::Changed);
    assert!(detail(&first, "daemon").contains(NIGHTLY_ACPMUX), "{}", detail(&first, "daemon"));
    assert!(detail(&first, "daemon").contains("with or without the app"));
    assert!(first.changed.contains(&"daemon".to_owned()));
    assert_eq!(mac.mac.borrow().daemon.as_deref(), Some(NIGHTLY_ACPMUX));
    // The app keepalive is still written: nothing was removed.
    assert_eq!(state(&first, "login-item"), StepState::Changed);
    let second = setup(&mac, &Asker::default());
    assert_eq!(state(&second, "daemon"), StepState::Ok);
    assert!(!second.changed.contains(&"daemon".to_owned()));
}

#[test]
fn the_daemon_script_installs_acpmuxs_own_launch_agent_and_reads_it_back() {
    assert!(DAEMON.contains(acpmux::capabilities::DAEMON_SERVICE_APP));
    assert!(DAEMON.contains("--json daemon service install"));
    assert!(DAEMON.contains("launchctl print \"gui/$(id -u)/com.acpmux.daemon\""));
    assert!(DAEMON.contains("'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux'"));
    for word in ["kill", "bootout", "quit", "sudo"] {
        assert!(!DAEMON.contains(word), "{word}");
    }
}

#[test]
fn with_no_one_at_the_screen_the_daemon_loads_at_the_next_login() {
    let mac = FakeMac::new(Mac { version: "2100".into(), console: "root", ..Mac::default() });
    let run = setup(&mac, &Asker::default());
    assert_eq!(state(&run, "daemon"), StepState::Changed);
    assert!(detail(&run, "daemon").contains("loads at the next login on studio-mac"));
}

#[test]
fn an_older_nightly_keeps_the_joins_launch_agent_and_a_mac_with_neither_is_told_to_join() {
    let joined = FakeMac::new(Mac {
        version: "2100".into(),
        daemon_app: false,
        joined: true,
        ..Mac::default()
    });
    let run = setup(&joined, &Asker::default());
    assert_eq!(state(&run, "daemon"), StepState::Changed);
    assert!(detail(&run, "daemon").contains("/Users/me/.local/bin/acpmux"));
    assert!(detail(&run, "daemon").contains("a newer cmux NIGHTLY runs it from the app"));
    let neither = FakeMac::new(Mac { version: "2100".into(), daemon_app: false, ..Mac::default() });
    let run = setup(&neither, &Asker::default());
    assert_eq!(state(&run, "daemon"), StepState::Warn);
    let line = run.lines.iter().find(|l| l.step == "daemon").unwrap();
    assert_eq!(line.fix, "cmux device add studio-mac --yes");
    assert!(run.failed().is_empty(), "the Mac is still set up: {run:?}");
}

#[test]
fn a_dry_run_reports_a_loaded_daemon_and_installs_nothing() {
    let mac = FakeMac::new(Mac { daemon: Some(NIGHTLY_ACPMUX.into()), ..Mac::default() });
    let run = run_device("studio-mac", &mac, &Asker::default(), Mode::Setup, true, &mut |_| {});
    assert_eq!(state(&run, "daemon"), StepState::Ok);
    assert!(mac.sent_script(DAEMON).is_empty());
    let none = FakeMac::new(Mac::default());
    let run = run_device("studio-mac", &none, &Asker::default(), Mode::Setup, true, &mut |_| {});
    assert_eq!(state(&run, "daemon"), StepState::Skip);
}

#[test]
fn a_dry_run_changes_nothing() {
    let mac = FakeMac::new(Mac { signed_in: false, grants: (false, true), ..Mac::default() });
    let run = run_device("studio-mac", &mac, &Asker::default(), Mode::Setup, true, &mut |_| {});
    assert!(run.changed.is_empty(), "{run:?}");
    for script in [INSTALL, DAEMON, KEEPALIVE, START, REDEEM, OPEN_SETTINGS] {
        assert!(mac.sent_script(script).is_empty());
    }
    assert_eq!(state(&run, "app"), StepState::Skip);
}

#[test]
fn json_lines_have_the_contract_shape() {
    let line = Line {
        step: "app",
        state: StepState::Changed,
        detail: "installed NIGHTLY 2100 (was 2000)".into(),
        fix: String::new(),
    };
    assert_eq!(
        line.json("studio-mac"),
        json!({"device": "studio-mac", "step": "app", "state": "changed",
               "detail": "installed NIGHTLY 2100 (was 2000)", "fix": ""})
    );
    let mut emitted = Vec::new();
    let mac = FakeMac::new(Mac::default());
    let run =
        run_device("studio-mac", &mac, &Asker::default(), Mode::Setup, false, &mut |l: &Line| {
            emitted.push(l.json("studio-mac"));
        });
    assert_eq!(emitted.len(), run.lines.len());
    for line in &emitted {
        let keys: Vec<_> = line.as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys.len(), 5, "{line}");
        for key in ["device", "step", "state", "detail", "fix"] {
            assert!(line.get(key).is_some(), "{key} in {line}");
        }
        assert!(
            ["ok", "changed", "warn", "fail", "skip"].contains(&line["state"].as_str().unwrap())
        );
    }
    let summary = run.summary_json();
    assert_eq!(summary["device"], "studio-mac");
    assert_eq!(summary["changed"], json!(["app none->2100", "daemon", "login-item", "started"]));
    assert!(
        summary["summary"]
            .as_str()
            .unwrap()
            .starts_with("studio-mac: changed app none->2100, daemon")
    );
}

fn device(id: &str, name: &str, kind: Kind, os: Option<&str>, via: Via) -> Device {
    Device {
        id: id.into(),
        name: name.into(),
        kind,
        device: cmux_device_kind::DeviceKind::Generic,
        symbol: cmux_device_kind::DeviceKind::Generic.symbol(),
        roles: vec![Role::RunsAgents],
        state: State::Offline,
        os: os.map(str::to_owned),
        reach: None,
        via: vec![via],
        added_at: None,
        detail: None,
        full_access: None,
        screen: None,
        hub_device: None,
    }
}

#[test]
fn all_selects_routed_macs_and_skips_phones_cloud_pool_and_unrouted_devices() {
    let peer = |n: &str| Via::Peer { name: n.into() };
    let listing = Listing {
        network: NetworkStatus { kind: NetworkKind::Tailscale, up: true, this: None, detail: None },
        devices: vec![
            device(
                "peer:studio-mac",
                "studio-mac",
                Kind::Computer,
                Some("macOS"),
                peer("studio-mac"),
            ),
            device("peer:mini-2", "mini-2", Kind::Computer, None, peer("mini-2")),
            device(
                "paired:p",
                "my-iphone",
                Kind::Phone,
                Some("iOS"),
                Via::Paired { id: "p".into() },
            ),
            device(
                "joined:m",
                "cloud-vm",
                Kind::Computer,
                Some("linux"),
                Via::Joined { machine_id: "m".into() },
            ),
            device(
                "peer:pool",
                "ci-linux-pool-3fa17bde",
                Kind::Computer,
                None,
                peer("ci-linux-pool-3fa17bde"),
            ),
            device("peer:box", "build-box", Kind::Computer, Some("linux"), peer("build-box")),
            device("peer:sandbox", "sandbox", Kind::Computer, Some("macOS"), peer("sandbox")),
        ],
        available: Vec::new(),
        pools: Vec::new(),
        invites: Vec::new(),
    };
    let sources = Sources {
        peers: json!({"peers": [
            {"name": "studio-mac", "url": "ssh://me@studio-mac.tail1234.ts.net"},
            {"name": "mini-2", "url": "ssh://mini-2:47811"},
            {"name": "ci-linux-pool-3fa17bde", "url": "ssh://pool"},
            {"name": "build-box", "url": "ssh://build-box"},
            {"name": "sandbox", "url": "ws://127.0.0.1:47811"}
        ]}),
        ..Sources::default()
    };
    let picks = select(&listing, &sources);
    assert_eq!(picks.len(), listing.devices.len(), "one line per device");
    let of = |name: &str| picks.iter().find(|(n, _)| n == name).unwrap().1.clone();
    assert_eq!(of("studio-mac"), Ok("me@studio-mac.tail1234.ts.net".into()));
    assert_eq!(of("mini-2"), Ok("mini-2".into()), "the URL's port is the daemon's, not ssh's");
    assert_eq!(of("my-iphone"), Err("a phone".into()));
    assert!(of("cloud-vm").unwrap_err().contains("Cloud"));
    assert!(of("ci-linux-pool-3fa17bde").unwrap_err().contains("pool"));
    assert_eq!(of("build-box"), Err("not a Mac (linux)".into()));
    assert!(of("sandbox").unwrap_err().contains("no ssh route"));
}

#[test]
fn an_ssh_config_host_is_a_route_too() {
    let d =
        device("joined:x", "studio", Kind::Computer, None, Via::Joined { machine_id: "x".into() });
    let sources = Sources {
        ssh_hosts: vec![crate::machine_runtime::SshConfigHost {
            alias: "studio".into(),
            host_name: None,
        }],
        ..Sources::default()
    };
    assert_eq!(route(&d, &sources), Ok("studio".into()));
    assert!(route(&d, &Sources::default()).is_err());
}

#[test]
fn the_device_usage_lists_setup_and_start() {
    for verb in ["device setup DEVICE|--all", "--dry-run", "device start DEVICE"] {
        assert!(super::super::USAGE.contains(verb), "{verb} missing");
    }
    let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        super::super::device_args(&words(&["device", "setup", "studio-mac"])),
        Some(words(&["setup", "studio-mac"]))
    );
    assert_eq!(
        super::super::device_args(&words(&["device", "start", "studio-mac"])),
        Some(words(&["start", "studio-mac"]))
    );
}

#[test]
fn scripts_carry_no_data_and_no_sudo() {
    for script in [
        PROBE,
        INSTALL,
        KEEPALIVE,
        KEEPALIVE_CHECK,
        START,
        WHOAMI,
        REDEEM,
        SHARE_STATUS,
        OPEN_SETTINGS,
    ] {
        assert!(!script.contains("sudo"), "{script}");
        assert!(!script.contains("kill"), "{script}");
    }
    // Whether NIGHTLY runs is its control socket answering the bundled CLI, never a process list.
    let plist = keepalive_plist();
    for script in [PROBE, INSTALL, plist.as_str()] {
        assert!(script.contains("version --json"), "{script}");
        assert!(script.contains("app_error"), "{script}");
        assert!(!script.contains("pgrep") && !script.contains(" ps "), "{script}");
    }
    assert!(INSTALL.contains("mktemp -d") && INSTALL.contains("trap cleanup EXIT"));
}

#[test]
fn the_daemon_op_and_the_cli_print_the_same_step_lines() {
    let request = cmux_tui_core::device_setup::DeviceSetupRequest {
        device: "studio-mac".into(),
        start_only: false,
        allow_agents: false,
        dry_run: false,
    };
    let mac =
        Mac { version: "2000".into(), signed_in: false, grants: (true, false), ..Mac::default() };

    let cli_world = FakeWorld::new(mac.clone());
    let mut cli = Vec::new();
    let run =
        run_one(&cli_world, "studio-mac", Mode::Setup, Options::default(), &mut |device, line| {
            cli.push(serde_json::from_str::<Value>(&cli_line(device, line, true)).unwrap());
        });
    let cli_summary = run.summary_json();

    let daemon_world = FakeWorld::new(mac);
    let mut events = Vec::new();
    let daemon_summary = serve(&daemon_world, &request, &mut |line| events.push(line));

    assert!(cli.len() >= 7, "{cli:?}");
    assert_eq!(events, cli, "the daemon's step lines are the CLI's --json lines");
    assert_eq!(daemon_summary, cli_summary);
    assert_eq!(*cli_world.audit.borrow(), *daemon_world.audit.borrow());
    assert_eq!(cli_world.audit.borrow()[0].0, "device.setup");
    // `verb: "start"` runs start's steps.
    let start_world = FakeWorld::new(Mac::default());
    let mut steps = Vec::new();
    serve(
        &start_world,
        &cmux_tui_core::device_setup::DeviceSetupRequest { start_only: true, ..request },
        &mut |line| steps.push(line["step"].as_str().unwrap().to_owned()),
    );
    assert_eq!(steps, ["reach", "daemon", "login-item", "start"]);
}

#[test]
fn a_device_with_no_route_fails_reach_in_the_shared_run() {
    let world = FakeWorld::new(Mac::default());
    let run = run_one(&world, "studio", Mode::Start, Options::default(), &mut |_, _| {});
    assert_eq!(run.failed(), ["reach"]);
    assert_eq!(run.lines[0].fix, "cmux device add studio");
    assert_eq!(world.audit.borrow()[0].1["failed"], json!(["reach"]));
}

#[test]
fn allow_agents_turns_the_permission_on_and_without_it_setup_only_reports() {
    let world = FakeWorld::new(Mac { version: "2100".into(), running: true, ..Mac::default() });
    let run = run_one(&world, "studio-mac", Mode::Setup, Options::default(), &mut |_, _| {});
    let agents = run.lines.iter().find(|l| l.step == "agents").unwrap();
    assert_eq!(agents.state, StepState::Ok);
    assert!(agents.detail.ends_with("is off"), "{agents:?}");
    assert_eq!(*world.asker.allow_calls.borrow(), 0, "never on without --allow-agents");

    let options = Options { allow_agents: true, ..Options::default() };
    let run = run_one(&world, "studio-mac", Mode::Setup, options, &mut |_, _| {});
    let agents = run.lines.iter().find(|l| l.step == "agents").unwrap();
    assert_eq!(agents.state, StepState::Changed);
    assert_eq!(*world.asker.allow_calls.borrow(), 1);
    assert!(run.changed.contains(&"agents allowed".to_owned()));

    // A cmux with no way to read the permission: no flag skips.
    let old = Asker::default();
    *old.agents.borrow_mut() = None;
    assert_eq!(share_policy_step(&old, false, false).state, StepState::Skip);
    assert_eq!(*old.allow_calls.borrow(), 0);
    // A dry run never calls the setter.
    let fresh = Asker::default();
    assert_eq!(share_policy_step(&fresh, true, true).state, StepState::Skip);
    assert_eq!(*fresh.allow_calls.borrow(), 0);
    // `start` never touches the permission.
    let run = run_one(&world, "studio-mac", Mode::Start, options, &mut |_, _| {});
    assert!(run.lines.iter().all(|l| l.step != "agents"));
}

#[test]
fn every_answer_to_allow_agents_is_a_line_and_none_is_a_fail() {
    let step = |allow: Result<Value, Value>| {
        let asker = Asker { allow, ..Asker::default() };
        let line = share_policy_step(&asker, true, false);
        assert_eq!(*asker.allow_calls.borrow(), 1, "the flag sends remote.confirm once");
        line
    };
    let on = step(Ok(json!({"ok": true, "agents_may_share": true})));
    assert_eq!(on.state, StepState::Changed);
    assert!(on.detail.ends_with("is on"), "{on:?}");

    let declined = step(Ok(json!({"ok": false, "declined": true})));
    assert_eq!(declined.state, StepState::Warn);
    assert!(declined.detail.contains("you said no"), "{declined:?}");

    let signed_out = step(Err(json!({"code": "invalid_params",
                                     "message": "Sign in to cmux to share this Mac."})));
    assert_eq!(signed_out.state, StepState::Warn);
    assert!(signed_out.detail.ends_with("sign in to cmux"), "{signed_out:?}");

    // An older app: its `remote.confirm` names the actions it has, or it has none.
    for older in [
        json!({"code": "invalid_params",
               "message": "action must be share, or access with device and scope (none, ask, view, full)"}),
        json!({"code": "method_not_found", "message": "remote.confirm"}),
    ] {
        let line = step(Err(older));
        assert_eq!(line.state, StepState::Warn);
        assert!(line.detail.ends_with("needs a newer cmux"), "{line:?}");
    }

    let closed = step(Err(json!({"code": "app.unavailable", "message": "cmux is not running"})));
    assert_eq!(closed.state, StepState::Warn);
    assert_eq!(closed.fix, "open cmux on this computer");
}
