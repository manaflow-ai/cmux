use super::*;
use crate::rule::MediaKind;

fn source(id: &str, folder: &str, drops: bool, rule: ScanRule) -> PaneSource {
    PaneSource {
        id: id.into(),
        label: id.into(),
        folder: folder.into(),
        accepts_drops: drops,
        rule,
    }
}

fn system() -> PaneSource {
    source("system", "/u/Desktop", true, ScanRule::default())
}

fn preview() -> PaneSource {
    source(
        "system.preview",
        "/t/TemporaryItems",
        false,
        ScanRule::with_depth(1, Some("NSIRD_screencaptureui_")),
    )
}

fn file<'a>(name: &'a str, kind: MediaKind) -> Entry<'a> {
    Entry { kind: EntryKind::File, hidden: false, name, system_kind: kind, modified: 1.0 }
}

fn folder_entry(name: &str) -> Entry<'_> {
    Entry {
        kind: EntryKind::Folder,
        hidden: false,
        name,
        system_kind: MediaKind::Other,
        modified: 1.0,
    }
}

fn strings(names: &[&str]) -> Vec<String> {
    names.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn new_sources_are_read_and_the_same_sources_change_nothing() {
    let mut pane = Pane::new(true);
    let plan = pane.set_sources(vec![system(), preview()]);
    assert!(plan.changed);
    assert_eq!(plan.read, ["system", "system.preview"]);
    assert!(plan.removed.is_empty());
    assert_eq!(pane.set_sources(vec![system(), preview()]), SourcesPlan::default());
    assert_eq!(pane.watched().unwrap(), ["/t/TemporaryItems", "/u/Desktop"]);
}

#[test]
fn a_changed_source_is_read_again_and_a_kept_one_is_not() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![system(), preview()]);
    let mut moved = system();
    moved.folder = "/u/Shots".into();
    let plan = pane.set_sources(vec![moved, preview()]);
    assert_eq!(plan.read, ["system"]);
    let mut renamed = preview();
    renamed.label = "Preview".into();
    let plan = pane.set_sources(vec![pane.sources()[0].clone(), renamed]);
    assert_eq!(plan.read, ["system.preview"]);
}

#[test]
fn removing_a_source_forgets_its_folders_and_failed_read() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![system(), preview()]);
    assert!(pane.read_done("system.preview", false, vec![]));
    let plan = pane.set_sources(vec![system()]);
    assert_eq!(plan.removed, ["system.preview"]);
    assert!(plan.read.is_empty());
    assert!(pane.unreadable().is_empty());
    assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
    assert!(!pane.has_source("system.preview"));
    assert!(!pane.read_done("system.preview", true, vec!["/t".into()]));
}

#[test]
fn a_read_watches_the_subfolders_it_entered() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![preview()]);
    pane.read_done(
        "system.preview",
        true,
        strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
    );
    assert_eq!(
        pane.watched().unwrap(),
        ["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]
    );
}

#[test]
fn an_unreadable_folder_is_reported_and_watched_alone() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![system()]);
    assert!(!pane.access_missing());
    pane.read_done("system", false, strings(&["/u/Desktop", "/u/Desktop/x"]));
    assert_eq!(pane.unreadable().into_iter().collect::<Vec<_>>(), ["system"]);
    assert!(pane.access_missing());
    assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
    pane.read_done("system", true, strings(&["/u/Desktop"]));
    assert!(!pane.access_missing());
}

#[test]
fn access_is_missing_only_when_every_source_failed_while_listing() {
    let mut pane = Pane::new(true);
    assert!(!pane.access_missing());
    pane.set_sources(vec![system(), preview()]);
    pane.read_done("system", false, vec![]);
    assert!(!pane.access_missing());
    pane.read_done("system.preview", false, vec![]);
    assert!(pane.access_missing());
    pane.pause();
    assert!(!pane.access_missing());
}

#[test]
fn a_pane_not_started_watches_nothing_until_started() {
    let mut pane = Pane::new(false);
    pane.set_sources(vec![system()]);
    assert_eq!(pane.watched(), None);
    assert_eq!(pane.change("/u/Desktop", Some(&strings(&["a.png"]))), ChangePlan::Ignore);
    assert!(pane.start());
    assert!(!pane.start());
    assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
}

#[test]
fn pause_forgets_failed_reads_and_entered_subfolders() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![preview()]);
    pane.read_done(
        "system.preview",
        true,
        strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
    );
    pane.pause();
    assert!(!pane.is_listing());
    assert_eq!(pane.watched(), None);
    pane.start();
    assert_eq!(pane.watched().unwrap(), ["/t/TemporaryItems"]);
}

#[test]
fn drops_go_to_the_selected_folder_when_it_takes_them_else_the_first_that_does() {
    let mut pane = Pane::new(true);
    let custom = source("custom./x", "/x", true, ScanRule::default());
    pane.set_sources(vec![preview(), system(), custom]);
    assert_eq!(pane.drop_source(None).map(|s| s.id.as_str()), Some("system"));
    assert_eq!(pane.drop_source(Some("custom./x")).map(|s| s.id.as_str()), Some("custom./x"));
    assert_eq!(pane.drop_source(Some("system.preview")).map(|s| s.id.as_str()), Some("system"));
    assert_eq!(pane.drop_source(Some("gone")).map(|s| s.id.as_str()), Some("system"));
    pane.set_sources(vec![preview()]);
    assert_eq!(pane.drop_source(None), None);
}

#[test]
fn the_deepest_source_holds_a_path() {
    let mut pane = Pane::new(true);
    let inner = source("custom./u/Desktop/Shots", "/u/Desktop/Shots", true, ScanRule::default());
    pane.set_sources(vec![system(), inner]);
    let id = |p: &str| pane.source_containing(p).map(|s| s.id.clone());
    assert_eq!(id("/u/Desktop/a.png").as_deref(), Some("system"));
    assert_eq!(id("/u/Desktop/Shots/a.png").as_deref(), Some("custom./u/Desktop/Shots"));
    assert_eq!(id("/u/Desktop").as_deref(), Some("system"));
    assert_eq!(id("/u/DesktopX/a.png"), None);
}

#[test]
fn a_burst_or_a_non_name_event_reads_the_source_again() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![system()]);
    assert_eq!(pane.change("/u/Desktop", None), ChangePlan::Rescan("system".into()));
    let many: Vec<String> = (0..=RESCAN_THRESHOLD).map(|i| format!("{i}.png")).collect();
    assert_eq!(pane.change("/u/Desktop", Some(&many)), ChangePlan::Rescan("system".into()));
    let fits: Vec<String> = (0..RESCAN_THRESHOLD).map(|i| format!("{i}.png")).collect();
    assert!(matches!(pane.change("/u/Desktop", Some(&fits)), ChangePlan::Look { .. }));
    assert_eq!(pane.change("/elsewhere", Some(&fits)), ChangePlan::Ignore);
}

#[test]
fn changed_names_are_looked_at_once_and_a_known_subfolder_relists() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![preview()]);
    pane.read_done(
        "system.preview",
        true,
        strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
    );
    let plan = pane.change(
        "/t/TemporaryItems",
        Some(&strings(&[
            "NSIRD_screencaptureui_1",
            "NSIRD_screencaptureui_2",
            "NSIRD_screencaptureui_2",
        ])),
    );
    assert_eq!(
        plan,
        ChangePlan::Look {
            source: "system.preview".into(),
            relist: true,
            paths: strings(&["/t/TemporaryItems/NSIRD_screencaptureui_2"]),
        }
    );
}

#[test]
fn a_new_file_is_listed_and_a_gone_one_removed() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![system()]);
    let png = file("Screenshot 1.png", MediaKind::Image);
    assert_eq!(
        pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&png)),
        EntryAction::Upsert
    );
    assert_eq!(
        pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", None),
        EntryAction::Remove
    );
    let txt = file("notes.txt", MediaKind::Other);
    assert_eq!(
        pane.entry_action("system", "/u/Desktop", "/u/Desktop/notes.txt", Some(&txt)),
        EntryAction::Remove
    );
    let hidden = Entry { hidden: true, ..png };
    assert_eq!(
        pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&hidden)),
        EntryAction::Remove
    );
    assert_eq!(
        pane.entry_action("gone", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&png)),
        EntryAction::Remove
    );
}

#[test]
fn a_new_preview_folder_relists_and_files_below_it_are_listed() {
    let mut pane = Pane::new(true);
    pane.set_sources(vec![preview()]);
    let dir = folder_entry("NSIRD_screencaptureui_9");
    assert_eq!(
        pane.entry_action(
            "system.preview",
            "/t/TemporaryItems",
            "/t/TemporaryItems/NSIRD_screencaptureui_9",
            Some(&dir)
        ),
        EntryAction::Relist
    );
    let other = folder_entry("Other");
    assert_eq!(
        pane.entry_action(
            "system.preview",
            "/t/TemporaryItems",
            "/t/TemporaryItems/Other",
            Some(&other)
        ),
        EntryAction::Remove
    );
    let png = file("Screenshot.png", MediaKind::Image);
    assert_eq!(
        pane.entry_action(
            "system.preview",
            "/t/TemporaryItems/NSIRD_screencaptureui_9",
            "/t/TemporaryItems/NSIRD_screencaptureui_9/Screenshot.png",
            Some(&png)
        ),
        EntryAction::Upsert
    );
    let deeper = folder_entry("NSIRD_screencaptureui_x");
    assert_eq!(
        pane.entry_action(
            "system.preview",
            "/t/TemporaryItems/NSIRD_screencaptureui_9",
            "/t/TemporaryItems/NSIRD_screencaptureui_9/NSIRD_screencaptureui_x",
            Some(&deeper)
        ),
        EntryAction::Remove
    );
}

#[test]
fn events_outside_the_rule_are_not_listed() {
    let preview = preview();
    assert!(Pane::is_listed(&preview, "/t/TemporaryItems/NSIRD_screencaptureui_1/a.png"));
    assert!(Pane::is_listed(&preview, "/t/TemporaryItems/a.png"));
    assert!(!Pane::is_listed(&preview, "/t/TemporaryItems/Other/a.png"));
    assert!(!Pane::is_listed(
        &preview,
        "/t/TemporaryItems/NSIRD_screencaptureui_1/NSIRD_screencaptureui_2/a.png"
    ));
    assert!(!Pane::is_listed(&preview, "/t/TemporaryItemsX/a.png"));
    assert!(!Pane::is_listed(&preview, "/t/TemporaryItems"));
    assert!(!Pane::is_listed(&system(), "/u/Desktop/sub/a.png"));
}

#[test]
fn child_paths_and_depths() {
    assert_eq!(child_path("/a", "b.png"), "/a/b.png");
    assert_eq!(child_path("/a/", "b"), "/a/b");
    assert_eq!(depth("/a", "/a"), 0);
    assert_eq!(depth("/a/b/c", "/a"), 2);
}
