use super::account_shell;

#[test]
fn account_shell_lookup_is_owned_and_safe_to_run_concurrently() {
    let uid = unsafe { libc::getuid() };
    let expected = account_shell(uid);
    let workers = (0..16)
        .map(|_| {
            let expected = expected.clone();
            std::thread::spawn(move || {
                for _ in 0..64 {
                    assert_eq!(account_shell(uid), expected);
                }
            })
        })
        .collect::<Vec<_>>();

    for worker in workers {
        worker.join().unwrap();
    }
}
