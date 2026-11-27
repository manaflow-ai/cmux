use super::*;

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn a_sample_is_one_json_line_with_the_rfd_fields() {
    let sample = Sample {
        op: "health".into(),
        route: "carrier".into(),
        from: "cosmic-gray".into(),
        to: "fs-agent-lane-2".into(),
        ms: 1804.3,
        ok: false,
        reason: Some("service.off".into()),
        reference: "abc123".into(),
    };
    let line = sample.line();
    assert!(!line.contains('\n'));
    let value: Value = serde_json::from_str(&line).unwrap();
    let mut keys: Vec<_> = value.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(keys, ["from", "ms", "ok", "op", "reason", "ref", "route", "to"]);
    assert_eq!(value["ms"], 1804.3);
    assert_eq!(value["ok"], false);
    assert_eq!(value["reason"], "service.off");
    assert_eq!(value["ref"], "abc123");
    let ok = Sample { ok: true, reason: None, ..sample };
    assert!(serde_json::from_str::<Value>(&ok.line()).unwrap()["reason"].is_null());
}

#[test]
fn bench_arguments_default_to_fifty_samples_of_every_op_and_route() {
    let plan = parse(&words(&["--bench", "lane-2", "lane-3"])).unwrap();
    assert_eq!(plan.machines, ["lane-2", "lane-3"]);
    assert_eq!(plan.n, 50);
    assert_eq!(plan.ops, ["connect", "health", "dial"]);
    assert_eq!(plan.routes, ["carrier", "freestyle-proxy", "tailnet"]);
}

#[test]
fn bench_arguments_choose_n_ops_routes_and_targets() {
    let plan = parse(&words(&[
        "--bench",
        "lane-2",
        "--bench-n",
        "7",
        "--bench-ops",
        "dial",
        "--bench-routes",
        "carrier,tailnet",
        "--bench-target",
        "tailnet:lane-2=cmux@100.64.0.2:2222",
        "--bench-out",
        "/tmp/x",
    ]))
    .unwrap();
    assert_eq!(plan.n, 7);
    assert_eq!(plan.ops, ["dial"]);
    assert_eq!(plan.routes, ["carrier", "tailnet"]);
    assert_eq!(plan.targets, [("tailnet".into(), "lane-2".into(), "cmux@100.64.0.2:2222".into())]);
    assert_eq!(plan.out, Some(PathBuf::from("/tmp/x")));
}

#[test]
fn bench_arguments_refuse_nonsense() {
    assert!(parse(&words(&["--bench"])).is_err());
    assert!(parse(&words(&["--bench", "m", "--bench-n", "0"])).is_err());
    assert!(parse(&words(&["--bench", "m", "--bench-ops", "nap"])).is_err());
    assert!(parse(&words(&["--bench", "m", "--bench-routes", "pigeon"])).is_err());
    assert!(parse(&words(&["--bench", "m", "--bench-target", "tailnet=x"])).is_err());
    assert!(parse(&words(&["--bench", "m", "--bogus"])).is_err());
}

#[test]
fn destinations_split_into_host_and_port() {
    assert_eq!(host_port("cmux@100.64.0.2:2222"), ("100.64.0.2".into(), 2222));
    assert_eq!(host_port("vm@vm-ssh.freestyle.sh"), ("vm-ssh.freestyle.sh".into(), 22));
    assert_eq!(host_port("box"), ("box".into(), 22));
}

#[test]
fn the_pipe_request_and_replies_match_carrier_pipe() {
    let request: Value = serde_json::from_str(pipe_request("lane-2", 22).trim()).unwrap();
    assert_eq!(request["method"], "_acpmux/remote.pipe");
    assert_eq!(request["params"], json!({"machine": "lane-2", "port": 22}));
    assert_eq!(pipe_reply(r#"{"jsonrpc":"2.0","id":1,"result":{}}"#), Ok(()));
    assert_eq!(
        pipe_reply(r#"{"error":{"message":"off","data":{"reason":"service.off"}}}"#),
        Err("service.off".to_owned())
    );
    assert_eq!(pipe_reply(r#"{"error":{"message":"x"}}"#), Err("unknown".to_owned()));
    assert_eq!(pipe_reply("garbage"), Err("acpmux.bad_answer".to_owned()));
}

#[test]
fn percentiles_use_the_nearest_rank() {
    let values = [5.0, 1.0, 3.0, 2.0, 4.0];
    assert_eq!(percentile(&values, 50.0), Some(3.0));
    assert_eq!(percentile(&values, 95.0), Some(5.0));
    assert_eq!(percentile(&[], 50.0), None);
}

#[test]
fn the_bench_flags_are_recognised_in_cmux_ssh_arguments() {
    assert!(wants(&words(&["--bench", "m"])));
    assert!(!wants(&words(&["m"])));
    assert!(wants_pipe(&words(&["--bench-pipe", "m", "22"])));
}
