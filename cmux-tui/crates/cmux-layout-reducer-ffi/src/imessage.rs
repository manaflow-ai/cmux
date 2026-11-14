//! Local connector, called off-main inside cmux.app so its own TCC grant applies.
//! Never registered on the daemon, peer, CLI or MCP transports. There is no send op.
use cmux_imessage::{MirrorError, Reader};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    Status,
    Connect,
    Disconnect,
    SkipAutomation,
    Threads,
}

#[derive(Deserialize)]
struct Request {
    action: Action,
    database_path: PathBuf,
    enabled: bool,
    automation_skipped: bool,
    full_disk_access: bool,
    automation: bool,
}

#[derive(Default)]
struct Connection {
    opted_in: bool,
    automation_skipped: bool,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Status {
    NotConnected,
    NeedsFullDiskAccess,
    NeedsAutomation,
    Connected,
}

#[derive(Serialize)]
struct Thread {
    chat_id: i64,
    title: String,
    is_group: bool,
    participants: Vec<String>,
    last_activity: Option<i64>,
}

impl From<cmux_imessage::Thread> for Thread {
    fn from(thread: cmux_imessage::Thread) -> Self {
        Self {
            chat_id: thread.chat_id,
            title: thread.title,
            is_group: thread.is_group,
            participants: thread.participants,
            last_activity: thread.last_message.and_then(|message| message.date_ms),
        }
    }
}

#[derive(Serialize)]
struct Reply {
    status: Status,
    sends_enabled: bool,
    threads: Vec<Thread>,
    error: Option<&'static str>,
    setting_writes: Vec<SettingWrite>,
}

#[derive(Serialize)]
struct SettingWrite {
    key: &'static str,
    value: bool,
}

impl Connection {
    fn status(&self, disk: bool, automation: bool) -> Status {
        if !self.opted_in {
            Status::NotConnected
        } else if !disk {
            Status::NeedsFullDiskAccess
        } else if !automation && !self.automation_skipped {
            Status::NeedsAutomation
        } else {
            Status::Connected
        }
    }
}

pub(super) fn respond(bytes: &[u8]) -> Result<Vec<u8>, i32> {
    let request: Request = serde_json::from_slice(bytes).map_err(|_| super::ERR_INVALID)?;
    let reply = run(&request);
    serde_json::to_vec(&reply).map_err(|_| super::ERR_INVALID)
}

fn run(request: &Request) -> Reply {
    // These are the effective declared cmux settings, shared with the daemon. There is no
    // second opt-in file or process-local consent flag. Swift commits effects via its settings
    // writer and asks again with the resulting effective snapshot before replying to the page.
    let mut connection =
        Connection { opted_in: request.enabled, automation_skipped: request.automation_skipped };
    let mut setting_writes = Vec::new();
    match request.action {
        Action::Connect => {
            connection.opted_in = true;
            connection.automation_skipped = false;
            setting_writes.push(SettingWrite { key: "imessage.enabled", value: true });
            setting_writes.push(SettingWrite { key: "imessage.automationSkipped", value: false });
        }
        Action::Disconnect => {
            connection = Connection::default();
            setting_writes.push(SettingWrite { key: "imessage.enabled", value: false });
            setting_writes.push(SettingWrite { key: "imessage.automationSkipped", value: false });
        }
        Action::SkipAutomation if connection.opted_in && request.full_disk_access => {
            connection.automation_skipped = true;
            setting_writes.push(SettingWrite { key: "imessage.automationSkipped", value: true });
        }
        _ => (),
    }
    let mut reply = Reply {
        status: connection.status(request.full_disk_access, request.automation),
        sends_enabled: connection.opted_in && request.full_disk_access && request.automation,
        threads: Vec::new(),
        error: None,
        setting_writes,
    };
    // Status and Connect never open chat.db. Both opt-in and FDA precede every read.
    if !matches!(request.action, Action::Threads) || reply.status != Status::Connected {
        return reply;
    }
    match Reader::open(&request.database_path).and_then(|reader| reader.threads(500)) {
        Ok(threads) => {
            // Keep Reader's newest-first order. Message bodies never enter this surface.
            reply.threads = threads.into_iter().map(Thread::from).collect();
        }
        Err(MirrorError::NotPermitted(_)) => {
            reply.status = Status::NeedsFullDiskAccess;
            reply.sends_enabled = false;
        }
        Err(error) => reply.error = Some(error.code()),
    }
    reply
}

#[cfg(test)]
mod tests;
