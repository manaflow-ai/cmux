//! The cross-language contract: `intent_vectors.json` (a copy of leo-workspace `tools/intent_vectors.json`)
//! holds parser specs, an argv each refuses and the outcome. Every vector builds a clap `Command` from its
//! spec and must come out as the Python layer does.

use clap::builder::PossibleValuesParser;
use clap::{Arg, ArgAction, Command, value_parser};
use cmux_intent::{Kind, Table, repair};
use serde_json::Value;

/// Vectors this layer does not hold under clap, each with the principled reason. Empty: all hold.
const SKIP: &[(&str, &str)] = &[];

fn leak(s: &str) -> &'static str {
    Box::leak(s.to_owned().into_boxed_str())
}

fn strs(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect())
        .unwrap_or_default()
}

/// A clap `Command` for the vectors' parser spec: flags {"--a,-b": "value"|"int"|"switch"|[choices]},
/// required [flag], args [name | {name, choices, int, optional}], subs {name: spec}.
fn build(name: &str, spec: &Value) -> Command {
    let mut cmd = Command::new(leak(name));
    let required = strs(&spec["required"]);
    if let Some(flags) = spec["flags"].as_object() {
        for (key, kind) in flags {
            let parts: Vec<&str> = key.split(',').collect();
            let long =
                parts.iter().find(|p| p.starts_with("--")).map(|p| p.trim_start_matches('-'));
            let shorts: Vec<char> = parts
                .iter()
                .filter(|p| !p.starts_with("--"))
                .filter_map(|p| p.trim_start_matches('-').chars().next())
                .collect();
            let id = long.map_or_else(|| shorts[0].to_string(), str::to_owned);
            let mut arg = Arg::new(leak(&id));
            if let Some(l) = long {
                arg = arg.long(leak(l));
            }
            if let Some(first) = shorts.first() {
                arg = arg.short(*first);
            }
            for extra in shorts.iter().skip(1) {
                arg = arg.short_alias(*extra);
            }
            arg = match kind {
                Value::String(k) if k == "switch" => arg.action(ArgAction::SetTrue),
                Value::String(k) if k == "int" => arg.num_args(1).value_parser(value_parser!(i64)),
                Value::Array(choices) => arg.num_args(1).value_parser(PossibleValuesParser::new(
                    choices.iter().filter_map(Value::as_str).map(leak).collect::<Vec<_>>(),
                )),
                _ => arg.num_args(1),
            };
            if parts.iter().any(|p| required.iter().any(|r| r == p)) {
                arg = arg.required(true);
            }
            cmd = cmd.arg(arg);
        }
    }
    for item in spec["args"].as_array().into_iter().flatten() {
        let (pname, choices, int, optional) = match item {
            Value::String(s) => (s.clone(), Vec::new(), false, false),
            o => (
                o["name"].as_str().unwrap_or("arg").to_owned(),
                strs(&o["choices"]),
                o["int"].as_bool().unwrap_or(false),
                o["optional"].as_bool().unwrap_or(false),
            ),
        };
        let mut arg = Arg::new(leak(&pname)).required(!optional);
        if !choices.is_empty() {
            arg = arg.value_parser(PossibleValuesParser::new(
                choices.iter().map(|c| leak(c)).collect::<Vec<_>>(),
            ));
        } else if int {
            arg = arg.value_parser(value_parser!(i64));
        }
        cmd = cmd.arg(arg);
    }
    // serde_json's maps sort their keys (the workspace does not enable `preserve_order`), but a parser's
    // subcommands are in the file's order, which is the order candidates are listed in: read it from the text.
    let mut subs: Vec<(&String, &Value)> = spec["subs"].as_object().into_iter().flatten().collect();
    let text = include_str!("../intent_vectors.json");
    let from = text.find(&format!("\"{name}\": {{")).unwrap_or(0);
    subs.sort_by_key(|(sub, _)| text[from..].find(&format!("\"{sub}\":")).unwrap_or(usize::MAX));
    for (sub, sspec) in subs {
        cmd = cmd.subcommand(build(sub, sspec));
    }
    cmd
}

#[test]
fn every_vector_holds() {
    let doc: Value =
        serde_json::from_str(include_str!("../intent_vectors.json")).expect("vectors parse");
    assert_eq!(doc["schema"], "intent-vectors.v1");
    let base = Table::embedded();
    let mut failures = Vec::new();
    let mut run = 0;
    for v in doc["vectors"].as_array().expect("vectors") {
        let name = v["name"].as_str().unwrap_or("?");
        if SKIP.iter().any(|(n, _)| *n == name) {
            continue;
        }
        run += 1;
        let parser = v["parser"].as_str().unwrap_or("?");
        let cmd = build(parser, &doc["parsers"][parser]);
        let mut tbl = base.clone();
        tbl.cli = serde_json::from_value(
            v.get("cli").cloned().unwrap_or(Value::Object(Default::default())),
        )
        .expect("cli part");
        let argv = strs(&v["argv"]);
        let got = repair(&cmd, parser, &argv, &tbl);
        let want = v["outcome"].as_str().unwrap_or("?");
        let want_to: Vec<Vec<String>> = match want {
            "ran" => vec![strs(&v["to"])],
            "candidates" | "exact" => v["to"].as_array().into_iter().flatten().map(strs).collect(),
            _ => Vec::new(),
        };
        let got_to: Vec<Vec<String>> = match got.outcome {
            Kind::Ran => vec![got.argv.clone()],
            Kind::Candidates | Kind::Exact => {
                got.candidates.iter().map(|c| c.argv.clone()).collect()
            }
            _ => Vec::new(),
        };
        if got.outcome.name() != want || got_to != want_to {
            failures.push(format!(
                "{name}: want {want} {want_to:?}, got {} {got_to:?} ({})",
                got.outcome.name(),
                got.error
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {run} vectors failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn the_skip_list_names_real_vectors() {
    let doc: Value =
        serde_json::from_str(include_str!("../intent_vectors.json")).expect("vectors parse");
    for (name, reason) in SKIP {
        assert!(!reason.is_empty());
        assert!(
            doc["vectors"].as_array().is_some_and(|a| a.iter().any(|v| v["name"] == *name)),
            "{name}"
        );
    }
}
