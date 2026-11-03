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
mod tests {
    use super::*;

    #[test]
    fn imessage_connector_never_exposes_message_previews() {
        let metadata = Thread::from(cmux_imessage::Thread {
            chat_id: 1,
            guid: "private-guid".into(),
            title: "Dinner".into(),
            display_name: Some("Dinner".into()),
            is_group: true,
            service: None,
            participants: vec!["maya@example.test".into()],
            last_message: Some(cmux_imessage::ThreadPreview {
                rowid: 2,
                text: Some("private message body".into()),
                is_from_me: false,
                sender: Some("private sender".into()),
                date_ms: Some(1234),
                has_attachments: true,
            }),
        });
        let json = serde_json::to_value(metadata).unwrap();
        assert_eq!(json["last_activity"], 1234);
        let text = json.to_string();
        assert!(!text.contains("private"));
        assert!(json.get("last_message").is_none());
        assert!(json.get("text").is_none());
    }

    #[test]
    fn imessage_connection_requires_opt_in_then_disk_then_optional_automation() {
        let mut connection = Connection::default();
        assert_eq!(connection.status(true, true), Status::NotConnected);
        connection.opted_in = true;
        assert_eq!(connection.status(false, true), Status::NeedsFullDiskAccess);
        assert_eq!(connection.status(true, false), Status::NeedsAutomation);
        connection.automation_skipped = true;
        assert_eq!(connection.status(true, false), Status::Connected);
        assert_eq!(connection.status(false, false), Status::NeedsFullDiskAccess);
    }

    #[test]
    fn imessage_never_reads_database_without_opt_in_or_disk_access() {
        let mut request = Request {
            action: Action::Threads,
            database_path: std::env::temp_dir()
                .join(format!("imessage-missing-{}.db", std::process::id())),
            enabled: false,
            automation_skipped: false,
            full_disk_access: true,
            automation: true,
        };
        let reply = run(&request);
        assert_eq!(reply.status, Status::NotConnected);
        assert_eq!(reply.error, None); // An attempted open would return `missing`.
        request.action = Action::Connect;
        let connect = run(&request);
        assert_eq!(connect.error, None);
        assert_eq!(connect.setting_writes[0].key, "imessage.enabled");
        assert!(connect.setting_writes[0].value);
        request.action = Action::Threads;
        assert_eq!(run(&request).status, Status::NotConnected); // Write not committed yet.
        request.enabled = true;
        request.full_disk_access = false;
        assert_eq!(run(&request).error, None);
        request.full_disk_access = true;
        assert_eq!(run(&request).error, Some("missing"));
        request.action = Action::Disconnect;
        let disconnect = run(&request);
        assert_eq!(disconnect.status, Status::NotConnected);
        assert_eq!(disconnect.setting_writes[0].key, "imessage.enabled");
        assert!(!disconnect.setting_writes[0].value);
        assert!(!disconnect.setting_writes[1].value);
        request.enabled = false;
        request.action = Action::Threads;
        assert_eq!(run(&request).error, None);
    }
}
