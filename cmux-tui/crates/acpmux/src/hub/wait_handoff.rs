//! Part of `Hub`; see `hub/mod.rs`. Under `adaptive-v1`, a harness that only waits hands its waits
//! to the daemon and hibernates.
//!
//! An agent that waits on CI, a PR or a process starts a background shell in its harness
//! (`sleep 600`, `tail --pid=P -f /dev/null`, `glaeda-gh wait ...`): that shell is in the chat's
//! process table (`processes.rs`), and a running one kept the harness up for the whole wait
//! (`idle.rs` `holds_work_below`), however long. A wait the daemon runs (`bg_tasks.rs`, notify)
//! is what `adaptive-v1` already hibernates after `SHORT` (`residency.rs`): its end prompts the
//! chat, which wakes it.
//!
//! So when the only thing keeping an idle harness up is its running background shells, and every
//! one of them is a wait this module can run again ([`plan`]), the idle pass starts each as a
//! notify task with what is left of it (a `sleep` or `timeout` less the time it already ran), and
//! the harness hibernates; its own shells end with it. A shell that does anything else (a dev
//! server, a build, a command substitution) keeps the harness up as before. Off under `static`.

use super::*;
use std::path::PathBuf;

/// A running harness shell the daemon runs in its place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Handoff {
    /// The command to run: the harness's, with elapsed time taken off its durations.
    pub(super) command: String,
    pub(super) cwd: String,
    pub(super) description: Option<String>,
}

/// Programs a handed-off wait may run besides the shell: the census lets a process under the
/// harness whose argv names one of these by (`covers`), while the handoff is planned.
const WAIT_PROGRAMS: &[&str] = &["sleep", "tail", "timeout", "glaeda-gh", "acpmux", "gh"];
/// Commands that only print or set nothing, allowed around a wait (`sleep 60; echo done`).
const HARMLESS: &[&str] = &["echo", "printf", "true", ":", "date"];
/// What a wait's output may be piped through.
const FILTERS: &[&str] = &["tail", "head", "grep", "cat", "cut", "wc", "tr"];
/// Shells a harness runs its background command in.
const SHELLS: &[&str] = &["bash", "sh", "zsh", "dash"];

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Word(String),
    /// `;`, `&&`, `||`.
    Sep(&'static str),
    Pipe,
}

/// The command's words and operators, or `None` for anything this module does not run again:
/// expansion (`$`, backticks), subshells and groups, a backslash, a lone `&`, input redirection,
/// or output redirected anywhere but `/dev/null` or another descriptor.
fn tokenize(command: &str) -> Option<Vec<Tok>> {
    let mut toks = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    let mut chars = command.chars().peekable();
    let flush = |word: &mut String, quoted: &mut bool, toks: &mut Vec<Tok>| {
        if !word.is_empty() || *quoted {
            toks.push(Tok::Word(std::mem::take(word)));
        }
        *quoted = false;
    };
    while let Some(c) = chars.next() {
        match c {
            '$' | '`' | '(' | ')' | '{' | '}' | '\\' | '<' | '\n' | '\r' | '*' | '?' | '['
            | '~' => {
                return None;
            }
            '\'' | '"' => {
                quoted = true;
                loop {
                    match chars.next() {
                        Some(q) if q == c => break,
                        Some(q) => word.push(q),
                        None => return None,
                    }
                }
            }
            ' ' | '\t' => flush(&mut word, &mut quoted, &mut toks),
            ';' => {
                flush(&mut word, &mut quoted, &mut toks);
                toks.push(Tok::Sep(";"));
            }
            '&' => {
                if word.ends_with('>') && chars.peek().is_some_and(char::is_ascii_digit) {
                    // `2>&1`: a descriptor, kept in the word.
                    word.push('&');
                    continue;
                }
                flush(&mut word, &mut quoted, &mut toks);
                if chars.next_if_eq(&'&').is_none() {
                    return None;
                }
                toks.push(Tok::Sep("&&"));
            }
            '|' => {
                flush(&mut word, &mut quoted, &mut toks);
                if chars.next_if_eq(&'|').is_some() {
                    toks.push(Tok::Sep("||"));
                } else {
                    toks.push(Tok::Pipe);
                }
            }
            _ => word.push(c),
        }
    }
    flush(&mut word, &mut quoted, &mut toks);
    drop_null_redirects(toks)
}

/// The tokens without their redirections to `/dev/null` or a descriptor (`>/dev/null`,
/// `2>&1`, `> /dev/null`); `None` for any other redirection.
fn drop_null_redirects(toks: Vec<Tok>) -> Option<Vec<Tok>> {
    let mut out = Vec::with_capacity(toks.len());
    let mut iter = toks.into_iter().peekable();
    while let Some(tok) = iter.next() {
        let Tok::Word(w) = &tok else {
            out.push(tok);
            continue;
        };
        let Some(at) = w.find('>') else {
            out.push(tok);
            continue;
        };
        let (fd, rest) = w.split_at(at);
        if !fd.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let target = rest.trim_start_matches('>');
        let target = if target.is_empty() {
            match iter.next() {
                Some(Tok::Word(t)) => t,
                _ => return None,
            }
        } else {
            target.to_string()
        };
        let descriptor =
            target.strip_prefix('&').is_some_and(|d| d.chars().all(|c| c.is_ascii_digit()));
        if target != "/dev/null" && !descriptor {
            return None;
        }
    }
    Some(out)
}

/// A duration as `sleep` and `timeout` read it (`90`, `1.5m`, `2h`, `1d`), in ms.
fn duration_ms(word: &str) -> Option<u64> {
    let unit = word.chars().next_back()?;
    let (num, unit) = match word.strip_suffix(['s', 'm', 'h', 'd']) {
        Some(num) => (num, unit),
        None => (word, 's'),
    };
    let n: f64 = num.parse().ok()?;
    if !n.is_finite() || n < 0.0 {
        return None;
    }
    let scale = match unit {
        'm' => 60_000.0,
        'h' => 3_600_000.0,
        'd' => 86_400_000.0,
        _ => 1_000.0,
    };
    Some((n * scale) as u64)
}

/// What is left of `word`'s duration after `elapsed_ms`, as whole seconds; `None` when it is up
/// (the shell ends on its own soon) or not a duration.
fn remaining(word: &str, elapsed_ms: u64) -> Option<String> {
    let left = duration_ms(word)?.checked_sub(elapsed_ms).filter(|ms| *ms >= 1_000)?;
    Some(format!("{}s", left.div_ceil(1_000)))
}

fn base(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

/// One simple command of a wait, its durations shortened by `elapsed_ms`: `Some(true)` for the
/// wait itself, `Some(false)` for a harmless one, `None` for anything else.
fn simple(words: &mut [String], elapsed_ms: u64) -> Option<bool> {
    let mut at = 0;
    if words.first().map(|w| base(w)) == Some("timeout") {
        at = 1;
        // Its options (`-k 5`, `--signal=KILL`), then its duration.
        while words.get(at).is_some_and(|w| w.starts_with('-')) {
            let opt = words.get(at)?.clone();
            at += 1;
            if matches!(opt.as_str(), "-k" | "-s" | "--kill-after" | "--signal") {
                at += 1;
            }
        }
        let left = remaining(words.get(at)?, elapsed_ms)?;
        *words.get_mut(at)? = left;
        at += 1;
    }
    let program = base(words.get(at)?).to_string();
    let rest = words.get_mut(at + 1..)?;
    let wait = match program.as_str() {
        "sleep" => {
            let [d] = rest else { return None };
            *d = remaining(d, elapsed_ms)?;
            true
        }
        "tail" => {
            rest.iter().any(|w| w.starts_with("--pid="))
                && rest.iter().any(|w| w == "-f" || w == "-F" || w == "--follow")
        }
        "glaeda-gh" => rest.first().is_some_and(|w| w == "wait"),
        "acpmux" => rest.first().is_some_and(|w| w == "pr-wait" || w == "run-wait"),
        "gh" => match &*rest {
            [run, watch, ..] if run == "run" && watch == "watch" => true,
            [pr, checks, more @ ..] if pr == "pr" && checks == "checks" => {
                more.iter().any(|w| w == "--watch")
            }
            _ => false,
        },
        p if at == 0 && HARMLESS.contains(&p) => return Some(false),
        _ => return None,
    };
    wait.then_some(true)
}

fn quote(word: &str) -> String {
    let plain = !word.is_empty()
        && word.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,@%+#".contains(c));
    if plain { word.to_string() } else { format!("'{}'", word.replace('\'', r"'\''")) }
}

/// `command`, a harness background shell that ran `elapsed_ms`, as the daemon would run the rest
/// of it: exactly one wait (`sleep`, `tail --pid=P -f`, `glaeda-gh wait`, `acpmux pr-wait` or
/// `run-wait`, `gh run watch`, `gh pr checks --watch`, each maybe under `timeout`), with only
/// harmless commands around it and filters after it. `None` for anything else, or a wait about to
/// end on its own.
pub(super) fn plan(command: &str, elapsed_ms: u64) -> Option<String> {
    let toks = tokenize(command)?;
    let mut waits = 0;
    let mut out: Vec<String> = Vec::new();
    // Each pipeline: its commands, split by `|`; the first may wait, the rest filter.
    let mut words: Vec<String> = Vec::new();
    let mut in_pipe = false;
    let mut finish =
        |words: &mut Vec<String>, in_pipe: bool, out: &mut Vec<String>| -> Option<()> {
            if words.is_empty() {
                return None;
            }
            if in_pipe {
                if !words.first().is_some_and(|w| FILTERS.contains(&base(w))) {
                    return None;
                }
            } else if simple(words, elapsed_ms)? {
                waits += 1;
            }
            out.extend(words.drain(..).map(|w| quote(&w)));
            Some(())
        };
    for tok in toks {
        match tok {
            Tok::Word(w) => words.push(w),
            Tok::Pipe => {
                finish(&mut words, in_pipe, &mut out)?;
                out.push("|".into());
                in_pipe = true;
            }
            Tok::Sep(sep) => {
                finish(&mut words, in_pipe, &mut out)?;
                out.push(sep.into());
                in_pipe = false;
            }
        }
    }
    if !words.is_empty() {
        finish(&mut words, in_pipe, &mut out)?;
    } else if out.last().is_some_and(|s| s != ";") {
        return None;
    }
    drop(finish);
    (waits == 1).then(|| out.join(" ").trim_end_matches(" ;").to_string())
}

/// Whether `args`, a process under an idle harness that is none of its own, can be part of a
/// planned wait: a shell, or a program a wait runs (`python3 /x/glaeda-gh wait` by its script).
pub(super) fn covers(args: &str) -> bool {
    let mut words = args.split_whitespace();
    let Some(first) = words.next() else { return false };
    let first = base(first).trim_start_matches('-');
    SHELLS.contains(&first)
        || WAIT_PROGRAMS.contains(&first)
        || FILTERS.contains(&first)
        || std::iter::once(first).chain(words.map(base)).any(|w| WAIT_PROGRAMS.contains(&w))
}

impl Hub {
    /// Under `adaptive-v1`, the waits `session`'s running background shells would be handed to
    /// the daemon as: `None` when none runs, or any one is not a wait [`plan`] runs again.
    pub(super) fn wait_handoffs(&self, session: &Session) -> Option<Vec<Handoff>> {
        if self.idle_policy() != super::residency::IdlePolicyKind::AdaptiveV1 {
            return None;
        }
        let now = crate::store::now_ms();
        let running = self.running_commands(session);
        if running.is_empty() {
            return None;
        }
        running
            .into_iter()
            .map(|(command, cwd, description, started_at)| {
                let command = plan(&command, now.saturating_sub(started_at))?;
                Some(Handoff { command, cwd, description })
            })
            .collect()
    }

    /// Starts each of `handoffs` as a notify task of `session`, once its harness hibernated.
    pub(super) async fn start_handoffs(&self, session: &Arc<Session>, handoffs: Vec<Handoff>) {
        if handoffs.is_empty() {
            return;
        }
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        for h in handoffs {
            let description =
                Some(h.description.unwrap_or_else(|| "a wait its harness ran".into()));
            let cwd = Some(PathBuf::from(&h.cwd)).filter(|p| p.is_dir());
            match hub.bg_start(session, &h.command, cwd, description, true, false, None).await {
                Ok(_) => tracing::info!(
                    session = %session.id, command = %h.command,
                    "handed a harness wait to the daemon: it notifies the chat when it ends"
                ),
                Err(e) => tracing::warn!(
                    session = %session.id, command = %h.command, error = %e.message,
                    "a harness wait could not be handed to the daemon"
                ),
            }
        }
    }
}

#[cfg(test)]
#[path = "wait_handoff_tests.rs"]
mod tests;
