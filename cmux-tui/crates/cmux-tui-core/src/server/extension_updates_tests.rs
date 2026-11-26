use super::*;

fn offer(app: &str, version: &str, commit: &str) -> Offer {
    Offer {
        app: app.into(),
        name: app.rsplit('/').next().unwrap().into(),
        current: "1.0.0".into(),
        version: version.into(),
        commit: commit.into(),
    }
}

#[test]
fn an_update_is_told_once_and_again_only_for_a_newer_commit() {
    let offers: BTreeMap<String, Offer> =
        [("octo/hello".to_string(), offer("octo/hello", "1.1.0", "b"))].into();
    let (fresh, told) = new_offers(&offers, &BTreeMap::new());
    assert_eq!(fresh.len(), 1);
    let (again, same) = new_offers(&offers, &told);
    assert!(again.is_empty(), "already told");
    assert_eq!(same, told);
    let newer: BTreeMap<String, Offer> =
        [("octo/hello".to_string(), offer("octo/hello", "1.2.0", "c"))].into();
    assert_eq!(new_offers(&newer, &told).0.len(), 1, "a newer commit is told");
    let (_, pruned) = new_offers(&BTreeMap::new(), &told);
    assert!(pruned.is_empty(), "an app no longer offered is forgotten");
}

#[test]
fn one_notification_names_one_update_or_counts_several() {
    let a = offer("octo/hello", "1.1.0", "b");
    let b = offer("octo/notes", "2.0.0", "c");
    assert_eq!(notification(&[]), None);
    let (title, body) = notification(&[&a]).unwrap();
    assert_eq!(title, "Extension update available");
    assert!(body.contains("hello 1.1.0 is available (you have 1.0.0)"));
    assert!(body.contains("cmux apps update octo/hello"));
    let (title, body) = notification(&[&a, &b]).unwrap();
    assert_eq!(title, "2 extension updates available");
    assert!(body.starts_with("hello 1.1.0, notes 2.0.0."));
}

#[test]
fn the_told_record_survives_a_restart() {
    let dir = std::env::temp_dir().join(format!("cmux-ext-told-{}", std::process::id()));
    let file = notified_file(&dir);
    let told: BTreeMap<String, String> = [("octo/hello".to_string(), "b".to_string())].into();
    write_told(&file, &told);
    assert_eq!(read_told(&file), told);
    let _ = std::fs::remove_file(&file);
}
