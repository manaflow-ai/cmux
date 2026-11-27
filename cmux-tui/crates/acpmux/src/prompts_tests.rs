use super::*;

fn store() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    (dir, path)
}

fn settings(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(n, t)| ((*n).to_owned(), (*t).to_owned())).collect()
}

fn names(rows: &[Prompt]) -> Vec<&str> {
    rows.iter().map(|p| p.name.as_str()).collect()
}

#[test]
fn a_missing_file_is_an_empty_store() {
    let (_dir, path) = store();
    assert!(list(&path, &[]).is_empty());
}

#[test]
fn a_save_is_listed_sorted_and_written_as_version_one() {
    let (_dir, path) = store();
    let saved = save(&path, "  review  ", "Review this diff.", 7).unwrap();
    assert_eq!(
        saved,
        Prompt {
            name: "review".into(),
            text: "Review this diff.".into(),
            source: Source::Saved,
            updated_at: Some(7),
        }
    );
    save(&path, "Alpha", "a", 8).unwrap();
    save(&path, "beta", "b", 9).unwrap();
    assert_eq!(names(&list(&path, &[])), ["Alpha", "beta", "review"]);
    let file: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["version"], 1);
    let first = json!({"name": "review", "text": "Review this diff.", "updatedAt": 7});
    assert_eq!(file["prompts"][0], first);
    let row = serde_json::to_value(&list(&path, &[])[0]).unwrap();
    assert_eq!(row, json!({"name": "Alpha", "text": "a", "source": "saved", "updatedAt": 8}));
}

#[test]
fn the_same_name_in_any_case_replaces_in_place() {
    let (_dir, path) = store();
    save(&path, "Review", "old", 1).unwrap();
    save(&path, "other", "o", 2).unwrap();
    save(&path, "REVIEW", "new", 3).unwrap();
    let rows = list(&path, &[]);
    assert_eq!(names(&rows), ["other", "REVIEW"]);
    assert_eq!((rows[1].text.as_str(), rows[1].updated_at), ("new", Some(3)));
    let file: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["prompts"][0]["name"], "REVIEW", "replaced where it was");
}

#[test]
fn names_and_texts_out_of_bounds_are_refused() {
    let (_dir, path) = store();
    let refused = |name: &str, text: &str| save(&path, name, text, 1).unwrap_err();
    assert_eq!(refused("   ", "t").code, -32602);
    assert_eq!(refused(&"n".repeat(65), "t").code, -32602);
    assert_eq!(refused("two\nlines", "t").code, -32602);
    assert_eq!(refused("n", "  \n ").code, -32602);
    // A long prompt is saved whole: the store caps no prompt's size.
    save(&path, &"é".repeat(64), &"x".repeat(256 * 1024), 1).unwrap();
    assert_eq!(list(&path, &[]).len(), 1);
}

#[test]
fn the_store_keeps_at_most_two_hundred() {
    let (_dir, path) = store();
    for i in 0..MAX_SAVED {
        save(&path, &format!("p{i}"), "t", 1).unwrap();
    }
    let refused = save(&path, "one more", "t", 2).unwrap_err();
    assert_eq!(refused.code, -32602);
    assert!(refused.message.contains("200 saved prompts"), "{}", refused.message);
    save(&path, "P0", "replaced", 3).unwrap();
    assert_eq!(list(&path, &[]).len(), MAX_SAVED);
}

#[test]
fn delete_removes_a_saved_prompt_in_any_case() {
    let (_dir, path) = store();
    save(&path, "Review", "t", 1).unwrap();
    assert!(delete(&path, &[], " review ").unwrap());
    assert!(!delete(&path, &[], "review").unwrap());
    assert!(list(&path, &[]).is_empty());
}

#[test]
fn settings_prompts_merge_and_a_saved_one_wins() {
    let (_dir, path) = store();
    save(&path, "review", "mine", 5).unwrap();
    let from_settings = settings(&[("Review", "theirs"), ("deploy", "ship it")]);
    let rows = list(&path, &from_settings);
    assert_eq!(names(&rows), ["deploy", "review"]);
    assert_eq!((rows[0].source, rows[0].updated_at), (Source::Settings, None));
    assert_eq!((rows[1].source, rows[1].text.as_str()), (Source::Saved, "mine"));
    assert_eq!(serde_json::to_value(&rows[0]).unwrap()["updatedAt"], Value::Null);
    // Deleting the saved one shows the settings one again.
    assert!(delete(&path, &from_settings, "review").unwrap());
    let rows = list(&path, &from_settings);
    assert_eq!((rows[1].name.as_str(), rows[1].source), ("Review", Source::Settings));
}

#[test]
fn a_settings_only_prompt_is_not_deleted() {
    let (_dir, path) = store();
    let refused = delete(&path, &settings(&[("Deploy", "ship it")]), "deploy").unwrap_err();
    assert_eq!(refused.code, -32602);
    assert_eq!(refused.message, "Deploy comes from cmux-next.json; remove it there");
    assert!(!path.exists(), "nothing was written");
}

#[test]
fn the_settings_value_keeps_only_strings() {
    let value = json!({" a ": "one", "b": 2, "c": null, " ": "blank", "d": {"x": 1}});
    assert_eq!(settings_prompts(Some(&value)), settings(&[("a", "one")]));
    // Names that differ only in case are one prompt.
    let value = json!({"a": "one", "A": "two"});
    assert_eq!(settings_prompts(Some(&value)).len(), 1);
    assert!(settings_prompts(Some(&json!(["a"]))).is_empty());
    assert!(settings_prompts(None).is_empty());
}

#[test]
fn an_unreadable_store_is_never_written_over() {
    let (_dir, path) = store();
    for text in ["{not json", r#"{"version": 2, "prompts": []}"#] {
        fs::write(&path, text).unwrap();
        let rows = list(&path, &settings(&[("deploy", "ship it")]));
        assert_eq!(names(&rows), ["deploy"]);
        assert_eq!(save(&path, "new", "t", 1).unwrap_err().code, -32603);
        assert_eq!(delete(&path, &[], "new").unwrap_err().code, -32603);
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "the file is as it was");
    }
}

#[test]
fn concurrent_saves_keep_every_prompt() {
    let (_dir, path) = store();
    let threads: Vec<_> = (0..4)
        .map(|t| {
            let path = path.clone();
            std::thread::spawn(move || {
                for i in 0..10 {
                    save(&path, &format!("t{t}-{i}"), "t", 1).unwrap();
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    assert_eq!(list(&path, &[]).len(), 40);
}
