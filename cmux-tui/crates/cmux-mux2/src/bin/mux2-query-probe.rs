//! `mux2-query-probe [N]`: runs inside a terminal, as `bench/query-rtt.pl`
//! does, on every OS (Windows has no perl or stty). Sends N cursor-position
//! reports (CSI 6 n) at known positions and N primary device attribute
//! queries (CSI c), waits for each reply, checks it, and prints one JSON
//! line with reply latency percentiles. A wrong or missing reply prints
//! `BAD-...` and exits 1.

use std::io;
use std::time::Instant;

#[cfg(unix)]
mod con {
    use std::io;

    pub struct Raw(libc::termios);

    impl Raw {
        pub fn enter() -> io::Result<Raw> {
            // SAFETY: tcgetattr/tcsetattr on stdin with valid storage.
            unsafe {
                let mut t: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(0, &mut t) != 0 {
                    return Err(io::Error::last_os_error());
                }
                let saved = t;
                libc::cfmakeraw(&mut t);
                libc::tcsetattr(0, libc::TCSANOW, &t);
                Ok(Raw(saved))
            }
        }
    }

    impl Drop for Raw {
        fn drop(&mut self) {
            // SAFETY: restoring the saved termios.
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0) };
        }
    }

    pub fn write(b: &[u8]) {
        let mut b = b;
        while !b.is_empty() {
            // SAFETY: writing a valid slice to stdout.
            let n = unsafe { libc::write(1, b.as_ptr().cast(), b.len()) };
            if n <= 0 {
                return;
            }
            b = &b[n as usize..];
        }
    }

    pub fn read(buf: &mut [u8]) -> usize {
        // SAFETY: reading into a valid buffer from stdin.
        let n = unsafe { libc::read(0, buf.as_mut_ptr().cast(), buf.len()) };
        n.max(0) as usize
    }
}

#[cfg(windows)]
mod con {
    use std::io;

    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
    use windows_sys::Win32::System::Console::*;

    pub struct Raw {
        input: (HANDLE, CONSOLE_MODE),
        output: (HANDLE, CONSOLE_MODE),
    }

    impl Raw {
        pub fn enter() -> io::Result<Raw> {
            // SAFETY: reading and setting our own console modes.
            unsafe {
                let (i, o) = (GetStdHandle(STD_INPUT_HANDLE), GetStdHandle(STD_OUTPUT_HANDLE));
                let (mut im, mut om) = (0, 0);
                if GetConsoleMode(i, &mut im) == 0 || GetConsoleMode(o, &mut om) == 0 {
                    return Err(io::Error::last_os_error());
                }
                SetConsoleMode(i, ENABLE_VIRTUAL_TERMINAL_INPUT);
                SetConsoleMode(
                    o,
                    om | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN,
                );
                Ok(Raw { input: (i, im), output: (o, om) })
            }
        }
    }

    impl Drop for Raw {
        fn drop(&mut self) {
            // SAFETY: restoring the saved modes.
            unsafe {
                SetConsoleMode(self.input.0, self.input.1);
                SetConsoleMode(self.output.0, self.output.1);
            }
        }
    }

    pub fn write(b: &[u8]) {
        let mut n = 0u32;
        // SAFETY: writing a valid slice to our console output.
        unsafe {
            WriteFile(
                GetStdHandle(STD_OUTPUT_HANDLE),
                b.as_ptr(),
                b.len() as u32,
                &mut n,
                std::ptr::null_mut(),
            )
        };
    }

    pub fn read(buf: &mut [u8]) -> usize {
        let mut n = 0u32;
        // SAFETY: reading into a valid buffer from our console input.
        let ok = unsafe {
            ReadFile(
                GetStdHandle(STD_INPUT_HANDLE),
                buf.as_mut_ptr(),
                buf.len() as u32,
                &mut n,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 { 0 } else { n as usize }
    }
}

/// Sends `q` and reads until `done(reply)`; returns the latency and reply.
fn ask(q: &[u8], done: impl Fn(&[u8]) -> bool) -> io::Result<(f64, Vec<u8>)> {
    let t = Instant::now();
    con::write(q);
    let mut reply = Vec::new();
    let mut buf = [0u8; 64];
    while !done(&reply) {
        let n = con::read(&mut buf);
        if n == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        reply.extend_from_slice(&buf[..n]);
    }
    Ok((t.elapsed().as_secs_f64(), reply))
}

fn pct(xs: &mut [f64], f: f64) -> f64 {
    xs.sort_by(f64::total_cmp);
    1e6 * xs[((xs.len() - 1) as f64 * f) as usize]
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|c| format!("{c:02x}")).collect::<Vec<_>>().join(" ")
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1000);
    let raw = con::Raw::enter().unwrap_or_else(|e| {
        eprintln!("mux2-query-probe: not a terminal: {e}");
        std::process::exit(2);
    });
    let (mut cpr, mut da) = (Vec::with_capacity(n), Vec::with_capacity(n));
    for i in 1..=n {
        let (row, col) = (1 + i % 20, 1 + i % 70);
        con::write(format!("\x1b[{row};{col}H").as_bytes());
        let want = format!("\x1b[{row};{col}R").into_bytes();
        let Ok((d, r)) = ask(b"\x1b[6n", |r| r.contains(&b'R')) else {
            drop(raw);
            con::write(format!("\r\nBAD-CPR {i} eof\r\n").as_bytes());
            std::process::exit(1);
        };
        if !r.windows(want.len()).any(|w| w == want) {
            drop(raw);
            con::write(format!("\r\nBAD-CPR {i} got {}\r\n", hex(&r)).as_bytes());
            std::process::exit(1);
        }
        cpr.push(d);
        let Ok((d, r)) = ask(b"\x1b[c", |r| r.ends_with(b"c")) else {
            drop(raw);
            con::write(format!("\r\nBAD-DA {i} eof\r\n").as_bytes());
            std::process::exit(1);
        };
        if !r.starts_with(b"\x1b[?") {
            drop(raw);
            con::write(format!("\r\nBAD-DA {i} got {}\r\n", hex(&r)).as_bytes());
            std::process::exit(1);
        }
        da.push(d);
    }
    drop(raw);
    con::write(b"\x1b[2J\x1b[H");
    con::write(
        format!(
            "{{\"query_rtt\":{n},\"cpr_p50_us\":{:.1},\"cpr_p99_us\":{:.1},\"da_p50_us\":{:.1},\"da_p99_us\":{:.1}}}\r\n",
            pct(&mut cpr, 0.5),
            pct(&mut cpr, 0.99),
            pct(&mut da, 0.5),
            pct(&mut da, 0.99)
        )
        .as_bytes(),
    );
}
