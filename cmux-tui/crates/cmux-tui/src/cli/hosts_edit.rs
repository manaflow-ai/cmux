//! `cmux hosts add|rename|set-endpoints|remove`: one change to
//! `machines.hosts` in cmux-next.json, through `cmux_config::hosts_edit`
//! (the key's own rule, the settings owner's lock, comments and other keys
//! kept, an atomic publish). Like `cmux hosts list`, it works with cmux quit;
//! a running cmux reads the change from the file.
//!
//! The key refuses agents (`network`: an agent cannot point cmux at an
//! address of its choosing), so these verbs refuse a caller an agent runs.

use cmux_config::hosts::HostDecl;
use cmux_config::hosts_edit::{self, HostEdit};
use serde_json::json;

use super::OutputMode;

/// Parses an edit verb and its words (`--json` already removed), or `None`
/// when `verb` is not one.
pub(super) fn parse(verb: &str, args: &[&str]) -> Option<Result<HostEdit, String>> {
    let owned = |words: &[&str]| words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    Some(match verb {
        "add" => parse_add(args),
        "rename" | "mv" => match args {
            [from, to] => Ok(HostEdit::Rename { from: (*from).into(), to: (*to).into() }),
            _ => Err("usage: cmux hosts rename OLD NEW".into()),
        },
        "set-endpoints" => match args.split_first() {
            Some((label, endpoints)) if !endpoints.is_empty() => no_options(endpoints).map(|()| {
                HostEdit::SetEndpoints { label: (*label).into(), endpoints: owned(endpoints) }
            }),
            _ => Err("usage: cmux hosts set-endpoints LABEL ENDPOINT...".into()),
        },
        "remove" | "rm" => match args {
            [label] => Ok(HostEdit::Remove { label: (*label).into() }),
            _ => Err("usage: cmux hosts remove LABEL".into()),
        },
        _ => return None,
    })
}

fn parse_add(args: &[&str]) -> Result<HostEdit, String> {
    let mut icon = None;
    let mut words = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--icon=") {
            icon = Some(value.to_owned());
        } else if *arg == "--icon" {
            icon = Some((*args.next().ok_or("--icon needs a name")?).to_owned());
        } else {
            words.push(*arg);
        }
    }
    no_options(&words)?;
    match words.split_first() {
        Some((label, endpoints)) if !endpoints.is_empty() => Ok(HostEdit::Add {
            label: (*label).into(),
            endpoints: endpoints.iter().map(|word| (*word).to_owned()).collect(),
            icon,
        }),
        _ => Err("usage: cmux hosts add LABEL ENDPOINT... [--icon NAME]".into()),
    }
}

/// An unknown option is refused, never taken as a label or an endpoint.
fn no_options(words: &[&str]) -> Result<(), String> {
    match words.iter().find(|word| word.starts_with('-')) {
        Some(option) => Err(format!("unknown option {option}")),
        None => Ok(()),
    }
}

/// Runs one edit; the exit code.
pub(super) fn run(output: OutputMode, edit: &HostEdit) -> i32 {
    if let Some(marker) = super::federation::agent_marker(|key| std::env::var(key).ok()) {
        eprintln!(
            "cmux hosts: an agent cannot change machines.hosts ({marker} is set): it would point \
             cmux at an address of its choosing. The person runs this in their own terminal, or \
             edits machines.hosts in cmux-next.json."
        );
        return 1;
    }
    let config = cmux_config::config_path();
    let seed = cmux_config::location::seed_path();
    let hosts = match hosts_edit::edit_file(&config, seed.as_deref(), edit) {
        Ok(hosts) => hosts,
        Err(error) => {
            eprintln!("cmux hosts: {error}");
            return 1;
        }
    };
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            println!("{}", json!({ "ok": true, "hosts": hosts, "path": config }));
        }
        OutputMode::Quiet => {}
        _ => println!("{}", done(edit, &hosts)),
    }
    0
}

fn done(edit: &HostEdit, hosts: &[HostDecl]) -> String {
    let count = match hosts.len() {
        1 => "1 host".to_owned(),
        n => format!("{n} hosts"),
    };
    match edit {
        HostEdit::Add { label, .. } => format!("Added {}. {count}.", label.trim()),
        HostEdit::Rename { from, to } => format!("Renamed {from} to {}.", to.trim()),
        HostEdit::SetEndpoints { label, endpoints } => {
            format!("{label} now tries {}.", endpoints.join(", "))
        }
        HostEdit::Remove { label } => format!("Removed {label}. {count}."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(verb: &str, args: &str) -> Result<HostEdit, String> {
        let words: Vec<&str> = args.split_whitespace().collect();
        parse(verb, &words).expect("an edit verb")
    }

    #[test]
    fn edit_verbs_parse() {
        assert_eq!(
            parsed("add", "studio studio.local ssh://leo@10.0.0.2:2222 --icon desktopcomputer"),
            Ok(HostEdit::Add {
                label: "studio".into(),
                endpoints: vec!["studio.local".into(), "ssh://leo@10.0.0.2:2222".into()],
                icon: Some("desktopcomputer".into()),
            })
        );
        assert_eq!(
            parsed("rename", "studio mini"),
            Ok(HostEdit::Rename { from: "studio".into(), to: "mini".into() })
        );
        assert_eq!(
            parsed("set-endpoints", "studio a b"),
            Ok(HostEdit::SetEndpoints {
                label: "studio".into(),
                endpoints: vec!["a".into(), "b".into()]
            })
        );
        assert_eq!(parsed("rm", "studio"), Ok(HostEdit::Remove { label: "studio".into() }));
        assert!(parsed("add", "studio").is_err());
        assert!(parsed("add", "studio a --bogus").is_err());
        assert!(parsed("rename", "studio").is_err());
        assert!(parsed("set-endpoints", "studio").is_err());
        assert!(parsed("remove", "a b").is_err());
        assert!(parse("frobnicate", &[]).is_none());
    }
}
