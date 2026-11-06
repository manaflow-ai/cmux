//! A silent turn ends the harness's unbounded file listing, and only that (`silent_listing.rs`).

use super::unbounded_listing;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn claude_codes_folder_count_is_an_unbounded_listing() {
    // The exact command Leo's stuck chat ran (cosmic-gray, 2026-11-06 00:21Z).
    assert!(unbounded_listing(&words("rg --no-config --files --hidden /Users/leoli/Projects")));
    assert!(unbounded_listing(&words("/opt/bin/rg --files --hidden --glob !.git /p")));
}

#[test]
fn bounded_or_tool_listings_are_left_alone() {
    // Depth-bounded scans (sandbox, plugins) and a Glob tool call (`--null`, a picking glob).
    for line in [
        "rg --files --hidden --no-ignore --no-config --line-buffered --max-depth 4 /p",
        "rg --files --hidden --max-depth=3 /p",
        "rg --files --null --glob *.rs --sort=modified --no-ignore --hidden /p",
        "rg --files --hidden --follow --no-ignore --glob *.md /p",
        "rg --files /p",
        "rg --hidden needle /p",
        "fd --files --hidden /p",
    ] {
        assert!(!unbounded_listing(&words(line)), "{line}");
    }
}

/// A process named `rg` with the folder count's arguments, under this test, ends on SIGTERM;
/// a sibling with other arguments runs on.
#[cfg(target_os = "linux")]
#[test]
fn terminate_under_ends_only_the_listing_it_picks() {
    use std::os::unix::process::CommandExt;
    use std::process::Command;
    // bash renamed `rg`, its argv the folder count's words; `; :` keeps it from exec'ing sleep.
    let spawn = |words: &str| {
        Command::new("/bin/bash")
            .args(["-c", &format!("exec -a rg /bin/bash -c 'sleep 20; :' {words}")])
            .process_group(0)
            .spawn()
            .unwrap()
    };
    let mut listing = spawn("--files --hidden /p");
    let mut other = spawn("--hidden needle /p");
    // Let both exec so their argv is the one the kernel reports.
    std::thread::sleep(std::time::Duration::from_millis(300));
    let ended =
        crate::agent_host::tree::terminate_under(&[std::process::id()], |a| unbounded_listing(a));
    assert_eq!(ended.iter().map(|(pid, _)| *pid).collect::<Vec<_>>(), vec![listing.id()]);
    let status = listing.wait().unwrap();
    assert!(!status.success(), "the listing ended on its signal: {status:?}");
    assert!(other.try_wait().unwrap().is_none(), "a process the filter does not pick runs on");
    for group in [listing.id(), other.id()] {
        // SAFETY: each group is one this test started (`process_group(0)`).
        unsafe { libc::killpg(i32::try_from(group).unwrap(), libc::SIGKILL) };
    }
    let _ = other.wait();
}
