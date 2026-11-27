//! A moved chat's file and secret requests for this Mac (cmuxterm-hq#1874 slice 6): the app's
//! `CloudAccessAsks` polls `cmux link access triage` per machine and shows each ask left as a card in
//! that chat's tab, and its `CloudAccessRevokes` ends the grants of chats brought back. The app runs
//! the CLI, reads the machines and draws the cards; this keeps the bookkeeping around them: which
//! revoke runs when, how long a failing machine waits, which listed asks a running or finished answer
//! hides, and which cards a tab shows.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The longest a failing revoke waits before its next try.
pub const REVOKE_LONGEST_BACKOFF_MS: u64 = 300_000;
/// The first wait after a failed revoke, unless the app's poll interval says otherwise.
pub const REVOKE_FIRST_BACKOFF_MS: u64 = 3_000;
/// The longest a machine whose triage fails waits.
pub const TRIAGE_LONGEST_BACKOFF_MS: u64 = 120_000;
/// How long a machine without access requests (an older image) waits.
pub const TRIAGE_UNAVAILABLE_BACKOFF_MS: u64 = 600_000;
/// The triage error code of a machine without access requests.
pub const UNAVAILABLE_CODE: &str = "access_request.unavailable";
/// The most cards a chat shows (`AgentPaneToolCard.maximumShown`).
pub const MAXIMUM_SHOWN: usize = 4;

/// A wait after a failure: until when, and how long it was (the next one doubles it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Backoff {
    pub until_ms: u64,
    pub delay_ms: u64,
}

impl Backoff {
    fn holds(&self, now_ms: u64) -> bool {
        now_ms < self.until_ms
    }
}

/// A moved chat: its machine and its session.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    pub machine_id: String,
    pub session: String,
}

/// One chat's running answers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answering {
    pub chat: Chat,
    pub count: u32,
}

/// One chat's wait after a failed revoke.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatBackoff {
    pub chat: Chat,
    #[serde(flatten)]
    pub backoff: Backoff,
}

/// The grants to end of chats brought back from a Cloud machine: each runs `cmux link access revoke
/// --all` until it answers ok, waiting longer after each failure. A chat with an answer still
/// running waits for it, and an answer that ends after its chat left the machine revokes again.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Revokes {
    #[serde(default)]
    pub pending: BTreeSet<Chat>,
    #[serde(default)]
    pub running: BTreeSet<Chat>,
    /// Revoked in this run of the app: a ledger entry still marked brought back isn't revoked again.
    #[serde(default)]
    pub done: BTreeSet<Chat>,
    #[serde(default)]
    pub answering: Vec<Answering>,
    #[serde(default)]
    pub backoff: Vec<ChatBackoff>,
}

impl Revokes {
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub fn add(&mut self, chat: Chat) {
        if !self.done.contains(&chat) {
            self.pending.insert(chat);
        }
    }

    fn answering_index(&self, chat: &Chat) -> Option<usize> {
        self.answering.iter().position(|entry| entry.chat == *chat)
    }

    fn backoff_of(&self, chat: &Chat) -> Option<Backoff> {
        self.backoff.iter().find(|entry| entry.chat == *chat).map(|entry| entry.backoff)
    }

    fn clear_backoff(&mut self, chat: &Chat) {
        self.backoff.retain(|entry| entry.chat != *chat);
    }

    /// An answer for `chat` starts: its revoke waits until it ends.
    pub fn answer_started(&mut self, chat: Chat) {
        match self.answering_index(&chat) {
            Some(index) => self.answering[index].count += 1,
            None => self.answering.push(Answering { chat, count: 1 }),
        }
    }

    /// An answer for `chat` ended; when the chat is no longer on its machine (`live` false), what it
    /// may have granted is revoked again.
    pub fn answer_ended(&mut self, chat: Chat, live: bool) {
        if let Some(index) = self.answering_index(&chat) {
            if self.answering[index].count > 1 {
                self.answering[index].count -= 1;
            } else {
                self.answering.remove(index);
            }
        }
        if live {
            return;
        }
        self.done.remove(&chat);
        self.clear_backoff(&chat);
        self.pending.insert(chat);
    }

    /// Whether `chat`'s revoke may start now: pending, not running, no answer running, no wait.
    /// The app asks again after its own await (the machine's link), since another run may have
    /// taken it meanwhile.
    pub fn may_run(&self, chat: &Chat, now_ms: u64) -> bool {
        self.pending.contains(chat)
            && !self.running.contains(chat)
            && self.answering_index(chat).is_none()
            && !self.backoff_of(chat).is_some_and(|wait| wait.holds(now_ms))
    }

    /// The revokes a run tries, in order (by machine, then session).
    pub fn due(&self, now_ms: u64) -> Vec<Chat> {
        self.pending.iter().filter(|chat| self.may_run(chat, now_ms)).cloned().collect()
    }

    pub fn run_started(&mut self, chat: Chat) {
        self.running.insert(chat);
    }

    /// `chat`'s revoke answered `ok`; a failure waits `first_backoff_ms` (the app's poll interval),
    /// then twice as long each time, at most [`REVOKE_LONGEST_BACKOFF_MS`].
    pub fn run_ended(&mut self, chat: Chat, ok: bool, now_ms: u64, first_backoff_ms: u64) {
        self.running.remove(&chat);
        if ok {
            self.pending.remove(&chat);
            self.clear_backoff(&chat);
            self.done.insert(chat);
            return;
        }
        let delay_ms = self
            .backoff_of(&chat)
            .map_or(first_backoff_ms, |wait| wait.delay_ms.saturating_mul(2))
            .min(REVOKE_LONGEST_BACKOFF_MS);
        self.clear_backoff(&chat);
        self.backoff.push(ChatBackoff {
            chat,
            backoff: Backoff { until_ms: now_ms.saturating_add(delay_ms), delay_ms },
        });
    }
}

/// The asks' bookkeeping (the app keeps the asks themselves, their cards and its loop).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Asks {
    /// Requests whose answer is running.
    #[serde(default)]
    pub answering: BTreeSet<String>,
    /// Requests answered, with the triage count when their answer ended: a triage that began by
    /// then may still list them, so it shows them no more.
    #[serde(default)]
    pub answered: BTreeMap<String, u64>,
    #[serde(default)]
    pub triages: u64,
    /// Machines whose triage failed, by machine id.
    #[serde(default)]
    pub backoff: BTreeMap<String, Backoff>,
    /// When each machine's granted folders were last copied again.
    #[serde(default)]
    pub last_sync_ms: BTreeMap<String, u64>,
}

/// What one poll round does before any triage.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum Poll {
    /// No moved chat and nothing to revoke (or no CLI): the loop ends; a move starts it again.
    Stop,
    /// No moved chat, or Cloud is turned off by the organization: no request goes out, the cards
    /// go, and the loop waits.
    #[serde(rename_all = "camelCase")]
    Clear { wait_ms: u64 },
    /// Triage each machine's chats.
    Triage,
}

/// One poll round's start, read after the revokes ran (with no await before a stop: a move
/// recorded meanwhile keeps the loop going).
pub fn poll(
    has_cli: bool,
    moved_chats: usize,
    cloud_disabled: bool,
    revokes_empty: bool,
    poll_ms: u64,
) -> Poll {
    if !has_cli {
        return Poll::Stop;
    }
    if moved_chats == 0 || cloud_disabled {
        return if moved_chats == 0 && revokes_empty {
            Poll::Stop
        } else {
            Poll::Clear { wait_ms: poll_ms }
        };
    }
    Poll::Triage
}

/// What a machine does in a triage round.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum Machine {
    /// Still waiting after a failure: its tabs keep the asks they had.
    Keep,
    /// Triage it; `sync` first copies each chat's granted folders again.
    Triage { sync: bool },
}

impl Asks {
    /// A triage round begins: its count.
    pub fn begin_triage(&mut self) -> u64 {
        self.triages += 1;
        self.triages
    }

    /// What machine `machine_id` does this round (`sync_ms`: how often folders are copied again).
    /// A sync is noted as done now.
    pub fn machine(&mut self, machine_id: &str, now_ms: u64, sync_ms: u64) -> Machine {
        if self.backoff.get(machine_id).is_some_and(|wait| wait.holds(now_ms)) {
            return Machine::Keep;
        }
        let sync = self
            .last_sync_ms
            .get(machine_id)
            .is_none_or(|last| now_ms.saturating_sub(*last) >= sync_ms);
        if sync {
            self.last_sync_ms.insert(machine_id.to_owned(), now_ms);
        }
        Machine::Triage { sync }
    }

    /// Machine `machine_id`'s triage failed with `code`: its cards stay as they were and it is asked
    /// less often (twice the last wait, from the poll interval, at most
    /// [`TRIAGE_LONGEST_BACKOFF_MS`]); a machine with no access requests much less.
    pub fn triage_failed(
        &mut self,
        machine_id: &str,
        code: Option<&str>,
        now_ms: u64,
        poll_ms: u64,
    ) -> u64 {
        let delay_ms = if code == Some(UNAVAILABLE_CODE) {
            TRIAGE_UNAVAILABLE_BACKOFF_MS
        } else {
            self.backoff
                .get(machine_id)
                .map_or(poll_ms, |wait| wait.delay_ms)
                .saturating_mul(2)
                .min(TRIAGE_LONGEST_BACKOFF_MS)
        };
        self.backoff.insert(
            machine_id.to_owned(),
            Backoff { until_ms: now_ms.saturating_add(delay_ms), delay_ms },
        );
        delay_ms
    }

    pub fn triage_ok(&mut self, machine_id: &str) {
        self.backoff.remove(machine_id);
    }

    /// The round's asks (request ids by tab) as the tabs show them: without those answering, and
    /// without those answered after triage `triage` began. Checked after every await: a triage that
    /// began before an answer ended may list it still; one that began after shows it again. Tabs
    /// left with none drop out.
    pub fn listed(
        &mut self,
        triage: u64,
        next: BTreeMap<String, Vec<String>>,
    ) -> BTreeMap<String, Vec<String>> {
        let next: BTreeMap<String, Vec<String>> = next
            .into_iter()
            .map(|(tab, list)| {
                let list: Vec<String> = list
                    .into_iter()
                    .filter(|id| {
                        !self.answering.contains(id)
                            && self.answered.get(id).is_none_or(|ended| triage > *ended)
                    })
                    .collect();
                (tab, list)
            })
            .collect();
        for id in next.values().flatten() {
            self.answered.remove(id);
        }
        self.answered.retain(|_, ended| *ended >= triage);
        next.into_iter().filter(|(_, list)| !list.is_empty()).collect()
    }

    /// The person answered request `id`: its card goes while the answer runs.
    pub fn answer_started(&mut self, id: String) {
        self.answering.insert(id);
    }

    /// Request `id`'s answer ended: the triages that began by now show it no more.
    pub fn answer_ended(&mut self, id: &str) {
        self.answering.remove(id);
        self.answered.insert(id.to_owned(), self.triages);
    }
}

/// Whether a finished answer leaves a failure card: a failure, unless the request changed or went
/// (the next triage shows it again as it is now, if it still waits).
pub fn answer_failure_shows(ok: bool, code: Option<&str>) -> bool {
    !ok && !matches!(code, Some("request_changed" | "request_gone"))
}

/// One listed ask of a tab: its request id and whether its chat is still on its machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Listed {
    pub id: String,
    pub live: bool,
}

/// A tab's cards, by request id (`render`): its live asks with no answer running, then one failed
/// answer (`failures`, already only those still live), at most [`MAXIMUM_SHOWN`]. Live asks
/// first: a failed answer's card never pushes one past the cap.
pub fn cards(asks: &Asks, listed: &[Listed], failures: &[String]) -> Vec<String> {
    listed
        .iter()
        .filter(|ask| ask.live && !asks.answering.contains(&ask.id))
        .map(|ask| ask.id.clone())
        .chain(failures.iter().take(1).cloned())
        .take(MAXIMUM_SHOWN)
        .collect()
}

#[cfg(test)]
#[path = "access_tests.rs"]
mod tests;
