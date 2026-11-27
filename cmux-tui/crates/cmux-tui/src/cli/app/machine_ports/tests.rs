use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn parses_machine_name_ports_and_leaves_other_machine_commands() {
    let ports = |machine: &str| Some(AppCommand::MachinePorts(Command { machine: machine.into() }));
    assert_eq!(parse(&args(&["machine", "studio", "ports"])).map(Result::unwrap), ports("studio"));
    assert_eq!(
        parse(&args(&["machine", "studio", "ports", "--json"])).map(Result::unwrap),
        ports("studio")
    );
    assert!(parse(&args(&["machine", "studio", "ports", "extra"])).unwrap().is_err());
    assert!(parse(&args(&["machine", "--x", "ports"])).unwrap().is_err());
    // The mux resource parser keeps the rest of `machine`.
    for words in [&["machine", "list"][..], &["machine", "studio", "show"], &["machine", "ports"]] {
        assert!(parse(&args(words)).is_none(), "{words:?}");
    }
}

#[test]
fn app_parse_routes_machine_ports_here() {
    let parsed = super::super::parse(&args(&["machine", "b-1", "ports"])).unwrap();
    assert_eq!(parsed, Some(AppCommand::MachinePorts(Command { machine: "b-1".into() })));
    assert_eq!(super::super::parse(&args(&["machine", "list"])).unwrap(), None);
}

#[test]
fn shape_keeps_port_numbers_only_sorted_and_distinct() {
    let far = json!({"ports": [{"port": 5173, "cmd": "vite"}, {"port": 3000}, {"port": 5173}, {"port": 70000}, {"x": 1}]});
    assert_eq!(shape(&far), json!({"ports": [{"port": 3000}, {"port": 5173}]}));
    assert_eq!(shape(&json!({})), json!({"ports": []}));
    assert_eq!(human("b", &shape(&far)), "b: 3000 5173\n");
    assert_eq!(human("b", &json!({"ports": []})), "b: no TCP port is listening\n");
}
