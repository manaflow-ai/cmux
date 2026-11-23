use super::*;

fn new(agent: Target, name: &str, prompt: &str) -> NewCommand {
    NewCommand {
        agent,
        name: name.into(),
        description: String::new(),
        prompt: prompt.into(),
        replace: false,
    }
}

#[test]
fn writes_each_agents_own_file() {
    let dir = tempfile::tempdir().unwrap();
    let homes = Homes::under(dir.path());
    let claude =
        add(&homes, &new(Target::Claude, "review", "Review the diff: $ARGUMENTS")).unwrap();
    assert_eq!(claude.path, dir.path().join(".claude/commands/review.md"));
    assert_eq!(claude.invocation, "/review");
    assert_eq!(claude.description, "Review the diff: $ARGUMENTS");
    assert_eq!(
        fs::read_to_string(&claude.path).unwrap(),
        "---\ndescription: \"Review the diff: $ARGUMENTS\"\n---\nReview the diff: $ARGUMENTS\n"
    );
    let codex = add(
        &homes,
        &NewCommand {
            description: "Ship \"it\"".into(),
            ..new(Target::Codex, "ship", "Ship it.\n\nNow.")
        },
    )
    .unwrap();
    assert_eq!(codex.path, dir.path().join(".codex/prompts/ship.md"));
    assert_eq!(codex.invocation, "/prompts:ship");
    assert_eq!(codex.description, "Ship \"it\"");
    assert_eq!(codex.prompt, "Ship it.\n\nNow.");
    let cmux = add(&homes, &new(Target::Cmux, "standup", "Write my standup")).unwrap();
    assert_eq!(cmux.path, dir.path().join(".config/cmux/commands/standup.md"));

    // Claude Code's own reader (the skills listing) sees the new command as a slash command.
    let listing = crate::skills::list(&homes, &crate::skills::ListOptions::default());
    assert!(listing.skills.iter().any(|s| s.name == "review"
        && s.kind == crate::skills::Kind::Command
        && s.description == "Review the diff: $ARGUMENTS"));

    let names: Vec<_> = list(&homes, None).into_iter().map(|c| (c.agent, c.name)).collect();
    assert_eq!(
        names,
        vec![
            (Target::Claude, "review".to_owned()),
            (Target::Codex, "ship".to_owned()),
            (Target::Cmux, "standup".to_owned())
        ]
    );
    assert_eq!(list(&homes, Some(Target::Cmux)).len(), 1);
}

#[test]
fn refuses_a_taken_name_bad_names_and_empty_prompts() {
    let dir = tempfile::tempdir().unwrap();
    let homes = Homes::under(dir.path());
    add(&homes, &new(Target::Claude, "x", "one")).unwrap();
    assert!(matches!(add(&homes, &new(Target::Claude, "x", "two")), Err(CommandError::Exists(_))));
    let replaced =
        add(&homes, &NewCommand { replace: true, ..new(Target::Claude, "x", "two") }).unwrap();
    assert_eq!(replaced.prompt, "two");
    for bad in ["", "../x", "a/b", ".hidden", "x.md", "a b", "-flag", &"a".repeat(65)] {
        assert!(
            matches!(add(&homes, &new(Target::Cmux, bad, "p")), Err(CommandError::BadName(_))),
            "{bad:?}"
        );
    }
    assert!(matches!(add(&homes, &new(Target::Cmux, "e", "  \n")), Err(CommandError::EmptyPrompt)));
}

#[test]
fn remove_keeps_a_backup() {
    let dir = tempfile::tempdir().unwrap();
    let homes = Homes::under(dir.path());
    let saved = add(&homes, &new(Target::Cmux, "gone", "bye")).unwrap();
    assert_eq!(remove(&homes, Target::Cmux, "gone").unwrap(), saved.path);
    assert!(!saved.path.exists());
    let backup = homes.edits.last_backup_path(&saved.path);
    assert!(fs::read_to_string(backup).unwrap().contains("bye"));
    assert!(matches!(remove(&homes, Target::Cmux, "gone"), Err(CommandError::Missing(_))));
}

#[test]
fn reads_a_hand_written_file_without_frontmatter() {
    let dir = tempfile::tempdir().unwrap();
    let homes = Homes::under(dir.path());
    let folder = Target::Cmux.dir(&homes);
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("plain.md"), "Summarize this chat\nin three bullets\n").unwrap();
    fs::write(folder.join("notes.txt"), "not a command").unwrap();
    let found = list(&homes, Some(Target::Cmux));
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].description, "Summarize this chat");
    assert_eq!(found[0].prompt, "Summarize this chat\nin three bullets");
}
