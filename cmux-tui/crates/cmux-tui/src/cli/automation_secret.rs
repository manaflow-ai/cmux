//! `cmux automation secret set|list|remove … --target cloud`: the named values a Cloud command
//! automation's machine steps get as environment variables (AUTOMATIONS-SPEC section 12).
//!
//! `set` reads the value from `--secret-file PATH` (one trailing line break dropped), else a
//! hidden prompt on a terminal, else all of stdin; never from an argument, so it is never in argv,
//! shell history or `ps`. The value goes to the app on its control socket, the app hands it to
//! `cmux cloud automation-relay` on stdin, and cmux Cloud seals it: no read ever returns it.

use std::path::PathBuf;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Args, Failure, Out, Outcome, cloud_find, cloud_out, usage};
use crate::cli::GlobalArgs;
use crate::cli::automation_cloud as cloud;

pub(super) const USAGE: &str = "usage: cmux automation secret set AUTOMATION NAME [--secret-file PATH] --target cloud\n       cmux automation secret list AUTOMATION --target cloud\n       cmux automation secret remove AUTOMATION NAME --target cloud\n  NAME is an environment variable name (A-Z, 0-9, _). Each step of a Cloud --command run gets\n  it in its environment. set reads the value from a hidden prompt or stdin unless\n  --secret-file names a file, never from an argument; no read shows it again.\n";

/// The longest value cmux Cloud keeps (`AUTOMATION_SECRET_MAX_BYTES`).
const MAX_VALUE_BYTES: usize = 32 * 1024;

/// What one `secret` command does.
#[derive(Debug, PartialEq)]
pub(super) enum Verb {
    Set { automation: String, name: String, file: Option<PathBuf> },
    List { automation: String },
    Remove { automation: String, name: String },
}

/// A valid environment variable name for a secret: `^[A-Z][A-Z0-9_]{0,63}$`.
pub(super) fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some('A'..='Z'))
        && name.len() <= 64
        && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

pub(super) fn parse(args: &[String]) -> Result<Verb, Failure> {
    let Some((verb, rest)) = args.split_first() else { return usage(USAGE) };
    let a = Args::parse(rest, &["secret-file"], &[])?;
    let name = |n: &str| -> Result<String, Failure> {
        if valid_name(n) {
            Ok(n.to_string())
        } else {
            usage(format!(
                "\"{n}\" is not a secret name: capital letters, digits and _, starting with a letter (at most 64)\n{USAGE}"
            ))
        }
    };
    let file = a.value("secret-file").map(PathBuf::from);
    match (verb.as_str(), a.words.as_slice()) {
        ("set", [automation, n]) => {
            Ok(Verb::Set { automation: automation.clone(), name: name(n)?, file })
        }
        // A third word is most likely the value: refuse it before it is sent anywhere.
        ("set", [_, _, _, ..]) => usage(format!(
            "secret set takes the value from a hidden prompt, stdin or --secret-file, never from an argument\n{USAGE}"
        )),
        ("list" | "ls", [automation]) if file.is_none() => {
            Ok(Verb::List { automation: automation.clone() })
        }
        ("remove" | "rm" | "delete", [automation, n]) if file.is_none() => {
            Ok(Verb::Remove { automation: automation.clone(), name: name(n)? })
        }
        _ => usage(USAGE),
    }
}

/// The value for `set`.
fn read_value(name: &str, file: Option<&PathBuf>) -> Result<Zeroizing<String>, Failure> {
    let value = match file {
        Some(path) => {
            let mut f = std::fs::File::open(path).map_err(|e| {
                // Neither the path nor the contents go into the error (a pasted value could be in either).
                Failure::Usage(format!("the --secret-file could not be read ({:?})", e.kind()))
            })?;
            acpmux::cli::harness_secret::read_secret_from(&mut f)
                .map_err(|e| Failure::Usage(e.to_string()))?
        }
        None => acpmux::cli::harness_secret::read_value(name)
            .map_err(|e| Failure::Usage(e.to_string()))?,
    };
    if value.is_empty() {
        return usage("the value is empty");
    }
    if value.len() > MAX_VALUE_BYTES {
        return usage(format!("the value is longer than {} KiB", MAX_VALUE_BYTES / 1024));
    }
    if value.contains('\0') {
        return usage("the value has a NUL byte, which an environment variable cannot hold");
    }
    Ok(value)
}

fn row(s: &Value) -> String {
    let text = |k: &str| s.get(k).and_then(Value::as_str).unwrap_or("-").to_string();
    let hint = s.get("hint").and_then(Value::as_str).map(|h| format!("…{h}")).unwrap_or_default();
    format!("{:<24} {:<8} updated by {}", text("name"), hint, text("updated_by"))
}

pub(super) fn run(args: &[String], global: &GlobalArgs, out: &Out) -> Outcome {
    let verb = parse(args)?;
    let word = match &verb {
        Verb::Set { automation, .. }
        | Verb::List { automation }
        | Verb::Remove { automation, .. } => automation.clone(),
    };
    // Read the value before any call, so a bad file fails with nothing sent.
    let value = match &verb {
        Verb::Set { name, file, .. } => Some(read_value(name, file.as_ref())?),
        _ => None,
    };
    let id = match cloud_find(global, out, &word)? {
        Ok(id) => id,
        Err(done) => return done,
    };
    match verb {
        Verb::Set { name, .. } => {
            let value = value.unwrap_or_default();
            let params = json!({"automation": id, "name": name, "value": value.as_str()});
            let answer = cloud::call(
                global,
                "automation.secret.set",
                params,
                Some(cloud::key(global, "secret-set")),
            );
            cloud_out(answer, out, |v| {
                println!("Set {name} on {id}{}", hint_suffix(v));
            })
        }
        Verb::List { .. } => cloud_out(
            cloud::call(global, "automation.secret.list", json!({"automation": id}), None),
            out,
            |v| {
                let all = v.get("secrets").and_then(Value::as_array).cloned().unwrap_or_default();
                if all.is_empty() {
                    println!("No secrets.");
                }
                for s in &all {
                    println!("{}", row(s));
                }
            },
        ),
        Verb::Remove { name, .. } => cloud_out(
            cloud::call(
                global,
                "automation.secret.remove",
                json!({"automation": id, "name": name}),
                Some(cloud::key(global, "secret-remove")),
            ),
            out,
            |v| {
                if v.get("removed").and_then(Value::as_bool) == Some(true) {
                    println!("Removed {name} from {id}");
                } else {
                    println!("{id} has no secret {name}");
                }
            },
        ),
    }
}

fn hint_suffix(v: &Value) -> String {
    v.get("hint").and_then(Value::as_str).map(|h| format!(" (ends …{h})")).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn parses_set_list_and_remove_and_keeps_the_value_off_argv() {
        assert_eq!(
            parse(&words("set scout MODELS_CATALOG_TOKEN")).ok(),
            Some(Verb::Set {
                automation: "scout".into(),
                name: "MODELS_CATALOG_TOKEN".into(),
                file: None
            })
        );
        assert_eq!(
            parse(&words("set scout GH_TOKEN --secret-file /tmp/t")).ok(),
            Some(Verb::Set {
                automation: "scout".into(),
                name: "GH_TOKEN".into(),
                file: Some("/tmp/t".into())
            })
        );
        assert_eq!(
            parse(&words("list scout")).ok(),
            Some(Verb::List { automation: "scout".into() })
        );
        assert_eq!(
            parse(&words("rm scout GH_TOKEN")).ok(),
            Some(Verb::Remove { automation: "scout".into(), name: "GH_TOKEN".into() })
        );
        // A value as an argument is refused, and the message does not echo it.
        let Err(Failure::Usage(m)) = parse(&words("set scout GH_TOKEN ghp_abcdef123456")) else {
            panic!("a value in argv must be refused")
        };
        assert!(!m.contains("ghp_abcdef123456"), "{m}");
        assert!(matches!(parse(&words("set scout GH_TOKEN --value x")), Err(Failure::Usage(_))));
    }

    #[test]
    fn names_are_environment_variable_names() {
        for ok in ["A", "GH_TOKEN", "CMUX_PRO_KEY", "X1"] {
            assert!(valid_name(ok), "{ok}");
        }
        for bad in ["", "gh_token", "1A", "_A", "A-B", "A B", &"A".repeat(65)] {
            assert!(!valid_name(bad), "{bad}");
        }
        assert!(matches!(parse(&words("set scout gh_token")), Err(Failure::Usage(_))));
    }

    #[test]
    fn a_secret_file_is_read_without_its_trailing_line_break_and_a_nul_is_refused() {
        let dir = std::env::temp_dir().join(format!("cmux-secret-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v");
        std::fs::write(&path, "line one\nline two\n").unwrap();
        assert_eq!(
            read_value("N", Some(&path)).ok().as_deref().map(|v| v.as_str()),
            Some("line one\nline two")
        );
        std::fs::write(&path, "a\0b").unwrap();
        assert!(read_value("N", Some(&path)).is_err());
        std::fs::write(&path, "").unwrap();
        assert!(read_value("N", Some(&path)).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
