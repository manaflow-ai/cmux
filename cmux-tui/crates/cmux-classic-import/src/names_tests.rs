use super::*;

fn clue(title: &str, branch: Option<&str>) -> Clues {
    Clues {
        custom: None,
        titles: vec![title.into()],
        agent: None,
        branch: branch.map(str::to_string),
        folder: "f".into(),
    }
}

#[test]
fn shared_names_take_their_branch_then_a_number() {
    let names = names(&[
        clue("vim", Some("main")),
        clue("vim", Some("dev")),
        clue("vim", None),
        clue("zsh", Some("x")),
    ]);
    assert_eq!(names, ["vim · main", "vim · dev", "vim", "zsh"]);
    let names = super::names(&[clue("vim", None), clue("vim", None)]);
    assert_eq!(names, ["vim", "vim 2"]);
}

#[test]
fn a_name_over_the_daemons_limit_is_cut_at_a_character_and_stays_unique() {
    let long = "é".repeat(800);
    let names = names(&[clue(&long, None), clue(&long, None)]);
    assert!(names.iter().all(|name| name.len() <= MAX_NAME_BYTES));
    assert_eq!(names[0].len(), 896);
    assert_ne!(names[0], names[1]);
}

/// Two long names that differ only past the limit still come out different.
#[test]
fn names_cut_at_the_limit_stay_unique() {
    let long = "x".repeat(1_000);
    let (a, b) = (format!("{}a", "b".repeat(200)), format!("{}b", "b".repeat(200)));
    let names = names(&[
        clue(&long, Some(&a)),
        clue(&long, Some(&b)),
        clue("vim 2", None),
        clue("vim", None),
        clue("vim", None),
    ]);
    assert!(names.iter().all(|name| name.len() <= MAX_NAME_BYTES));
    assert_ne!(names[0], names[1]);
    assert_eq!(names[2..], ["vim 2", "vim", "vim 3"]);
}

#[test]
fn path_titles_are_not_names_and_the_folder_is_the_last_resort() {
    let value: Value = serde_json::json!({
        "currentDirectory": "/Users/me/proj/",
        "processTitle": "~/proj",
        "panels": [{"title": "/bin/zsh"}, {"title": "  "}]
    });
    let clues = clues(value.as_object().unwrap(), "/Users/me");
    assert!(clues.titles.is_empty());
    assert_eq!(clues.folder, "proj");
    let root: Value = serde_json::json!({"currentDirectory": "/"});
    assert_eq!(super::clues(root.as_object().unwrap(), "/h").folder, UNNAMED);
}
