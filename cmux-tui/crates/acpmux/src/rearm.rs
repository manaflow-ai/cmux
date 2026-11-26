//! Re-armable waits: the background tasks a session move can start again at the destination
//! (`_acpmux/bg/rearm`, `server/bg_rearm.rs`) instead of holding the session where it is.
//!
//! A wait is re-armable when it names its whole target and its deadline and keeps no local
//! state, so the same wait started on another machine with the time it has left waits for the
//! same thing:
//!
//! - `acpmux pr-wait N --repo OWNER/REPO [--sha SHA] [--until checks|merged] --timeout SECS`
//!   (kind `pr_wait`, `cli/pr_wait.rs`);
//! - `acpmux ci wait pr|run ID --repo OWNER/REPO --timeout SECS` (kind `ci_wait`,
//!   `cli/ci_wait.rs`);
//! - `glaeda-gh wait pr OWNER/REPO#N | run OWNER/REPO/ID [--until WORD] [--sha SHA] --timeout
//!   SECS` (the machine's GitHub poller: `pr_wait` for a pull request, `ci_wait` for a run).
//!
//! Only one simple command is read: any other character than a letter, a digit, a space or one
//! of `._/#:=-` (a pipe, a `;`, a `$`, a redirect, a newline...) makes the task not a wait, and so
//! do an unknown flag, a missing `--repo` (the default reads the folder's origin, local state)
//! and a missing `--timeout` (no deadline). `sleep`, a shell command, a build or a test is never
//! one, and stays held.
//!
//! The destination never runs a command it was sent: it reads the wait's fields
//! ([`Wait::from_json`], checked as strictly as the parse) and writes the command again from them
//! ([`Wait::command`]) with the deadline's remaining seconds.

use serde_json::{Value, json};

/// The `_acpmux/bg/rearm` message version this build speaks (`server/bg_rearm.rs`).
pub const VERSION: u64 = 1;
/// A wait with less than this left is not moved: it ends where it is, sooner than a move.
pub const MIN_LEFT_MS: u64 = 60_000;

/// Which command a wait is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Form {
    /// `acpmux pr-wait`.
    AcpmuxPrWait,
    /// `acpmux ci wait pr`.
    AcpmuxCiPr,
    /// `acpmux ci wait run`.
    AcpmuxCiRun,
    /// `glaeda-gh wait pr`.
    GlaedaPr,
    /// `glaeda-gh wait run`.
    GlaedaRun,
}

impl Form {
    const ALL: [Form; 5] =
        [Form::AcpmuxPrWait, Form::AcpmuxCiPr, Form::AcpmuxCiRun, Form::GlaedaPr, Form::GlaedaRun];

    pub fn as_str(self) -> &'static str {
        match self {
            Form::AcpmuxPrWait => "acpmux-pr-wait",
            Form::AcpmuxCiPr => "acpmux-ci-wait-pr",
            Form::AcpmuxCiRun => "acpmux-ci-wait-run",
            Form::GlaedaPr => "glaeda-wait-pr",
            Form::GlaedaRun => "glaeda-wait-run",
        }
    }

    fn of(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|f| f.as_str() == s)
    }

    /// `pr_wait` (a pull request) or `ci_wait` (CI: a run, or a pull request's checks through
    /// `acpmux ci wait`).
    pub fn kind(self) -> &'static str {
        match self {
            Form::AcpmuxPrWait | Form::GlaedaPr => "pr_wait",
            Form::AcpmuxCiPr | Form::AcpmuxCiRun | Form::GlaedaRun => "ci_wait",
        }
    }

    fn takes_sha(self) -> bool {
        matches!(self, Form::AcpmuxPrWait | Form::GlaedaPr)
    }

    fn takes_until(self) -> bool {
        matches!(self, Form::AcpmuxPrWait | Form::GlaedaPr | Form::GlaedaRun)
    }
}

/// One re-armable wait: its target and its deadline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wait {
    pub form: Form,
    pub repo: String,
    /// The pull request's number or the run's id.
    pub number: u64,
    pub sha: Option<String>,
    pub until: Option<String>,
    /// When it gives up (its start plus its `--timeout`), Unix ms.
    pub deadline_ms: u64,
}

fn repo_ok(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            && p != "."
            && p != ".."
    };
    repo.split_once('/').is_some_and(|(o, r)| part(o) && part(r))
}

fn sha_ok(sha: &str) -> bool {
    (4..=40).contains(&sha.len()) && sha.chars().all(|c| c.is_ascii_hexdigit())
}

fn until_ok(form: Form, until: &str) -> bool {
    match form {
        Form::AcpmuxPrWait => matches!(until, "checks" | "merged"),
        _ => {
            !until.is_empty()
                && until.len() <= 20
                && until.chars().all(|c| c.is_ascii_lowercase() || c == '-')
        }
    }
}

fn number_of(s: &str) -> Option<u64> {
    let s = s.strip_prefix('#').unwrap_or(s);
    if s.is_empty() || !s.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse().ok().filter(|n| *n > 0)
}

fn secs_of(s: &str) -> Option<u64> {
    if s.is_empty() || s.len() > 9 || !s.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse().ok().filter(|n| *n > 0)
}

/// The wait `command` is, started at `started_at_ms`; `None` when it is anything else.
pub fn parse(command: &str, started_at_ms: u64) -> Option<Wait> {
    let allowed = |c: char| {
        c.is_ascii_alphanumeric() || matches!(c, ' ' | '.' | '_' | '/' | '#' | ':' | '=' | '-')
    };
    if command.is_empty() || command.len() > 400 || !command.chars().all(allowed) {
        return None;
    }
    let words: Vec<&str> = command.split(' ').filter(|w| !w.is_empty()).collect();
    let (form, target, rest): (Form, &str, &[&str]) = match words.as_slice() {
        ["acpmux", "pr-wait", n, rest @ ..] => (Form::AcpmuxPrWait, n, rest),
        ["acpmux", "ci", "wait", "pr", n, rest @ ..] => (Form::AcpmuxCiPr, n, rest),
        ["acpmux", "ci", "wait", "run", n, rest @ ..] => (Form::AcpmuxCiRun, n, rest),
        ["glaeda-gh", "wait", "pr", t, rest @ ..] => (Form::GlaedaPr, t, rest),
        ["glaeda-gh", "wait", "run", t, rest @ ..] => (Form::GlaedaRun, t, rest),
        _ => return None,
    };
    let glaeda = matches!(form, Form::GlaedaPr | Form::GlaedaRun);
    let (mut repo, number) = if glaeda {
        let sep = if form == Form::GlaedaPr { '#' } else { '/' };
        let (r, n) = target.rsplit_once(sep)?;
        (Some(r.to_owned()), number_of(n)?)
    } else {
        (None, number_of(target)?)
    };
    let (mut sha, mut until, mut timeout) = (None, None, None);
    let mut i = 0;
    while i < rest.len() {
        let (flag, value) = match rest[i].split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v)),
            _ => (rest[i], None),
        };
        let value = match value {
            Some(v) => v,
            None => {
                i += 1;
                *rest.get(i)?
            }
        };
        i += 1;
        let slot = match flag {
            "--repo" | "-R" if !glaeda => &mut repo,
            "--sha" if form.takes_sha() => &mut sha,
            "--until" if form.takes_until() => &mut until,
            "--timeout" => &mut timeout,
            _ => return None,
        };
        if slot.replace(value.to_owned()).is_some() {
            return None;
        }
    }
    let repo = repo.filter(|r| repo_ok(r))?;
    if sha.as_deref().is_some_and(|s| !sha_ok(s))
        || until.as_deref().is_some_and(|u| !until_ok(form, u))
    {
        return None;
    }
    let secs = secs_of(timeout.as_deref()?)?;
    Some(Wait {
        form,
        repo,
        number,
        sha: sha.map(|s| s.to_ascii_lowercase()),
        until,
        deadline_ms: started_at_ms.saturating_add(secs.saturating_mul(1000)),
    })
}

impl Wait {
    /// How long it has left at `now_ms`.
    pub fn left_ms(&self, now_ms: u64) -> u64 {
        self.deadline_ms.saturating_sub(now_ms)
    }

    /// The wire form (`bgWaits` rows, `_acpmux/bg/rearm`'s `waits`).
    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.form.kind(), "form": self.form.as_str(), "repo": self.repo,
            "number": self.number, "sha": self.sha, "until": self.until,
            "deadlineMs": self.deadline_ms,
        })
    }

    /// A wait read from the wire, checked as strictly as [`parse`] checks a command.
    pub fn from_json(v: &Value) -> Result<Self, String> {
        let form = v
            .get("form")
            .and_then(Value::as_str)
            .and_then(Form::of)
            .ok_or("form is not a re-armable wait")?;
        let repo = v
            .get("repo")
            .and_then(Value::as_str)
            .filter(|r| repo_ok(r))
            .ok_or("repo must be OWNER/REPO")?;
        let number = v
            .get("number")
            .and_then(Value::as_u64)
            .filter(|n| *n > 0)
            .ok_or("number must be a positive integer")?;
        let text = |k: &str| -> Result<Option<String>, String> {
            match v.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err(format!("{k} must be a string")),
            }
        };
        let sha = text("sha")?;
        if sha.as_deref().is_some_and(|s| !form.takes_sha() || !sha_ok(s)) {
            return Err("sha must be hex, on a pull request wait".into());
        }
        let until = text("until")?;
        if until.as_deref().is_some_and(|u| !form.takes_until() || !until_ok(form, u)) {
            return Err("until is not one this wait takes".into());
        }
        let deadline_ms =
            v.get("deadlineMs").and_then(Value::as_u64).ok_or("deadlineMs is required")?;
        Ok(Self { form, repo: repo.to_owned(), number, sha, until, deadline_ms })
    }

    /// The command that waits for the same target until the same deadline, started at
    /// `now_ms`; `None` once the deadline passed.
    pub fn command(&self, now_ms: u64) -> Option<String> {
        let left = self.left_ms(now_ms);
        if left == 0 {
            return None;
        }
        let secs = left.div_ceil(1000);
        let (repo, n) = (&self.repo, self.number);
        let mut words = match self.form {
            Form::AcpmuxPrWait => format!("acpmux pr-wait {n} --repo {repo}"),
            Form::AcpmuxCiPr => format!("acpmux ci wait pr {n} --repo {repo}"),
            Form::AcpmuxCiRun => format!("acpmux ci wait run {n} --repo {repo}"),
            Form::GlaedaPr => format!("glaeda-gh wait pr {repo}#{n}"),
            Form::GlaedaRun => format!("glaeda-gh wait run {repo}/{n}"),
        };
        if let Some(until) = &self.until {
            words.push_str(&format!(" --until {until}"));
        }
        if let Some(sha) = &self.sha {
            words.push_str(&format!(" --sha {sha}"));
        }
        words.push_str(&format!(" --timeout {secs}"));
        Some(words)
    }
}

#[cfg(test)]
#[path = "rearm_tests.rs"]
mod tests;
