//! Send-path microbench for one screen-share keyframe and one P-frame (Linux).
//!
//! Real frames: a FrameBody packetized by cmux-rd-core at the link's shard size
//! (1126 B), each datagram sealed by a real established `Link` (Noise transport),
//! sent in pacer-sized bursts on a real UDP socket out the default route
//! (TEST-NET-1, so nothing answers). Variants:
//!   cur   : per datagram: to_vec + pipe wake write + seal + send_to (today's link path)
//!   wake1 : one pipe wake per burst, seal + send_to per datagram
//!   mmsg  : one wake per burst, seal, one sendmmsg per burst
//!   gso   : one wake per burst, seal, one sendmsg with UDP_SEGMENT per burst
//! Prints per-frame syscalls and send-loop time (median, p95) over N frames.

use cmux_rd_core::packetize::Packetizer;
use cmux_rd_link::{KeyPair, Link, Role};
use cmux_rd_proto::FrameBody;
use std::net::UdpSocket;
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

const SHARD: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;

fn links() -> (Link, Link) {
    let (vk, hk) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut v = Link::new(Role::Initiator, b"bench", &vk, hk.public, 0).unwrap();
    let mut h = Link::new(Role::Responder, b"bench", &hk, vk.public, 0).unwrap();
    let mut now = 0;
    for _ in 0..20 {
        now += 10_000;
        for p in v.poll_transmit(now).unwrap() {
            h.on_packet(&p, now).unwrap();
        }
        for p in h.poll_transmit(now).unwrap() {
            v.on_packet(&p, now).unwrap();
        }
        if h.is_established() && v.is_established() {
            break;
        }
    }
    assert!(h.is_established());
    (h, v)
}

fn frame(bytes: usize, parity: usize, n: u32, p: &mut Packetizer) -> Vec<Vec<u8>> {
    let mut x = 0x9e37_79b9u32.wrapping_mul(n + 1);
    let au = (0..bytes)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect();
    let body = FrameBody { t_capture_us: 1, ref_frame: n.wrapping_sub(1), access_unit: au };
    p.packetize(n, 0, &body, parity).unwrap().datagrams
}

struct Out {
    sock: UdpSocket,
    dest: libc::sockaddr_in,
    pipe: [i32; 2],
    syscalls: u64,
    dropped: u64,
}

impl Out {
    fn wake(&mut self) {
        unsafe { libc::write(self.pipe[1], [1u8].as_ptr().cast(), 1) };
        self.syscalls += 1;
    }
    fn drain(&mut self) {
        let mut s = [0u8; 4096];
        while unsafe { libc::read(self.pipe[0], s.as_mut_ptr().cast(), s.len()) } > 0 {}
    }
    fn send_to(&mut self, d: &[u8]) {
        let rc = unsafe {
            libc::sendto(
                self.sock.as_raw_fd(),
                d.as_ptr().cast(),
                d.len(),
                0,
                (&self.dest as *const libc::sockaddr_in).cast(),
                std::mem::size_of::<libc::sockaddr_in>() as u32,
            )
        };
        self.syscalls += 1;
        if rc < 0 {
            self.dropped += 1;
        }
    }
    fn sendmmsg(&mut self, ds: &[Vec<u8>]) {
        let mut iov: Vec<libc::iovec> = ds
            .iter()
            .map(|d| libc::iovec { iov_base: d.as_ptr() as *mut _, iov_len: d.len() })
            .collect();
        let mut msgs: Vec<libc::mmsghdr> = iov
            .iter_mut()
            .map(|v| {
                let mut h: libc::mmsghdr = unsafe { std::mem::zeroed() };
                h.msg_hdr.msg_name = (&self.dest as *const libc::sockaddr_in) as *mut _;
                h.msg_hdr.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as u32;
                h.msg_hdr.msg_iov = v;
                h.msg_hdr.msg_iovlen = 1;
                h
            })
            .collect();
        let mut off = 0;
        while off < msgs.len() {
            let rc = unsafe {
                libc::sendmmsg(
                    self.sock.as_raw_fd(),
                    msgs[off..].as_mut_ptr(),
                    (msgs.len() - off) as u32,
                    0,
                )
            };
            self.syscalls += 1;
            if rc <= 0 {
                self.dropped += (msgs.len() - off) as u64;
                break;
            }
            off += rc as usize;
        }
    }
    /// All datagrams but the last share one length (sealed equal shards).
    fn gso(&mut self, ds: &[Vec<u8>], buf: &mut Vec<u8>) {
        let seg = ds[0].len();
        for chunk in ds.chunks((65_000 / seg).min(64)) {
            buf.clear();
            for d in chunk {
                buf.extend_from_slice(d);
            }
            let mut iov = libc::iovec { iov_base: buf.as_mut_ptr().cast(), iov_len: buf.len() };
            let mut cbuf = [0u64; 8];
            let mut h: libc::msghdr = unsafe { std::mem::zeroed() };
            h.msg_name = (&self.dest as *const libc::sockaddr_in) as *mut _;
            h.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as u32;
            h.msg_iov = &mut iov;
            h.msg_iovlen = 1;
            if chunk.len() > 1 {
                h.msg_control = cbuf.as_mut_ptr().cast();
                h.msg_controllen = unsafe { libc::CMSG_SPACE(2) } as _;
                unsafe {
                    let c = libc::CMSG_FIRSTHDR(&h);
                    (*c).cmsg_level = libc::SOL_UDP;
                    (*c).cmsg_type = 103; // UDP_SEGMENT
                    (*c).cmsg_len = libc::CMSG_LEN(2) as _;
                    std::ptr::write_unaligned(libc::CMSG_DATA(c).cast::<u16>(), seg as u16);
                }
            }
            let rc = unsafe { libc::sendmsg(self.sock.as_raw_fd(), &h, 0) };
            self.syscalls += 1;
            if rc < 0 {
                self.dropped += chunk.len() as u64;
            }
        }
    }
}

fn stats(mut v: Vec<f64>) -> (f64, f64) {
    v.sort_by(f64::total_cmp);
    (v[v.len() / 2], v[(v.len() * 95 / 100).min(v.len() - 1)])
}

fn main() {
    let dest_ip: std::net::Ipv4Addr =
        std::env::var("BENCH_DEST").unwrap_or_else(|_| "192.0.2.1".into()).parse().unwrap();
    let frames: usize =
        std::env::var("BENCH_FRAMES").ok().and_then(|s| s.parse().ok()).unwrap_or(60);
    let sock = UdpSocket::bind("0.0.0.0:0").unwrap();
    sock.set_nonblocking(true).unwrap();
    let big: i32 = 8 << 20;
    unsafe {
        libc::setsockopt(
            sock.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&big as *const i32).cast(),
            4,
        );
    }
    let mut dest: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    dest.sin_family = libc::AF_INET as _;
    dest.sin_port = 9u16.to_be();
    dest.sin_addr.s_addr = u32::from(dest_ip).to_be();
    let mut pipe = [0i32; 2];
    unsafe {
        libc::pipe(pipe.as_mut_ptr());
        libc::fcntl(pipe[0], libc::F_SETFL, libc::O_NONBLOCK);
        libc::fcntl(pipe[1], libc::F_SETFL, libc::O_NONBLOCK);
    }
    let mut out = Out { sock, dest, pipe, syscalls: 0, dropped: 0 };
    let (mut host, _viewer) = links();
    let mut pk = Packetizer::new(1, SHARD);
    let mut gbuf = Vec::with_capacity(70_000);
    // Pacer burst at 50 Mbit/s target x2.5 pacing factor over 2 ms (pacer.rs BURST_US).
    let burst: usize = std::env::var("BENCH_BURST").ok().and_then(|s| s.parse().ok()).unwrap_or(28);
    println!(
        "shard={SHARD} wire={} burst={burst} frames={frames} dest={dest_ip}",
        SHARD + cmux_rd_link::SEAL_OVERHEAD
    );
    for (label, bytes, parity) in [("keyframe", 600_000usize, 0usize), ("pframe", 6_000, 2)] {
        for variant in ["cur", "wake1", "mmsg", "gso"] {
            let mut times = Vec::new();
            let mut seal_times = Vec::new();
            let (mut sys, mut drop, mut n_dg) = (0, 0, 0);
            for f in 0..frames as u32 + 3 {
                let dgs = frame(bytes, parity, f, &mut pk);
                n_dg = dgs.len();
                out.syscalls = 0;
                out.dropped = 0;
                let mut total = Duration::ZERO;
                let mut seal = Duration::ZERO;
                for b in dgs.chunks(burst) {
                    let t = Instant::now();
                    match variant {
                        "cur" => {
                            for d in b {
                                let copy = d.to_vec();
                                out.wake();
                                let s = Instant::now();
                                let sealed = host.seal_datagram(&copy).unwrap();
                                seal += s.elapsed();
                                out.send_to(&sealed);
                            }
                        }
                        _ => {
                            out.wake();
                            let s = Instant::now();
                            let sealed: Vec<Vec<u8>> =
                                b.iter().map(|d| host.seal_datagram(d).unwrap()).collect();
                            seal += s.elapsed();
                            match variant {
                                "wake1" => sealed.iter().for_each(|d| out.send_to(d)),
                                "mmsg" => out.sendmmsg(&sealed),
                                _ => out.gso(&sealed, &mut gbuf),
                            }
                        }
                    }
                    total += t.elapsed();
                    out.drain();
                    std::thread::sleep(Duration::from_millis(2));
                }
                if f >= 3 {
                    times.push(total.as_secs_f64() * 1e6);
                    seal_times.push(seal.as_secs_f64() * 1e6);
                    sys = out.syscalls;
                    drop += out.dropped;
                }
            }
            let (p50, p95) = stats(times);
            let (s50, _) = stats(seal_times);
            println!(
                "RESULT {label} {variant}: datagrams={n_dg} syscalls={sys} send_loop_us p50={p50:.0} p95={p95:.0} seal_us p50={s50:.0} non_seal_us p50={:.0} dropped_total={drop}",
                p50 - s50
            );
        }
    }
}
