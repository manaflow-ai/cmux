use std::io::{Read as _, Write as _};
use std::path::Path;

use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::{AppCommand, parse};
use super::{
    CHANNELS, Check, Command, DEFAULT_BASE, Fetched, LOG_FILE, STATE_FILE, STATUS_LINES, apply,
    base_url, fetch, file_url, log, refused, status,
};

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const NOW: u64 = 1_795_340_100;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn pair(seed: u8) -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap()
}

fn raw(pair: &Ed25519KeyPair) -> [u8; 32] {
    pair.public_key().as_ref().try_into().unwrap()
}

/// A key's id as `cmux_signed_envelope::key_id` names it: 16 hex digits of its SHA-256.
fn key_id(raw: &[u8; 32]) -> String {
    Sha256::digest(raw).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

fn keys(pair: &Ed25519KeyPair) -> Vec<(String, [u8; 32])> {
    vec![(key_id(&raw(pair)), raw(pair))]
}

/// A switch file as scripts/cmux-next/web-ota-pointer.py signs it (cmux-web-pieces' tests).
fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    json!({"schema": 1, "payload": b64.encode(&bytes),
           "signatures": [{"key_id": key_id(&raw(pair)),
                           "sig": b64.encode(pair.sign(&bytes).as_ref())}]})
    .to_string()
}

fn file(channel: &str, serial: u64, pieces: Value) -> Value {
    json!({"schema": 1, "purpose": cmux_web_pieces::PURPOSE, "channel": channel,
           "serial": serial, "published_at": 1_795_340_000u64, "pieces": pieces, "refuse": []})
}

/// Serial `serial` of every-merge with the agent pane switched to the last good update.
fn switched(pair: &Ed25519KeyPair, serial: u64) -> Fetched {
    let pieces = json!({"agent-pane": {"serve": "last-good", "reason": "cmux#1"}});
    Fetched::Body(envelope(pair, &file("every-merge", serial, pieces)), Some("\"v1\"".to_owned()))
}

fn check(dir: &Path, channel: &str) -> Check {
    Check {
        state: dir.to_path_buf(),
        channel: channel.to_owned(),
        base: DEFAULT_BASE.to_owned(),
        active: Some(A.to_owned()),
        kept: vec![B.to_owned()],
        offline: false,
    }
}

fn state(dir: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(dir.join(STATE_FILE)).unwrap()).unwrap()
}

fn log_lines(dir: &Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join(LOG_FILE))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// The reply still serves the agent pane from the last good update `B`, the rest live from `A`.
fn assert_agent_pane_switched(reply: &Value) {
    assert_eq!(reply["pieces"]["agent-pane"]["serve"], "last-good", "{reply}");
    assert_eq!(reply["pieces"]["agent-pane"]["update"], B, "{reply}");
    assert_eq!(reply["pieces"]["pages"]["serve"], "live", "{reply}");
    assert_eq!(reply["pieces"]["pages"]["update"], A, "{reply}");
}

#[test]
fn web_pieces_parses_its_options() {
    let parsed = parse(&args(&[
        "app",
        "web-pieces",
        "check",
        "--state",
        "/tmp/s",
        "--channel",
        "nightly",
        "--active",
        A,
        "--kept",
        B,
        "--kept",
        A,
        "--offline",
    ]))
    .unwrap();
    assert_eq!(
        parsed,
        Some(AppCommand::WebPieces(Command::Check(Check {
            state: "/tmp/s".into(),
            channel: "nightly".to_owned(),
            base: DEFAULT_BASE.to_owned(),
            active: Some(A.to_owned()),
            kept: vec![B.to_owned(), A.to_owned()],
            offline: true,
        })))
    );
    assert_eq!(
        parse(&args(&["app", "web-pieces", "status", "--state", "/tmp/s"])).unwrap(),
        Some(AppCommand::WebPieces(Command::Status { state: "/tmp/s".into() }))
    );
    for bad in [
        &["app", "web-pieces"][..],
        &["app", "web-pieces", "status"],
        &["app", "web-pieces", "check", "--state", "/tmp/s"],
        &["app", "web-pieces", "check", "--channel", "nightly"],
        &["app", "web-pieces", "check", "--state", "/tmp/s", "--channel", "stable"],
        &[
            "app",
            "web-pieces",
            "check",
            "--state",
            "/tmp/s",
            "--channel",
            "nightly",
            "--active",
            "x",
        ],
        &[
            "app",
            "web-pieces",
            "check",
            "--state",
            "/tmp/s",
            "--channel",
            "nightly",
            "--kept",
            "AB",
        ],
        &["app", "web-pieces", "check", "--state", "/tmp/s", "--channel", "nightly", "--bogus"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn web_pieces_refused_parses_its_options() {
    let words = ["app", "web-pieces", "refused", "--state", "/tmp/s", "--channel", "nightly"];
    let mut good = words.to_vec();
    good.extend(["--key", A]);
    assert_eq!(
        parse(&args(&good)).unwrap(),
        Some(AppCommand::WebPieces(Command::Refused {
            state: "/tmp/s".into(),
            channel: "nightly".to_owned(),
            key: A.to_owned(),
        }))
    );
    let no_key = words.to_vec();
    let mut bad_key = words.to_vec();
    bad_key.extend(["--key", "AB"]);
    let mut bad_channel = good.clone();
    bad_channel[6] = "stable";
    let mut no_state = good.clone();
    no_state.drain(3..5);
    let mut extra = good.clone();
    extra.push("--offline");
    for bad in [no_key, bad_key, bad_channel, no_state, extra] {
        assert!(parse(&args(&bad)).is_err(), "{bad:?}");
    }
}

/// A switch file of every-merge at `serial` that refuses the updates `refuse`.
fn refusing(pair: &Ed25519KeyPair, serial: u64, refuse: &[&str]) -> Fetched {
    let mut payload = file("every-merge", serial, json!({}));
    payload["refuse"] = json!(refuse);
    Fetched::Body(envelope(pair, &payload), None)
}

#[test]
fn refused_answers_from_the_file_last_taken_with_no_write() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    // No file taken yet: nothing is refused, and nothing is written.
    assert_eq!(refused(dir.path(), "every-merge", B), json!({"refused": false, "serial": 0}));
    assert!(!dir.path().join(STATE_FILE).exists());

    apply(&check(dir.path(), "every-merge"), Some(refusing(&pair, 4, &[B])), &keys(&pair), NOW)
        .unwrap();
    let state_before = std::fs::read(dir.path().join(STATE_FILE)).unwrap();
    let log_before = std::fs::read(dir.path().join(LOG_FILE)).unwrap();
    assert_eq!(refused(dir.path(), "every-merge", B), json!({"refused": true, "serial": 4}));
    assert_eq!(refused(dir.path(), "every-merge", A), json!({"refused": false, "serial": 4}));
    // Another channel's file says nothing about this one.
    assert_eq!(refused(dir.path(), "nightly", B), json!({"refused": false, "serial": 0}));
    assert_eq!(std::fs::read(dir.path().join(STATE_FILE)).unwrap(), state_before);
    assert_eq!(std::fs::read(dir.path().join(LOG_FILE)).unwrap(), log_before);

    // A later file that allows it again: no longer refused.
    apply(&check(dir.path(), "every-merge"), Some(refusing(&pair, 5, &[])), &keys(&pair), NOW)
        .unwrap();
    assert_eq!(refused(dir.path(), "every-merge", B), json!({"refused": false, "serial": 5}));
}

#[test]
fn refused_keeps_the_refusal_when_a_later_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    apply(&check(dir.path(), "every-merge"), Some(refusing(&pair, 4, &[B])), &keys(&pair), NOW)
        .unwrap();
    // A forged file that would allow it is not taken: B stays refused.
    let other = self::pair(9);
    apply(&check(dir.path(), "every-merge"), Some(refusing(&other, 9, &[])), &keys(&pair), NOW)
        .unwrap();
    assert_eq!(refused(dir.path(), "every-merge", B), json!({"refused": true, "serial": 4}));
}

#[test]
fn a_bad_base_is_refused() {
    assert_eq!(base_url(DEFAULT_BASE).unwrap(), DEFAULT_BASE);
    assert_eq!(base_url("https://example.com/web").unwrap(), "https://example.com/web/");
    assert_eq!(base_url("http://127.0.0.1:8080/").unwrap(), "http://127.0.0.1:8080/");
    assert_eq!(base_url("http://localhost:8080/x/").unwrap(), "http://localhost:8080/x/");
    assert_eq!(
        file_url(DEFAULT_BASE, "nightly"),
        "https://files.cmux.com/cmux-next-web/ota/pieces-nightly.json"
    );
    for bad in [
        "http://files.cmux.com/cmux-next-web/",
        "http://127.0.0.1.example.com/",
        "file:///tmp/x/",
        "ftp://localhost/",
        "https://user:secret@files.cmux.com/",
        "https://files.cmux.com/?token=1",
        "files.cmux.com/cmux-next-web/",
        "",
    ] {
        assert!(base_url(bad).is_err(), "{bad:?}");
        let words = [
            "app",
            "web-pieces",
            "check",
            "--state",
            "/tmp/s",
            "--channel",
            "nightly",
            "--base",
            bad,
        ];
        assert!(parse(&args(&words)).is_err(), "{bad:?}");
    }
}

#[test]
fn a_taken_file_writes_the_state_and_one_log_line() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join("made/by/check");
    let pair = pair(7);
    let reply =
        apply(&check(&dir, "every-merge"), Some(switched(&pair, 3)), &keys(&pair), NOW).unwrap();
    assert_eq!(reply["taken"], true, "{reply}");
    assert_eq!(reply["fetch"], json!({"result": "fetched"}));
    assert_eq!(reply["state"], dir.display().to_string());
    assert_agent_pane_switched(&reply);

    use std::os::unix::fs::PermissionsExt as _;
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    let state = state(&dir);
    assert_eq!(state["channel"], "every-merge");
    assert_eq!(state["floor"], 3);
    assert_eq!(state["last"], reply["switches"]);
    assert_eq!(state["etag"], "\"v1\"");
    assert_eq!(state["checked_at"], NOW);
    let lines = log_lines(&dir);
    assert_eq!(lines, vec![reply["log"].clone()]);
    assert_eq!(lines[0]["verdict"], "taken");
    // Nothing but the two files is left in the folder (no temp file).
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, [STATE_FILE, LOG_FILE]);
}

#[test]
fn the_same_file_again_adds_no_log_line() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let command = check(dir.path(), "every-merge");
    for round in 0..3 {
        let reply =
            apply(&command, Some(switched(&pair, 3)), &keys(&pair), NOW + round * 60).unwrap();
        assert_eq!(reply["taken"], true);
    }
    assert_eq!(log_lines(dir.path()).len(), 1);
    assert_eq!(state(dir.path())["checked_at"], NOW + 120);

    // A 304 plans from the kept switches; its verdict is new once, then quiet.
    for _ in 0..3 {
        let reply = apply(&command, Some(Fetched::NotModified), &keys(&pair), NOW + 300).unwrap();
        assert_eq!(reply["taken"], false);
        assert_eq!(reply["fetch"], json!({"result": "not_modified"}));
        assert_agent_pane_switched(&reply);
    }
    let lines = log_lines(dir.path());
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[1]["verdict"], "no_file");
    assert_eq!(state(dir.path())["etag"], "\"v1\"");

    // A newer file is a change: logged, and its serial is the next floor.
    let reply = apply(&command, Some(switched(&pair, 4)), &keys(&pair), NOW + 400).unwrap();
    assert_eq!(reply["taken"], true);
    assert_eq!(log_lines(dir.path()).len(), 3);
    assert_eq!(state(dir.path())["floor"], 4);
}

#[test]
fn a_file_signed_by_another_key_is_refused_and_logged() {
    let dir = tempfile::tempdir().unwrap();
    let (ours, theirs) = (pair(7), pair(9));
    let command = check(dir.path(), "every-merge");
    apply(&command, Some(switched(&ours, 3)), &keys(&ours), NOW).unwrap();
    let taken = state(dir.path());

    // Theirs switches nothing: taking it would put the agent pane back on the live update.
    let forged = envelope(&theirs, &file("every-merge", 9, json!({})));
    for round in 1..=2 {
        let fetched = Fetched::Body(forged.clone(), Some("\"forged\"".to_owned()));
        let reply = apply(&command, Some(fetched), &keys(&ours), NOW + round * 60).unwrap();
        assert_eq!(reply["taken"], false, "{reply}");
        assert_eq!(reply["refusal"]["code"], "unsigned", "{reply}");
        assert_eq!(reply["serial"], 3);
        assert_agent_pane_switched(&reply);
    }
    // The floor, the switches and the ETag of the file taken stay, so the refused file is
    // fetched and judged again; each check that refuses it is on the log.
    let after = state(dir.path());
    assert_eq!(after["floor"], taken["floor"]);
    assert_eq!(after["last"], taken["last"]);
    assert_eq!(after["etag"], "\"v1\"");
    let lines = log_lines(dir.path());
    assert_eq!(lines.len(), 3);
    assert_eq!(lines[1]["verdict"], "unsigned");
    assert_eq!(lines[2]["verdict"], "unsigned");

    // Not an envelope at all is refused the same way.
    let reply =
        apply(&command, Some(Fetched::Body("<html>".to_owned(), None)), &keys(&ours), NOW).unwrap();
    assert_eq!(reply["refusal"]["code"], "unsigned");
    assert_agent_pane_switched(&reply);
}

#[test]
fn a_stale_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let command = check(dir.path(), "every-merge");
    apply(&command, Some(switched(&pair, 5)), &keys(&pair), NOW).unwrap();
    let replayed = Fetched::Body(envelope(&pair, &file("every-merge", 4, json!({}))), None);
    let reply = apply(&command, Some(replayed), &keys(&pair), NOW + 60).unwrap();
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["refusal"]["code"], "stale", "{reply}");
    assert_agent_pane_switched(&reply);
    assert_eq!(state(dir.path())["floor"], 5);
    assert_eq!(log_lines(dir.path()).last().unwrap()["verdict"], "stale");
}

#[test]
fn no_file_and_a_failed_fetch_keep_the_last_switches() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let command = check(dir.path(), "every-merge");
    apply(&command, Some(switched(&pair, 3)), &keys(&pair), NOW).unwrap();
    let taken = state(dir.path());

    let reply = apply(&command, Some(Fetched::Missing), &keys(&pair), NOW + 60).unwrap();
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["refusal"], Value::Null);
    assert_eq!(reply["fetch"], json!({"result": "missing"}));
    assert_agent_pane_switched(&reply);
    let after = state(dir.path());
    assert_eq!(after["last"], taken["last"]);
    assert_eq!(after["floor"], 3);
    assert_eq!(after["checked_at"], NOW + 60);

    let failed = Fetched::Failed("HTTP 503".to_owned());
    let reply = apply(&command, Some(failed), &keys(&pair), NOW + 120).unwrap();
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["fetch"], json!({"result": "failed", "error": "HTTP 503"}));
    assert_agent_pane_switched(&reply);
    // No answer is no check: the state file is as the 404 left it.
    assert_eq!(state(dir.path()), after);
    // 404 and the failure say the same thing as each other: one line for both.
    let lines = log_lines(dir.path());
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[1]["verdict"], "no_file");
}

#[test]
fn a_first_check_with_no_file_serves_the_live_update() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let reply =
        apply(&check(dir.path(), "nightly"), Some(Fetched::Missing), &keys(&pair), NOW).unwrap();
    assert_eq!(reply["switches"], Value::Null);
    assert_eq!(reply["pieces"]["agent-pane"]["update"], A);
    assert_eq!(
        state(dir.path()),
        json!({"channel": "nightly", "floor": 0, "last": null,
                                         "etag": null, "checked_at": NOW})
    );
}

#[test]
fn offline_plans_from_the_state() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let mut command = check(dir.path(), "every-merge");
    apply(&command, Some(switched(&pair, 3)), &keys(&pair), NOW).unwrap();
    let before = std::fs::read(dir.path().join(STATE_FILE)).unwrap();

    command.offline = true;
    let reply = apply(&command, None, &keys(&pair), NOW + 60).unwrap();
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["fetch"], json!({"result": "offline"}));
    assert_eq!(reply["serial"], 3);
    assert_agent_pane_switched(&reply);
    assert_eq!(std::fs::read(dir.path().join(STATE_FILE)).unwrap(), before);

    // With no state at all, offline serves the live update and writes no state.
    let empty = tempfile::tempdir().unwrap();
    command.state = empty.path().to_path_buf();
    let reply = apply(&command, None, &keys(&pair), NOW).unwrap();
    assert_eq!(reply["pieces"]["agent-pane"]["update"], A);
    assert!(!empty.path().join(STATE_FILE).exists());
}

#[test]
fn another_channels_state_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    apply(&check(dir.path(), "every-merge"), Some(switched(&pair, 3)), &keys(&pair), NOW).unwrap();
    let every_merge = state(dir.path());

    // Nightly has no file: every-merge's switches do not apply, and its state stays.
    let nightly = check(dir.path(), "nightly");
    let reply = apply(&nightly, Some(Fetched::Missing), &keys(&pair), NOW + 60).unwrap();
    assert_eq!(reply["switches"], Value::Null, "{reply}");
    assert_eq!(reply["serial"], 0);
    assert_eq!(reply["pieces"]["agent-pane"]["serve"], "live");
    assert_eq!(reply["pieces"]["agent-pane"]["update"], A);
    assert_eq!(state(dir.path()), every_merge);

    // Nightly's own file is taken from serial 1, under every-merge's floor of 3.
    let file = Fetched::Body(envelope(&pair, &file("nightly", 1, json!({}))), None);
    let reply = apply(&nightly, Some(file), &keys(&pair), NOW + 120).unwrap();
    assert_eq!(reply["taken"], true, "{reply}");
    let state = state(dir.path());
    assert_eq!(state["channel"], "nightly");
    assert_eq!(state["floor"], 1);
    assert_eq!(state["etag"], Value::Null);
}

#[test]
fn an_unparsable_state_is_empty() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(STATE_FILE), b"{not json").unwrap();
    let pair = pair(7);
    let reply =
        apply(&check(dir.path(), "every-merge"), Some(switched(&pair, 1)), &keys(&pair), NOW)
            .unwrap();
    assert_eq!(reply["taken"], true);
    assert_eq!(state(dir.path())["floor"], 1);
}

/// A drill file is never a channel's own: its own name, and its payload names the drill channel.
#[test]
fn a_drill_channel_reads_its_own_file_only() {
    assert!(CHANNELS.contains(&"drill-every-merge") && CHANNELS.contains(&"drill-nightly"));
    assert_eq!(
        file_url(DEFAULT_BASE, "drill-nightly"),
        "https://files.cmux.com/cmux-next-web/ota/pieces-drill-nightly.json"
    );
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    // The real channel's file, served where the drill's is read, is refused.
    let reply =
        apply(&check(dir.path(), "drill-every-merge"), Some(switched(&pair, 3)), &keys(&pair), NOW)
            .unwrap();
    assert_eq!(reply["refusal"]["code"], "wrong_channel", "{reply}");
    assert_eq!(reply["taken"], false);
}

#[test]
fn a_drill_only_reports_a_refused_active_update() {
    let dir = tempfile::tempdir().unwrap();
    let pair = pair(7);
    let mut payload = file("drill-every-merge", 4, json!({}));
    payload["refuse"] = json!([A]);
    let drill = Fetched::Body(envelope(&pair, &payload), None);
    // The drill's file refuses the active update A: reported, never a roll back.
    let reply =
        apply(&check(dir.path(), "drill-every-merge"), Some(drill), &keys(&pair), NOW).unwrap();
    assert_eq!(reply["taken"], true, "{reply}");
    assert_eq!(reply["refused_active"], false, "{reply}");
    assert_eq!(reply["drill_refused_active"], true, "{reply}");
    // Nor does the drill block taking it.
    assert_eq!(
        refused(dir.path(), "drill-every-merge", A),
        json!({"refused": false, "serial": 4, "drill_refused": true})
    );
    assert_eq!(
        refused(dir.path(), "drill-every-merge", B),
        json!({"refused": false, "serial": 4, "drill_refused": false})
    );
    // The offline plan from the drill's state says the same.
    let mut offline = check(dir.path(), "drill-every-merge");
    offline.offline = true;
    let reply = apply(&offline, None, &keys(&pair), NOW).unwrap();
    assert_eq!(reply["refused_active"], false, "{reply}");
    assert_eq!(reply["drill_refused_active"], true, "{reply}");

    // The real channel's refusal still rolls back, with no drill field.
    let real = tempfile::tempdir().unwrap();
    let reply = apply(
        &check(real.path(), "every-merge"),
        Some(refusing(&pair, 4, &[A])),
        &keys(&pair),
        NOW,
    )
    .unwrap();
    assert_eq!(reply["refused_active"], true, "{reply}");
    assert!(reply.get("drill_refused_active").is_none(), "{reply}");
}

#[test]
fn an_unwritable_state_folder_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let blocked = dir.path().join("a-file");
    std::fs::write(&blocked, b"").unwrap();
    let pair = pair(7);
    let error =
        apply(&check(&blocked.join("state"), "every-merge"), None, &keys(&pair), NOW).unwrap_err();
    assert!(error.contains("a-file"), "{error}");
}

#[test]
fn the_log_keeps_its_newest_half_past_its_cap() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(LOG_FILE);
    let line = |serial: u64| json!({"verdict": "taken", "serial": serial, "switched": []});
    let size = format!("{}\n", line(100)).len() as u64;
    // Room for ten lines.
    for serial in 100..110 {
        log(&path, &line(serial), false, size * 10).unwrap();
    }
    assert_eq!(log_lines(dir.path()).len(), 10);
    log(&path, &line(110), false, size * 10).unwrap();
    let serials: Vec<u64> =
        log_lines(dir.path()).iter().map(|line| line["serial"].as_u64().unwrap()).collect();
    assert_eq!(serials, [106, 107, 108, 109, 110]);
    assert!(std::fs::metadata(&path).unwrap().len() <= size * 10);
    // It keeps growing from there and is cut again, never past the cap.
    for serial in 111..200 {
        log(&path, &line(serial), false, size * 10).unwrap();
        assert!(std::fs::metadata(&path).unwrap().len() <= size * 10);
    }
    assert_eq!(log_lines(dir.path()).last().unwrap()["serial"], 199);
    // The same line again is not written; a refusal is, every time.
    let before = log_lines(dir.path()).len();
    log(&path, &line(199), false, size * 100).unwrap();
    assert_eq!(log_lines(dir.path()).len(), before);
    log(&path, &line(199), true, size * 100).unwrap();
    assert_eq!(log_lines(dir.path()).len(), before + 1);
}

#[test]
fn status_prints_the_state_and_the_last_log_lines() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(status(dir.path()), json!({"state": {}, "log": []}));
    let pair = pair(7);
    let command = check(dir.path(), "every-merge");
    for serial in 1..=(STATUS_LINES as u64 + 5) {
        apply(&command, Some(switched(&pair, serial)), &keys(&pair), NOW + serial).unwrap();
    }
    let status = status(dir.path());
    assert_eq!(status["state"], state(dir.path()));
    let lines = status["log"].as_array().unwrap();
    assert_eq!(lines.len(), STATUS_LINES);
    assert_eq!(lines[0]["serial"], 6);
    assert_eq!(lines[STATUS_LINES - 1]["serial"], STATUS_LINES as u64 + 5);
}

/// Answers one request per entry of `answers` on 127.0.0.1 and gives back each request's head.
fn serve(answers: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}/web/", listener.local_addr().unwrap().port());
    let server = std::thread::spawn(move || {
        answers
            .iter()
            .map(|answer| {
                let (mut stream, _) = listener.accept().unwrap();
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") && stream.read(&mut byte).unwrap() == 1 {
                    head.push(byte[0]);
                }
                // The reader hangs up on a body past its cap.
                let _ = stream.write_all(answer.as_bytes());
                String::from_utf8_lossy(&head).to_ascii_lowercase()
            })
            .collect()
    });
    (base, server)
}

fn answer(status: &str, headers: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
        body.len()
    )
}

#[test]
fn fetch_reads_each_answer_of_the_server() {
    let huge = "x".repeat(cmux_web_pieces::MAX_BYTES + 1);
    let (base, server) = serve(vec![
        answer("200 OK", "ETag: \"v7\"\r\n", "{\"schema\":1}"),
        answer("304 Not Modified", "", ""),
        answer("404 Not Found", "", "no such key"),
        answer("503 Service Unavailable", "", "later"),
        answer("302 Found", "Location: https://example.com/elsewhere\r\n", ""),
        answer("200 OK", "", &huge),
    ]);
    let url = file_url(&base_url(&base).unwrap(), "every-merge");
    assert!(url.ends_with("/web/ota/pieces-every-merge.json"));
    assert_eq!(
        fetch(&url, None),
        Fetched::Body("{\"schema\":1}".to_owned(), Some("\"v7\"".to_owned()))
    );
    assert_eq!(fetch(&url, Some("\"v7\"")), Fetched::NotModified);
    assert_eq!(fetch(&url, None), Fetched::Missing);
    assert!(matches!(fetch(&url, None), Fetched::Failed(why) if why.contains("HTTP 503")));
    // A redirect is an answer the check does not follow.
    assert!(matches!(fetch(&url, None), Fetched::Failed(why) if why.contains("HTTP 302")));
    assert!(matches!(fetch(&url, None), Fetched::Failed(why) if why.contains("larger than")));
    let heads = server.join().unwrap();
    assert!(heads[0].starts_with("get /web/ota/pieces-every-merge.json "), "{}", heads[0]);
    assert!(!heads[0].contains("if-none-match"), "{}", heads[0]);
    assert!(heads[1].contains("if-none-match: \"v7\""), "{}", heads[1]);

    // Nothing listens: a failure, not a panic.
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = closed.local_addr().unwrap().port();
    drop(closed);
    let url = file_url(&format!("http://127.0.0.1:{port}/"), "nightly");
    assert!(matches!(fetch(&url, None), Fetched::Failed(_)));
}

/// The base the person names with `--base` passes the egress gate in enforce mode; a host
/// nobody named is still refused.
#[test]
fn the_named_base_passes_the_gate() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let host = "base-web-pieces-test.org";
    assert!(cmux_egress::check(host, "test").is_err());
    let base = format!("https://{host}/web/");
    let words = [
        "app",
        "web-pieces",
        "check",
        "--state",
        "/tmp/s",
        "--channel",
        "nightly",
        "--base",
        &base,
    ];
    assert!(matches!(parse(&args(&words)), Ok(Some(_))));
    assert!(cmux_egress::check(host, "test").is_ok());
    assert!(cmux_egress::check("unrelated-base-web-pieces-test.org", "test").is_err());
}
