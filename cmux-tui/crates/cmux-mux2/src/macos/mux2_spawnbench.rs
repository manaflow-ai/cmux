//! `mux2-spawnbench N`: where the time of one terminal create goes.
//! Times `Terminal::new`, `openpty`, and starting `/bin/sleep` with fork +
//! exec and with posix_spawn, N times each. One JSON line, microseconds p50.

use std::time::Instant;

use ghostty_vt::{Callbacks, Terminal};

/// The median of `v`; NaN when `v` is empty.
fn p50(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v.get(v.len() / 2).copied().unwrap_or(f64::NAN)
}

pub fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(200);
    let file = c"/bin/sleep".as_ptr();
    let ptrs: [*const libc::c_char; 3] = [file, c"1000".as_ptr(), std::ptr::null()];
    let (mut t_new, mut t_pty, mut t_fork, mut t_spawn) = (vec![], vec![], vec![], vec![]);
    let mut keep = Vec::new();
    let mut pids = Vec::new();
    for _ in 0..n {
        let t = Instant::now();
        match Terminal::new(80, 24, 10_000_000, Callbacks::default()) {
            Ok(terminal) => keep.push(terminal),
            Err(e) => {
                eprintln!("mux2-spawnbench: terminal: {e}");
                std::process::exit(1);
            }
        }
        t_new.push(t.elapsed().as_secs_f64() * 1e6);

        let (mut m, mut s) = (-1, -1);
        let t = Instant::now();
        // SAFETY: openpty with null name/termios/winsize.
        unsafe {
            libc::openpty(
                &mut m,
                &mut s,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        t_pty.push(t.elapsed().as_secs_f64() * 1e6);

        let t = Instant::now();
        // SAFETY: the bench is single-threaded; the child only execs.
        let pid = unsafe { libc::fork() };
        if pid == 0 {
            // SAFETY: child: async-signal-safe exec or exit.
            unsafe {
                libc::execv(file, ptrs.as_ptr());
                libc::_exit(127);
            }
        }
        t_fork.push(t.elapsed().as_secs_f64() * 1e6);
        pids.push(pid);

        let mut pid2 = 0;
        let t = Instant::now();
        // SAFETY: posix_spawn with default attributes and a valid argv.
        unsafe {
            libc::posix_spawn(
                &mut pid2,
                file,
                std::ptr::null(),
                std::ptr::null(),
                ptrs.as_ptr() as _,
                std::ptr::null(),
            );
        }
        t_spawn.push(t.elapsed().as_secs_f64() * 1e6);
        pids.push(pid2);
        // SAFETY: closing the PTY pair opened above.
        unsafe {
            libc::close(m);
            libc::close(s)
        };
    }
    for pid in pids {
        // SAFETY: ending and reaping our own children.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
            libc::waitpid(pid, std::ptr::null_mut(), 0);
        }
    }
    println!(
        "{{\"spawnbench\":{n},\"terminal_new_us\":{:.1},\"openpty_us\":{:.1},\"fork_us\":{:.1},\"posix_spawn_us\":{:.1}}}",
        p50(t_new),
        p50(t_pty),
        p50(t_fork),
        p50(t_spawn)
    );
}
