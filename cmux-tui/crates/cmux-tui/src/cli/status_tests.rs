use super::*;

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

fn sent(args: &[&str]) -> Vec<String> {
    match parse(&words(args)) {
        Ok(Status::Send(words)) => words,
        other => panic!("{args:?} did not send: {other:?}"),
    }
}

#[test]
fn status_list_all_lists_every_workspace() {
    assert_eq!(sent(&["list", "--all"]), words(&["workspace", "status", "list", "--all"]));
}

#[test]
fn status_list_all_with_a_target_is_refused() {
    assert!(parse(&words(&["list", "--all", "--target", "ws_1"])).is_err());
}

#[test]
fn status_flags_a_verb_does_not_read_are_refused() {
    for args in [
        &["set", "k", "text", "--all"][..],
        &["run", "--all", "--", "true"],
        &["list", "--label", "x"],
        &["clear", "--label", "x"],
        &["set", "k", "text", "--badge-ttl", "3s"],
        &["clear", "--badge-ttl", "3s"],
        &["list", "--badge-ttl", "3s"],
    ] {
        assert!(parse(&words(args)).is_err(), "{args:?} was accepted");
    }
}

#[test]
fn status_run_keeps_its_label_and_badge_ttl() {
    let Ok(Status::Run(run)) =
        parse(&words(&["run", "--label", "build", "--badge-ttl", "3s", "--", "make"]))
    else {
        panic!("run did not parse");
    };
    assert_eq!((run.label.as_str(), run.badge_ttl.as_str()), ("build", "3s"));
}
