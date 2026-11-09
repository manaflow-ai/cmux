//! Termination of a host that ended before the daemon sent its request.

use super::*;

#[test]
fn legacy_termination_reads_the_exit_of_a_host_that_ended_before_the_request() {
    let (record_path, mut record, lease) = record_fixture("legacy-terminate-ended-host");
    record.supports_terminate_ack = false;
    let (mut attachment, mut host) = input_ack_surface_fixture();
    attachment.record = record;
    attachment.record_path = record_path.clone();
    let expected = TerminalHostExitRecord::new(
        &attachment.identity(),
        TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
            exited_at_ms: 1,
        },
    );
    // The host persisted its exit, queued its Exit frame and ended before the
    // daemon sent Terminate, so that write fails with EPIPE.
    write_exit_record(&attachment.exit_record_path(), &expected).unwrap();
    write_frame(&mut host, &Frame::new(MessageKind::Exit, encode_terminal_exit(&expected.exit)))
        .unwrap();
    drop(host);

    let exit = attachment
        .terminate_and_wait_for_exit()
        .expect("a host that ended before the Terminate request still reports its exit");

    assert_eq!(exit, expected);
    drop(attachment);
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}
