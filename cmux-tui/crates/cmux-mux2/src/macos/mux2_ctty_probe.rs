//! `mux2-ctty-probe N`: can posix_spawn give a child its PTY as the
//! controlling terminal? Spawns `/bin/sh` with POSIX_SPAWN_SETSID and the PTY
//! slave opened by path as fds 0-2, then has the shell report its tty, its
//! session and its foreground process group. Also times posix_openpt +
//! grantpt + unlockpt + ptsname against openpty, N times each.

use std::ffi::{CStr, CString};
use std::time::Instant;

const POSIX_SPAWN_SETSID: libc::c_short = 0x0400;

/// The median of `v`; NaN when `v` is empty.
fn p50(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v.get(v.len() / 2).copied().unwrap_or(f64::NAN)
}

fn open_pt() -> (libc::c_int, CString) {
    // SAFETY: standard PTY master allocation calls with valid buffers.
    unsafe {
        let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
        assert!(m >= 0);
        libc::grantpt(m);
        libc::unlockpt(m);
        let mut name = [0 as libc::c_char; 128];
        // TIOCPTYGNAME writes the slave path into a 128-byte buffer.
        assert_eq!(libc::ioctl(m, libc::TIOCPTYGNAME as _, name.as_mut_ptr()), 0);
        (m, CStr::from_ptr(name.as_ptr()).to_owned())
    }
}

pub fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(200);
    let (mut t_open, mut t_pt) = (vec![], vec![]);
    for _ in 0..n {
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
        t_open.push(t.elapsed().as_secs_f64() * 1e6);
        // SAFETY: closing what openpty opened.
        unsafe {
            libc::close(m);
            libc::close(s)
        };
        let t = Instant::now();
        let (m, _) = open_pt();
        t_pt.push(t.elapsed().as_secs_f64() * 1e6);
        // SAFETY: closing the master.
        unsafe { libc::close(m) };
    }

    let (master, slave_path) = open_pt();
    let script = c"printf 'tty=%s ' \"$(tty)\"; ps -o sess=,tpgid=,pgid=,tty= -p $$ | tr -s ' ' | sed 's/^/sess,tpgid,pgid,tty=/'; \
         sleep 0.1 & wait; echo job-control-ok";
    let file = c"/bin/sh".as_ptr();
    let argv = [file, c"-c".as_ptr(), script.as_ptr(), std::ptr::null()];
    let mut pid = 0;
    // SAFETY: posix_spawn attribute and file-action setup with valid pointers.
    let rc = unsafe {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawnattr_setflags(&mut attr, POSIX_SPAWN_SETSID);
        let mut fa: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        libc::posix_spawn_file_actions_init(&mut fa);
        libc::posix_spawn_file_actions_addopen(&mut fa, 0, slave_path.as_ptr(), libc::O_RDWR, 0);
        libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 1);
        libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 2);
        libc::posix_spawn_file_actions_addclose(&mut fa, master);
        let t = Instant::now();
        let rc =
            libc::posix_spawn(&mut pid, file, &fa, &attr, argv.as_ptr() as _, std::ptr::null());
        eprintln!("posix_spawn with setsid + addopen: {:.1} us", t.elapsed().as_secs_f64() * 1e6);
        rc
    };
    assert_eq!(rc, 0, "posix_spawn failed");
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        // SAFETY: reading the master into a valid buffer.
        let k = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
        if k <= 0 {
            break;
        }
        out.extend_from_slice(buf.get(..k as usize).unwrap_or_default());
        if out.windows(14).any(|w| w == b"job-control-ok") {
            break;
        }
    }
    let mut status = 0;
    // SAFETY: reaping our child.
    unsafe { libc::waitpid(pid, &mut status, 0) };
    println!(
        "{{\"openpty_us\":{:.1},\"posix_openpt_us\":{:.1},\"child_pid\":{pid},\"slave\":{:?},\"child_report\":{:?}}}",
        p50(t_open),
        p50(t_pt),
        slave_path,
        String::from_utf8_lossy(&out).trim()
    );
}
