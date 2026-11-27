use super::*;

const KINDS: [&str; 9] =
    ["read", "edit", "delete", "move", "search", "execute", "other", "fetch", "think"];

fn boot(stage: Option<Cloud>) -> Boot<'static> {
    Boot { stage, machine: Some("vm-1") }
}

fn routed(stage: Option<Cloud>, kind: &str, held_ms: u64) -> Route {
    route(&boot(stage), &Call { kind, held_ms })
}

#[test]
fn each_stage_routes_each_kind_as_the_table_says() {
    let on = || Route::OnMachine { machine: "vm-1".into() };
    for kind in KINDS {
        let anywhere = matches!(kind, "fetch" | "think");
        let side = |route: Route| if anywhere { here(RUNS_ANYWHERE) } else { route };
        assert_eq!(routed(None, kind, 0), here(NOT_HYBRID), "{kind}");
        assert_eq!(routed(Some(Cloud::None), kind, 0), here(NOT_HYBRID), "{kind}");
        assert_eq!(routed(Some(Cloud::Booting), kind, 0), side(Route::Hold), "{kind}");
        assert_eq!(
            routed(Some(Cloud::Booting), kind, HOLD_DEADLINE_MS - 1),
            side(Route::Hold),
            "{kind}"
        );
        assert_eq!(
            routed(Some(Cloud::Booting), kind, HOLD_DEADLINE_MS),
            side(here(MACHINE_NOT_READY)),
            "{kind}"
        );
        for stage in [Cloud::Ready, Cloud::Moving] {
            let want = if kind == "execute" { on() } else { here(NO_FILE_ROUTE) };
            assert_eq!(routed(Some(stage), kind, 0), side(want), "{kind} {stage:?}");
        }
        assert_eq!(routed(Some(Cloud::Live), kind, 0), side(here(CHAT_ON_MACHINE)), "{kind}");
        assert_eq!(routed(Some(Cloud::Failed), kind, 0), side(here(MACHINE_FAILED)), "{kind}");
    }
}

#[test]
fn an_execute_with_no_machine_id_runs_here_and_says_so() {
    for machine in [None, Some("")] {
        let boot = Boot { stage: Some(Cloud::Ready), machine };
        assert_eq!(route(&boot, &Call { kind: "execute", held_ms: 0 }), here(NO_MACHINE_ID));
    }
}

/// One call, one answer: a held call is asked about again only when the stage changes, and
/// the first answer that is not Hold is its only one. Replays a boot and counts answers.
#[test]
fn a_held_call_gets_one_answer_never_two_or_none() {
    let stages = [Cloud::Booting, Cloud::Booting, Cloud::Ready, Cloud::Moving, Cloud::Live];
    let mut answers = Vec::new();
    for (at, stage) in stages.iter().enumerate() {
        let route = routed(Some(*stage), "execute", at as u64 * 1000);
        if route != Route::Hold {
            answers.push(route);
            break;
        }
    }
    assert_eq!(answers, [Route::OnMachine { machine: "vm-1".into() }]);
    // Past the deadline with the machine still booting: one answer, here, with the reason.
    let late = routed(Some(Cloud::Booting), "execute", HOLD_DEADLINE_MS + 1);
    assert_eq!(late, here(MACHINE_NOT_READY));
}

#[test]
fn stage_tags_round_trip() {
    for cloud in
        [Cloud::None, Cloud::Booting, Cloud::Ready, Cloud::Moving, Cloud::Live, Cloud::Failed]
    {
        assert_eq!(stage_of(Some(&stage_tag(cloud))), Some(cloud));
    }
    assert_eq!(stage_tag(Cloud::Booting), "booting");
    assert_eq!(stage_of(Some("sideways")), None);
    assert_eq!(stage_of(None), None);
}

#[test]
fn the_machine_command_quotes_what_it_runs() {
    assert_eq!(
        on_machine_command("vm-1", "echo 'hi' && ls"),
        r#"cmux vm exec 'vm-1' -- bash -lc 'echo '\''hi'\'' && ls'"#
    );
}

#[test]
fn readiness_is_monotonic_and_100_only_when_ready() {
    assert_eq!(readiness(Cloud::None, &[]), None);
    assert_eq!(readiness(Cloud::Failed, &["running"]), None);
    let mut reached = Vec::new();
    let mut last = readiness(Cloud::Booting, &reached).unwrap();
    assert_eq!(last, BOOTING);
    for (name, _) in MARKS {
        reached.push(*name);
        let now = readiness(Cloud::Booting, &reached).unwrap();
        assert!(now > last && now < 100, "{name}: {last} -> {now}");
        last = now;
    }
    // A mark reached out of order never lowers it.
    assert_eq!(readiness(Cloud::Booting, &["secrets", "created"]), Some(90));
    for cloud in [Cloud::Ready, Cloud::Moving, Cloud::Live] {
        assert_eq!(readiness(cloud, &[]), Some(100));
    }
}
