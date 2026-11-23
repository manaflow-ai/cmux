//! The owner's routes: the Auto machine, a chat's Auto flag, a chat started with no laptop, the
//! list, one chat, and keeping a chat in the Cloud.

use super::store::{Caller, Chat, Store, invalid, not_found, refused};
use crate::cloud::{AutoCloudError, CloudResult};
use crate::wire::{
    AssignmentKind, CreateRequest, ErrorCode, Holder, InboxMessage, MachineSetting, PutRequest,
    SessionList, SessionView,
};

/// How many chats a page of the list has when the caller names no limit, and at most.
const LIST_DEFAULT: u32 = 50;
const LIST_MAX: u32 = 200;

impl Store {
    pub fn machine(&self, caller: &Caller) -> CloudResult<MachineSetting> {
        self.owner_only(caller)?;
        self.machine.clone().ok_or_else(|| {
            AutoCloudError::http(404, ErrorCode::NoMachine.as_str(), "no Auto machine is set")
        })
    }

    /// Sets the Auto machine. The parked chats that waited for one go to it.
    pub fn set_machine(
        &mut self,
        caller: &Caller,
        setting: &MachineSetting,
    ) -> CloudResult<MachineSetting> {
        self.owner_only(caller)?;
        if setting.team.is_empty() || setting.machine.is_empty() {
            return Err(invalid("team and machine are required"));
        }
        self.team = setting.team.clone();
        self.machine = Some(setting.clone());
        let now = self.now;
        for id in self.order.clone() {
            if self.settle(&id)
                && let Some(chat) = self.chats.get_mut(&id)
            {
                chat.touch(now);
            }
        }
        self.wake();
        Ok(setting.clone())
    }

    /// Switches Auto on or off for a chat. The first call makes it, held by the caller's laptop
    /// at epoch 1.
    pub fn put(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &PutRequest,
    ) -> CloudResult<SessionView> {
        self.owner_only(caller)?;
        if id.is_empty() || request.device.is_empty() {
            return Err(invalid("a session id and a device are required"));
        }
        let me = Holder::device(request.device.clone());
        if !self.chats.contains_key(id) {
            if !request.auto {
                return Err(not_found());
            }
            let mut chat = Chat::new(id, me, self.now);
            describe(&mut chat, request);
            self.order.push(id.to_owned());
            self.chats.insert(id.to_owned(), chat);
            self.wake();
            return self.answer(id);
        }
        self.change(id, |chat, now| {
            if !request.auto {
                if chat.auto && chat.holder.is_vm() {
                    return Err(refused(ErrorCode::HeldInCloud, "a Cloud machine runs this chat"));
                }
                chat.auto = false;
                chat.needs_run = false;
                chat.blocked = None;
                chat.standby.clear();
                return Ok(());
            }
            // Auto switched on again: the chat is this laptop's, at a new epoch.
            if !chat.auto {
                chat.auto = true;
                chat.hand_to(me, now);
            }
            describe(chat, request);
            Ok(())
        })
    }

    /// A chat started with no laptop: the Auto machine holds it, with a `create` assignment.
    /// Its first message is message 1 of its inbox.
    pub fn create(&mut self, caller: &Caller, request: &CreateRequest) -> CloudResult<SessionView> {
        self.owner_only(caller)?;
        if request.harness.is_empty() || request.first_message.id.is_empty() {
            return Err(invalid("a harness and a first message are required"));
        }
        let Some(auto) = self.machine.clone() else {
            return Err(refused(ErrorCode::NoMachine, "no Auto machine is set"));
        };
        let now = self.now;
        self.made = self.made.saturating_add(1);
        let id = format!("auto-{}", self.made);
        let mut chat = Chat::new(&id, Holder::vm(auto.machine.clone()), now);
        chat.title = request.title.clone().unwrap_or_default();
        chat.harness = request.harness.clone();
        chat.repo = Some(request.repo.clone());
        chat.assignment = Some(AssignmentKind::Create);
        chat.inbox.push(InboxMessage {
            n: 1,
            id: request.first_message.id.clone(),
            text: request.first_message.text.clone(),
            at: now,
        });
        self.starts.push(auto.machine);
        self.order.push(id.clone());
        self.chats.insert(id.clone(), chat);
        self.wake();
        self.answer(&id)
    }

    /// One page of the owner's chats, oldest first. The cursor is the last id of the page
    /// before.
    pub fn list(
        &self,
        caller: &Caller,
        limit: Option<u32>,
        cursor: Option<&str>,
    ) -> CloudResult<SessionList> {
        self.owner_only(caller)?;
        let limit = limit.unwrap_or(LIST_DEFAULT).clamp(1, LIST_MAX);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        let start = match cursor {
            None => 0,
            Some(cursor) => {
                let at = self.order.iter().position(|id| id == cursor);
                at.ok_or_else(|| invalid("no such cursor"))?.saturating_add(1)
            }
        };
        let mut rest = self.order.iter().skip(start).filter_map(|id| self.chats.get(id));
        let sessions: Vec<SessionView> =
            rest.by_ref().take(limit).map(|chat| self.view(chat)).collect();
        let more = rest.next().is_some();
        let next_cursor = sessions.last().filter(|_| more).map(|last| last.id.clone());
        Ok(SessionList { sessions, next_cursor })
    }

    pub fn get(&self, caller: &Caller, id: &str) -> CloudResult<SessionView> {
        self.read(caller, id).map(|chat| self.view(chat))
    }

    /// Keeps the chat in the Cloud (no handback), or stops keeping it.
    pub fn keep(
        &mut self,
        caller: &Caller,
        id: &str,
        keep_in_cloud: bool,
    ) -> CloudResult<SessionView> {
        self.owner_only(caller)?;
        self.change(id, |chat, _| {
            chat.open()?;
            chat.keep_in_cloud = keep_in_cloud;
            Ok(())
        })
    }
}

/// What a `PUT` says about the chat besides its Auto flag.
fn describe(chat: &mut Chat, request: &PutRequest) {
    chat.title = request.title.clone();
    chat.harness = request.harness.clone();
    if let Some(keep_in_cloud) = request.keep_in_cloud {
        chat.keep_in_cloud = keep_in_cloud;
    }
    if let Some(repo) = &request.repo {
        chat.repo = Some(repo.clone());
    }
}
