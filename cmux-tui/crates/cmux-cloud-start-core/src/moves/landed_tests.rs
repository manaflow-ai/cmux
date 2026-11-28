use super::*;

fn object(line: &str) -> Map<String, Value> {
    match serde_json::from_str::<Value>(line).unwrap() {
        Value::Object(object) => object,
        _ => panic!("not an object: {line}"),
    }
}

fn landed(line: &str) -> Option<Landed> {
    read(&object(line))
}

#[test]
fn a_clone_that_left_nothing_says_nothing() {
    assert_eq!(landed(r#"{"ok":true,"mode":"seed","skipped_files":[]}"#), None);
    assert_eq!(landed(r#"{"ok":true,"mode":"clone","head":"abc"}"#), None);
    assert_eq!(landed(r#"{"ok":true,"mode":"projected","skipped_files":[]}"#), None);
    assert_eq!(landed(r#"{"ok":true,"written":3}"#), None, "not a seed push's answer");
    assert_eq!(landed(r#"{"ok":true,"mode":"later"}"#), None, "a mode it does not know");
}

#[test]
fn a_copy_says_copied_not_cloned_and_why() {
    let plain =
        landed(r#"{"ok":true,"mode":"copy","skipped_files":[],"copy":{"skipped_files":[]}}"#)
            .unwrap();
    assert_eq!(plain.how, How::Copied);
    assert_eq!(plain.headline.as_deref(), Some("Copied, not cloned"));
    assert!(plain.reason.as_deref().is_some_and(|why| why.contains("copied")));
    assert!(plain.skipped.is_empty());
    assert_eq!(plain.summary, None);

    let fallback = landed(
        r#"{"ok":true,"mode":"copy","fallback_code":"not_git","fallback_why":"This folder is not a git repository.","skipped_files":[]}"#,
    )
    .unwrap();
    assert_eq!(fallback.reason.as_deref(), Some("This folder is not a git repository."));
}

#[test]
fn the_fleet_runs_folder_names_the_env_the_build_folder_and_the_big_file() {
    // RFD 0066's fleet run (case c): `.env` and `node_modules/` left; with pieces 2 and 4 the copy
    // names ignored paths and the seed names a big file.
    let got = landed(
        r#"{"ok":true,"mode":"copy","skipped_files":[
            {"path":".env","kind":"secret","why":"secret: .env files are shared only on purpose"},
            {"path":"node_modules/","kind":"heavy","why":"a heavy folder rebuilt on the machine"},
            {"path":"dist/","kind":"ignored","why":"ignored by .gitignore"},
            {"path":"big.bin","kind":"big","why":"a big file (120 MB) that stays on this Mac"}]}"#,
    )
    .unwrap();
    let groups: Vec<_> = got.skipped.iter().map(|group| group.group).collect();
    assert_eq!(groups, vec![Group::Secret, Group::Rebuilt, Group::Big], "in the toast's order");
    assert_eq!(got.skipped[1].paths, vec!["node_modules/", "dist/"]);
    assert_eq!(got.skipped[0].text, "Secrets, kept on this Mac: .env");
    assert_eq!(
        got.skipped[1].text,
        "Ignored and build output, rebuilt on the machine: node_modules/, dist/"
    );
    assert_eq!(
        got.summary.as_deref(),
        Some("Left on this Mac: 1 secret, 2 ignored paths, 1 big file")
    );
}

#[test]
fn a_clone_that_left_secrets_names_them_without_the_copy_headline() {
    let got = landed(
        r#"{"ok":true,"mode":"seed","skipped_files":[
            {"path":"id_rsa","kind":"secret","why":"a key"},
            {"path":"vendor/lib/","kind":"repository","why":"a separate git repository inside this folder (not a submodule)"}]}"#,
    )
    .unwrap();
    assert_eq!((got.how, got.headline, got.reason), (How::Cloned, None, None));
    assert_eq!(
        got.skipped.iter().map(|group| group.group).collect::<Vec<_>>(),
        vec![Group::Secret, Group::Repository]
    );
}

#[test]
fn past_the_named_paths_a_group_says_how_many_more() {
    let files: Vec<String> = (0..5)
        .map(|n| format!(r#"{{"path":"keys/{n}.pem","kind":"secret","why":"a key"}}"#))
        .collect();
    let line = format!(
        r#"{{"ok":true,"mode":"copy","skipped_files":[{}],"copy":{{"skipped_counts":{{"secret":9,"left_on_mac":4,"symlink":0}}}}}}"#,
        files.join(",")
    );
    let got = landed(&line).unwrap();
    let secret = &got.skipped[0];
    assert_eq!((secret.paths.len(), secret.more), (5, 4), "the copy counted 9, named 5");
    assert_eq!(
        secret.text,
        "Secrets, kept on this Mac: keys/0.pem, keys/1.pem, keys/2.pem and 6 more"
    );
    let big = &got.skipped[1];
    assert_eq!((big.group, big.paths.len(), big.more), (Group::Big, 0, 4));
    assert_eq!(big.text, "Big files, kept on this Mac: 4 big files", "counted, none named");
    assert_eq!(got.skipped.len(), 2, "a kind counted 0 is no group");
    assert_eq!(got.summary.as_deref(), Some("Left on this Mac: 9 secrets, 4 big files"));
}

#[test]
fn a_kind_it_does_not_know_goes_under_not_copied() {
    let got = landed(
        r#"{"ok":true,"mode":"copy","skipped_files":[{"path":"link","kind":"symlink","why":"a symlink (to nothing)"},{"path":"x","why":"no kind"}]}"#,
    )
    .unwrap();
    assert_eq!(got.skipped.len(), 1);
    assert_eq!(got.skipped[0].group, Group::Other);
    assert_eq!(got.skipped[0].text, "Not copied: link, x");
}

#[test]
fn the_native_toast_says_copied_and_groups_what_stayed() {
    // The fleet run's folder (case c) as the app's done toast shows it, in look C.
    let got = landed(
        r#"{"ok":true,"mode":"copy","fallback_why":"This folder is not a git repository.","skipped_files":[
            {"path":".env","kind":"secret","why":"a secret"},
            {"path":"node_modules/","kind":"heavy","why":"heavy"},
            {"path":"dist/","kind":"ignored","why":"ignored"},
            {"path":"big.bin","kind":"big","why":"big"}]}"#,
    );
    let toast = toast("This chat now runs on dev.", got.as_ref()).unwrap();
    assert_eq!(
        toast.message,
        "Copied, not cloned. This chat now runs on dev. Left on this Mac: 1 secret, 2 ignored paths, 1 big file."
    );
    assert_eq!(
        toast.detail.as_deref(),
        Some(
            "This folder is not a git repository.\n\n\
             Secrets, kept on this Mac\n.env\n\n\
             Ignored and build output, rebuilt on the machine\nnode_modules/   dist/\n\n\
             Big files, kept on this Mac\nbig.bin"
        )
    );
}

#[test]
fn the_native_toast_shows_four_paths_then_how_many_more() {
    let files: Vec<String> = (0..6)
        .map(|n| format!(r#"{{"path":"keys/{n}.pem","kind":"secret","why":"a key"}}"#))
        .collect();
    let line = format!(
        r#"{{"ok":true,"mode":"seed","skipped_files":[{}],"skipped_counts":{{"secret":10}}}}"#,
        files.join(",")
    );
    let toast = toast("This chat now runs on dev.", landed(&line).as_ref()).unwrap();
    assert_eq!(
        toast.message, "This chat now runs on dev. Left on this Mac: 10 secrets.",
        "a clone has no headline"
    );
    assert_eq!(
        toast.detail.as_deref(),
        Some("Secrets, kept on this Mac\nkeys/0.pem   keys/1.pem   keys/2.pem   keys/3.pem   +6")
    );
}

#[test]
fn a_clone_that_left_nothing_keeps_the_toast_it_always_had() {
    assert_eq!(toast("This chat now runs on dev.", None), None);
    let copied = landed(r#"{"ok":true,"mode":"copy","skipped_files":[]}"#);
    let plain = toast("This chat now runs on dev.", copied.as_ref()).unwrap();
    assert_eq!(plain.message, "Copied, not cloned. This chat now runs on dev.");
    assert!(plain.detail.is_some_and(|why| why.contains("copied")), "says why, nothing stayed");
}
