//! The app's WorkspaceHoverCardPreviewTests, WorkspaceHoverCardTimelineTests and
//! WorkspaceHoverCardPortTests, mirrored, plus the transliterated vectors.

use super::*;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-hover-card-rules/vectors.json");

const HOME: &str = "/Users/leoli";
const NOW: f64 = 1_800_000_000.0;

fn web_ota() -> Workspace {
    Workspace {
        title: "web-ota".into(),
        directory: Some("~".into()),
        last_message: Some("Done: shipped the OTA page.".into()),
        ..Workspace::default()
    }
}

fn request(workspace: Workspace) -> CardRequest {
    CardRequest {
        workspace,
        machine: None,
        now: NOW,
        options: None,
        timeline: Vec::new(),
        pull_requests: None,
        home: HOME.into(),
        since_looked: None,
        port_links: None,
    }
}

fn kinds(card: &Card) -> Vec<&str> {
    card.facts.iter().map(|f| f.kind.as_str()).collect()
}

fn text_of<'a>(card: &'a Card, kind: &str) -> Option<&'a str> {
    card.facts.iter().find(|f| f.kind == kind).and_then(|f| f.text.as_deref())
}

fn pr(state: PrState, number: i64) -> PrItem {
    PrItem {
        state,
        number,
        title: String::new(),
        additions: 0,
        deletions: 0,
        repository: String::new(),
    }
}

fn on(directory: &str, branch: Option<&str>) -> Workspace {
    Workspace {
        title: "t".into(),
        directory: Some(directory.into()),
        branch: branch.map(str::to_owned),
        ..Workspace::default()
    }
}

// MARK: WorkspaceHoverCardPreviewTests

#[test]
fn a_home_folder_is_no_fact() {
    for directory in [
        "~",
        "~/",
        "/Users/leoli",
        "/Users/leoli/",
        "/Users/leoli/.",
        "/home/ubuntu",
        "/Users/other",
        "/root",
        "/",
        "",
        "  ",
    ] {
        assert_eq!(meaningful_folder(Some(directory), HOME), None, "{directory}");
    }
    assert_eq!(meaningful_folder(None, HOME), None);
}

#[test]
fn a_folder_reads_as_its_own_name() {
    for (directory, name) in [
        ("~/code/cmux", "cmux"),
        ("/Users/leoli/Projects", "Projects"),
        ("~/Projects/web-ota/", "web-ota"),
        ("/home/ubuntu/src/app", "app"),
        ("/tmp", "tmp"),
    ] {
        assert_eq!(meaningful_folder(Some(directory), HOME).as_deref(), Some(name), "{directory}");
    }
}

#[test]
fn a_home_workspace_shows_only_its_last_reply() {
    let card = card(&request(web_ota()));
    assert_eq!(kinds(&card), ["lastReply"]);
    assert!(card.facts[0].preview);
}

#[test]
fn a_checkout_reads_as_its_repository_and_branch() {
    let card = card(&request(on("~/code/cmux", Some("feat-cmux-next"))));
    assert_eq!(text_of(&card, kind::BRANCH), Some("cmux · feat-cmux-next"));
}

#[test]
fn a_pull_request_names_the_repository() {
    let mut item = pr(PrState::Passing, 5);
    item.repository = "manaflow-ai/cmux-next".into();
    let mut r = request(on("~/code/cmux", Some("fix/card")));
    r.pull_requests = Some(vec![item]);
    assert_eq!(text_of(&card(&r), kind::BRANCH), Some("cmux-next · fix/card"));
}

#[test]
fn a_worktree_named_after_its_branch_reads_as_the_branch() {
    for (directory, branch) in [
        ("~/wt/glass-regressions--hover-card-polish", "glass-regressions/hover-card-polish"),
        ("~/wt/lane--fix-card", "lane/fix-card"),
        ("~/code/Fix_Card", "fix-card"),
    ] {
        assert_eq!(
            text_of(&card(&request(on(directory, Some(branch)))), kind::BRANCH),
            Some(branch)
        );
    }
}

#[test]
fn a_repository_named_like_its_branch_tail_keeps_its_name() {
    assert_eq!(
        text_of(&card(&request(on("~/code/card", Some("feature/card")))), kind::BRANCH),
        Some("card · feature/card")
    );
    assert_eq!(
        text_of(&card(&request(on("~/code/cmux", Some("lane/cmux")))), kind::BRANCH),
        Some("cmux · lane/cmux")
    );
}

#[test]
fn ports_never_land_under_the_preview() {
    let mut workspace = web_ota();
    workspace.ports = Some("web app".into());
    let card = card(&request(workspace));
    assert_eq!(kinds(&card), ["ports", "lastReply"]);
}

#[test]
fn a_branch_in_the_home_folder_reads_as_the_branch() {
    assert_eq!(text_of(&card(&request(on("~", Some("main")))), kind::BRANCH), Some("main"));
}

#[test]
fn a_folder_off_a_branch_reads_as_the_folder() {
    let card = card(&request(on("~/Downloads", None)));
    assert_eq!(text_of(&card, kind::FOLDER), Some("Downloads"));
}

#[test]
fn without_git_the_place_is_the_folder() {
    let mut r = request(on("~/code/cmux", Some("main")));
    r.options = Some(Options { shows_git: false, ..Options::default() });
    let card = card(&r);
    assert_eq!(text_of(&card, kind::FOLDER), Some("cmux"));
    assert!(!kinds(&card).contains(&kind::BRANCH));
}

#[test]
fn a_wait_wins_over_the_reply_and_the_pull_request() {
    let mut workspace = web_ota();
    workspace.needs_input = Some("Approve the deploy?".into());
    workspace.pull_request = Some("#1".into());
    assert_eq!(preview(&workspace, None, true), Preview::NeedsYou);
    let card = card(&request(workspace));
    assert_eq!(kinds(&card).first(), Some(&kind::NEEDS_INPUT));
    assert!(!kinds(&card).contains(&kind::LAST_REPLY));
    assert!(!kinds(&card).contains(&kind::NEEDS_YOU));
}

#[test]
fn a_chip_that_needs_you_ends_the_card_with_needs_you() {
    let mut workspace = web_ota();
    workspace.needs_you_chip = true;
    let card = card(&request(workspace.clone()));
    let last = card.facts.last();
    assert_eq!(last.map(|f| f.kind.as_str()), Some(kind::NEEDS_YOU));
    assert_eq!(last.and_then(|f| f.tone), Some(Tone::Attention));
    for layout in [Layout::Timeline, Layout::Compact, Layout::Log, Layout::Classic, Layout::Minimal]
    {
        let mut r = request(workspace.clone());
        r.options = Some(Options { layout, ..Options::default() });
        r.timeline = vec![Entry {
            kind: EntryKind::Prompt,
            date: NOW - 60.0,
            text: Some("Ship it".into()),
            is_notice: false,
        }];
        let card = super::card(&r);
        assert_eq!(kinds(&card).last(), Some(&kind::NEEDS_YOU), "{layout:?}");
        if layout == Layout::Minimal {
            assert_eq!(kinds(&card), ["task", "needsYou"]);
        }
    }
}

#[test]
fn a_blank_reason_is_no_wait() {
    let mut workspace = web_ota();
    workspace.needs_input = Some("   ".into());
    assert_eq!(
        preview(&workspace, None, true),
        Preview::Message { message: "Done: shipped the OTA page.".into() }
    );
}

#[test]
fn a_pull_request_preview_reads_in_its_state() {
    let item = PrItem {
        state: PrState::Passing,
        number: 23729,
        title: "Polish the workspace card".into(),
        additions: 120,
        deletions: 30,
        repository: "manaflow-ai/cmux".into(),
    };
    let mut r = request(web_ota());
    r.pull_requests = Some(vec![item]);
    let card = card(&r);
    let prs: Vec<&Fact> = card.facts.iter().filter(|f| f.kind == kind::PULL_REQUEST).collect();
    assert_eq!(prs.len(), 1);
    let fact = prs[0];
    assert!(fact.preview);
    assert_eq!(fact.text.as_deref(), Some("#23729 Polish the workspace card"));
    assert_eq!(fact.tone, Some(Tone::Success));
    assert_eq!((fact.additions, fact.deletions), (Some(120), Some(30)));
}

#[test]
fn the_newest_open_pull_request_is_named() {
    // The badge's items, newest first (`SidebarPullRequestBadge.combining(items:)` sorts them).
    let items = [pr(PrState::Closed, 2), pr(PrState::Failing, 3), pr(PrState::Merged, 1)];
    assert_eq!(newest_pull_request(Some(&items)), Some(1), "the newest one that is not closed");
    assert_eq!(newest_pull_request(Some(&[pr(PrState::Closed, 2)])), Some(0));
    assert_eq!(newest_pull_request(Some(&[])), None);
}

#[test]
fn a_hook_pull_request_is_the_preview_unless_git_is_hidden() {
    let mut workspace = web_ota();
    workspace.pull_request = Some("#42 ✓".into());
    assert_eq!(preview(&workspace, None, true), Preview::PullRequest);
    let card = card(&request(workspace.clone()));
    assert_eq!(card.facts.last().and_then(|f| f.text.as_deref()), Some("#42 ✓"));
    assert!(matches!(preview(&workspace, None, false), Preview::Message { .. }));
}

#[test]
fn a_task_or_a_blank_reply_previews_nothing() {
    let mut workspace = web_ota();
    workspace.task = Some("Fix it".into());
    assert_eq!(preview(&workspace, None, true), Preview::Empty);
    let mut blank = web_ota();
    blank.last_message = Some("  ".into());
    assert_eq!(preview(&blank, None, true), Preview::Empty);
    let mut none = web_ota();
    none.last_message = None;
    assert!(card(&request(none)).facts.is_empty());
}

// MARK: WorkspaceHoverCardTimelineTests

fn history(count: usize) -> Vec<Entry> {
    (0..count)
        .map(|i| {
            let date = NOW - 60.0 * (i as f64 + 1.0);
            if i % 2 == 0 {
                Entry { kind: EntryKind::Finished, date, text: None, is_notice: false }
            } else {
                Entry {
                    kind: EntryKind::Prompt,
                    date,
                    text: Some(format!("Prompt {i}")),
                    is_notice: false,
                }
            }
        })
        .collect()
}

fn site(options: Options) -> CardRequest {
    let workspace = Workspace {
        title: "site".into(),
        directory: Some("~/Projects/site".into()),
        branch: Some("main".into()),
        ports: Some(":3000".into()),
        pull_request: Some("#42".into()),
        activity_since: true,
        ..Workspace::default()
    };
    CardRequest {
        options: Some(options),
        timeline: history(6),
        port_links: Some(1),
        ..request(workspace)
    }
}

#[test]
fn the_default_card_lists_the_history_and_its_stats() {
    let card = card(&site(Options::default()));
    assert_eq!(card.timeline.len(), 6);
    assert_eq!(card.stats, Some(Stats { prompts: 3, worked: 180.0 }));
    assert_eq!(card.ports.len(), 1);
    assert!(card.ports_text);
    assert!(!kinds(&card).contains(&kind::PORTS));
}

#[test]
fn sections_turned_off_leave_their_lines_out() {
    let options = Options {
        shows_git: false,
        shows_ports: false,
        shows_waiting: false,
        shows_timings: false,
        ..Options::default()
    };
    let card = card(&site(options));
    for gone in [kind::BRANCH, kind::PULL_REQUEST, kind::PORTS] {
        assert!(!kinds(&card).contains(&gone), "{gone}");
    }
    assert!(card.ports.is_empty());
    assert_eq!(card.timeline.len(), 3);
    let r = site(Options::default());
    assert!(card.timeline.iter().all(|l| r.timeline[l.index].kind == EntryKind::Prompt));
    assert_eq!(card.stats, None);
    assert!(!card.activity_since);
}

#[test]
fn max_rows_cuts_the_history() {
    assert_eq!(card(&site(Options { max_rows: 4, ..Options::default() })).timeline.len(), 4);
}

#[test]
fn each_layout_cuts_the_card_its_way() {
    let at = |layout| card(&site(Options { layout, ..Options::default() }));
    let timeline = at(Layout::Timeline);
    assert_eq!((timeline.timeline.len(), timeline.stats.is_some()), (6, true));
    let compact = at(Layout::Compact);
    assert_eq!((compact.timeline.len(), compact.stats.is_some()), (3, false));
    let log = at(Layout::Log);
    assert_eq!(log.timeline.len(), 6);
    assert!(log.facts.is_empty());
    assert!(at(Layout::Classic).timeline.is_empty());
    let minimal = at(Layout::Minimal);
    let texts: Vec<_> = minimal.facts.iter().map(|f| f.text.as_deref()).collect();
    assert_eq!(texts, [Some("Prompt 1")]);
    assert_eq!(minimal.facts[0].index, Some(1));
}

#[test]
fn the_newest_wait_says_why() {
    let mut r = site(Options::default());
    r.workspace.waits_for_person = true;
    r.workspace.needs_input = Some("  Approve the deploy?  ".into());
    r.timeline.insert(
        0,
        Entry { kind: EntryKind::Waiting, date: NOW - 10.0, text: None, is_notice: false },
    );
    let card = card(&r);
    assert_eq!(card.timeline[0].text.as_deref(), Some("Approve the deploy?"));
}

#[test]
fn a_notice_is_never_listed_but_still_counts() {
    let mut r = site(Options::default());
    r.timeline[1].is_notice = true;
    let card = card(&r);
    assert_eq!(card.timeline.len(), 5);
    assert_eq!(card.stats.map(|s| s.prompts), Some(3));
}

// MARK: WorkspaceHoverCardPortTests

fn web(ports: Option<&str>, links: Option<usize>) -> CardRequest {
    let workspace =
        Workspace { title: "web".into(), ports: ports.map(str::to_owned), ..Workspace::default() };
    CardRequest { port_links: links, ..request(workspace) }
}

#[test]
fn each_port_of_the_entry_is_a_row() {
    let card = card(&web(Some(":3000, :5173"), Some(2)));
    assert_eq!(card.ports.iter().map(|f| f.index).collect::<Vec<_>>(), [Some(0), Some(1)]);
    assert!(card.ports_text);
    assert!(!kinds(&card).contains(&kind::PORTS));
}

#[test]
fn an_entry_with_no_port_to_open_reads_as_before() {
    for links in [Some(0), None] {
        let card = card(&web(Some("web app"), links));
        assert!(card.ports.is_empty());
        assert_eq!(text_of(&card, kind::PORTS), Some("web app"));
        assert!(!card.ports_text);
    }
}

#[test]
fn a_workspace_without_ports_has_no_port_row() {
    let card = card(&web(None, Some(1)));
    assert!(card.ports.is_empty());
    assert!(card.facts.is_empty());
}

// MARK: The rest

#[test]
fn a_local_host_plus_the_title_is_no_fact() {
    assert!(!non_redundant("local · site", " Site "));
    assert!(non_redundant("local · other", "site"));
    assert!(non_redundant("local · site · x", "site"));
    assert!(!non_redundant("", "site"));
}

#[test]
fn a_remote_machine_is_the_host() {
    let mut r = request(web_ota());
    r.machine = Some(Machine {
        kind: MachineKind::Ssh,
        name: "mini".into(),
        status: MachineStatus::Offline,
    });
    let card = card(&r);
    assert!(card.host);
    let machine = card.facts.iter().find(|f| f.kind == kind::MACHINE);
    assert_eq!(machine.and_then(|f| f.text.as_deref()), Some("mini"));
    let status = card.facts.iter().find(|f| f.kind == kind::MACHINE_STATUS);
    assert_eq!(status.and_then(|f| f.word), Some(Word::Offline));
    assert_eq!(status.and_then(|f| f.tone), Some(Tone::Danger));
    r.machine = Some(Machine {
        kind: MachineKind::Local,
        name: "here".into(),
        status: MachineStatus::Offline,
    });
    assert!(!super::card(&r).host);
}

#[test]
fn status_entries_and_checklists_stop_at_their_limits() {
    let mut workspace = web_ota();
    workspace.reported = (0..5).map(|i| format!("s{i}")).collect();
    workspace.checklist = (0..8).map(|i| format!("c{i}")).collect();
    let card = card(&request(workspace));
    let mores: Vec<_> =
        card.facts.iter().filter(|f| f.kind == kind::MORE).map(|f| f.count).collect();
    assert_eq!(mores, [Some(2), Some(2)]);
    assert_eq!(card.facts.iter().filter(|f| f.kind == kind::STATUS).count(), 3);
    assert_eq!(card.facts.iter().filter(|f| f.kind == kind::CHECKLIST).count(), 6);
}

#[test]
fn stats_and_since_looked_count_the_history() {
    assert_eq!(stats(&[], NOW), None);
    let running =
        [Entry { kind: EntryKind::Started, date: NOW - 30.0, text: None, is_notice: false }];
    assert_eq!(stats(&running, NOW), Some(Stats { prompts: 0, worked: 30.0 }));
    let mut tl = history(4);
    tl.insert(0, Entry { kind: EntryKind::Failed, date: NOW - 5.0, text: None, is_notice: false });
    assert_eq!(since_looked(&tl, NOW - 150.0), Some(SinceLooked { done: 1, asked: 0, failed: 1 }));
    assert_eq!(since_looked(&tl, NOW), None);
    assert_eq!(elapsed(NOW + 30.0, NOW), 1.0);
    assert_eq!(elapsed(NOW - 252.9, NOW), 252.0);
}

#[test]
fn the_resource_row_warms_with_the_cpu() {
    assert_eq!(resource_row(false, Some(3.0), &[]), None);
    let hot = resource_row(true, Some(2.0), &[4.0, 2.0]);
    assert_eq!(hot, Some(ResourceRow { tone: Tone::Danger, bars: Some(vec![1.0, 0.5]) }));
    let quiet = resource_row(true, None, &[0.5]);
    assert_eq!(quiet, Some(ResourceRow { tone: Tone::Secondary, bars: Some(vec![0.5]) }));
}

fn same(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    use serde_json::Value;
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc["cases"].as_array().expect("cases").iter().enumerate() {
        let mut request = case.clone();
        let expected = request.as_object_mut().and_then(|o| o.remove("reply")).expect("reply");
        let request: Request = serde_json::from_value(request).expect("request");
        let reply = serde_json::to_value(respond(&request)).expect("reply");
        assert!(same(&reply, &expected), "case {index}: {reply} vs {expected}");
    }
}
