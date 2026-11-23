//! The owner's routes: the Auto machine, a chat's Auto flag, a chat started with no laptop, the
//! list, one chat, and keeping a chat in the Cloud.

use super::check;
use super::record::view_of;
use super::rules::{self, Step};
use super::store::{Caller, Chat, Message, Store, invalid, named};
use crate::chunks;
use crate::cloud::{AutoCloudError, CloudResult};
use crate::wire::{
    CreateRequest, Delivery, ErrorCode, MachineSetting, PutRequest, SessionList, SessionView,
};

/// How many chats a page of the list has when the caller names no limit, and at most.
const LIST_DEFAULT: u32 = 50;
const LIST_MAX: u32 = 100;

/// Where a chat stands in the list: by when it was made, then by id.
fn place(chat: &Chat) -> (u64, &str) {
    (chat.rec.created_at, chat.rec.id.as_str())
}

/// A page's cursor names its last chat. The real store's is opaque too, in another encoding.
fn cursor_of(last: &SessionView) -> String {
    format!("{}.{}", last.created_at, last.id)
}

fn read_cursor(cursor: &str) -> Option<(u64, String)> {
    let (at, id) = cursor.split_once('.')?;
    Some((at.parse().ok()?, id.to_owned()))
}

impl Store {
    pub fn machine(&self, caller: &Caller) -> CloudResult<MachineSetting> {
        self.owner_only(caller)?;
        self.machine.clone().ok_or_else(|| {
            AutoCloudError::http(404, ErrorCode::NoMachine.as_str(), "no Auto machine is set")
        })
    }

    /// Sets the Auto machine. The chats that waited for one go to it, oldest first, and so do
    /// the chats given to another machine that never picked them up.
    pub fn set_machine(
        &mut self,
        caller: &Caller,
        setting: &MachineSetting,
    ) -> CloudResult<MachineSetting> {
        self.owner_only(caller)?;
        if !check::team(&setting.team) {
            return Err(invalid("team: the team the machine belongs to"));
        }
        if !check::machine(&setting.machine) {
            return Err(invalid(
                "machine: the Cloud machine id (letters, digits, _ -, at most 64)",
            ));
        }
        self.machine = Some(setting.clone());
        let mut waiting: Vec<(u64, String)> =
            self.chats.values().map(|chat| (chat.rec.created_at, chat.rec.id.clone())).collect();
        waiting.sort();
        for (_, id) in waiting {
            // The rule refuses nothing, and the chat is there: there is no error to pass on.
            let _moved = self.apply(&id, |chat, _| {
                Ok(match rules::machine_set(&chat.rec, setting) {
                    Some(next) => Step::loud((), next),
                    None => Step::same(()),
                })
            });
        }
        Ok(setting.clone())
    }

    /// Switches Auto on or off for a chat. The first call makes it, held by the caller's laptop
    /// at epoch 1. Off closes the chat and drops its copy.
    pub fn put(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &PutRequest,
    ) -> CloudResult<SessionView> {
        named(id)?;
        self.owner_only(caller)?;
        if !request.auto {
            let closed = self.apply(id, |chat, _| {
                let step = rules::close(&chat.rec)?;
                if step.rec.is_some() {
                    chat.drop_copy();
                }
                Ok(step)
            });
            return closed.map(|((), view)| view);
        }
        if !check::title(&request.title) {
            return Err(invalid("title: the chat's title (at most 200 characters)"));
        }
        if !check::harness(&request.harness) {
            return Err(invalid(
                "harness: the agent the chat runs (lowercase letters, digits, _ . -, at most 32)",
            ));
        }
        if !check::device(&request.device) {
            return Err(invalid("device: this laptop's id (letters, digits, _ . -, at most 64)"));
        }
        if request.repo.as_ref().is_some_and(|repo| !check::repo(repo)) {
            return Err(invalid("repo: {remote, branch}"));
        }
        if !self.chats.contains_key(id) {
            // The owner's own team is not the fake's to know: the chat has none until a
            // machine takes it.
            let rec = rules::open_record(id, &self.owner, None, request, self.now);
            return Ok(self.insert(Chat::new(rec)));
        }
        self.apply(id, |chat, now| rules::edit(&chat.rec, request, now)).map(|((), view)| view)
    }

    /// A chat started with no laptop: the Auto machine holds it, with a `create` assignment.
    /// Its first message is message 1 of its inbox, and names the chat: the same request
    /// again answers the chat the first made.
    pub fn create(&mut self, caller: &Caller, request: &CreateRequest) -> CloudResult<SessionView> {
        self.owner_only(caller)?;
        if request.title.as_deref().is_some_and(|title| !check::title(title)) {
            return Err(invalid("title: the chat's title (at most 200 characters)"));
        }
        if !check::harness(&request.harness) {
            return Err(invalid(
                "harness: the agent the chat runs (lowercase letters, digits, _ . -, at most 32)",
            ));
        }
        if !check::repo(&request.repo) {
            return Err(invalid("repo: {remote, branch}, the repository and branch"));
        }
        let first = &request.first_message;
        if !check::message_id(&first.id) || !check::text(&first.text) {
            return Err(invalid("firstMessage: {id, text}, the chat's first message"));
        }
        let hash = chunks::name_of(format!("{}\0{}", self.owner, first.id).as_bytes());
        let id = format!("as_{}", hash.chars().take(20).collect::<String>());
        if let Some(seen) = self.view(&id) {
            return Ok(seen);
        }
        let Some(machine) = self.machine.clone() else {
            return Err(AutoCloudError::refused(ErrorCode::NoMachine, "no Auto machine is set"));
        };
        let now = self.now;
        let mut chat = Chat::new(rules::cloud_record(&id, &self.owner, &machine, request, now));
        chat.inbox.push(Message {
            n: 1,
            id: first.id.clone(),
            text: Some(first.text.clone()),
            state: Delivery::Resuming,
            at: now,
        });
        Ok(self.insert(chat))
    }

    /// One page of the owner's open chats, newest first. The cursor is the `next_cursor` of
    /// the page before.
    pub fn list(
        &self,
        caller: &Caller,
        limit: Option<u32>,
        cursor: Option<&str>,
    ) -> CloudResult<SessionList> {
        self.owner_only(caller)?;
        let before = match cursor {
            None | Some("") => None,
            Some(cursor) => Some(
                read_cursor(cursor)
                    .ok_or_else(|| invalid("cursor: use the nextCursor of the previous page"))?,
            ),
        };
        let limit = limit.unwrap_or(LIST_DEFAULT).clamp(1, LIST_MAX);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        let mut open: Vec<&Chat> = self.chats.values().filter(|chat| chat.rec.auto).collect();
        open.sort_by(|a, b| place(b).cmp(&place(a)));
        let mut rest = open.into_iter().filter(|chat| match &before {
            Some((at, id)) => place(chat) < (*at, id.as_str()),
            None => true,
        });
        let sessions: Vec<SessionView> =
            rest.by_ref().take(limit).map(|chat| view_of(&chat.rec, self.now)).collect();
        let more = rest.next().is_some();
        let next_cursor = sessions.last().filter(|_| more).map(cursor_of);
        Ok(SessionList { sessions, next_cursor })
    }

    pub fn get(&self, caller: &Caller, id: &str) -> CloudResult<SessionView> {
        self.admitted(caller, id, false).map(|chat| view_of(&chat.rec, self.now))
    }

    /// The chat as a `wait` answers it: the owner's route.
    pub fn waited(&self, caller: &Caller, id: &str) -> CloudResult<SessionView> {
        named(id)?;
        self.owner_only(caller)?;
        self.get(caller, id)
    }

    /// Keeps the chat in the Cloud (no handback), or stops keeping it.
    pub fn keep(
        &mut self,
        caller: &Caller,
        id: &str,
        keep_in_cloud: bool,
    ) -> CloudResult<SessionView> {
        named(id)?;
        self.owner_only(caller)?;
        self.apply(id, |chat, _| rules::keep(&chat.rec, keep_in_cloud)).map(|((), view)| view)
    }
}
