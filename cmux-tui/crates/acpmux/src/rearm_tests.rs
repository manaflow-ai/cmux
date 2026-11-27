use super::*;

const T0: u64 = 1_000_000;

#[test]
fn rearm_parses_the_waits_and_writes_them_back_with_the_time_left() {
    let w = parse("acpmux pr-wait 58117 --repo manaflow-ai/cmux --sha e0ef135d --timeout 3600", T0)
        .expect("a pr-wait");
    assert_eq!(w.form, Form::AcpmuxPrWait);
    assert_eq!(w.form.kind(), "pr_wait");
    assert_eq!(
        (w.repo.as_str(), w.number, w.sha.as_deref()),
        ("manaflow-ai/cmux", 58117, Some("e0ef135d"))
    );
    assert_eq!(w.deadline_ms, T0 + 3_600_000);
    // 10 minutes in, 50 minutes left.
    assert_eq!(
        w.command(T0 + 600_000).unwrap(),
        "acpmux pr-wait 58117 --repo manaflow-ai/cmux --sha e0ef135d --timeout 3000"
    );
    assert_eq!(w.command(T0 + 3_600_000), None, "past its deadline nothing is armed");

    let ci = parse("acpmux ci wait run 123456789 --repo octo/app --timeout=1800", T0).unwrap();
    assert_eq!((ci.form.kind(), ci.number), ("ci_wait", 123456789));
    assert_eq!(
        ci.command(T0 + 1).unwrap(),
        "acpmux ci wait run 123456789 --repo octo/app --timeout 1800"
    );

    let g = parse(
        "glaeda-gh wait pr manaflow-ai/cmuxterm-hq#28390 --until done --sha abcdef1 --timeout 5400",
        T0,
    )
    .unwrap();
    assert_eq!((g.form, g.form.kind()), (Form::GlaedaPr, "pr_wait"));
    assert_eq!(
        g.command(T0).unwrap(),
        "glaeda-gh wait pr manaflow-ai/cmuxterm-hq#28390 --until done --sha abcdef1 --timeout 5400"
    );
    let run = parse("glaeda-gh wait run o/r/7 --timeout 60", T0).unwrap();
    assert_eq!((run.form.kind(), run.repo.as_str(), run.number), ("ci_wait", "o/r", 7));
}

#[test]
fn rearm_refuses_what_is_not_a_wait_with_a_target_and_deadline() {
    for c in [
        "sleep 600",
        "cargo test -p acpmux rebalance",
        "cmux-ci test -- cargo test",
        // No deadline.
        "acpmux pr-wait 1 --repo o/r",
        "glaeda-gh wait pr o/r#1 --until done",
        // No named repo: the default reads this folder's origin.
        "acpmux pr-wait 1 --timeout 60",
        "acpmux ci wait pr 1 --timeout 60",
        // A shell around it.
        "sleep 5; acpmux pr-wait 1 --repo o/r --timeout 60",
        "acpmux pr-wait 1 --repo o/r --timeout 60 | tail -3",
        "acpmux pr-wait 1 --repo o/r --timeout 60 > out",
        "acpmux pr-wait 1 --repo o/r --timeout $T",
        "acpmux pr-wait 1 --repo o/r --timeout 60\nrm x",
        "cd /tmp && acpmux pr-wait 1 --repo o/r --timeout 60",
        "timeout 70 acpmux pr-wait 1 --repo o/r --timeout 60",
        // Flags it does not know, twice, or bad values.
        "acpmux pr-wait 1 --repo o/r --timeout 60 --json",
        "acpmux pr-wait 1 --repo o/r --timeout 60 --timeout 90",
        "acpmux pr-wait 1 --repo o/r --until done --timeout 60",
        "acpmux pr-wait 1 --repo ../r --timeout 60",
        "acpmux pr-wait 1 --repo o/r --sha zz --timeout 60",
        "acpmux pr-wait 0 --repo o/r --timeout 60",
        "acpmux pr-wait https://github.com/o/r/pull/1 --repo o/r --timeout 60",
        "acpmux ci wait run 5 --repo o/r --sha abcd --timeout 60",
        "/usr/bin/acpmux pr-wait 1 --repo o/r --timeout 60",
    ] {
        assert_eq!(parse(c, T0), None, "{c:?} is not a re-armable wait");
    }
}

#[test]
fn rearm_wire_form_round_trips_and_is_checked_as_strictly() {
    let w = parse("acpmux pr-wait 9 --repo o/r --until merged --sha ABCDEF0 --timeout 120", T0)
        .unwrap();
    assert_eq!(w.sha.as_deref(), Some("abcdef0"));
    let back = Wait::from_json(&w.to_json()).unwrap();
    assert_eq!(back, w);
    for (k, v) in [
        ("form", json!("sleep")),
        ("repo", json!("o/r; rm -rf ~")),
        ("number", json!(0)),
        ("sha", json!("$(id)")),
        ("until", json!("done now")),
        ("deadlineMs", json!(null)),
    ] {
        let mut bad = w.to_json();
        bad[k] = v.clone();
        assert!(Wait::from_json(&bad).is_err(), "{k} = {v} is refused");
    }
    // A run wait takes no sha.
    let mut run = parse("acpmux ci wait run 5 --repo o/r --timeout 60", T0).unwrap().to_json();
    run["sha"] = json!("abcd");
    assert!(Wait::from_json(&run).is_err());
}
