//! Argument parsing for the `cmux server` verbs: a static table of verbs,
//! their positional arguments and flags. Unknown verbs and flags are usage
//! errors (exit 2).

use std::collections::BTreeMap;

use crate::error::{Error, Result};

/// One verb: its words, positional names, and flags (`true` = takes a
/// value).
pub struct VerbSpec {
    pub path: &'static [&'static str],
    pub positionals: &'static [&'static str],
    pub flags: &'static [(&'static str, bool)],
    pub help: &'static str,
}

const PG_BIN: (&str, bool) = ("pg-bin", true);

pub static VERBS: &[VerbSpec] = &[
    VerbSpec {
        path: &["pair"],
        positionals: &[],
        flags: &[("api-origin", true), ("name", true), ("invite", true)],
        help: "server.pair.begin",
    },
    VerbSpec {
        path: &["pair", "status"],
        positionals: &[],
        flags: &[],
        help: "server.pair.status",
    },
    VerbSpec {
        path: &["unpair"],
        positionals: &[],
        flags: &[("local", false)],
        help: "server.unpair",
    },
    VerbSpec {
        path: &["install"],
        positionals: &["ssh://host?"],
        flags: &[
            ("version", true),
            ("system", false),
            ("channel", true),
            ("channel-url", true),
            ("binary", false),
            ("session-name", true),
            ("yes", false),
            ("nightly", false),
            ("user", false),
            ("label", true),
        ],
        help: "keep cmux running here as a service (or on ssh://[user@]host[:port], installed there first)",
    },
    VerbSpec {
        path: &["uninstall"],
        positionals: &["ssh://host?"],
        flags: &[("purge", false), ("no-backup", false), PG_BIN, ("yes", false), ("user", false)],
        help: "stop and remove the service, shim and store; keep state unless --purge",
    },
    VerbSpec {
        path: &["logs"],
        positionals: &[],
        flags: &[("follow", false), ("lines", true)],
        help: "show the service's log (--lines N or -n N, default 100; --follow or -f to keep reading)",
    },
    VerbSpec {
        path: &["up"],
        positionals: &[],
        flags: &[],
        help: "start the installed service and keep it started across logins",
    },
    VerbSpec {
        path: &["down"],
        positionals: &[],
        flags: &[],
        help: "stop the service and keep it stopped across logins; keep the install",
    },
    VerbSpec {
        path: &["status"],
        positionals: &[],
        flags: &[PG_BIN, ("binary-only", false)],
        help: "installed state",
    },
    VerbSpec {
        path: &["upgrade"],
        positionals: &[],
        flags: &[("version", true), ("generation", true), ("wait", false), ("channel-url", true)],
        help: "apply a newer manifest, or flip to an installed --generation",
    },
    VerbSpec {
        path: &["rollback"],
        positionals: &[],
        flags: &[("generation", true)],
        help: "flip back to the previous (or the given) generation",
    },
    VerbSpec {
        path: &["pin"],
        positionals: &["version?"],
        flags: &[("clear", false)],
        help: "pin a version (stops automatic updates) or --clear the pin",
    },
    VerbSpec {
        path: &["db", "create"],
        positionals: &["app"],
        flags: &[("mode", true), PG_BIN],
        help: "create the app's role and database (or schema); prints its URL",
    },
    VerbSpec {
        path: &["db", "url"],
        positionals: &["app"],
        flags: &[PG_BIN],
        help: "the app's DATABASE_URL (no password)",
    },
    VerbSpec {
        path: &["db", "archive-wal"],
        positionals: &["path", "file"],
        flags: &[],
        help: "Postgres archive_command: copy, fsync, rename; exit 0 only after",
    },
    VerbSpec {
        path: &["db", "backup"],
        positionals: &[],
        flags: &[("wait", false), PG_BIN],
        help: "take a base backup now",
    },
    VerbSpec {
        path: &["health"],
        positionals: &[],
        flags: &[("link-up", false)],
        help: "probe once and print alerts, facts and the next re-check time",
    },
];

/// Parsed arguments.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub verb: Vec<String>,
    pub positionals: Vec<String>,
    pub flags: BTreeMap<String, Option<String>>,
    pub json: bool,
    pub help: bool,
    pub idempotency_key: Option<String>,
}

impl Args {
    pub fn has(&self, flag: &str) -> bool {
        self.flags.contains_key(flag)
    }

    pub fn value(&self, flag: &str) -> Option<&str> {
        self.flags.get(flag).and_then(|v| v.as_deref())
    }

    /// A flag value parsed as an integer.
    pub fn number(&self, flag: &str) -> Result<Option<u64>> {
        match self.value(flag) {
            None => Ok(None),
            Some(v) => v
                .parse()
                .map(Some)
                .map_err(|_| Error::usage(format!("--{flag} takes a number, got {v:?}"))),
        }
    }

    pub fn verb_str(&self) -> String {
        self.verb.join(" ")
    }

    /// The arguments that [`parse`] turns back into these (verb words,
    /// `--flag=value` flags, `--json`, `--idempotency-key`, then `--` and
    /// the positionals), with no `server` noun: the argv for the re-exec.
    pub fn to_argv(&self) -> Vec<String> {
        let mut out = self.verb.clone();
        for (name, value) in &self.flags {
            out.push(match value {
                Some(v) => format!("--{name}={v}"),
                None => format!("--{name}"),
            });
        }
        if self.json {
            out.push("--json".to_owned());
        }
        if let Some(key) = &self.idempotency_key {
            out.push(format!("--idempotency-key={key}"));
        }
        if !self.positionals.is_empty() {
            out.push("--".to_owned());
            out.extend(self.positionals.iter().cloned());
        }
        out
    }
}

fn find_spec(words: &[String]) -> Option<&'static VerbSpec> {
    VERBS
        .iter()
        .filter(|v| v.path.len() <= words.len() && v.path.iter().zip(words).all(|(a, b)| a == b))
        .max_by_key(|v| v.path.len())
}

/// The words and the `--` flags (name, value) of `args`, in order, with a
/// leading `server` word dropped. With `log_aliases`, `-f`, `-n` and
/// `-n=N` before any `--` read as `--follow`, `--lines` and `--lines=N`.
fn split(args: &[String], log_aliases: bool) -> (Vec<String>, Vec<(String, Option<String>)>) {
    let mut words = Vec::new();
    let mut raw_flags = Vec::new();
    let mut iter = args.iter().peekable();
    let mut only_positional = false;
    while let Some(arg) = iter.next() {
        let alias = match arg.as_str() {
            _ if only_positional || !log_aliases => None,
            "-f" => Some("--follow".to_owned()),
            "-n" => Some("--lines".to_owned()),
            other => other.strip_prefix("-n=").map(|v| format!("--lines={v}")),
        };
        let arg = alias.as_ref().unwrap_or(arg);
        if only_positional || !arg.starts_with("--") {
            words.push(arg.clone());
            continue;
        }
        if arg == "--" {
            only_positional = true;
            continue;
        }
        let (name, inline) = match arg[2..].split_once('=') {
            Some((n, v)) => (n.to_owned(), Some(v.to_owned())),
            None => (arg[2..].to_owned(), None),
        };
        // A value for a flag that takes one may be the following word.
        let inline = match inline {
            None if takes_value_anywhere(&name) => iter.next_if(|n| !n.starts_with("--")).cloned(),
            inline => inline,
        };
        raw_flags.push((name, inline));
    }
    if words.first().map(String::as_str) == Some("server") {
        words.remove(0);
    }
    (words, raw_flags)
}

/// Parses `args` (after `cmux server`; a leading `server` word is skipped,
/// so the standalone binary also accepts Postgres's
/// `… server db archive-wal %p %f`).
pub fn parse(args: &[String]) -> Result<Args> {
    // `cmux server logs` also takes the short flags the Rex docs use, `-n N`
    // for `--lines N` and `-f` for `--follow`. They are read in the same
    // pass as the long flags, in order, and only when that reading gives
    // the logs verb: every other verb keeps such words as positionals (a
    // file may be named `-n`).
    let (words, raw_flags) = match split(args, true) {
        (words, flags) if find_spec(&words).is_some_and(|s| s.path == ["logs"]) => (words, flags),
        _ => split(args, false),
    };
    let mut out = Args::default();
    for (name, value) in raw_flags {
        match name.as_str() {
            "json" => out.json = true,
            "help" | "h" => out.help = true,
            "idempotency-key" => {
                out.idempotency_key = Some(
                    value
                        .filter(|value| !value.is_empty())
                        .ok_or_else(|| Error::usage("server.idempotency_key.required"))?,
                );
            }
            _ => {
                out.flags.insert(name, value);
            }
        }
    }
    if words.is_empty() && !out.help {
        // An option with no verb (`cmux server --frobnicate`) is a usage
        // error, not the help with exit 0.
        if let Some(name) = out.flags.keys().next() {
            return Err(Error::usage(format!(
                "--{name} needs a verb; run `cmux server --help` for the verbs"
            )));
        }
    }
    if words.is_empty() || words[0] == "help" {
        out.help = true;
        return Ok(out);
    }
    let spec = find_spec(&words).ok_or_else(|| {
        Error::usage(format!(
            "unknown verb: {}; run `cmux server --help` for the verbs",
            words.join(" ")
        ))
    })?;
    out.verb = spec.path.iter().map(|s| (*s).to_owned()).collect();
    out.positionals = words[spec.path.len()..].to_vec();
    check_spec(spec, &out)?;
    Ok(out)
}

fn takes_value_anywhere(name: &str) -> bool {
    name == "idempotency-key" || VERBS.iter().flat_map(|v| v.flags).any(|(n, v)| *n == name && *v)
}

fn check_spec(spec: &VerbSpec, args: &Args) -> Result<()> {
    let verb = spec.path.join(" ");
    for (name, value) in &args.flags {
        let Some((_, takes)) = spec.flags.iter().find(|(n, _)| n == name) else {
            return Err(Error::usage(format!("{verb} has no flag --{name}")));
        };
        match (takes, value) {
            (true, None) => return Err(Error::usage(format!("--{name} needs a value"))),
            (false, Some(_)) => return Err(Error::usage(format!("--{name} takes no value"))),
            _ => {}
        }
    }
    let required = spec.positionals.iter().filter(|p| !p.ends_with('?')).count();
    let n = args.positionals.len();
    if n < required || n > spec.positionals.len() {
        let names: Vec<String> = spec.positionals.iter().map(|p| format!("<{p}>")).collect();
        return Err(Error::usage(format!("usage: cmux server {verb} {}", names.join(" "))));
    }
    Ok(())
}

/// The help text.
pub fn help() -> String {
    let mut out = String::from("cmux server: run this machine as a cmux server\n\n");
    let pairing = crate::pairing::messages::current();
    for v in VERBS {
        let mut line = v.path.join(" ");
        for p in v.positionals {
            line.push_str(&format!(" <{}>", p.trim_end_matches('?')));
        }
        let help = match v.help {
            "server.pair.begin" => pairing.pair_help,
            "server.pair.status" => pairing.status_help,
            "server.unpair" => pairing.unpair_help,
            other => other,
        };
        out.push_str(&format!("  {line:28} {help}\n"));
    }
    out.push_str("\nGlobal flags: --json --idempotency-key K\n");
    out.push_str("Exit codes: 0 ok, 1 internal, 2 usage, 3 not found, 4 rejected, 5 unreachable or deadline, 6 idempotency conflict, 7 verification failed\n");
    out
}
