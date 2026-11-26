use super::*;

#[test]
fn subcommand_skips_options_and_their_values() {
    let args = ["-c", "core.fsmonitor=false", "-C", "/tmp", "--no-pager", "bundle", "x"];
    assert_eq!(git_name(args.map(OsStr::new)), "git bundle");
    let bare = ["--git-dir", "/q", "cat-file", "-e"];
    assert_eq!(git_name(bare.map(OsStr::new)), "git cat-file");
}

#[test]
fn a_poll_wait_starts_short_and_stops_at_its_ceiling() {
    let mut wait = PollWait::up_to(Duration::from_millis(500));
    let steps: Vec<u64> = (0..8).map(|_| wait.step().as_millis() as u64).collect();
    assert_eq!(steps, [10, 20, 40, 80, 160, 320, 500, 500]);
    // A job that ends in 150 ms is seen after 150 ms of waits, not 500.
    assert_eq!(steps[..4].iter().sum::<u64>(), 150);
    // A ceiling under the first step is the whole wait.
    assert_eq!(PollWait::up_to(Duration::from_millis(4)).step(), Duration::from_millis(4));
}
