use super::still_connecting_line;

#[test]
fn an_invitation_wait_names_the_host_commands_that_approve_it() {
    let line = still_connecting_line(8, None, Some("CI3913cdem3cZSqR2jimyA"));
    assert_eq!(
        line,
        "remote connect: waiting 8s for the host to approve this device; on the host, \
             `cmux remote enroll pending` lists it and \
             `cmux remote enroll approve CI3913cdem3cZSqR2jimyA` lets it in"
    );
}

#[test]
fn a_failing_or_plain_connect_keeps_its_line() {
    assert_eq!(
        still_connecting_line(4, Some("connection refused"), Some("id")),
        "remote connect: still connecting after 4s; last: connection refused"
    );
    assert_eq!(still_connecting_line(4, None, None), "remote connect: still connecting after 4s");
}
