//! Termination of a host that closed its link before the daemon set or
//! restored the link's read timeout.

use super::*;

#[test]
fn termination_reads_the_exit_of_a_host_that_already_closed_its_link() {
    let (mut attachment, mut host) = input_ack_surface_fixture();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
        exited_at_ms: 1,
    };
    // The host queues its exit and closes its sending direction. The legacy
    // Terminate then closes the daemon's sending direction. Both directions
    // of the link are now shut down, as after the host process ended: macOS
    // refuses SO_RCVTIMEO on that socket with EINVAL.
    write_frame(&mut host, &Frame::new(MessageKind::Exit, encode_terminal_exit(&exit))).unwrap();
    host.shutdown(std::net::Shutdown::Write).unwrap();

    let record = attachment
        .terminate_and_wait_for_exit()
        .expect("a host that closed its link after its exit frame still reports its exit");

    assert_eq!(record, TerminalHostExitRecord::new(&attachment.identity(), exit));
    let request = read_required_frame(&mut host, "terminate request").unwrap();
    assert_eq!(request.kind, MessageKind::Terminate);
}
