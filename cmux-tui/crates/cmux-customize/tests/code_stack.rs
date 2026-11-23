//! Code layers built as one series (cmuxterm-hq RFD 0038, phase 4 step 11):
//! with two PR layers on, the stack CI built from both serves in place of the
//! top one, and only while exactly those layers are on.

use std::fs;

use cmux_customize::library::{CodeLayer, StackLayer, stack};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

fn key(n: u8) -> String {
    format!("{n:064x}")
}

fn layer(pr: u64, n: u8) -> CodeLayer {
    CodeLayer {
        kind: Default::default(),
        source: String::new(),
        repo: "manaflow-ai/cmux".to_owned(),
        pr,
        title: format!("pr {pr}"),
        head: format!("{n:040x}"),
        base: format!("{:040x}", 99_u8),
        web: key(n),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    }
}

fn install(customize: &Customize, n: u8) -> String {
    let dir = customize.layer_dir(&key(n));
    fs::create_dir_all(dir.join("pages")).unwrap();
    fs::write(dir.join("manifest.json"), "{}").unwrap();
    dir.to_string_lossy().into_owned()
}

fn overlay(home: &tempfile::TempDir) -> Value {
    let text = fs::read_to_string(home.path().join("config/web-dev.json")).unwrap();
    serde_json::from_str::<Value>(&text).unwrap()["overlay"].clone()
}

#[test]
fn items_name_each_change_bottom_first_and_only_what_ci_builds() {
    assert_eq!(stack::item(&layer(7, 1)), Some(format!("pr:7@{:040x}", 1)));
    let mut fork = layer(7, 1);
    fork.repo = "someone/cmux".into();
    assert_eq!(stack::item(&fork), None);
    let mut short = layer(7, 1);
    short.head = "abc".into();
    assert_eq!(stack::item(&short), None);
    // The id CI publishes under: sha256 of the items, one per line, 24 hex.
    let id = StackLayer::id(&["a".into(), "b".into()]);
    assert_eq!(id.len(), 24);
    assert_eq!(id, "7e18f737311b2dc3b2f269dd"); // the workflow computes the same
    assert_ne!(id, StackLayer::id(&["b".into(), "a".into()]));
}

#[test]
fn the_stack_serves_while_its_layers_are_on_and_the_top_one_otherwise() {
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let low = install(&customize, 1);
    let high = install(&customize, 2);
    let built = install(&customize, 3);

    let (items, none) = customize.library_stack().unwrap();
    assert_eq!((items, none), (None, None));
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    assert_eq!(overlay(&home), json!(high));

    let (items, none) = customize.library_stack().unwrap();
    let items = items.unwrap();
    assert_eq!(items, vec![format!("pr:10@{:040x}", 1), format!("pr:20@{:040x}", 2)]);
    assert_eq!(none, None);

    let stack = StackLayer {
        items: items.clone(),
        base: format!("{:040x}", 98),
        web: key(3),
        abi: Some(1),
    };
    customize.library_set_stack(stack.clone(), "cli", 3).unwrap();
    assert_eq!(overlay(&home), json!(built));
    assert_eq!(customize.library_stack().unwrap().1, Some(stack.clone()));

    // One layer off: the other serves alone; on again: the stack again.
    customize.library_set_on("pr-20", false, "cli", 4).unwrap();
    assert_eq!(overlay(&home), json!(low));
    assert_eq!(customize.library_stack().unwrap(), (None, None));
    customize.library_set_on("pr-20", true, "cli", 5).unwrap();
    assert_eq!(overlay(&home), json!(built));

    // Another order is another series: the top one serves until it is built.
    customize.library_order("pr-20", cmux_customize::library::Position::Bottom, "cli", 6).unwrap();
    assert_eq!(overlay(&home), json!(low));
    assert!(customize.library_set_stack(stack, "cli", 7).is_err());
    assert_eq!(overlay(&home), json!(low));
}

#[test]
fn a_stack_not_on_this_computer_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    install(&customize, 1);
    let high = install(&customize, 2);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    let items = customize.library_stack().unwrap().0.unwrap();
    let stack = StackLayer { items, base: format!("{:040x}", 98), web: key(4), abi: None };
    assert!(customize.library_set_stack(stack, "cli", 3).is_err());
    assert_eq!(overlay(&home), json!(high));
}
