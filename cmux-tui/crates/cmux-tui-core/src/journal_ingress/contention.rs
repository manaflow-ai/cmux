//! Contention on the session journal is transient.
//!
//! The journal writer shares the workspace registry mutex and the SQLite
//! database with every other mutation. Under load (hundreds of terminals
//! starting at once) a batch can wait past its deadline for that lock. That
//! is congestion, not a broken store: the writer gives the callers that wait
//! on the batch their timeout, keeps the terminal output that nobody waits
//! on, and retries it. Only other errors (a store that rejects the write) can
//! fail the writer for good. Before, one 2 s wait failed the writer, every
//! terminal reader then stopped the daemon, and its hosts were left without
//! an owner (about 260 terminals on a 32-vCPU Linux VM).

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::mpsc::sync_channel;
    use std::time::Duration;

    use crate::Mux;
    use crate::resource::TerminalPublicId;

    #[test]
    fn registry_lock_held_past_the_journal_deadline_does_not_fail_the_writer() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-contention-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("journal-contention", crate::SurfaceOptions::default(), &root)
                .unwrap();
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);

        // A slow registry holder: longer than the writer's 2 s deadline.
        let locked_mux = mux.clone();
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel(1);
        let blocker = std::thread::spawn(move || {
            locked_mux.hold_workspace_registry_for_test(entered, release_receiver);
        });
        entered_receiver.recv().unwrap();
        let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 21)).unwrap());
        mux.journal_terminal_output(
            terminal_id.clone(),
            Arc::from("contention-generation"),
            b"output while the registry is busy".to_vec(),
        );
        std::thread::sleep(
            crate::journal_ingress::JOURNAL_DURABLE_WAIT + Duration::from_millis(1500),
        );
        release.send(()).unwrap();
        blocker.join().unwrap();

        assert!(
            failed_receiver.try_recv().is_err(),
            "registry contention must not fail the journal writer permanently"
        );
        mux.journal_terminal_output(
            terminal_id,
            Arc::from("contention-generation"),
            b"output after the registry is free".to_vec(),
        );
        mux.flush_terminal_journal().unwrap();
        let outputs = mux
            .session_journal_after(0, 1024)
            .unwrap()
            .records
            .into_iter()
            .filter(|record| record.kind == "terminal.output")
            .filter_map(|record| record.terminal_output)
            .collect::<Vec<_>>();
        assert!(
            outputs.iter().any(|bytes| &bytes[..] == b"output while the registry is busy"),
            "output queued during the contention must commit after it: {outputs:?}"
        );
        assert!(
            outputs.iter().any(|bytes| &bytes[..] == b"output after the registry is free"),
            "the writer must keep accepting output: {outputs:?}"
        );
        assert!(!mux.daemon_shutdown_requested());
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
