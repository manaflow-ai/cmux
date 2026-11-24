//! A phone's chat start (`cloud-mobile-chat-v1` on the Cloud carrier, hq#8003 step 2): the
//! machine holds it to acpmux's Cloud mobile floor itself, also on the caller's own Cloud VM,
//! where a Mac's start keeps whatever mode its harness starts in.

use super::agent_session_attach_tests::{
    Client, FakeAcpmux, Fixture, KeyedRun, PhoneFloor, SESSION, WAIT, assert_code, mux_with, run,
    terminal_pane,
};
use super::*;
use crate::server::AgentStartHost;
use serde_json::{Value, json};

struct Phone {
    mux: Arc<Mux>,
    fake: FakeAcpmux,
    client: Client,
    surface: u64,
    cwd: String,
    mode: Arc<Mutex<String>>,
}

/// A carrier stream of the owner (stamped), declared a phone's when `phone`, with a fresh agent
/// tab in this machine's store; acpmux starts `family` sessions in `mode`.
fn connect(
    label: &str,
    phone: bool,
    strict: bool,
    family: &'static str,
    mode: &str,
    stuck: bool,
) -> Phone {
    let mode = Arc::new(Mutex::new(mode.to_owned()));
    let floor = PhoneFloor { strict, family, mode, stuck, table_gate: None };
    connect_with(label, phone, floor)
}

fn connect_with(label: &str, phone: bool, floor: PhoneFloor) -> Phone {
    connect_fixture(label, phone, floor, Fixture::default())
}

/// [`connect_with`], with `extra`'s catalog timing (`catalog_after`, `catalog_hang_ups`).
fn connect_fixture(label: &str, phone: bool, floor: PhoneFloor, extra: Fixture) -> Phone {
    let (family, mode) = (floor.family, floor.mode.clone());
    let fake = FakeAcpmux::start_with(
        label,
        Fixture { start_folder_trusted: Some(true), phone: Some(floor), ..extra },
    );
    let mux = mux_with(&fake, label);
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (_, pane) = terminal_pane(&mux);
    let host = agent_session_attach::agent_session_start::store_host(&mux);
    let surface = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":host,"harness":family}}),
    )["surface"]
        .as_u64()
        .unwrap();
    let mut client = Client::connect(&mux, label);
    let stamped = client.request(json!({"cmd":"carrier-role","vmk":"owner"}));
    assert_eq!(stamped["ok"], json!(true), "{stamped}");
    if phone {
        let info = client.request(json!({"cmd":"set-client-info","kind":"ios",
            "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
        assert_eq!(info["ok"], json!(true), "{info}");
    }
    // The chat's folder: anywhere below the home folder's parent but the home folder itself.
    let directory = PathBuf::from(format!("/tmp/cmux-phone-{label}-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let cwd = directory.to_string_lossy().into_owned();
    Phone { mux, fake, client, surface, cwd, mode }
}

impl Phone {
    fn start(&mut self) -> Value {
        let start = json!({"cmd":"agent-session-start","surface":self.surface,"cwd":self.cwd,
            "harness":"claude","vm_kind":"owner"});
        self.client.request(start)
    }

    /// The methods the daemon sent acpmux, in order, until the fake goes quiet.
    fn methods(&self) -> Vec<String> {
        let mut methods = Vec::new();
        while let Ok(frame) = self.fake.frames.recv_timeout(Duration::from_millis(300)) {
            if let Some(method) = frame["method"].as_str()
                && method != "_acpmux/watch"
            {
                methods.push(method.to_owned());
            }
        }
        methods
    }
}

#[test]
fn a_phone_start_on_the_owners_cloud_vm_moves_to_a_phone_mode() {
    let mut phone = connect("phone-settles", true, true, "claude", "acceptEdits", false);
    let started = phone.start();
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(started["data"]["session"], json!(SESSION));
    assert_eq!(*phone.mode.lock().unwrap(), "default");
    let methods = phone.methods();
    assert!(methods.contains(&"session/set_mode".to_owned()), "{methods:?}");
    assert!(!methods.contains(&"_acpmux/kill".to_owned()), "{methods:?}");
}

#[test]
fn a_phone_start_that_cannot_reach_a_phone_mode_is_ended() {
    let mut phone = connect("phone-stuck", true, true, "claude", "bypassPermissions", true);
    assert_code(&phone.start(), "agent_session.not_asking");
    let methods = phone.methods();
    assert!(methods.contains(&"session/new".to_owned()), "{methods:?}");
    assert_eq!(methods.last().map(String::as_str), Some("_acpmux/kill"), "{methods:?}");
}

#[test]
fn a_phone_start_needs_an_acpmux_that_holds_phone_prompts_to_the_floor() {
    let mut phone = connect("phone-old-acpmux", true, false, "claude", "default", false);
    assert_code(&phone.start(), "agent_session.not_asking");
    // Refused before any agent process exists.
    let methods = phone.methods();
    assert!(!methods.contains(&"session/new".to_owned()), "{methods:?}");
}

#[test]
fn a_phone_start_of_a_family_the_floor_has_no_mode_for_never_starts() {
    let mut phone = connect("phone-family", true, true, "opencode", "build", false);
    // The harness the tab names resolves through acpmux's catalog to its default family.
    let start = json!({"cmd":"agent-session-start","surface":phone.surface,"cwd":phone.cwd,
        "vm_kind":"owner"});
    assert_code(&phone.client.request(start), "agent_session.not_asking");
    let methods = phone.methods();
    assert!(!methods.contains(&"session/new".to_owned()), "{methods:?}");
}

#[test]
fn the_owners_own_start_on_their_cloud_vm_keeps_its_harness_mode() {
    let mut owner = connect("owner-keeps-mode", false, true, "claude", "acceptEdits", false);
    let started = owner.start();
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(*owner.mode.lock().unwrap(), "acceptEdits");
    let methods = owner.methods();
    assert!(!methods.contains(&"session/set_mode".to_owned()), "{methods:?}");
}

#[test]
fn a_phone_start_keeps_the_phones_floor_after_the_phone_disconnects() {
    let (release, gate) = std::sync::mpsc::channel();
    let floor = PhoneFloor {
        strict: true,
        family: "claude",
        mode: Arc::new(Mutex::new("acceptEdits".to_owned())),
        stuck: false,
        table_gate: Some(Arc::new(Mutex::new(gate))),
    };
    let Phone { fake, mut client, surface, cwd, mode, .. } =
        connect_with("phone-disconnects", true, floor);
    client.send(json!({"cmd":"agent-session-start","surface":surface,"cwd":cwd,
        "harness":"claude","vm_kind":"owner"}));
    // The start's worker waits on acpmux's table; the phone's connection ends meanwhile.
    let mut methods = Vec::new();
    while let Ok(frame) = fake.frames.recv_timeout(WAIT) {
        let method = frame["method"].as_str().unwrap_or_default().to_owned();
        let asked = method == "_acpmux/web_modes";
        methods.push(method);
        if asked {
            break;
        }
    }
    drop(client);
    release.send(()).unwrap();
    while let Ok(frame) = fake.frames.recv_timeout(Duration::from_millis(500)) {
        methods.push(frame["method"].as_str().unwrap_or_default().to_owned());
    }
    // The start that went on still got the phone's floor.
    assert!(methods.contains(&"session/new".to_owned()), "{methods:?}");
    assert!(methods.contains(&"session/set_mode".to_owned()), "{methods:?}");
    assert_eq!(*mode.lock().unwrap(), "default");
}

#[test]
fn a_phone_start_of_a_codex_bridge_session_moves_to_ask() {
    // acpmux lists Codex as a refused Web family; its bridge holds to the phone floor in `ask`.
    let mut phone = connect("phone-codex", true, true, "codex", "auto", false);
    let start = json!({"cmd":"agent-session-start","surface":phone.surface,"cwd":phone.cwd,
        "vm_kind":"owner"});
    let started = phone.client.request(start);
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(*phone.mode.lock().unwrap(), "ask");
}

/// hostd closes a start's tab past its session limit (`cloud_acp.rs` `Reply::Start`): the phone's
/// channel may close a tab whose chat it started itself, and no other bound tab.
#[test]
fn a_phone_may_close_the_tab_of_a_chat_it_started_and_no_other() {
    let mut phone = connect("phone-closes-own", true, true, "claude", "default", false);
    let started = phone.start();
    assert_eq!(started["ok"], json!(true), "{started}");
    // Another phone channel can't close it.
    let mut other = Client::connect(&phone.mux, "phone-closes-own-other");
    assert_eq!(other.request(json!({"cmd":"carrier-role","vmk":"owner"}))["ok"], json!(true));
    let declared = other.request(json!({"cmd":"set-client-info","kind":"ios",
        "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
    assert_eq!(declared["ok"], json!(true), "{declared}");
    let refused = other.request(json!({"cmd":"close-surface","surface":phone.surface}));
    assert_code(&refused, "remote_denied");
    let closed = phone.client.request(json!({"cmd":"close-surface","surface":phone.surface}));
    assert_eq!(closed["ok"], json!(true), "{closed}");
}

/// cmuxterm-hq run 42837396397 (cloud-chat-replies-production, 2026-11-10): the app restarted the
/// machine's acpmux with a person key (remote approvals) 0.3 s before the start, and the start's
/// catalog read waited on that fresh acpmux's login shell read past the 5 s every other call gets.
/// The start was refused `agent_session.timeout` ("did not start the agent in time") with no agent
/// spawned. A start waits for a starting acpmux's catalog, as acpmux itself holds it.
#[test]
fn the_owners_start_waits_for_a_starting_acpmuxs_catalog() {
    let mode = Arc::new(Mutex::new("default".to_owned()));
    let floor = PhoneFloor { strict: true, family: "claude", mode, stuck: false, table_gate: None };
    let late = Fixture { catalog_after: Some(Duration::from_secs(7)), ..Default::default() };
    let mut owner = connect_fixture("catalog-wait", false, floor, late);
    let start = json!({"cmd":"agent-session-start","surface":owner.surface,"cwd":owner.cwd,
        "harness":"claude","vm_kind":"owner"});
    let id = owner.client.send(start);
    let started = owner.client.answer_within(id, Duration::from_secs(30));
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(started["data"]["session"], json!(SESSION));
    let methods = owner.methods();
    assert!(methods.contains(&"session/new".to_owned()), "{methods:?}");
}

/// The app's keyed restart of acpmux (remote approvals) can land while the start reads the
/// catalog: the old acpmux closes the start's connection with no answer. The start connects to
/// the acpmux that comes up and asks again, and the agent starts there, not a refusal.
#[test]
fn the_owners_start_survives_acpmux_restarting_under_it() {
    let mode = Arc::new(Mutex::new("default".to_owned()));
    let floor = PhoneFloor { strict: true, family: "claude", mode, stuck: false, table_gate: None };
    let hang_ups = Arc::new(AtomicU64::new(2));
    let restarting = Fixture { catalog_hang_ups: hang_ups.clone(), ..Default::default() };
    let mut owner = connect_fixture("catalog-restart", false, floor, restarting);
    let start = json!({"cmd":"agent-session-start","surface":owner.surface,"cwd":owner.cwd,
        "harness":"claude","vm_kind":"owner"});
    let id = owner.client.send(start);
    let started = owner.client.answer_within(id, Duration::from_secs(30));
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(started["data"]["session"], json!(SESSION));
    assert_eq!(hang_ups.load(Ordering::SeqCst), 0);
    let methods = owner.methods();
    assert_eq!(methods.iter().filter(|m| *m == "_acpmux/harnesses").count(), 3, "{methods:?}");
    assert!(methods.contains(&"session/new".to_owned()), "{methods:?}");
}

/// router-review F2 on cmux#40640: the keyed gate read the acpmux run before a restart; the start
/// that reconnects to the run the restart brings, which holds no key for the caller, is refused
/// `needs_keyed_start` before any agent starts, and a run that still holds it starts the agent.
#[test]
fn a_keyed_start_checks_the_key_again_on_the_restarted_acpmux() {
    for (restarted, keyed) in [("run-b", false), ("run-a", true)] {
        let mode = Arc::new(Mutex::new("default".to_owned()));
        let floor =
            PhoneFloor { strict: true, family: "claude", mode, stuck: false, table_gate: None };
        let run = KeyedRun { current: Arc::new(Mutex::new("run-a")), restarted };
        let restarting = Fixture {
            catalog_hang_ups: Arc::new(AtomicU64::new(1)),
            keyed_run: Some(run),
            ..Default::default()
        };
        let mut owner = connect_fixture(&format!("keyed-{restarted}"), false, floor, restarting);
        let start = json!({"cmd":"agent-session-start","surface":owner.surface,"cwd":owner.cwd,
            "harness":"claude","vm_kind":"owner","require_person_key":true,
            "person_instance":"run-a"});
        let id = owner.client.send(start);
        let answer = owner.client.answer_within(id, Duration::from_secs(30));
        let methods = owner.methods();
        assert_eq!(methods.iter().filter(|m| *m == "_acpmux/status").count(), 2, "{methods:?}");
        assert_eq!(methods.contains(&"session/new".to_owned()), keyed, "{methods:?}");
        if keyed {
            assert_eq!(answer["ok"], json!(true), "{answer}");
        } else {
            assert_eq!(answer["error_code"], json!("agent_session.needs_keyed_start"), "{answer}");
            assert_eq!(answer["data"]["safe_to_restart"], json!(true), "{answer}");
        }
    }
}
