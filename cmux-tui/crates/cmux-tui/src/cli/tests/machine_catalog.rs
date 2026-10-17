use super::*;

#[test]
fn cmux_next_machine_catalog_agent_surface_cli_exposes_only_catalog_reads() {
    let machine = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    for (args, operation) in [
        (vec!["--json", "machine", "list"], "machine.list"),
        (vec!["--json", "machine", machine, "show"], "machine.get"),
    ] {
        let parsed = parse(&strings(&args), Surface::Cmux).expect("curated machine catalog read");
        let ParsedCommand::Command { global, plan: CommandPlan::Protocol(plan) } = parsed else {
            panic!("not a protocol read")
        };
        assert_eq!(global.output, OutputMode::Json);
        assert_eq!(plan.operation.name().unwrap(), operation);
        assert!(plan.idempotency_key.is_none());
    }
    assert!(parse(&strings(&["help", "machine"]), Surface::Cmux).is_ok());
    for args in [
        vec!["machine", machine, "session", "list"],
        vec!["machine", machine, "session", "current", "open"],
    ] {
        assert!(parse(&strings(&args), Surface::Cmux).is_err(), "{args:?}");
        assert!(parse(&strings(&args), Surface::CmuxTui).is_ok(), "legacy full grammar {args:?}");
    }
}
