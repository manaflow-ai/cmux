use super::*;
use crate::place_mode::PlaceMode;
use serde_json::json;

fn here() -> &'static str {
    "mac"
}

#[test]
fn a_place_parses_each_mode_and_refuses_junk() {
    assert_eq!(parse(&json!({"mode": "auto"})).unwrap(), PlaceMode::Auto);
    assert_eq!(parse(&json!({"mode": "cloud"})).unwrap(), PlaceMode::Cloud);
    assert_eq!(
        parse(&json!({"mode": "machine", "machine": "mini"})).unwrap(),
        PlaceMode::Machine { id: "mini".into() }
    );
    assert!(parse(&json!({"mode": "machine", "machine": " "})).is_err());
    assert!(parse(&json!({"mode": "moon"})).is_err());
    let back = serde_json::to_value(PlaceMode::Machine { id: "mini".into() }).unwrap();
    assert_eq!(back, json!({"mode": "machine", "machine": "mini"}));
}

fn proc(pid: u32, ppid: u32, command: &str) -> Proc {
    Proc { pid, ppid, command: command.into() }
}

#[test]
fn the_process_tree_is_what_hangs_under_the_agent() {
    let procs = [
        proc(1, 0, "init"),
        proc(10, 1, "claude"),
        proc(11, 10, "node"),
        proc(12, 11, "x"),
        proc(99, 1, "o"),
    ];
    assert_eq!(descendants(&procs, 10), BTreeSet::from([11, 12]));
    assert_eq!(
        ssh_tunnel("/usr/bin/ssh -N -L 5432:db:5432 box").as_deref(),
        Some("-L 5432:db:5432")
    );
    assert_eq!(ssh_tunnel("ssh box"), None);
    assert_eq!(ssh_tunnel("scp -L x y"), None);
}

#[test]
fn what_stays_behind_is_named_by_kind() {
    let procs = [
        proc(10, 1, "claude"),
        proc(11, 10, "node server.js"),
        proc(12, 10, "ssh -R9000:localhost:9000 box"),
        proc(99, 1, "x"),
    ];
    let listeners = [Listener { pid: 11, port: 3000 }, Listener { pid: 99, port: 8080 }];
    let cwd = Path::new("/repo");
    let left = left_behind(&Inputs {
        cwd,
        in_repo: true,
        root: Some(10),
        procs: &procs,
        listeners: &listeners,
        outside: &[],
    });
    let kinds: Vec<LeftKind> = left.iter().map(|l| l.kind).collect();
    assert_eq!(kinds, [LeftKind::LocalhostServer, LeftKind::SshTunnel], "{left:?}");
    assert!(left[0].detail.contains("3000"));
    assert!(left[1].detail.contains("-R 9000:localhost:9000"));
    // Nothing known, nothing reported: no agent process and a repo means an empty list.
    assert!(
        left_behind(&Inputs {
            cwd,
            in_repo: true,
            root: None,
            procs: &procs,
            listeners: &listeners,
            outside: &[]
        })
        .is_empty()
    );
    let outside = left_behind(&Inputs {
        cwd: Path::new("/tmp/x"),
        in_repo: false,
        root: None,
        procs: &[],
        listeners: &[],
        outside: &[],
    });
    assert_eq!(outside[0].kind, LeftKind::OutsideRepo);
}

fn one_left() -> Vec<LeftBehind> {
    vec![LeftBehind { kind: LeftKind::LocalhostServer, detail: "x".into() }]
}

#[test]
fn a_pick_lands_in_one_state() {
    let mini = PlaceMode::Machine { id: "mini".into() };
    let to_mini = Some(Target::Machine("mini".into()));
    // Auto and the machine it is on only store the pin.
    let p = plan(&PlaceMode::Auto, here(), false, false, &[], false);
    assert_eq!((p.state, p.store, p.move_to), (State::Pinned, true, None));
    let p = plan(&PlaceMode::Machine { id: "mac".into() }, here(), false, true, &one_left(), false);
    assert_eq!((p.state, p.move_to), (State::Pinned, None));
    // Between turns: moving. Mid-turn: after the turn.
    let p = plan(&mini, here(), false, false, &[], false);
    assert_eq!((p.state, p.move_to), (State::Moving, to_mini));
    let p = plan(&mini, here(), false, true, &[], false);
    assert_eq!(p.state, State::AfterTurn);
    // Something stays behind: asked first, nothing moves; confirmed, it moves.
    let p = plan(&mini, here(), false, false, &one_left(), false);
    assert_eq!((p.state, p.move_to), (State::NeedsConfirm, None));
    assert_eq!(plan(&mini, here(), false, false, &one_left(), true).state, State::Moving);
    assert_eq!(plan(&mini, here(), false, true, &one_left(), true).state, State::AfterTurn);
}

/// Cloud only moves the chat to a fresh Cloud machine, as a machine pick moves it: now between
/// turns, after the turn mid-turn, asked first when something stays. On a Cloud machine it
/// already holds.
#[test]
fn cloud_only_moves_to_a_fresh_machine() {
    let cloud = PlaceMode::Cloud;
    assert!(needs_left(&cloud, here(), false));
    assert!(!needs_left(&cloud, here(), true));
    assert!(!needs_left(&PlaceMode::Auto, here(), false));
    let p = plan(&cloud, here(), false, false, &[], false);
    assert_eq!((p.state, p.store, p.move_to), (State::Moving, false, Some(Target::NewCloud)));
    assert_eq!(p.reason, None);
    assert_eq!(plan(&cloud, here(), false, true, &[], false).state, State::AfterTurn);
    let p = plan(&cloud, here(), false, false, &one_left(), false);
    assert_eq!((p.state, p.move_to), (State::NeedsConfirm, None));
    assert_eq!(
        plan(&cloud, here(), false, false, &one_left(), true).move_to,
        Some(Target::NewCloud)
    );
    let p = plan(&cloud, here(), true, false, &[], false);
    assert_eq!((p.state, p.store, p.move_to), (State::Pinned, true, None));
    assert_eq!(Target::NewCloud.label(), "Cloud");
    assert_eq!(Target::Machine("mini".into()).label(), "mini");
}

/// The `cmux` steps of a Cloud move are the hybrid driver's own words.
#[test]
fn a_cloud_move_runs_the_drivers_cmux_steps() {
    assert_eq!(cloud_new_words(), ["vm", "new", "--wait", "--json"]);
    assert_eq!(cloud_move_words("s1", "m-9"), ["move", "s1", "--to", "vm:m-9", "--json"]);
    assert_eq!(
        cloud_pause_words("m-9"),
        ["cloud", "pause-machine", "--target", "machine:m-9", "--json"]
    );
}

/// A step's answer: its `result` (or the object), its error's message, else its last line; the
/// fresh machine is the answer's `machine_id`.
#[test]
fn a_cmux_step_answers_its_result_or_why() {
    let ok = step_answer(true, "starting\n{\"ok\":true,\"result\":{\"machine_id\":\"m-1\"}}\n", "");
    assert_eq!(machine_of(&ok.unwrap()).unwrap(), "m-1");
    let flat = step_answer(true, "{\"machine_id\":\"m-2\"}", "").unwrap();
    assert_eq!(machine_of(&flat).unwrap(), "m-2");
    assert!(machine_of(&json!({"machine_id": " "})).is_err());
    let err =
        step_answer(false, "", "{\"error\":{\"code\":\"auth\",\"message\":\"sign in to cmux\"}}");
    assert_eq!(err.unwrap_err(), "sign in to cmux");
    let err = step_answer(false, "", "{\"code\":\"x\",\"message\":\"no room\"}");
    assert_eq!(err.unwrap_err(), "no room");
    assert_eq!(step_answer(false, "", "boom\nlast words\n").unwrap_err(), "last words");
    assert_eq!(step_answer(true, "not json", "").unwrap_err(), "not json");
    assert!(step_answer(false, "", "").is_err());
}

#[test]
fn a_move_line_names_where_and_why() {
    assert_eq!(move_line("Cloud", "Mac went to sleep"), "Moved to Cloud · Mac went to sleep");
}
