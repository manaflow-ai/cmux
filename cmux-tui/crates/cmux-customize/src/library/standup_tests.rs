use super::*;
use crate::library::{CodeLayer, Conflict, Thumbnail};
use serde_json::json;

fn entry(position: usize, name: &str, on: bool) -> Listed {
    Listed {
        position,
        name: name.to_owned(),
        on,
        source: "ask".to_owned(),
        words: Vec::new(),
        description: String::new(),
        thumbnail: Thumbnail::default(),
        settings: Vec::new(),
        files: Vec::new(),
        added_ms: None,
        overridden: Vec::new(),
        code: None,
        until_ms: None,
    }
}

fn code(kind: CodeKind, pr: u64, source: &str, title: &str, note: &str) -> CodeLayer {
    serde_json::from_value(json!({
        "kind": kind.as_str(),
        "source": source,
        "repo": "manaflow-ai/cmux",
        "pr": pr,
        "title": title,
        "head": "3ea2d75aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "note": note,
    }))
    .expect("a code layer")
}

fn receipt(id: &str, name: &str) -> Receipt {
    serde_json::from_value(json!({
        "id": id,
        "name": name,
        "source": { "kind": "repo", "reference": { "host": "github.com", "owner": "manaflow-ai", "repo": "ember-look" } },
        "repository": "github.com/manaflow-ai/ember-look",
        "commit": "0123456",
        "sha256": "00",
        "installed_ms": 1,
        "on": true,
    }))
    .expect("a receipt")
}

#[test]
fn code_first_then_repos_then_recipes_each_with_its_state_and_link() {
    let mut recipe = entry(1, "warm-tabs", true);
    recipe.words = vec!["make the tabs warmer".to_owned()];
    let setup = entry(2, &crate::setup::profile_name("manaflow-ai/ember-look"), false);
    let mut pr = entry(3, "pr-43496", true);
    pr.code = Some(code(CodeKind::Pr, 43496, "", "Cat icon", "in your build"));
    let mut lower = entry(4, "pr-10", true);
    lower.code = Some(code(CodeKind::Pr, 10, "", "", ""));
    let mut fork = entry(5, "fork-someone-idea", false);
    fork.code = Some(code(CodeKind::Fork, 0, "someone/cmux@idea", "", ""));
    let listing = Listing {
        entries: vec![recipe, setup, pr, lower, fork],
        conflicts: vec![Conflict {
            kind: "code",
            key: "code:web".to_owned(),
            winner: "pr-43496".to_owned(),
            losers: vec!["pr-10".to_owned()],
        }],
    };
    let report = standup(&listing, &[receipt("manaflow-ai/ember-look", "Ember")], 0);
    let names: Vec<&str> = report.lines.iter().map(|line| line.name.as_str()).collect();
    assert_eq!(
        names,
        ["pr-43496", "pr-10", "fork-someone-idea", "setup-manaflow-ai-ember-look", "warm-tabs"]
    );
    assert_eq!(report.on, 3);
    let pr = &report.lines[0];
    assert_eq!(
        (pr.kind, pr.title.as_str(), pr.status.as_str()),
        ("pr", "#43496 Cat icon", "on · in your build")
    );
    assert_eq!(pr.link.as_deref(), Some("https://github.com/manaflow-ai/cmux/pull/43496"));
    assert_eq!(report.lines[1].status, "on · pr-43496 wins over it");
    assert_eq!(report.lines[2].link.as_deref(), Some("https://github.com/someone/cmux/tree/idea"));
    let setup = &report.lines[3];
    assert_eq!((setup.kind, setup.title.as_str()), ("setup", "Ember (manaflow-ai/ember-look)"));
    assert_eq!(setup.link.as_deref(), Some("https://github.com/manaflow-ai/ember-look"));
    assert_eq!(report.lines[4].title, "warm-tabs: make the tabs warmer");
    assert_eq!(
        report.text,
        "Customizations: 3 on of 5\n\
         \nUnmerged code in my build\n\
         - [x] #43496 Cat icon: on · in your build https://github.com/manaflow-ai/cmux/pull/43496\n\
         - [x] #10: on · pr-43496 wins over it https://github.com/manaflow-ai/cmux/pull/10\n\
         - [ ] fork someone/cmux@idea: off https://github.com/someone/cmux/tree/idea\n\
         \nRepos\n\
         - [ ] Ember (manaflow-ai/ember-look): off https://github.com/manaflow-ai/ember-look\n\
         \nRecipes\n\
         - [x] warm-tabs: make the tabs warmer: on\n"
    );
}

#[test]
fn a_try_says_how_long_it_has_left() {
    let mut tried = entry(1, "branch-lane-cat", true);
    tried.code = Some(code(CodeKind::Branch, 0, "lane/cat", "", ""));
    tried.until_ms = Some(4 * 60_000 + 1);
    let report = standup(&Listing { entries: vec![tried], conflicts: Vec::new() }, &[], 0);
    assert_eq!(report.lines[0].status, "on for a try, 5 min left");
    assert_eq!(
        report.lines[0].link.as_deref(),
        Some("https://github.com/manaflow-ai/cmux/tree/lane/cat")
    );
}

#[test]
fn an_empty_library_says_how_to_start() {
    let report = standup(&Listing { entries: Vec::new(), conflicts: Vec::new() }, &[], 0);
    assert!(report.lines.is_empty());
    assert!(report.text.contains("cmux customize use pr:N"));
}
