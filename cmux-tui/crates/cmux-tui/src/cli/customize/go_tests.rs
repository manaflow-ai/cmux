use super::*;
use cmux_customize::Roots;
use cmux_customize::library::CodeLayer;

fn tried(customize: &Customize, pr: u64, head: &str) {
    let layer = CodeLayer {
        kind: Default::default(),
        source: String::new(),
        repo: REPO.into(),
        pr,
        title: format!("pr {pr}"),
        head: head.into(),
        base: String::new(),
        web: String::new(),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    };
    customize.library_use_code(layer, vec![], "cli", 1).unwrap();
}

/// A fake `gh`: answers the PR read with `pull`, the user read with `leo`,
/// records every call.
fn fake(
    pull: Value,
    calls: &mut Vec<Vec<String>>,
) -> impl FnMut(&[String]) -> Result<String, String> + '_ {
    move |args: &[String]| {
        calls.push(args.to_vec());
        match args.get(1).map(String::as_str) {
            Some(path) if path.ends_with("/pulls/9") => Ok(pull.to_string()),
            Some("user") => Ok("teamleaderleo\n".into()),
            _ => Ok(String::new()),
        }
    }
}

fn human(answer: Answer) -> (Value, String) {
    match answer {
        Answer::Library { json, human } => (json, human),
        _ => panic!("not a library answer"),
    }
}

#[test]
fn go_marks_the_tried_head_merge_ready_and_lifts_the_look_hold() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let head = "a".repeat(40);
    tried(&customize, 9, &head);
    let pull = json!({"head": head, "state": "open", "merged": false, "draft": false,
                      "title": "Sidebar", "labels": ["needs a call", "risk:low"]});
    let mut calls = Vec::new();
    let (json, said) = human(go_with(&customize, 9, &mut fake(pull, &mut calls)).unwrap());
    assert_eq!(json["head"], head);
    assert_eq!(json["lifted"], true);
    assert_eq!(json["login"], "teamleaderleo");
    assert!(said.contains("merge-ready at aaaaaaaaaaaa"), "{said}");
    let joined: Vec<String> = calls.iter().map(|call| call.join(" ")).collect();
    assert!(
        joined
            .iter()
            .any(|call| call
                .contains("issues/9/labels -f labels[]=land-now -f labels[]=ready-to-land")),
        "{joined:?}"
    );
    assert!(
        joined
            .iter()
            .any(|call| call
                .contains("DELETE repos/manaflow-ai/cmux/issues/9/labels/needs%20a%20call")),
        "{joined:?}"
    );
    assert!(
        joined
            .iter()
            .any(|call| call.contains("issues/9/comments")
                && call.contains(&format!("Go at {head}"))),
        "{joined:?}"
    );
}

#[test]
fn go_refuses_code_the_person_did_not_see() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    // Never tried: no GitHub call at all.
    let mut calls = Vec::new();
    let error = go_with(&customize, 9, &mut fake(json!({}), &mut calls)).err().unwrap();
    assert!(error.message.contains("never tried on here"), "{}", error.message);
    assert!(calls.is_empty());

    // Tried at one head, pushed since: no label.
    tried(&customize, 9, &"a".repeat(40));
    let moved = json!({"head": "b".repeat(40), "state": "open", "merged": false, "labels": []});
    let mut calls = Vec::new();
    let error = go_with(&customize, 9, &mut fake(moved, &mut calls)).err().unwrap();
    assert!(error.message.contains("moved since you tried it"), "{}", error.message);
    assert!(!calls.iter().any(|call| call.iter().any(|arg| arg.contains("labels"))), "{calls:?}");

    for (pull, why) in [
        (json!({"head": "a".repeat(40), "state": "closed", "merged": true}), "merged already"),
        (json!({"head": "a".repeat(40), "state": "closed", "merged": false}), "is closed"),
    ] {
        let mut calls = Vec::new();
        let error = go_with(&customize, 9, &mut fake(pull, &mut calls)).err().unwrap();
        assert!(error.message.contains(why), "{}", error.message);
    }
}

#[test]
fn go_parses_only_a_pr() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    assert_eq!(
        super::super::parse(&words("go pr:57001")).unwrap(),
        super::super::Request::Go { pr: 57001 }
    );
    assert_eq!(
        super::super::parse(&words("go #57001")).unwrap(),
        super::super::Request::Go { pr: 57001 }
    );
    for bad in ["go", "go branch:x", "go pr:1 pr:2", "go --help-me"] {
        assert!(super::super::parse(&words(bad)).is_err(), "{bad}");
    }
}
