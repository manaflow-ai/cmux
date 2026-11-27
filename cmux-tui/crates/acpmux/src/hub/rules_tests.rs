mod caller_identity {
    use super::super::*;
    use serde_json::json;

    /// A Claude Code subagent's Bash title starts with the hook's mark line
    /// (`bg_hook::subagent_mark`); a rule still matches the command it was written as.
    #[test]
    fn a_rule_matches_a_subagents_marked_command_as_written() {
        let rules = json!({"autoDeny": ["rm", "git push"], "autoApprove": ["cargo build"]});
        let mark = "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\n";
        let request = |title: &str| json!({"toolCall": {"kind": "execute", "title": title}});
        for (command, want) in [
            ("rm -rf build", Some(RuleDecision::Deny)),
            ("git push origin HEAD", Some(RuleDecision::Deny)),
            ("cargo build --release", Some(RuleDecision::Approve)),
            ("./scripts/tell beta hi", None),
        ] {
            assert_eq!(decide(&rules, &request(command)), want, "{command}");
            let marked = format!("{mark}{command}");
            assert_eq!(decide(&rules, &request(&marked)), want, "marked {command}");
        }
        // Only the hook's exact mark is passed over: another first line is the command.
        let other = request("export X=1\nrm -rf build");
        assert_eq!(decide(&rules, &other), None);
    }
}
