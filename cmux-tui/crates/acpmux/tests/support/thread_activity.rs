//! Which threads of a process ran in a measured window, for the idle tests:
//! a thread that runs in every window is woken by a timer, not an event,
//! however little each wake costs (a 5-second loop costs 2 switches per
//! 10-second window, under the process limit, and still wakes the Mac all day).

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

/// Threads of the daemon that ran in every window: a timer wakes them, not
/// an event, however little each wake costs. A one-off event (a late journal
/// fsync, a deadline set during setup) runs a thread in one window.
pub fn periodic_threads(marks: &[std::collections::HashMap<u64, (String, u64)>]) -> Vec<String> {
    let Some(first) = marks.first() else { return Vec::new() };
    let mut periodic: Vec<String> = first
        .iter()
        .filter(|(id, _)| {
            marks.windows(2).all(|pair| match (pair[0].get(id), pair[1].get(id)) {
                (Some((_, before)), Some((_, after))) => after > before,
                _ => false,
            })
        })
        .map(|(id, (name, _))| format!("{name} (thread {id})"))
        .collect();
    periodic.sort();
    periodic
}
