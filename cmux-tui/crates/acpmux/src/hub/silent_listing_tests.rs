//! A silent turn ends the harness's unbounded file listing, and only that (`silent_listing.rs`).

use super::{still_silent, unbounded_listing};

/// The process tests below spawn listings under this test process and look for them there: run
/// one at a time, or one would see (and end) the other's (review F2 of #36966).
#[cfg(target_os = "linux")]
static PROCESSES: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn claude_codes_folder_count_is_an_unbounded_listing() {
    // The exact command Leo's stuck chat ran (cosmic-gray, 2026-11-06 00:21Z).
    assert!(unbounded_listing(&words("rg --no-config --files --hidden /Users/leoli/Projects")));
    assert!(unbounded_listing(&words("/opt/bin/rg --files --hidden --glob !.git /p")));
    assert!(unbounded_listing(&words("rg --files --hidden --glob=!.git -g!node_modules /p")));
}

#[test]
fn bounded_or_tool_listings_are_left_alone() {
    // Depth-bounded scans (sandbox, plugins) and a Glob tool call (`--null`, a picking glob).
    for line in [
        "rg --files --hidden --no-ignore --no-config --line-buffered --max-depth 4 /p",
        "rg --files --hidden --max-depth=3 /p",
        "rg --files --hidden -d 4 /p",
        "rg --files --hidden -d4 /p",
        "rg --files --hidden -d=4 /p",
        "rg --files --hidden --maxdepth 2 /p",
        "rg --files --hidden --maxdepth=2 /p",
        "rg --files --hidden -0 /p",
        "rg --files --null --glob *.rs --sort=modified --no-ignore --hidden /p",
        "rg --files --hidden --follow --no-ignore --glob *.md /p",
        "rg --files --hidden --glob=*.rs /p",
        "rg --files --hidden --iglob=*.rs /p",
        "rg --files --hidden -g*.rs /p",
        "rg --files --hidden --glob",
        "rg --files /p",
        "rg --hidden needle /p",
        "fd --files --hidden /p",
    ] {
        assert!(!unbounded_listing(&words(line)), "{line}");
    }
}

/// A listing is ended only while the turn that went silent still runs and is still silent: a
/// turn that heard its model, or ended for the next one, while its listings were being found
/// leaves them alone, so the next turn's own count runs on (review 5 F1 of #36966).
#[test]
fn a_listing_is_ended_only_while_its_turn_runs_silent() {
    assert!(still_silent(Some("t1"), Some("t1"), "t1"));
    assert!(!still_silent(None, Some("t1"), "t1"), "the turn heard its model");
    assert!(!still_silent(Some("t1"), Some("t2"), "t1"), "the next turn runs");
    assert!(!still_silent(Some("t1"), None, "t1"), "the turn ended");
}

/// A process named `rg` with the folder count's arguments, under this test, ends on SIGTERM;
/// a sibling with other arguments runs on.
#[cfg(target_os = "linux")]
#[test]
fn terminate_under_ends_only_the_listing_it_picks() {
    let _one = PROCESSES.lock().unwrap_or_else(|e| e.into_inner());
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
    let under = crate::agent_host::tree::descendants(&[std::process::id()]);
    let ended = crate::agent_host::tree::terminate_picked(&under, unbounded_listing);
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

/// A hosted agent's listings are found by its host's start nonce (`HOST_MARK`), never by a pid:
/// a listing that carries another host's nonce, or none, runs on (review F1 of #36966).
#[cfg(target_os = "linux")]
#[test]
fn a_hosted_agents_listings_are_found_by_its_hosts_nonce() {
    let _one = PROCESSES.lock().unwrap_or_else(|e| e.into_inner());
    use std::os::unix::process::CommandExt;
    use std::process::Command;
    let mark = crate::agent_host::HOST_MARK;
    let ours = format!("silent-listing-{}", std::process::id());
    let spawn = |nonce: Option<&str>| {
        let mut command = Command::new("/bin/bash");
        command
            .args(["-c", "exec -a rg /bin/bash -c 'sleep 20; :' --files --hidden /p"])
            .env_remove(mark)
            .process_group(0);
        if let Some(nonce) = nonce {
            command.env(mark, nonce);
        }
        command.spawn().unwrap()
    };
    let mut listing = spawn(Some(&ours));
    let mut other_host = spawn(Some("another-host"));
    let mut unmarked = spawn(None);
    std::thread::sleep(std::time::Duration::from_millis(300));
    let marked = crate::agent_host::tree::marked(mark, &ours);
    let ended = crate::agent_host::tree::terminate_picked(&marked, unbounded_listing);
    assert_eq!(ended.iter().map(|(pid, _)| *pid).collect::<Vec<_>>(), vec![listing.id()]);
    assert!(!listing.wait().unwrap().success());
    assert!(other_host.try_wait().unwrap().is_none(), "another host's listing runs on");
    assert!(unmarked.try_wait().unwrap().is_none(), "a listing with no nonce runs on");
    for child in [&mut other_host, &mut unmarked] {
        // SAFETY: each group is one this test started (`process_group(0)`).
        unsafe { libc::killpg(i32::try_from(child.id()).unwrap(), libc::SIGKILL) };
        let _ = child.wait();
    }
}
