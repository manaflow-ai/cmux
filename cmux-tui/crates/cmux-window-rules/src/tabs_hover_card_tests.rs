use super::*;

const MB: u64 = 1 << 20;

fn sample(id: &str, megabytes: u64, processes: i64) -> Sample {
    Sample {
        id: id.into(),
        available: true,
        process_count: processes,
        memory_bytes: megabytes * MB,
        cpu: None,
    }
}

fn browser() -> Item {
    Item {
        id: "b1".into(),
        title: "cmux".into(),
        subtitle: Some("https://www.cmux.com/docs".into()),
        host: Some("cmux.com".into()),
        kind: Kind::Browser,
        ..Item::default()
    }
}

fn terminal() -> Item {
    Item {
        id: "t1".into(),
        title: "cargo build".into(),
        subtitle: Some("~/src".into()),
        kind: Kind::Terminal,
        ..Item::default()
    }
}

#[test]
fn a_browser_tabs_card_shows_its_host_and_memory() {
    let report = [sample("b1", 106, 1)];
    let card = make(&browser(), Some(&report), 0.0);
    assert_eq!(card.place, Some(vec![PlacePart::Where { text: "cmux.com".into() }]));
    assert_eq!(card.memory, Some(Memory::Memory { bytes: 106 * MB }));
}

#[test]
fn notable_cpu_shows_next_to_the_memory() {
    let mut busy = sample("b1", 106, 1);
    busy.cpu = Some(0.5);
    let card = make(&browser(), Some(std::slice::from_ref(&busy)), 0.0);
    assert_eq!(card.memory, Some(Memory::MemoryCpu { bytes: 106 * MB, cpu: 0.5 }));
    busy.cpu = Some(0.49);
    assert_eq!(memory(&browser(), Some(&[busy])), Some(Memory::Memory { bytes: 106 * MB }));
}

#[test]
fn a_hibernated_page_says_so_and_what_it_was_using() {
    let item = Item { is_dormant: true, ..browser() };
    let report = [sample("b1", 180, 1)];
    assert_eq!(memory(&item, Some(&report)), Some(Memory::HibernatedWasUsing { bytes: 180 * MB }));
    let zero = [sample("b1", 0, 1)];
    assert_eq!(memory(&item, Some(&zero)), Some(Memory::Hibernated));
    assert_eq!(memory(&item, None), Some(Memory::Hibernated));
}

#[test]
fn the_memory_row_is_the_tabs_own() {
    let report = [sample("other", 900, 1), sample("b1", 106, 1)];
    assert_eq!(memory(&browser(), Some(&report)), Some(Memory::Memory { bytes: 106 * MB }));
}

#[test]
fn a_tab_with_no_measured_process_shows_the_dash() {
    let report = [sample("t1", 40, 0)];
    assert_eq!(memory(&terminal(), Some(&report)), Some(Memory::Dash));
    assert_eq!(memory(&terminal(), None), Some(Memory::Dash));
    let other = Item { kind: Kind::Other, ..terminal() };
    assert_eq!(memory(&other, Some(&report)), None);
}

#[test]
fn a_running_terminal_says_running_and_for_how_long() {
    let item = Item { activity: Some(Activity::Running), since: Some(100.0), ..terminal() };
    let line = make(&item, None, 112.7).status.unwrap();
    assert_eq!(line, StatusLine { word: Some(Word::Busy), elapsed: Some(12.0), model: None });
    assert_eq!(tone(&item), Some(Tone::Working));
}

#[test]
fn a_shell_at_its_prompt_says_output_then_idle() {
    let item = Item { last_output: Some(1000.0), ..terminal() };
    let recent = make(&item, None, 1012.0).status.unwrap();
    assert_eq!(recent.word, Some(Word::Output));
    assert_eq!(recent.elapsed, Some(12.0));
    let quiet = make(&item, None, 1300.0).status.unwrap();
    assert_eq!(quiet.word, Some(Word::Idle));
    assert_eq!(tone(&item), Some(Tone::Secondary));
}

#[test]
fn a_start_ahead_of_the_clock_counts_one_second() {
    assert_eq!(elapsed(200.0, 100.0), 1.0);
    assert_eq!(elapsed(100.0, 100.9), 1.0);
}

#[test]
fn no_prompt_record_says_nothing_about_output() {
    let card = make(&terminal(), None, 0.0);
    assert_eq!(card.status, None);
    assert_eq!(card.tone, None);
}

#[test]
fn a_finished_command_says_done_or_failed() {
    let done = Item { status: Status::Success, last_output: Some(0.0), ..terminal() };
    assert_eq!(make(&done, None, 5.0).status.unwrap().word, Some(Word::Success));
    let failed = Item { status: Status::Failure, ..terminal() };
    assert_eq!(make(&failed, None, 5.0).status.unwrap().word, Some(Word::Failure));
    assert_eq!(tone(&failed), Some(Tone::Danger));
    let page = Item { status: Status::Success, ..browser() };
    assert_eq!(make(&page, None, 5.0).status, None);
}

#[test]
fn an_agent_chat_shows_its_state_for_how_long_and_its_model() {
    let item = Item {
        id: "c1".into(),
        title: "Mango".into(),
        subtitle: Some("~/Projects/site".into()),
        kind: Kind::AgentChat,
        activity: Some(Activity::Working),
        since: Some(0.0),
        model: Some("Opus 5.5".into()),
        branch: Some("main".into()),
        former_name: Some("claude-sr2-coord".into()),
        ..Item::default()
    };
    let card = make(&item, Some(&[sample("c1", 46, 2)]), 180.0);
    assert_eq!(
        card.status,
        Some(StatusLine {
            word: Some(Word::Working),
            elapsed: Some(180.0),
            model: Some("Opus 5.5".into())
        })
    );
    assert_eq!(card.place, Some(vec![PlacePart::Where { text: "~/Projects/site · main".into() }]));
    assert_eq!(
        card.title,
        Title::Formerly { title: "Mango".into(), former: "claude-sr2-coord".into() }
    );
    assert_eq!(card.memory, Some(Memory::Memory { bytes: 46 * MB }));
}

#[test]
fn a_model_alone_is_a_status_row() {
    let item = Item { model: Some("Opus 5.5".into()), ..terminal() };
    let line = make(&item, None, 0.0).status.unwrap();
    assert_eq!(line, StatusLine { word: None, elapsed: None, model: Some("Opus 5.5".into()) });
    let empty = Item { model: Some(String::new()), status: Status::Success, ..terminal() };
    assert_eq!(make(&empty, None, 0.0).status.unwrap().word, Some(Word::Success));
}

#[test]
fn a_blank_page_and_an_empty_title_are_untitled() {
    let blank = Item { title: "About:Blank".into(), ..browser() };
    assert_eq!(title(&blank), Title::Untitled);
    let shell = Item { title: "about:blank".into(), ..terminal() };
    assert_eq!(title(&shell), Title::Plain { title: "about:blank".into() });
    assert_eq!(title(&Item::default()), Title::Untitled);
    // A mark on the colon makes another character: no `about:`.
    assert!(!is_blank("about:\u{301}x"));
    assert!(is_blank("about:"));
    assert!(!is_blank("about"));
}

#[test]
fn a_former_name_equal_to_the_title_is_not_said() {
    let item =
        Item { title: "caf\u{e9}".into(), former_name: Some("cafe\u{301}".into()), ..terminal() };
    assert_eq!(title(&item), Title::Plain { title: "caf\u{e9}".into() });
}

#[test]
fn a_folder_the_title_names_is_said_once_and_badges_lead_the_place() {
    let item = Item {
        title: "~".into(),
        subtitle: Some("~".into()),
        branch: Some("dev".into()),
        profile_badge: Some("Work".into()),
        machine_badge_help: Some(String::new()),
        theme_badge: Some("Dusk".into()),
        ..terminal()
    };
    assert_eq!(
        make(&item, None, 0.0).place,
        Some(vec![
            PlacePart::Profile { name: "Work".into() },
            PlacePart::Theme { name: "Dusk".into() },
            PlacePart::Where { text: "dev".into() },
        ])
    );
    let bare = Item { subtitle: None, ..terminal() };
    assert_eq!(make(&bare, None, 0.0).place, None);
}

#[test]
fn a_status_detail_is_its_own_row_and_activity_leads_the_tone() {
    let item = Item {
        status_detail: Some("3 files changed".into()),
        activity: Some(Activity::NeedsInput),
        status: Status::Failure,
        ..terminal()
    };
    let card = make(&item, None, 0.0);
    assert_eq!(card.detail.as_deref(), Some("3 files changed"));
    assert_eq!(card.tone, Some(Tone::Attention));
    let empty = Item { status_detail: Some(String::new()), ..terminal() };
    assert_eq!(make(&empty, None, 0.0).detail, None);
}
