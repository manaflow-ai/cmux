//! Client connections: accept, read, queue and write frames, and keep each
//! attached viewer exact (the snapshot resync of a lagging network viewer).

use super::*;

impl Server {
    pub(super) fn accept(&mut self, listen: RawFd, tcp: bool) {
        loop {
            // SAFETY: accept on our listening socket.
            let fd = unsafe { libc::accept(listen, std::ptr::null_mut(), std::ptr::null_mut()) };
            if fd < 0 {
                return;
            }
            let tuned = !tcp
                || (proto::net::peer_ip(fd).is_some_and(|ip| self.peers.admits(ip))
                    && proto::net::tune(fd, Some(self.notsent_lowat)).is_ok());
            if !tuned || set_nonblock_cloexec(fd).is_err() {
                // SAFETY: closing a descriptor we just received.
                unsafe { libc::close(fd) };
                continue;
            }
            let id = self.next_conn;
            self.next_conn = self.next_conn.wrapping_add(1).max(1);
            // SIGPIPE is ignored server-wide; macOS also takes it per socket.
            #[cfg(target_os = "macos")]
            let nosig: libc::c_int = 1;
            #[cfg(target_os = "macos")]
            // SAFETY: setting SO_NOSIGPIPE with a valid option value.
            unsafe {
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    (&raw const nosig).cast(),
                    4,
                );
            }
            self.conns.insert(
                id,
                Conn {
                    fd,
                    inbuf: Vec::new(),
                    out: VecDeque::new(),
                    front_sent: 0,
                    queued: 0,
                    attached: None,
                    write_armed: false,
                    read_armed: true,
                    closing: false,
                    stale: false,
                    tcp,
                    rate: None,
                    win_start: None,
                    win_bytes: 0,
                },
            );
            let _ = self.poll.add(fd, Interest::Read, KIND_CONN | u64::from(id));
        }
    }

    pub(super) fn conn_readable(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        loop {
            // SAFETY: buf is valid for its length.
            let n = unsafe { libc::read(conn.fd, self.buf.as_mut_ptr().cast(), self.buf.len()) };
            if n > 0 {
                conn.inbuf.extend_from_slice(&self.buf[..n as usize]);
                continue;
            }
            if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::WouldBlock {
                conn.closing = true;
            }
            break;
        }
        let mut offset = 0;
        loop {
            let Some(conn) = self.conns.get_mut(&id) else { return };
            let frame = match proto::take_frame(&conn.inbuf[offset..]) {
                Ok(Some((kind, payload, used))) => Some((kind, payload.to_vec(), used)),
                Ok(None) => None,
                Err(_) => {
                    conn.closing = true;
                    None
                }
            };
            let Some((kind, payload, used)) = frame else { break };
            offset += used;
            self.request(id, kind, &payload);
        }
        let Some(conn) = self.conns.get_mut(&id) else { return };
        conn.inbuf.drain(..offset);
        if conn.closing {
            // EOF stays readable; stop listening so it cannot spin the loop.
            if conn.read_armed {
                conn.read_armed = false;
                let fd = conn.fd;
                self.poll.delete(fd, Interest::Read);
            }
            if self.conns.get(&id).is_some_and(|c| c.out.is_empty()) {
                self.drop_conn(id);
            }
        }
    }

    pub(super) fn send(&mut self, id: u32, kind: u8, payload: &[u8]) {
        if let Some(conn) = self.conns.get_mut(&id) {
            let mut frame = Vec::with_capacity(payload.len() + 5);
            proto::put_frame(&mut frame, kind, payload);
            conn.queued += frame.len();
            conn.out.push_back(frame);
            self.flush_conn(id);
        }
    }

    pub(super) fn flush_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        let mut failed = false;
        while !conn.out.is_empty() {
            // Every queued frame in one writev: a reply and the output behind
            // it leave in one segment, not one segment per frame.
            let mut iov = [libc::iovec { iov_base: std::ptr::null_mut(), iov_len: 0 }; IOV_MAX];
            let mut count = 0;
            for (slot, frame) in iov.iter_mut().zip(&conn.out) {
                let rest = if count == 0 { &frame[conn.front_sent..] } else { &frame[..] };
                *slot = libc::iovec { iov_base: rest.as_ptr() as *mut _, iov_len: rest.len() };
                count += 1;
            }
            // SAFETY: the first `count` iovecs point into frames that outlive
            // the call.
            let n = unsafe { libc::writev(conn.fd, iov.as_ptr(), count as libc::c_int) };
            if n > 0 {
                let mut n = n as usize;
                conn.queued -= n;
                conn.win_bytes += n;
                while n > 0 {
                    let left = conn.out[0].len() - conn.front_sent;
                    if n < left {
                        conn.front_sent += n;
                        break;
                    }
                    n -= left;
                    conn.out.pop_front();
                    conn.front_sent = 0;
                }
                continue;
            }
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock {
                break;
            }
            failed = true;
            break;
        }
        if failed {
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
            conn.closing = true;
        }
        let want = !conn.out.is_empty();
        if !want && conn.stale && !conn.closing {
            // Built after the current event, outside this flush.
            self.refresh.push(id);
        }
        // Drain rate: measured only while the link, not the program, is the
        // limit (the queue is not empty), over windows of RATE_WINDOW.
        let now = std::time::Instant::now();
        match conn.win_start {
            Some(start) if !want || now - start >= RATE_WINDOW => {
                let secs = (now - start).as_secs_f64();
                if now - start >= RATE_WINDOW / 4 {
                    let sample = conn.win_bytes as f64 / secs;
                    conn.rate = Some(conn.rate.map_or(sample, |r| 0.5 * r + 0.5 * sample));
                }
                conn.win_start = want.then_some(now);
                conn.win_bytes = 0;
            }
            None if want => {
                conn.win_start = Some(now);
                conn.win_bytes = 0;
            }
            _ => {}
        }
        let (fd, armed) = (conn.fd, conn.write_armed);
        let done = conn.closing && !want;
        if want != armed {
            conn.write_armed = want;
            if want {
                let _ = self.poll.add(fd, Interest::Write, KIND_CONN | u64::from(id));
            } else {
                self.poll.delete(fd, Interest::Write);
            }
        }
        if done {
            self.drop_conn(id);
        }
    }

    pub(super) fn drop_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.remove(&id) else { return };
        if let Some(t) = conn.attached.and_then(|t| self.terms.get_mut(&t)) {
            t.attached.retain(|c| *c != id);
        }
        for t in self.terms.values_mut() {
            t.waiters.retain(|c| *c != id);
        }
        // SAFETY: closing a descriptor we own; kqueue drops its filters.
        unsafe { libc::close(conn.fd) };
    }

    pub(super) fn close_conn(&mut self, id: u32) {
        if let Some(conn) = self.conns.get_mut(&id) {
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
        }
        self.drop_conn(id);
    }

    /// Sends `t`'s current state to `c` as a SNAPSHOT. Closes the connection
    /// when no faithful snapshot can be made, so the client never has a gap.
    pub(super) fn snapshot_to(&mut self, t: u32, c: u32) {
        if !self.terms.contains_key(&t) {
            return;
        }
        match self.build_snapshot(t) {
            Some(p) => self.resync(c, &p),
            None => self.close_conn(c),
        }
    }

    /// `t`'s current state as a SNAPSHOT payload: size, then the replay.
    pub(super) fn build_snapshot(&mut self, t: u32) -> Option<Vec<u8>> {
        let term = self.terms.get_mut(&t)?;
        flush_parse(term);
        let payload = term.vt().vt_replay_bytes().ok().map(|replay| {
            let mut p = Vec::with_capacity(replay.len() + 4);
            p.extend_from_slice(&term.cols.to_le_bytes());
            p.extend_from_slice(&term.rows.to_le_bytes());
            p.extend_from_slice(&replay);
            p
        });
        self.flush_replies(t);
        if let Some(p) = &payload {
            self.snapshot_len.insert(t, p.len());
        }
        payload
    }

    /// Replaces `c`'s unsent terminal stream with snapshot `p`.
    pub(super) fn resync(&mut self, c: u32, p: &[u8]) {
        if let Some(conn) = self.conns.get_mut(&c) {
            conn.drop_unstarted();
            conn.stale = false;
        }
        self.resyncs += 1;
        self.send(c, proto::SNAPSHOT, p);
    }

    pub(super) fn refresh_drained(&mut self) {
        for c in std::mem::take(&mut self.refresh) {
            self.refresh_stale(c);
        }
    }

    /// A stale viewer has drained: give it the current state.
    pub(super) fn refresh_stale(&mut self, c: u32) {
        let Some(conn) = self.conns.get(&c) else { return };
        if !conn.stale {
            return;
        }
        match conn.attached {
            Some(t) => self.snapshot_async(t, c),
            None => {
                if let Some(conn) = self.conns.get_mut(&c) {
                    conn.stale = false;
                }
            }
        }
    }

    pub(super) fn fanout(&mut self, t: u32, clients: &[u32], bytes: &[u8]) {
        let snapshot_len = self.snapshot_len.get(&t).copied().unwrap_or(0);
        for &c in clients {
            let Some(conn) = self.conns.get_mut(&c) else { continue };
            // A stale viewer's coming snapshot holds these bytes too.
            if conn.stale {
                continue;
            }
            // The snapshot holds every byte parsed so far, including these,
            // so it replaces the unsent backlog exactly.
            let behind = conn.queued + bytes.len() + 5;
            if behind > CLIENT_BACKLOG_MAX {
                self.snapshot_to(t, c);
                continue;
            }
            // Only a measured, slow network link: an unmeasured one is
            // assumed fast, and a local (Unix socket) viewer keeps the whole
            // stream, as before.
            let lagging = conn.tcp
                && behind > self.backlog_floor
                && conn.rate.is_some_and(|r| behind as f64 > r * self.lag_ms as f64 / 1e3)
                && behind > 2 * (snapshot_len + 5);
            if lagging {
                conn.drop_unstarted();
                conn.stale = true;
                if conn.out.is_empty() {
                    self.refresh.push(c);
                }
                continue;
            }
            self.send(c, proto::OUTPUT, bytes);
        }
    }
}
