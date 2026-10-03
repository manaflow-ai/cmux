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
        path: &["install"],
        positionals: &[],
        flags: &[("version", true), ("system", false), ("channel", true), ("channel-url", true)],
        help: "install or update to the channel's (or --version) manifest; start the service",
    },
    VerbSpec {
        path: &["uninstall"],
        positionals: &[],
        flags: &[("purge", false), ("no-backup", false), PG_BIN],
        help: "stop and remove the service, shim and store; keep state unless --purge",
    },
    VerbSpec { path: &["status"], positionals: &[], flags: &[PG_BIN], help: "installed state" },
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

/// Parses `args` (after `cmux server`; a leading `server` word is skipped,
/// so the standalone binary also accepts Postgres's
/// `… server db archive-wal %p %f`).
pub fn parse(args: &[String]) -> Result<Args> {
    let mut out = Args::default();
    let mut words = Vec::new();
    let mut raw_flags = Vec::new();
    let mut iter = args.iter().peekable();
    let mut only_positional = false;
    while let Some(arg) = iter.next() {
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
        raw_flags.push((name, inline));
        // A value for a flag that takes one is attached later, so collect
        // the following word lazily below.
        if let Some((name, None)) = raw_flags.last()
            && takes_value_anywhere(name)
            && let Some(next) = iter.next_if(|n| !n.starts_with("--"))
        {
            let last = raw_flags.last_mut().expect("just pushed");
            last.1 = Some(next.clone());
        }
    }
    if words.first().map(String::as_str) == Some("server") {
        words.remove(0);
    }
    for (name, value) in raw_flags {
        match name.as_str() {
            "json" => out.json = true,
            "help" | "h" => out.help = true,
            "idempotency-key" => out.idempotency_key = value,
            _ => {
                out.flags.insert(name, value);
            }
        }
    }
    if words.is_empty() || words[0] == "help" {
        out.help = true;
        return Ok(out);
    }
    let spec = find_spec(&words)
        .ok_or_else(|| Error::usage(format!("unknown verb: {}", words.join(" "))))?;
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
    for v in VERBS {
        let mut line = v.path.join(" ");
        for p in v.positionals {
            line.push_str(&format!(" <{}>", p.trim_end_matches('?')));
        }
        out.push_str(&format!("  {line:28} {}\n", v.help));
    }
    out.push_str("\nGlobal flags: --json --idempotency-key K\n");
    out.push_str("Exit codes: 0 ok, 1 internal, 2 usage, 3 not found, 4 rejected, 5 unreachable or deadline, 6 idempotency conflict, 7 verification failed\n");
    out
}
