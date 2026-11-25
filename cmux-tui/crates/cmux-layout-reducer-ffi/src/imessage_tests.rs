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
