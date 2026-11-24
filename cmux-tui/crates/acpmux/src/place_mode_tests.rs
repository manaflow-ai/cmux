use super::*;
use serde_json::json;

fn here() -> &'static str {
    "mac"
}

#[test]
fn a_place_parses_each_mode_and_refuses_junk() {
    assert_eq!(PlaceMode::parse(&json!({"mode": "auto"})).unwrap(), PlaceMode::Auto);
    assert_eq!(
        PlaceMode::parse(&json!({"mode": "cloud", "size": "m"})).unwrap(),
        PlaceMode::Cloud { size: Some(Size::M) }
    );
    assert_eq!(
        PlaceMode::parse(&json!({"mode": "cloud"})).unwrap(),
        PlaceMode::Cloud { size: None }
    );
    assert_eq!(
        PlaceMode::parse(&json!({"mode": "machine", "machine": "mini"})).unwrap(),
        PlaceMode::Machine { id: "mini".into() }
    );
    assert!(PlaceMode::parse(&json!({"mode": "machine", "machine": " "})).is_err());
    assert!(PlaceMode::parse(&json!({"mode": "cloud", "size": "xl"})).is_err());
    assert!(PlaceMode::parse(&json!({"mode": "moon"})).is_err());
    let back = serde_json::to_value(PlaceMode::Machine { id: "mini".into() }).unwrap();
    assert_eq!(back, json!({"mode": "machine", "machine": "mini"}));
}

#[test]
fn a_chat_with_no_stored_mode_is_pinned_to_the_machine_it_is_on() {
    assert_eq!(PlaceMode::effective(None, here()), PlaceMode::Machine { id: "mac".into() });
    assert_eq!(PlaceMode::effective(Some(PlaceMode::Auto), here()), PlaceMode::Auto);
}

#[test]
fn the_process_tree_and_listeners_are_read_from_ps_and_lsof() {
    let procs = parse_ps(
        "  1     0 /sbin/init\n 10     1 claude\n 11    10 node server.js\n 12    10 \
         /usr/bin/ssh -N -L 5432:db:5432 box\n 99     1 other\n",
    );
    assert_eq!(procs.len(), 5);
    assert_eq!(descendants(&procs, 10), BTreeSet::from([11, 12]));
    let listeners = parse_lsof("p11\nn127.0.0.1:3000\nn[::1]:3000\np99\nn*:8080\n");
    assert_eq!(
        listeners,
        vec![
            Listener { pid: 11, port: 3000 },
            Listener { pid: 11, port: 3000 },
            Listener { pid: 99, port: 8080 }
        ]
    );
}

#[test]
fn what_stays_behind_is_named_by_kind() {
    let procs = parse_ps(
        "10 1 claude\n11 10 node server.js\n12 10 ssh -R9000:localhost:9000 box\n99 1 x\n",
    );
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
    // Auto and the machine it is on only store the pin.
    let p = plan(&PlaceMode::Auto, here(), false, &[], false);
    assert_eq!((p.state, p.store, p.move_to), (State::Pinned, true, None));
    let p = plan(&PlaceMode::Machine { id: "mac".into() }, here(), true, &one_left(), false);
    assert_eq!((p.state, p.move_to), (State::Pinned, None));
    // Between turns: moving. Mid-turn: after the turn.
    let p = plan(&mini, here(), false, &[], false);
    assert_eq!((p.state, p.move_to.as_deref()), (State::Moving, Some("mini")));
    let p = plan(&mini, here(), true, &[], false);
    assert_eq!(p.state, State::AfterTurn);
    // Something stays behind: asked first, nothing moves; confirmed, it moves.
    let p = plan(&mini, here(), false, &one_left(), false);
    assert_eq!((p.state, p.move_to), (State::NeedsConfirm, None));
    assert_eq!(plan(&mini, here(), false, &one_left(), true).state, State::Moving);
    assert_eq!(plan(&mini, here(), true, &one_left(), true).state, State::AfterTurn);
    // Cloud says why it is refused and stores nothing.
    let p = plan(&PlaceMode::Cloud { size: None }, here(), false, &[], true);
    assert_eq!((p.state, p.store), (State::Refused, false));
    assert!(p.reason.unwrap().contains("app"));
}

#[test]
fn a_move_line_names_where_and_why() {
    assert_eq!(move_line("Cloud", "Mac went to sleep"), "Moved to Cloud · Mac went to sleep");
}
