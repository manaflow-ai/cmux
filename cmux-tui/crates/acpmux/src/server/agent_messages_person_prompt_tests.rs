use super::counts_as_person_prompt;

#[test]
fn only_a_persons_prompt_counts() {
    assert!(counts_as_person_prompt(false, false, false), "the person's own prompt");
    assert!(!counts_as_person_prompt(true, false, false), "another agent's message");
    assert!(!counts_as_person_prompt(false, true, false), "a trigger's delivery");
    assert!(!counts_as_person_prompt(false, false, true), "a send from inside a session");
}
