//! Which threads of a process ran in a measured window, for the idle tests:
//! a thread pool that runs in more than one window is woken by a timer, not
//! an event, however little each wake costs (a 5-second loop costs 2 switches
//! per 10-second window, under the process limit, and still wakes the Mac all
//! day).

/// Each thread of `pid` by id: its name and a counter that grows whenever the
/// thread runs (context switches on Linux, CPU time in nanoseconds on macOS,
/// which has no per-thread switch count).
#[cfg(target_os = "linux")]
pub fn thread_activity(pid: u32) -> std::collections::HashMap<u64, (String, u64)> {
    std::fs::read_dir(format!("/proc/{pid}/task"))
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|task| {
            let tid = task.file_name().to_str()?.parse::<u64>().ok()?;
            let name = std::fs::read_to_string(task.path().join("comm")).ok()?.trim().to_string();
            let switches = std::fs::read_to_string(task.path().join("status"))
                .ok()?
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .sum();
            Some((tid, (name, switches)))
        })
        .collect()
}

#[cfg(target_os = "macos")]
pub fn thread_activity(pid: u32) -> std::collections::HashMap<u64, (String, u64)> {
    use std::os::raw::{c_char, c_int, c_void};

    #[repr(C)]
    struct ThreadInfo {
        user_time: u64,
        system_time: u64,
        cpu_usage: i32,
        policy: i32,
        run_state: i32,
        flags: i32,
        sleep_time: i32,
        current_priority: i32,
        priority: i32,
        max_priority: i32,
        name: [c_char; 64],
    }

    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
    }
    const PROC_PIDLISTTHREADS: c_int = 6;
    const PROC_PIDTHREADINFO: c_int = 5;

    let mut handles = vec![0_u64; 4096];
    let size = (handles.len() * size_of::<u64>()) as c_int;
    // SAFETY: the buffer holds `size` bytes of thread handles.
    let filled = unsafe {
        proc_pidinfo(pid as c_int, PROC_PIDLISTTHREADS, 0, handles.as_mut_ptr().cast(), size)
    };
    handles.truncate(usize::try_from(filled).unwrap_or(0) / size_of::<u64>());
    handles
        .into_iter()
        .filter_map(|handle| {
            // SAFETY: zeroed is a valid ThreadInfo (integers and a C string).
            let mut info: ThreadInfo = unsafe { std::mem::zeroed() };
            let size = size_of::<ThreadInfo>() as c_int;
            // SAFETY: the buffer matches the PROC_PIDTHREADINFO layout and size.
            let read = unsafe {
                proc_pidinfo(pid as c_int, PROC_PIDTHREADINFO, handle, (&raw mut info).cast(), size)
            };
            (read == size).then(|| {
                // SAFETY: the kernel NUL-terminates the thread name.
                let name = unsafe { std::ffi::CStr::from_ptr(info.name.as_ptr()) };
                (handle, (name.to_string_lossy().into_owned(), info.user_time + info.system_time))
            })
        })
        .collect()
}

/// Thread names of the daemon (a name is one pool, such as the async
/// runtime's workers, which take each other's work) whose threads ran in at
/// least `min` windows, each with the windows it ran in (1-based). A timer
/// wakes a pool on any of its threads, and a period longer than a window
/// skips windows: a 15 s period runs in 2 of each 3 windows of 10 s, a 30 s
/// period in 1 of 3, so no single thread runs in every window. Over 6 windows
/// any period up to 30 s runs in 2 windows or more; a one-off event runs in
/// one.
pub fn names_in_windows(
    marks: &[std::collections::HashMap<u64, (String, u64)>],
    min: usize,
) -> Vec<String> {
    let mut ran: std::collections::BTreeMap<&str, Vec<usize>> = std::collections::BTreeMap::new();
    for (index, pair) in marks.windows(2).enumerate() {
        let mut names: Vec<&str> = pair[1]
            .iter()
            .filter(|(id, (_, after))| pair[0].get(*id).is_some_and(|(_, before)| after > before))
            .map(|(_, (name, _))| if name.is_empty() { "(unnamed)" } else { name.as_str() })
            .collect();
        names.sort_unstable();
        names.dedup();
        for name in names {
            ran.entry(name).or_default().push(index + 1);
        }
    }
    ran.into_iter()
        .filter(|(_, windows)| windows.len() >= min)
        .map(|(name, windows)| format!("{name} (ran in windows {windows:?})"))
        .collect()
}
