use super::{Build, Options, Process, Table, parse, parse_ps, reap, targets};
use std::collections::BTreeMap;
use std::time::Duration;

const BUNDLE: &str = "/Users/me/dev-builds/x/cmux DEV x.app";
const BUNDLE_ID: &str = "com.cmuxterm.app.debug.x";

fn build() -> Build {
    Build::new(BUNDLE, Some(BUNDLE_ID))
}

/// A process whose executable is its command's first word; under a `/bin/` folder (a bundle
/// path may hold spaces), the path up to the space after the program's name.
fn process(pid: i32, ppid: i32, command: &str) -> Process {
    let exe = match command.find("/bin/") {
        Some(bin) => command[bin..].find(' ').map_or(command, |space| &command[..bin + space]),
        None => command.split(' ').next().unwrap_or(command),
    };
    Process { pid, ppid, command: command.to_owned(), exe: exe.to_owned() }
}

fn with_exe(pid: i32, ppid: i32, exe: &str, command: &str) -> Process {
    Process { pid, ppid, command: command.to_owned(), exe: exe.to_owned() }
}

/// The tree a quit Debug DEV build left on a Mac (issue 55842), plus unrelated processes.
fn left_behind() -> Vec<Process> {
    let b = BUNDLE;
    vec![
        process(1, 0, "/sbin/launchd"),
        with_exe(
            100,
            1,
            &format!("{b}/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host"),
            &format!(
                "{b}/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host run -- {b}/Contents/Resources/bin/cmux-tui --headless"
            ),
        ),
        with_exe(
            101,
            100,
            "/Users/me/Library/Application Support/cmux/files-host/app/d0/cmux Files (dev).app/Contents/MacOS/cmux-files-host",
            &format!(
                "/Users/me/Library/Application Support/cmux/files-host/app/d0/cmux Files (dev).app/Contents/MacOS/cmux-files-host host -- {b}/Contents/Resources/bin/cmux-tui --headless"
            ),
        ),
        process(
            102,
            101,
            &format!("{b}/Contents/Resources/bin/cmux-tui --headless --session cmux-app-x"),
        ),
        process(103, 102, "/bin/zsh -l"),
        process(104, 103, "vim notes.txt"),
        process(110, 1, &format!("{b}/Contents/Resources/bin/acpmux daemon run")),
        process(111, 110, &format!("{b}/Contents/Resources/bin/acpmux __agent-host")),
        process(112, 111, "/opt/homebrew/bin/claude --settings /tmp/s.json"),
        process(
            120,
            1,
            &format!("{b}/Contents/Resources/bin/optchat-chief host --daemon-socket /tmp/s"),
        ),
        // The same bundle through another spelling of its folder.
        process(
            121,
            1,
            "/private/Users/me/dev-builds/x/cmux DEV x.app/Contents/Resources/bin/cmux-tui link serve",
        ),
        // A terminal holder of an earlier daemon of this build, adopted by launchd, and its shell.
        process(
            123,
            1,
            "cmux-holder --socket /tmp/cmux-hd-501/00.sock --owner com.cmuxterm.app.debug.x:x@99",
        ),
        process(124, 123, "-zsh"),
        // Another build's holder whose id starts with this one's.
        process(
            125,
            1,
            "cmux-holder --socket /tmp/cmux-hd-501/01.sock --owner com.cmuxterm.app.debug.xy:xy@98",
        ),
        // An agent's shell, an editor and a test script that only name the bundle in arguments.
        with_exe(126, 1, "/bin/bash", &format!("/bin/bash -c ls '{b}/Contents/Resources/bin'")),
        with_exe(127, 1, "/usr/bin/python3", &format!("/usr/bin/python3 quit-live.py x {b}")),
        with_exe(128, 1, "/usr/bin/grep", "/usr/bin/grep -- --owner com.cmuxterm.app.debug.x: log"),
        // Chromium's helper app nested in another build: not this tag.
        process(
            122,
            1,
            "/b/cmux DEV y.app/Contents/Frameworks/cmux DEV Helper.app/Contents/MacOS/cmux DEV Helper",
        ),
        process(200, 1, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux daemon run"),
        process(201, 200, "/opt/homebrew/bin/claude"),
        // Another tag whose name starts with this one's: never matched.
        process(
            300,
            1,
            "/Users/me/dev-builds/x/cmux DEV x.apple.app/Contents/Resources/bin/cmux-tui --headless",
        ),
        // The reaper itself.
        process(900, 1, &format!("{b}/Contents/Resources/bin/cmux-tui __dev-reaper --bundle {b}")),
    ]
}

fn pids(processes: &[Process]) -> Vec<i32> {
    processes.iter().map(|p| p.pid).collect()
}

#[test]
fn targets_the_whole_tree_of_the_bundle_and_nothing_else() {
    let chosen = targets(&build(), 900, &left_behind());
    assert_eq!(pids(&chosen), vec![100, 101, 102, 103, 104, 110, 111, 112, 120, 121, 123, 124]);
}

#[test]
fn spares_everything_while_another_instance_of_the_app_runs() {
    let mut processes = left_behind();
    let app = format!("{BUNDLE}/Contents/MacOS/cmux DEV");
    processes.push(with_exe(500, 1, &app, &app));
    assert!(targets(&build(), 900, &processes).is_empty());
}

#[test]
fn spares_another_reaper_of_the_same_bundle() {
    let mut processes = left_behind();
    processes.push(process(
        901,
        1,
        &format!(
            "{BUNDLE}/Contents/Resources/bin/cmux-tui __dev-reaper --bundle {BUNDLE} --app-pid 7"
        ),
    ));
    assert!(!pids(&targets(&build(), 900, &processes)).contains(&901));
}

#[test]
fn parses_ps_lines_with_spaces_in_paths() {
    let parsed = parse_ps(
        "  1     0 /sbin/launchd\n 4242  1 /a b/cmux DEV x.app/Contents/MacOS/cmux DEV -psn\n 7 1 gone\nbogus\n",
        "  1 /sbin/launchd\n 4242 /a b/cmux DEV x.app/Contents/MacOS/cmux DEV\n",
    );
    assert_eq!(
        parsed,
        vec![
            with_exe(1, 0, "/sbin/launchd", "/sbin/launchd"),
            with_exe(
                4242,
                1,
                "/a b/cmux DEV x.app/Contents/MacOS/cmux DEV",
                "/a b/cmux DEV x.app/Contents/MacOS/cmux DEV -psn"
            ),
        ]
    );
}

#[test]
fn parses_options() {
    let args = |list: &[&str]| list.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        parse(&args(&["--app-pid", "42", "--bundle", "/x/cmux DEV t.app/", "--grace-ms", "250"])),
        Ok(Options {
            app_pid: Some(42),
            bundle: "/x/cmux DEV t.app".into(),
            bundle_id: None,
            grace: Duration::from_millis(250)
        })
    );
    assert!(parse(&args(&["--bundle", "relative.app"])).is_err());
    assert!(parse(&args(&["--bundle", "/x/y"])).is_err());
    assert!(parse(&args(&["--app-pid", "1", "--bundle", "/x/a.app"])).is_err());
    assert!(parse(&args(&["--app-pid", "5"])).is_err());
    assert!(parse(&args(&["--bundle", "/x/a.app", "--bundle-id", "a:b"])).is_err());
    assert_eq!(
        parse(&args(&["--bundle", "/x/a.app", "--bundle-id", "com.x"]))
            .unwrap()
            .bundle_id
            .as_deref(),
        Some("com.x")
    );
}

/// A fake table: SIGTERM ends a process unless it is stubborn; a dying acpmux restarts itself
/// once (the hook that respawned helpers in issue 55842).
struct Fake {
    processes: BTreeMap<i32, Process>,
    stubborn: Vec<i32>,
    respawn: Option<Process>,
    signals: Vec<(i32, i32)>,
}

impl Table for Fake {
    fn snapshot(&mut self) -> Vec<Process> {
        self.processes.values().cloned().collect()
    }
    fn signal(&mut self, pid: i32, signal: i32) {
        self.signals.push((pid, signal));
        if signal == libc::SIGKILL || !self.stubborn.contains(&pid) {
            if self.processes.remove(&pid).is_some() && pid == 110 {
                if let Some(next) = self.respawn.take() {
                    self.processes.insert(next.pid, next);
                }
            }
        }
    }
    fn alive(&mut self, pid: i32) -> bool {
        self.processes.contains_key(&pid)
    }
    fn sleep(&mut self, _: Duration) {}
}

#[test]
fn terminates_then_kills_stubborn_ones_and_catches_a_respawn() {
    let mut fake = Fake {
        processes: left_behind().into_iter().map(|p| (p.pid, p)).collect(),
        stubborn: vec![120],
        respawn: Some(process(
            130,
            1,
            &format!("{BUNDLE}/Contents/Resources/bin/acpmux daemon run"),
        )),
        signals: Vec::new(),
    };
    let ended = reap(&build(), 900, Duration::from_millis(300), &mut fake);
    assert!(ended.contains(&130), "{ended:?}");
    assert!(fake.signals.contains(&(120, libc::SIGKILL)), "{:?}", fake.signals);
    let left: Vec<i32> = fake.processes.keys().copied().collect();
    assert_eq!(left, vec![1, 122, 125, 126, 127, 128, 200, 201, 300, 900]);
}
