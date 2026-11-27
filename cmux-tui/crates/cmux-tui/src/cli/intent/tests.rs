use super::*;
use crate::cli::completion::verbs;

const ROOT: &str = "cmux

COMMANDS
  session    Agent sessions
  vm         Cloud machines
  status     What is running
  get        Read one thing
  list       List things
";
const VM: &str = "cmux vm

  cmux vm ls | status | pause [NAME]
";

fn run(args: &[&str]) -> (Option<Vec<String>>, String) {
    let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    let mut err = Vec::new();
    let fixed = fix(
        &args,
        ROOT,
        &|scope| if scope == "vm" { verbs("vm", VM) } else { Vec::new() },
        &cmux_intent::Table::embedded(),
        &mut err,
    );
    (fixed, String::from_utf8(err).unwrap())
}

fn words(v: &[&str]) -> Option<Vec<String>> {
    Some(v.iter().map(|s| (*s).to_owned()).collect())
}

#[test]
fn a_synonym_scope_runs_the_one_it_meant() {
    let (fixed, said) = run(&["sessions", "ls"]);
    assert_eq!(fixed, words(&["session", "ls"]));
    assert!(said.contains("ran `session` for `sessions`"), "{said}");
}

#[test]
fn a_mistyped_scope_runs_the_close_match() {
    let (fixed, _) = run(&["--session", "x", "sesion", "ls"]);
    assert_eq!(fixed, words(&["--session", "x", "session", "ls"]));
}

#[test]
fn a_synonym_verb_under_a_scope_runs() {
    let (fixed, _) = run(&["vm", "list"]);
    assert_eq!(fixed, words(&["vm", "ls"]));
}

#[test]
fn an_ambiguous_scope_lists_the_candidates_and_runs_nothing() {
    let (fixed, said) = run(&["info"]);
    assert_eq!(fixed, None);
    assert!(said.contains("could mean (nothing ran)"), "{said}");
}

#[test]
fn a_destructive_verb_with_a_typo_needs_its_exact_form() {
    let (fixed, said) = run(&["vm", "paus", "box"]);
    assert_eq!(fixed, None);
    assert!(said.contains("exact form is needed"), "{said}");
}

#[test]
fn a_valid_form_is_untouched() {
    assert_eq!(run(&["session", "ls"]).0, None);
    assert_eq!(run(&["vm", "status"]).0, None);
}
