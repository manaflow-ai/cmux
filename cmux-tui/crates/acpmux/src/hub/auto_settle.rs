//! Part of `Hub`; see `hub/mod.rs`. Settle a chat on its own: when its pull requests merge, when
//! they close, or after a number of idle days (Leo, 2026-11-18: "I know there's, like, the settle
//! chats feature or whatever").
//!
//! Settled is archived with a reason: the chat gets the `archived` tag (the one the chat menu's
//! Archive sets, `_acpmux/archive`; every list hides it, on every device that mirrors this
//! daemon) and [`SETTLED_TAG`] naming why (`merged`, `closed`, `idle`, or `manual` for `acpmux
//! session settle`). No second store: a plain Archive is a settle without a reason, and the
//! Settled shelf is the archived chats with [`SETTLED_TAG`].
//!
//! The rule runs here, in the daemon that owns the chat, so it covers every harness, chats
//! adopted from a terminal, and a Cloud machine's chats (its own daemon, with its own settings
//! file). Settings (all off by default): `agents.autoSettle.onMerge`, `agents.autoSettle.onClose`
//! and `agents.autoSettle.idleDays` (0: never). A chat tagged [`OVERRIDE_TAG`]=`never` is left
//! alone whatever they say.
//!
//! - Pull requests: the ones the chat opened (`SessionMeta::pull_requests`). Once every one of
//!   them is merged or closed, it settles `merged` if any merged (with onMerge), else `closed`
//!   (with onClose). Their state is GitHub's, read with this machine's `gh` ([`read_pr`]) at most
//!   every [`PR_RECHECK_MS`] while one is open; a merged one is never read again. A session's own
//!   `gh pr merge` or `gh pr close` reads it again at once (`permissions.rs`, [`pr_changed`]).
//! - Idle: no record in its log for `idleDays` days (`SessionMeta::updated_at`).
//! - Never while it works: a turn, a queued prompt, a permission or question, a background
//!   subagent, sub-session, harness process or daemon task (a PR wait, a watch), or someone
//!   typing or holding a draft in it ([`Hub::settle_blocked`]). It is tried again after
//!   [`BLOCKED_RECHECK_MS`].
//! - Un-settle: Unarchive (`_acpmux/archive` false, the toast's Undo, `acpmux session
//!   unsettle`) or the person's own prompt into it (`server/agent_messages.rs`); an agent's
//!   message or a trigger's never does. It then carries [`UNSETTLED_TAG`] with the number of pull
//!   requests it had, so the same merged pull requests do not settle it again; a new one does.
//!   Its idle days count again from the un-settle (a log record).
//!
//! The timer: one task ([`Hub::auto_settle_loop`]). With every setting off it sets no timer and
//! waits for the settings watch. On, it makes one pass over the live chats, then sleeps until the
//! first idle deadline, the next pull request read, or a blocked chat's retry, whichever comes
//! first; a settings change or [`pr_changed`] ends the sleep early. It ends with the daemon.

use super::*;
use std::sync::LazyLock;

pub const SETTING_ON_MERGE: &str = "agents.autoSettle.onMerge";
pub const SETTING_ON_CLOSE: &str = "agents.autoSettle.onClose";
pub const SETTING_IDLE_DAYS: &str = "agents.autoSettle.idleDays";
/// Why a chat settled (`merged`, `closed`, `idle`, `manual`); only on a settled chat.
pub(crate) const SETTLED_TAG: &str = "settled";
/// A chat's own override: [`NEVER`] keeps the rule off it.
pub(crate) const OVERRIDE_TAG: &str = "autoSettle";
pub(crate) const NEVER: &str = "never";
/// Set when a settled chat is un-settled: how many pull requests it had then.
pub(crate) const UNSETTLED_TAG: &str = "unsettled";
const ARCHIVED_TAG: &str = super::plan_build::ARCHIVED_TAG;

const IDLE_DAYS_MAX: u64 = 365;
const DAY_MS: u64 = 24 * 60 * 60 * 1000;
/// How long an open pull request's read stays fresh.
pub(crate) const PR_RECHECK_MS: u64 = 10 * 60 * 1000;
/// When a chat due to settle but busy is looked at again.
pub(crate) const BLOCKED_RECHECK_MS: u64 = 10 * 60 * 1000;
/// The most pull requests one pass reads; the rest wait for the next.
const PR_READS_PER_PASS: usize = 30;
/// One `gh` read's bound.
const GH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
/// A pass that read a pull request that closed runs again this soon, to settle its chat.
const AFTER_READ_MS: u64 = 1_000;

/// The settings as the daemon reads them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Rules {
    pub on_merge: bool,
    pub on_close: bool,
    /// `idleDays` in ms; None when 0 or unset.
    pub idle_ms: Option<u64>,
}

impl Rules {
    pub(crate) fn any(&self) -> bool {
        self.on_merge || self.on_close || self.idle_ms.is_some()
    }

    fn pull_requests(&self) -> bool {
        self.on_merge || self.on_close
    }
}

/// The settings document's rules: all off for a missing or unreadable file.
pub(crate) fn rules(doc: Option<&Value>) -> Rules {
    let Some(doc) = doc else { return Rules::default() };
    let get = |key: &str| crate::user_settings::value(doc, key);
    let on = |key: &str| get(key).and_then(|v| v.as_bool()) == Some(true);
    let days = get(SETTING_IDLE_DAYS)
        .and_then(|v| v.as_f64())
        .filter(|n| n.is_finite() && *n >= 1.0)
        .map(|n| (n as u64).min(IDLE_DAYS_MAX));
    Rules {
        on_merge: on(SETTING_ON_MERGE),
        on_close: on(SETTING_ON_CLOSE),
        idle_ms: days.map(|d| d * DAY_MS),
    }
}

fn read_rules() -> Rules {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => rules(Some(&doc)),
        _ => Rules::default(),
    }
}

/// Why a chat settled, as [`SETTLED_TAG`] says it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    Merged,
    Closed,
    Idle,
    Manual,
}

impl Reason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Merged => "merged",
            Self::Closed => "closed",
            Self::Idle => "idle",
            Self::Manual => "manual",
        }
    }
}

/// A pull request's state on GitHub.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PrState {
    Open,
    Merged,
    Closed,
}

/// What the rule reads of one chat.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Facts {
    pub archived: bool,
    pub never: bool,
    /// [`UNSETTLED_TAG`]'s pull request count.
    pub held_at: Option<usize>,
    pub pull_requests: Vec<String>,
    /// The newest log record's time (Unix ms).
    pub last_activity_ms: u64,
}

impl Facts {
    pub(crate) fn of(m: &SessionMeta) -> Self {
        let now = now_ms();
        let tag = |k: &str| {
            m.tags.get(k).filter(|t| t.expires_at.is_none_or(|e| e > now)).map(|t| t.value.as_str())
        };
        Self {
            archived: tag(ARCHIVED_TAG).is_some(),
            never: tag(OVERRIDE_TAG) == Some(NEVER),
            held_at: tag(UNSETTLED_TAG).and_then(|v| v.parse().ok()),
            pull_requests: m.pull_requests.clone(),
            last_activity_ms: m.updated_at,
        }
    }

    /// Whether its pull requests may settle it: it has some, and more than an un-settle held.
    fn pull_requests_count(&self, rules: &Rules) -> bool {
        rules.pull_requests()
            && !self.pull_requests.is_empty()
            && self.held_at.is_none_or(|n| self.pull_requests.len() > n)
    }

    fn eligible(&self, rules: &Rules) -> bool {
        rules.any() && !self.archived && !self.never
    }
}

/// Whether, and why, a chat settles now, with `state` the known state of a pull request.
pub(crate) fn decide(
    rules: &Rules,
    facts: &Facts,
    state: impl Fn(&str) -> Option<PrState>,
    now_ms: u64,
) -> Option<Reason> {
    if !facts.eligible(rules) {
        return None;
    }
    if facts.pull_requests_count(rules) {
        let states: Option<Vec<PrState>> = facts.pull_requests.iter().map(|u| state(u)).collect();
        if let Some(states) = states.filter(|s| !s.contains(&PrState::Open)) {
            if states.contains(&PrState::Merged) {
                if rules.on_merge {
                    return Some(Reason::Merged);
                }
            } else if rules.on_close {
                return Some(Reason::Closed);
            }
        }
    }
    let idle = rules.idle_ms?;
    (now_ms >= facts.last_activity_ms.saturating_add(idle)).then_some(Reason::Idle)
}

/// When the chat's idle days end, if the idle rule is on and it may settle.
pub(crate) fn idle_due_at(rules: &Rules, facts: &Facts) -> Option<u64> {
    if !facts.eligible(rules) {
        return None;
    }
    rules.idle_ms.map(|idle| facts.last_activity_ms.saturating_add(idle))
}

/// The chat's pull requests whose state the rule still needs: none known yet, or open.
pub(crate) fn to_read<'a>(
    rules: &Rules,
    facts: &'a Facts,
    state: impl Fn(&str) -> Option<PrState>,
) -> Vec<&'a str> {
    if !facts.eligible(rules) || !facts.pull_requests_count(rules) {
        return vec![];
    }
    facts
        .pull_requests
        .iter()
        .map(String::as_str)
        .filter(|u| state(u).is_none_or(|s| s == PrState::Open))
        .collect()
}

/// `owner/repo` and the number of a pull request's URL.
pub(crate) fn pr_path(url: &str) -> Option<(String, u64)> {
    let rest = url.strip_prefix("https://github.com/")?;
    let mut parts = rest.split('/');
    let (owner, repo, pull, n) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    let n = n.parse().ok().filter(|_| pull == "pull" && parts.next().is_none())?;
    let ok = |s: &str| {
        !s.is_empty()
            && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    (ok(owner) && ok(repo)).then(|| (format!("{owner}/{repo}"), n))
}

/// What [`read_pr`]'s `gh api` prints (`STATE MERGED`, e.g. `closed true`) as a state.
pub(crate) fn parse_state(out: &str) -> Option<PrState> {
    let mut words = out.split_whitespace();
    match (words.next()?, words.next()?) {
        ("open", _) => Some(PrState::Open),
        ("closed", "true") => Some(PrState::Merged),
        ("closed", "false") => Some(PrState::Closed),
        _ => None,
    }
}

/// One pull request's state, read with this machine's `gh` (on a lane VM, its broker). None when
/// gh is missing, refused, slow or printed something else: the next pass tries again.
async fn read_pr(url: &str) -> Option<PrState> {
    let (repo, n) = pr_path(url)?;
    let mut gh = tokio::process::Command::new("gh");
    gh.args(["api", &format!("repos/{repo}/pulls/{n}"), "--jq", r#""\(.state) \(.merged)""#])
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let out = tokio::time::timeout(GH_TIMEOUT, gh.output()).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    parse_state(&String::from_utf8_lossy(&out.stdout))
}

/// What the last reads said, by URL: the state and when it was read (Unix ms).
static PR_STATES: LazyLock<StdMutex<HashMap<String, (PrState, u64)>>> =
    LazyLock::new(Default::default);
/// Ends the timer's sleep: a pull request a session merged or closed.
static WAKE: LazyLock<tokio::sync::Notify> = LazyLock::new(tokio::sync::Notify::new);

fn known(url: &str) -> Option<PrState> {
    PR_STATES.lock().unwrap_or_else(|e| e.into_inner()).get(url).map(|(s, _)| *s)
}

/// Whether `url` is due a read at `now`: never read, or open and read [`PR_RECHECK_MS`] ago.
fn read_due(url: &str, now: u64) -> bool {
    match PR_STATES.lock().unwrap_or_else(|e| e.into_inner()).get(url) {
        None => true,
        Some((PrState::Merged, _)) => false,
        Some((_, at)) => now >= at.saturating_add(PR_RECHECK_MS),
    }
}

/// A session's `gh pr merge` or `gh pr close` named `url`: it is read again at the next pass,
/// which starts now.
pub(crate) fn pr_changed(url: &str) {
    PR_STATES.lock().unwrap_or_else(|e| e.into_inner()).remove(url);
    WAKE.notify_one();
}

/// Tests: what GitHub says of `url`.
#[cfg(test)]
pub(crate) fn set_known(url: &str, state: PrState) {
    PR_STATES.lock().unwrap_or_else(|e| e.into_inner()).insert(url.to_owned(), (state, now_ms()));
}

impl Hub {
    /// Settles chats by the settings until the daemon shuts down (module docs).
    pub async fn auto_settle_loop(hub: std::sync::Weak<Hub>) {
        let Some(mut settings) = hub.upgrade().map(|h| h.settings_changes.subscribe()) else {
            return;
        };
        let mut was = Rules::default();
        loop {
            let Some(h) = hub.upgrade() else { return };
            if h.shutting_down() {
                return;
            }
            settings.borrow_and_update();
            let rules = tokio::task::spawn_blocking(read_rules).await.unwrap_or_default();
            if rules != was {
                was = rules;
                tracing::info!(?rules, "auto-settle");
            }
            if !rules.any() {
                drop(h);
                // No timer while off: the next settings change, or the hub's end.
                if settings.changed().await.is_err() {
                    return;
                }
                continue;
            }
            let wait = if h.startup_settled() {
                h.auto_settle_pass(&rules).await
            } else {
                std::time::Duration::from_secs(30)
            };
            drop(h);
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                changed = settings.changed() => if changed.is_err() { return },
                _ = WAKE.notified() => {}
            }
        }
    }

    /// One pass: settles each live chat that is due and not busy, reads the pull requests the
    /// rule still needs, and answers how long until the next pass.
    pub(crate) async fn auto_settle_pass(&self, rules: &Rules) -> std::time::Duration {
        let now = now_ms();
        let mut next: Option<u64> = None;
        let mut soon = |at: u64| next = Some(next.map_or(at, |n| n.min(at)));
        let mut reads: Vec<String> = vec![];
        for session in self.live_session_handles() {
            let facts = session.read_meta(Facts::of);
            if !facts.eligible(rules) {
                continue;
            }
            if let Some(reason) = decide(rules, &facts, known, now) {
                if self.settle_blocked(&session) {
                    soon(now + BLOCKED_RECHECK_MS);
                } else if let Err(e) = self.settle(&session, reason) {
                    tracing::warn!(session = %session.id, error = ?e, "auto-settle not saved");
                }
                continue;
            }
            if let Some(at) = idle_due_at(rules, &facts) {
                soon(at);
            }
            for url in to_read(rules, &facts, known) {
                soon(now + PR_RECHECK_MS);
                if read_due(url, now) && !reads.iter().any(|r| r == url) {
                    reads.push(url.to_owned());
                }
            }
        }
        let mut settled_some = false;
        for url in reads.into_iter().take(PR_READS_PER_PASS) {
            let Some(state) = read_pr(&url).await else {
                // Unreadable: kept as unknown, read again after the recheck.
                PR_STATES
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .entry(url)
                    .or_insert((PrState::Open, now));
                continue;
            };
            settled_some |= state != PrState::Open;
            PR_STATES.lock().unwrap_or_else(|e| e.into_inner()).insert(url, (state, now_ms()));
        }
        if settled_some {
            soon(now + AFTER_READ_MS);
        }
        let wait = next.map_or(PR_RECHECK_MS, |at| at.saturating_sub(now_ms()).max(AFTER_READ_MS));
        std::time::Duration::from_millis(wait)
    }

    /// Whether `session` is at work, so it does not settle now (module docs).
    pub(crate) fn settle_blocked(&self, session: &Session) -> bool {
        let idle = self.idle_eligible(session) && session.turn_lock.try_lock().is_ok();
        let presence = self.presence.snapshot(&session.id);
        let typing = presence.get("participants").and_then(Value::as_array).is_some_and(|people| {
            people.iter().any(|p| p.get("typing").and_then(Value::as_bool) == Some(true))
        });
        let draft = session
            .read_meta(|m| m.composer_draft.as_deref().is_some_and(|d| !d.trim().is_empty()))
            || session.composers.lock().unwrap_or_else(|e| e.into_inner()).any_draft();
        !idle || typing || draft || self.bg_running(session)
    }

    /// Settles `session` for `reason`: archived, with why.
    pub(crate) fn settle(&self, session: &Session, reason: Reason) -> Result<(), RpcError> {
        let mut set = serde_json::Map::new();
        set.insert(ARCHIVED_TAG.into(), Value::String(now_ms().to_string()));
        set.insert(SETTLED_TAG.into(), Value::String(reason.as_str().into()));
        tracing::info!(session = %session.id, reason = reason.as_str(), "chat settled");
        self.set_tags_answered(session, Some(&set), &[UNSETTLED_TAG.to_owned()], None)
    }

    /// Unarchives `session`; a settled one also loses its reason and keeps how many pull
    /// requests it had, so they do not settle it again (module docs).
    pub(crate) fn unarchive(&self, session: &Session) -> Result<(), RpcError> {
        let (settled, prs) =
            session.read_meta(|m| (m.tags.contains_key(SETTLED_TAG), m.pull_requests.len()));
        if !settled {
            return self.set_tags_answered(session, None, &[ARCHIVED_TAG.to_owned()], None);
        }
        let mut set = serde_json::Map::new();
        set.insert(UNSETTLED_TAG.into(), Value::String(prs.to_string()));
        let remove = [ARCHIVED_TAG.to_owned(), SETTLED_TAG.to_owned()];
        self.set_tags_answered(session, Some(&set), &remove, None)
    }

    /// The person's own prompt reached `session`: a settled chat comes back.
    pub(crate) fn unsettle_on_person_prompt(&self, session: &Session) {
        if session.read_meta(|m| m.tags.contains_key(SETTLED_TAG))
            && let Err(e) = self.unarchive(session)
        {
            tracing::warn!(session = %session.id, error = ?e, "un-settle not saved");
        }
    }
}

#[cfg(test)]
#[path = "auto_settle_tests.rs"]
mod tests;
