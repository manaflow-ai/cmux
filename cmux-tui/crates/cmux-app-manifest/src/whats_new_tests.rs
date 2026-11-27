use super::*;

fn line(subject: &str) -> Option<(String, u64)> {
    person_line(subject).map(|item| (item.title, item.pr))
}

#[test]
fn a_subject_becomes_the_sentence_a_person_reads() {
    let said = |title: &str, pr| Some((title.to_string(), pr));
    assert_eq!(
        line("App Store: hero buttons use the one corner token (#44805)"),
        said("Hero buttons use the one corner token", 44805)
    );
    assert_eq!(
        line("cloud: a paused machine says what its pause costs a month (F11) (#40336)"),
        said("A paused machine says what its pause costs a month", 40336)
    );
    assert_eq!(
        line("Cloud: show the team's spending cap (warning, pause, refusals) (#40036)"),
        said("Show the team's spending cap (warning, pause, refusals)", 40036)
    );
    assert_eq!(
        line("fix(cloud): Reconnect waits for the machine (cx-9ce.2.28) (#7)"),
        said("Reconnect waits for the machine", 7)
    );
    // A long clause before a colon is the sentence, not an area.
    assert_eq!(
        line("The Cloud server never idle-stops: machine links stay up (#38154)"),
        said("The Cloud server never idle-stops: machine links stay up", 38154)
    );
    // Internal work and subjects with no PR never reach the person.
    assert_eq!(line("cloud: resume survives a 503; a 404 names its step (#44513)"), None);
    assert_eq!(line("Cloud clients honour the platform's refusal codes (#40552)"), None);
    assert_eq!(line("Select Cloud backend at runtime (#35284)"), None);
    assert_eq!(line("Rust release profiles: fat LTO for cmux-cloud (#42338)"), None);
    assert_eq!(line("test(apps): an open page hears installs (#9)"), None);
    assert_eq!(line("chore: bump deps (#10)"), None);
    assert_eq!(line("apps: first-party apps are hide-only"), None);
    assert_eq!(line("App Store: (#11)"), None);
}

#[test]
fn the_file_round_trips() {
    let file = WhatsNew {
        version: "1.1.0".into(),
        items: vec![WhatsNewItem { title: "Faster".into(), pr: 3 }],
        versions: vec![
            VersionRow {
                version: "1.1.0".into(),
                commit: Some("abc".into()),
                date_ms: Some(1000),
                ..VersionRow::default()
            },
            VersionRow {
                version: "1.0.0".into(),
                tag: Some("v1.0.0".into()),
                ..Default::default()
            },
        ],
    };
    let value = file.to_json();
    assert_eq!(value["versions"][1], json!({ "version": "1.0.0", "tag": "v1.0.0" }));
    assert_eq!(WhatsNew::from_json(&value), Some(file.clone()));
    let text = file.to_file_text();
    assert!(text.ends_with("}\n"), "{text}");
    assert_eq!(WhatsNew::from_json(&json!({ "items": [] })), None);
}
