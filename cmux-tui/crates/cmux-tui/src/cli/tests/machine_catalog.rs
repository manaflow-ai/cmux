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

#[test]
fn cmux_next_machine_catalog_agent_surface_cli_routes_session_without_metadata_fields() {
    for args in [vec!["machine", "list"], vec!["machine", "current", "show"]] {
        let mut words = vec!["--session", "catalog-owner"];
        words.extend(args);
        let ParsedCommand::Command { global, plan: CommandPlan::Protocol(mut plan) } =
            parse(&strings(&words), Surface::Cmux).unwrap()
        else {
            panic!("catalog request")
        };
        resolve::apply_global_route(&global, &mut plan).unwrap();
        assert!(plan.params.get("session").is_none());
        if plan.operation.name().unwrap() == "machine.list" {
            assert_eq!(plan.params, serde_json::json!({}));
        } else {
            assert_eq!(plan.params, serde_json::json!({"machine":"current"}));
        }
    }
    assert!(
        parse(&strings(&["machine", "name:session", "show"]), Surface::Cmux).is_ok(),
        "a machine name is not session plumbing"
    );
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let messages = &crate::localization::catalog_for_locale(locale).local_server;
        assert!(
            messages.cmux_root_help.lines().any(|line| line.trim_start().starts_with("machine "))
        );
    }
    assert!(!MACHINE_CATALOG_HELP.contains("session"));
}

#[test]
fn cmux_next_machine_catalog_agent_surface_cli_requires_explicit_catalog_opt_in() {
    for args in
        [vec!["machine", "list", "--catalog"], vec!["machine", "current", "show", "--catalog"]]
    {
        let ParsedCommand::Command { plan: CommandPlan::Protocol(plan), .. } =
            parse(&strings(&args), Surface::Cmux).unwrap()
        else {
            panic!("catalog request")
        };
        assert_eq!(plan.params["catalog"], true);
        assert!(plan.params.get("session").is_none());
    }
    for args in [
        vec!["workspace", "list", "--catalog"],
        vec!["machine", "current", "session", "list", "--catalog"],
    ] {
        assert!(parse(&strings(&args), Surface::CmuxTui).is_err(), "{args:?}");
    }
}
