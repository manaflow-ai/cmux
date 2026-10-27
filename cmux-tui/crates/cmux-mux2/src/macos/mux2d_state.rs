//! The in-place upgrade state file: format and dry-run parsing.

use super::*;

pub(super) const STATE_MAGIC: &[u8] = b"MUX2S2";

pub(super) struct RestoredTerm {
    pub(super) id: u32,
    pub(super) pid: libc::pid_t,
    pub(super) master: RawFd,
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) exit: Option<i32>,
    pub(super) pty_open: bool,
    pub(super) bytes_in: u64,
    pub(super) input: Vec<u8>,
    pub(super) vt: Terminal,
    pub(super) replies: Arc<Mutex<Vec<u8>>>,
}

pub(super) struct ParsedState {
    pub(super) next_term: u32,
    pub(super) terms: Vec<RestoredTerm>,
    pub(super) orphans: Vec<libc::pid_t>,
}

/// Parses an upgrade state file and rebuilds every terminal from its
/// replay. Touches no descriptor, so `--verify-state` can run it in a dry
/// run before the old server commits to the exec.
pub(super) fn parse_state(state: &[u8]) -> io::Result<ParsedState> {
    let bad = || io::Error::new(io::ErrorKind::InvalidData, "bad upgrade state");
    let rest = state.strip_prefix(STATE_MAGIC).ok_or_else(bad)?;
    let mut r = Reader(rest);
    let next_term = r.u32().ok_or_else(bad)?;
    let _listen = r.u32().ok_or_else(bad)?; // adopted by main
    let count = r.u32().ok_or_else(bad)?;
    let mut terms = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let id = r.u32().ok_or_else(bad)?;
        let pid = r.u32().ok_or_else(bad)? as libc::pid_t;
        let master = r.u32().ok_or_else(bad)? as RawFd;
        let cols = r.u16().ok_or_else(bad)?;
        let rows = r.u16().ok_or_else(bad)?;
        let (exited, rest) = r.0.split_first().ok_or_else(bad)?;
        r.0 = rest;
        let code = r.u32().ok_or_else(bad)? as i32;
        let (open, rest) = r.0.split_first().ok_or_else(bad)?;
        r.0 = rest;
        let lo = u64::from(r.u32().ok_or_else(bad)?);
        let hi = u64::from(r.u32().ok_or_else(bad)?);
        let input = r.bytes().ok_or_else(bad)?.to_vec();
        let replay = r.bytes().ok_or_else(bad)?;
        let replies = Arc::new(Mutex::new(Vec::new()));
        let sink = replies.clone();
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new(move |bytes: &[u8]| {
                sink.lock().expect("reply sink").extend_from_slice(bytes);
            })),
            ..Callbacks::default()
        };
        let mut vt = Terminal::new(cols, rows, SCROLLBACK_BYTES, callbacks)
            .map_err(|e| io::Error::other(format!("terminal: {e}")))?;
        vt.vt_write(replay);
        // Restoring state is not program output: drop any reply it made.
        replies.lock().expect("reply sink").clear();
        terms.push(RestoredTerm {
            id,
            pid,
            master,
            cols,
            rows,
            exit: (*exited != 0).then_some(code),
            pty_open: *open != 0,
            bytes_in: lo | (hi << 32),
            input,
            vt,
            replies,
        });
    }
    let orphan_count = r.u32().ok_or_else(bad)?;
    let mut orphans = Vec::with_capacity(orphan_count as usize);
    for _ in 0..orphan_count {
        orphans.push(r.u32().ok_or_else(bad)? as libc::pid_t);
    }
    if !r.0.is_empty() {
        return Err(bad());
    }
    Ok(ParsedState { next_term, terms, orphans })
}

impl Server {
    /// Upgrade in place: write every terminal's state to a file, keep the
    /// PTY and listening descriptors open across exec, and exec the new
    /// binary with `--resume`. The pid stays the same, so programs remain
    /// our children and their exit codes are still ours to collect.
    pub(super) fn upgrade(&mut self, requester: u32, payload: &[u8]) -> io::Result<()> {
        let exe = if payload.is_empty() {
            std::env::current_exe()?
        } else {
            std::path::PathBuf::from(OsStr::from_bytes(payload))
        };
        let mut state = STATE_MAGIC.to_vec();
        state.extend_from_slice(&self.next_term.to_le_bytes());
        state.extend_from_slice(&self.listen.to_le_bytes());
        state.extend_from_slice(&u32::try_from(self.terms.len()).expect("fits").to_le_bytes());
        let ids: Vec<u32> = self.terms.keys().copied().collect();
        for &t in &ids {
            let term = self.terms.get_mut(&t).expect("listed");
            flush_parse(term);
            // A replay cut inside a long control string would not resume the
            // stream exactly; refuse rather than lose state.
            if !term.vt().vt_replay_resumes_stream() {
                return Err(io::Error::other(format!(
                    "terminal {t} is inside a long control sequence; retry"
                )));
            }
            let replay = term
                .vt()
                .vt_replay_bytes()
                .map_err(|e| io::Error::other(format!("terminal {t}: {e}")))?;
            self.flush_replies(t);
            let term = &self.terms[&t];
            state.extend_from_slice(&t.to_le_bytes());
            state.extend_from_slice(&term.pid.to_le_bytes());
            state.extend_from_slice(&term.master.to_le_bytes());
            state.extend_from_slice(&term.cols.to_le_bytes());
            state.extend_from_slice(&term.rows.to_le_bytes());
            state.push(u8::from(term.exit.is_some()));
            state.extend_from_slice(&term.exit.unwrap_or(0).to_le_bytes());
            state.push(u8::from(term.pty_open));
            state.extend_from_slice(&term.bytes_in.to_le_bytes());
            let input: Vec<u8> = term.input.iter().copied().collect();
            proto::put_bytes(&mut state, &input)?;
            proto::put_bytes(&mut state, &replay)?;
        }
        state.extend_from_slice(&u32::try_from(self.orphans.len()).expect("fits").to_le_bytes());
        for pid in &self.orphans {
            state.extend_from_slice(&pid.to_le_bytes());
        }
        let path = proto::socket_path().with_file_name(format!("state-{}", std::process::id()));
        {
            use std::io::Write as _;
            use std::os::unix::fs::OpenOptionsExt as _;
            let _ = std::fs::remove_file(&path);
            let mut f =
                std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
            f.write_all(&state)?;
            f.sync_all()?;
        }
        // Everything that can fail is checked before the requester hears OK:
        // the new binary must read this exact state file in a dry run.
        let checked = (|| -> io::Result<(CString, CString)> {
            let cexe = CString::new(exe.as_os_str().as_bytes()).map_err(io::Error::other)?;
            let cpath = CString::new(path.as_os_str().as_bytes()).map_err(io::Error::other)?;
            let status = std::process::Command::new(&exe)
                .arg("--verify-state")
                .arg(&path)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .status()?;
            if !status.success() {
                return Err(io::Error::other(format!("new server rejected the state ({status})")));
            }
            Ok((cexe, cpath))
        })();
        let (cexe, cpath) = match checked {
            Ok(v) => v,
            Err(e) => {
                let _ = std::fs::remove_file(&path);
                return Err(e);
            }
        };
        let cflag = CString::new("--resume").expect("static");
        let argv = [cexe.as_ptr(), cflag.as_ptr(), cpath.as_ptr(), std::ptr::null()];
        let keep: Vec<RawFd> =
            std::iter::once(self.listen).chain(self.terms.values().map(|t| t.master)).collect();
        for &fd in &keep {
            // SAFETY: clearing close-on-exec on descriptors we own.
            unsafe { libc::fcntl(fd, libc::F_SETFD, 0) };
        }
        // Tell the requester before the exec closes its connection; give a
        // reader that does not drain its socket two seconds at most.
        self.send(requester, proto::OK, &[]);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        if let Some(conn) = self.conns.get_mut(&requester) {
            for (index, frame) in conn.out.iter().enumerate() {
                let start = if index == 0 { conn.front_sent.min(frame.len()) } else { 0 };
                write_all_blocking(conn.fd, &frame[start..], deadline);
            }
            // Written (or abandoned): never send these frames a second time.
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
        }
        // SAFETY: execv with a null-terminated argv of live CStrings. Client
        // sockets and the kqueue are close-on-exec.
        unsafe { libc::execv(cexe.as_ptr(), argv.as_ptr()) };
        let err = io::Error::last_os_error();
        for &fd in &keep {
            // SAFETY: restoring close-on-exec after the failed exec.
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        let _ = std::fs::remove_file(&path);
        Err(err)
    }

    /// Rebuilds the server from an upgrade state file.
    pub(super) fn resume(&mut self, state: &[u8]) -> io::Result<()> {
        let parsed = parse_state(state)?;
        self.next_term = parsed.next_term;
        for r in parsed.terms {
            let (t, pid, master, open, exited) =
                (r.id, r.pid, r.master, r.pty_open, r.exit.is_some());
            set_nonblock_cloexec(master)?;
            self.terms.insert(
                t,
                Term {
                    pid,
                    master,
                    // A replay may end inside the sequence the old parser
                    // was in; the next chunk must then parse at once.
                    open_seq: !r.vt.vt_stream_is_ground(),
                    parser: Arc::new(Mutex::new(r.vt)),
                    inflight: Arc::default(),
                    carry: Vec::new(),
                    read_paused: false,
                    cols: r.cols,
                    rows: r.rows,
                    pending: Vec::new(),
                    replies: r.replies,
                    input: r.input.into(),
                    input_armed: false,
                    attached: Vec::new(),
                    waiters: Vec::new(),
                    exit: r.exit,
                    pty_open: open,
                    bytes_in: r.bytes_in,
                },
            );
            self.kev(
                t as usize,
                libc::EVFILT_USER,
                libc::EV_ADD | libc::EV_CLEAR,
                0,
                KIND_WAKE | u64::from(t),
            )?;
            if open {
                self.kev(
                    master as usize,
                    libc::EVFILT_READ,
                    libc::EV_ADD,
                    0,
                    KIND_PTY | u64::from(t),
                )?;
            }
            if !exited {
                self.watch_child(t, pid)?;
            }
            self.flush_input(t);
        }
        // Children of killed terminals: terminal id 0 never exists, so the
        // exit event only reaps them.
        for pid in parsed.orphans {
            self.orphans.push(pid);
            self.watch_child(0, pid)?;
        }
        Ok(())
    }

    /// Watches `pid` for exit; reaps it at once if it already exited.
    fn watch_child(&mut self, t: u32, pid: libc::pid_t) -> io::Result<()> {
        match self.kev(
            pid as usize,
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_ONESHOT,
            libc::NOTE_EXIT,
            KIND_PROC | u64::from(t),
        ) {
            Err(e) if e.raw_os_error() == Some(libc::ESRCH) => {
                self.child_exited(t, pid);
                Ok(())
            }
            other => other,
        }
    }
}
