//! One finding and its kind.

use std::fmt;
use std::str::FromStr;

use serde::Serialize;

/// What a finding is about; each kind feeds one stability queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A blocking call in async code, or a std lock guard held over `.await` (Q11).
    Blocking,
    /// A dropped tokio JoinHandle, or a thread started outside a supervisor (Q12).
    Spawn,
    /// A call between fork and exec that is not async-signal-safe (Q20).
    PreExec,
    /// A spawned Child that is never awaited, waited, stored or kill_on_drop (Q20).
    Child,
    /// An unbounded channel without `// unbounded-allow:` (Q20).
    Unbounded,
}

impl Kind {
    pub const ALL: [Kind; 5] =
        [Kind::Blocking, Kind::Spawn, Kind::PreExec, Kind::Child, Kind::Unbounded];

    pub fn name(self) -> &'static str {
        match self {
            Kind::Blocking => "blocking",
            Kind::Spawn => "spawn",
            Kind::PreExec => "pre_exec",
            Kind::Child => "child",
            Kind::Unbounded => "unbounded",
        }
    }

    /// The comment tag that exempts one finding of this kind, with a reason:
    /// `// blocking-allow: <why>`.
    pub fn allow_tag(self) -> &'static str {
        match self {
            Kind::Blocking => "blocking-allow:",
            Kind::Spawn => "supervise-allow:",
            Kind::PreExec => "pre-exec-allow:",
            Kind::Child => "child-allow:",
            Kind::Unbounded => "unbounded-allow:",
        }
    }

    /// The stability queue (plans/cmux-next/chrome-parity/p10-stability.md, section 6).
    pub fn queue(self) -> &'static str {
        match self {
            Kind::Blocking => "Q11",
            Kind::Spawn => "Q12",
            Kind::PreExec | Kind::Child | Kind::Unbounded => "Q20",
        }
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// A `--kind` value that names no kind.
#[derive(Debug)]
pub struct UnknownKind(pub String);

impl fmt::Display for UnknownKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let names: Vec<&str> = Kind::ALL.iter().map(|k| k.name()).collect();
        write!(f, "unknown kind `{}` (kinds: {})", self.0, names.join(", "))
    }
}

impl std::error::Error for UnknownKind {}

impl FromStr for Kind {
    type Err = UnknownKind;

    fn from_str(s: &str) -> Result<Kind, UnknownKind> {
        let wanted = s.trim().replace('-', "_");
        Kind::ALL.into_iter().find(|k| k.name() == wanted).ok_or_else(|| UnknownKind(s.to_string()))
    }
}

/// One hit, before or after its allow comment is read.
#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub kind: Kind,
    /// The rule inside the kind (`call`, `method`, `lock-over-await`, `dropped-handle`, ...).
    pub rule: String,
    /// The path shown to people: the root as given, joined with the file.
    pub file: String,
    pub line: usize,
    pub column: usize,
    #[serde(rename = "crate")]
    pub krate: String,
    /// The enclosing function (`Type::method`), or `` at item level.
    pub function: String,
    pub message: String,
    /// The call's source text, whitespace-normalized (the `--diff` key with the rule and function).
    pub snippet: String,
    /// The allow comment's reason, when one exempts this finding.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exempt: Option<String>,
    /// The first line of the enclosing statement: an allow comment above it
    /// covers a finding on a later line of a multi-line statement.
    #[serde(skip)]
    pub stmt_line: usize,
}

impl Finding {
    /// The identity `--diff` compares: everything but the line and column, so
    /// moving code is not a new finding.
    pub fn diff_key(&self) -> (Kind, String, String, String, String) {
        (
            self.kind,
            self.rule.clone(),
            self.file.clone(),
            self.function.clone(),
            self.snippet.clone(),
        )
    }
}
