use super::*;

#[test]
fn the_test_process_leads_the_group_of_what_it_starts() {
    // A CLI the test ran through a shell: the shell and the CLI stay in
    // the test's group.
    assert_eq!(test_process(50, 30, 40), Some(30));
    // A daemon the test spawned in a group of its own.
    assert_eq!(test_process(50, 50, 30), Some(30));
}

#[test]
fn init_or_no_process_names_no_test() {
    // A process that leads its group and was adopted by init.
    assert_eq!(test_process(50, 50, 1), None);
    assert_eq!(test_process(50, 0, 30), None);
    assert_eq!(test_process(50, 50, 0), None);
}

#[test]
fn the_variable_names_a_pid_and_its_start_time() {
    assert_eq!(
        parse("4242:1700000000000"),
        Some(Starter { pid: 4242, started_ms: 1_700_000_000_000 })
    );
    assert_eq!(parse(" 4242\n"), Some(Starter { pid: 4242, started_ms: 0 }));
    assert_eq!(parse("1"), None);
    assert_eq!(parse("0:5"), None);
    assert_eq!(parse("x"), None);
    assert_eq!(parse("42:x"), None);
    assert_eq!(parse("4294967295"), None);
}
