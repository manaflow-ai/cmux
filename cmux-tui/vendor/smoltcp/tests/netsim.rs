use std::cell::RefCell;
use std::collections::BinaryHeap;
use std::fmt::Write as _;
use std::io::Write as _;
use std::rc::Rc;
use std::sync::Mutex;

use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha20Rng;
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::Tracer;
use smoltcp::phy::{self, ChecksumCapabilities, Device, DeviceCapabilities, Medium};
use smoltcp::socket::tcp;
use smoltcp::time::{Duration, Instant};
use smoltcp::wire::{EthernetAddress, HardwareAddress, IpAddress, IpCidr};

const BYTES: usize = 10 * 1024 * 1024;

static CLOCK: Mutex<(Instant, char)> = Mutex::new((Instant::ZERO, ' '));

#[test]
fn netsim() {
    setup_logging();

    let rtt = Duration::from_millis(100);
    let buffers = [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768];
    let losses = [0.0, 0.001, 0.01, 0.02, 0.05, 0.10, 0.20, 0.30];

    let mut s = String::new();

    write!(&mut s, "buf\\loss").unwrap();
    for loss in losses {
        write!(&mut s, "{loss:9.3} ").unwrap();
    }

    writeln!(&mut s).unwrap();

    for buffer in buffers {
        write!(&mut s, "{buffer:7}").unwrap();

        for loss in losses {
            let result = run_test(TestSpec {
                flows: vec![FlowSpec {
                    rtt: Box::new(move |_| rtt),
                    loss,
                    bytes: BYTES,
                    seed_a_to_b: 0,
                    seed_b_to_a: 1,
                }],
                buffer,
                bandwidth: u64::MAX,
                capacity: usize::MAX,
            });

            write!(&mut s, " {:9.2}", result.throughput).unwrap();
        }
        writeln!(&mut s).unwrap();
    }

    insta::assert_snapshot!(s);
}

#[test]
fn netsim_multiflow() {
    setup_logging();

    let flow_counts = [1, 2, 4, 16, 32, 64];

    // link
    let bandwidth: u64 = 200_000_000 / 8;
    let rtt = Duration::from_millis(100);
    let queue = 64 * 1024;
    let wire_loss = 0.0;

    // flow
    let buffer = 256 * 1024;
    let bytes_per_flow = 2 * 1024 * 1024;

    let mss = 1460;
    let bdp = (bandwidth * rtt.total_micros() / 1_000_000) as usize;
    let max_flows = *flow_counts.iter().max().unwrap();
    let cwnd_peak = ((bdp + queue) / max_flows).min(buffer);

    debug_assert!(
        cwnd_peak >= 16 * mss,
        "cwnd_peak at N={max_flows} is {} MSS",
        cwnd_peak / mss
    );

    let mut results = Vec::with_capacity(flow_counts.len());
    for flow_count in flow_counts {
        let mut flow_specs = Vec::with_capacity(flow_count);
        for i in 0..flow_count {
            let flow_spec = FlowSpec {
                rtt: Box::new(move |rng| {
                    Duration::from_millis(
                        (rtt.total_millis() as f64 * rng.gen_range(0.5..=1.5)) as u64,
                    )
                }),
                loss: wire_loss,
                bytes: bytes_per_flow,
                seed_a_to_b: (i * 2) as u64,
                seed_b_to_a: (i * 2 + 1) as u64,
            };

            flow_specs.push(flow_spec);
        }

        let test_spec = TestSpec {
            flows: flow_specs,
            buffer,
            bandwidth,
            capacity: queue,
        };

        let result = run_test(test_spec);
        results.push(result);
    }

    let mut s = String::new();

    writeln!(
        &mut s,
        "{:>5} {:>11} {:>11} {:>11} {:>9} {:>9}",
        "flows", "agg_thru", "min_thru", "max_thru", "fairness", "drops",
    )
    .unwrap();

    for (flow_count, result) in flow_counts.iter().zip(results) {
        writeln!(
            &mut s,
            "{flow_count:>5} {:>11.2} {:>11.2} {:>11.2} {:>9.4} {:>9.4}",
            result.throughput,
            result.min_throughput,
            result.max_throughput,
            result.fairness,
            result.tail_drop_rate,
        )
        .unwrap();
    }

    insta::assert_snapshot!(s);
}

/// Per-flow workload spec. One per flow.
struct FlowSpec {
    /// Called once per side when constructing the flow, with each side's seeded RNG.
    /// Return the desired wire latency for each side(e.g. `DESIRED_RTT / 2`).
    rtt: Box<dyn Fn(&mut ChaCha20Rng) -> Duration>,
    /// Random loss applied on the wire (after the shared bottleneck)
    loss: f64,
    /// Target receive byte count. Loop runs until every flow has hit its target.
    bytes: usize,
    /// Seed for the A->B wire's loss RNG.
    seed_a_to_b: u64,
    /// Seed for the B->A wire's loss RNG.
    seed_b_to_a: u64,
}

/// Test parameters.
/// A combination of per-flow specifications and a shared bottle neck to run flows through.
struct TestSpec {
    flows: Vec<FlowSpec>,
    /// Socket rx/tx buffer size.
    buffer: usize,
    /// Shared link bandwidth in bytes/sec. Use `u64::MAX` for effectively unlimited.
    bandwidth: u64,
    /// Shared drop-tail bottleneck buffer in bytes. Use `usize::MAX` for effectively unlimited.
    capacity: usize,
}

struct Side {
    iface: Interface,
    device: Tracer<QueueDevice>,
    sockets: SocketSet<'static>,
    handle: SocketHandle,
    ip: IpAddress,
    port: u16,
}

impl Side {
    fn next_event(&mut self, time: Instant) -> Option<Instant> {
        let rx_arrival = self.device.get_ref().rx_wire.borrow().peek_arrival();
        let poll = self.iface.poll_at(time, &self.sockets);
        [rx_arrival, poll].into_iter().flatten().min()
    }
}

struct Flow {
    a: Side,
    b: Side,
    did_listen: bool,
    did_connect: bool,
    received: usize,
    target: usize,
}

fn run_test(case: TestSpec) -> TestResult {
    assert!(case.flows.len() < 256, "too many flows");

    let mut time = Instant::ZERO;

    let bottleneck_a_to_b = Rc::new(RefCell::new(Bottleneck::new(case.bandwidth, case.capacity)));
    let bottleneck_b_to_a = Rc::new(RefCell::new(Bottleneck::new(case.bandwidth, case.capacity)));

    let mut flows: Vec<Flow> = Vec::with_capacity(case.flows.len());
    for (i, spec) in case.flows.into_iter().enumerate() {
        let mac_a = HardwareAddress::Ethernet(EthernetAddress([0x02, 0, 0, 0, i as u8, 0x01]));
        let mac_b = HardwareAddress::Ethernet(EthernetAddress([0x02, 0, 0, 0, i as u8, 0x02]));

        let ip_a = IpAddress::v4(10, 0, 0, i as u8);
        let ip_b = IpAddress::v4(10, 0, 0, i as u8);
        let port_a = 1;
        let port_b = 2;

        let mut rng_a_to_b = ChaCha20Rng::seed_from_u64(spec.seed_a_to_b);
        let mut rng_b_to_a = ChaCha20Rng::seed_from_u64(spec.seed_b_to_a);

        let rtt_a_to_b = (spec.rtt)(&mut rng_a_to_b);
        let rtt_b_to_a = (spec.rtt)(&mut rng_b_to_a);

        let wire_a_to_b = Rc::new(RefCell::new(Wire::new(
            rtt_a_to_b / 2,
            spec.loss,
            rng_a_to_b,
        )));
        let wire_b_to_a = Rc::new(RefCell::new(Wire::new(
            rtt_b_to_a / 2,
            spec.loss,
            rng_b_to_a,
        )));

        let device_a = QueueDevice::new(
            Rc::clone(&bottleneck_a_to_b),
            Rc::clone(&wire_a_to_b),
            Rc::clone(&wire_b_to_a),
            Medium::Ethernet,
        );
        let device_b = QueueDevice::new(
            Rc::clone(&bottleneck_b_to_a),
            Rc::clone(&wire_b_to_a),
            Rc::clone(&wire_a_to_b),
            Medium::Ethernet,
        );

        let mut device_a =
            Tracer::new(device_a, |_timestamp, _printer| log::trace!("{}", _printer));
        let mut device_b =
            Tracer::new(device_b, |_timestamp, _printer| log::trace!("{}", _printer));

        let mut iface_a = Interface::new(Config::new(mac_a), &mut device_a, time);
        iface_a.update_ip_addrs(|a| a.push(IpCidr::new(ip_a, 24)).unwrap());
        let mut iface_b = Interface::new(Config::new(mac_b), &mut device_b, time);
        iface_b.update_ip_addrs(|a| a.push(IpCidr::new(ip_b, 24)).unwrap());

        let mut sockets_a = SocketSet::new(Vec::new());
        let mut sockets_b = SocketSet::new(Vec::new());

        let socket_a = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; case.buffer]),
            tcp::SocketBuffer::new(vec![0; case.buffer]),
        );
        let socket_b = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; case.buffer]),
            tcp::SocketBuffer::new(vec![0; case.buffer]),
        );
        let handle_a = sockets_a.add(socket_a);
        let handle_b = sockets_b.add(socket_b);

        flows.push(Flow {
            a: Side {
                iface: iface_a,
                device: device_a,
                sockets: sockets_a,
                handle: handle_a,
                ip: ip_a,
                port: port_a,
            },
            b: Side {
                iface: iface_b,
                device: device_b,
                sockets: sockets_b,
                handle: handle_b,
                ip: ip_b,
                port: port_b,
            },
            did_listen: false,
            did_connect: false,
            received: 0,
            target: spec.bytes,
        });
    }

    while flows.iter().any(|f| f.received < f.target) {
        *CLOCK.lock().unwrap() = (time, ' ');
        log::info!("loop");

        for flow in &mut flows {
            // poll A
            *CLOCK.lock().unwrap() = (time, 'A');
            flow.a
                .iface
                .poll(time, &mut flow.a.device, &mut flow.a.sockets);

            let socket = flow.a.sockets.get_mut::<tcp::Socket>(flow.a.handle);

            if !socket.is_active() && !socket.is_listening() && !flow.did_listen {
                socket.listen(flow.a.port).unwrap();
                flow.did_listen = true;
            }

            while socket.can_recv() {
                let recv = socket.recv(|buffer| (buffer.len(), buffer.len())).unwrap();
                flow.received += recv;
            }

            // poll B
            *CLOCK.lock().unwrap() = (time, 'B');
            flow.b
                .iface
                .poll(time, &mut flow.b.device, &mut flow.b.sockets);

            let socket = flow.b.sockets.get_mut::<tcp::Socket>(flow.b.handle);
            if !socket.is_open() && !flow.did_connect {
                let cx = flow.b.iface.context();
                socket
                    .connect(cx, (flow.a.ip, flow.a.port), flow.b.port)
                    .unwrap();
                flow.did_connect = true;
            }

            while socket.can_send() {
                socket.send(|buffer| (buffer.len(), ())).unwrap();
            }
        }

        *CLOCK.lock().unwrap() = (time, ' ');

        let next_time = flows
            .iter_mut()
            .flat_map(|flow| [flow.a.next_event(time), flow.b.next_event(time)])
            .flatten()
            .min()
            .expect("no pending event");

        time = time.max(next_time);
    }

    let duration_secs = duration_to_secs(time - Instant::ZERO);
    let xs: Vec<f64> = flows.iter().map(|f| f.received as f64).collect();
    let sum: f64 = xs.iter().sum();

    // throughput
    let throughput = sum / duration_secs;
    let min_throughput = xs.iter().copied().fold(f64::INFINITY, f64::min) / duration_secs;
    let max_throughput = xs.iter().copied().fold(0.0_f64, f64::max) / duration_secs;

    // fairness
    let sum_sq: f64 = xs.iter().map(|x| x * x).sum();
    let fairness = if sum_sq > 0.0 {
        (sum * sum) / (xs.len() as f64 * sum_sq)
    } else {
        1.0
    };

    // drop rate
    let a = bottleneck_a_to_b.borrow();
    let b = bottleneck_b_to_a.borrow();
    let pushes = a.pushes + b.pushes;
    let tail_drops = a.tail_drops + b.tail_drops;
    let tail_drop_rate = if pushes > 0 {
        tail_drops as f64 / pushes as f64
    } else {
        0.0
    };

    TestResult {
        throughput,
        min_throughput,
        max_throughput,
        fairness,
        tail_drop_rate,
    }
}

fn duration_to_secs(d: Duration) -> f64 {
    d.total_micros() as f64 / 1e6
}

struct TestResult {
    /// Aggregate throughput across all flows, bytes/sec.
    throughput: f64,
    /// Slowest flow's throughput, bytes/sec.
    min_throughput: f64,
    /// Fastest flow's throughput, bytes/sec.
    max_throughput: f64,
    /// Jain's fairness index across per-flow received bytes.
    fairness: f64,
    /// Fraction of pushed packets that were dropped by the drop-tail bottleneck buffer.
    tail_drop_rate: f64,
}

struct Packet {
    timestamp: Instant,
    id: u64,
    data: Vec<u8>,
}

impl PartialEq for Packet {
    fn eq(&self, other: &Self) -> bool {
        (other.timestamp, other.id) == (self.timestamp, self.id)
    }
}

impl Eq for Packet {}

impl PartialOrd for Packet {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Packet {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (other.timestamp, other.id).cmp(&(self.timestamp, self.id))
    }
}

/// Shared bottleneck to run flows through.
/// Models a router's egress link: bandwidth + drop-tail buffer.
struct Bottleneck {
    bandwidth: u64,
    capacity: usize,
    next_tx_available: Instant,

    pushes: u64,
    tail_drops: u64,
}

impl Bottleneck {
    fn new(bandwidth: u64, capacity: usize) -> Self {
        Self {
            bandwidth,
            capacity,
            next_tx_available: Instant::ZERO,
            pushes: 0,
            tail_drops: 0,
        }
    }

    /// Try to transmit a packet through the bottleneck.
    // Returns `None` if dropped by drop-tail. `Some(tx_done)` if admitted.
    fn transmit(&mut self, len: usize, timestamp: Instant) -> Option<Instant> {
        self.pushes += 1;

        let queued_micros =
            (self.next_tx_available.total_micros() - timestamp.total_micros()).max(0) as u64;

        let queued_bytes = (queued_micros * self.bandwidth) / 1_000_000;

        if (queued_bytes as usize).saturating_add(len) > self.capacity {
            log::info!("PACKET DROPPED (drop-tail, queue full)");
            self.tail_drops += 1;
            return None;
        }

        let tx_start = self.next_tx_available.max(timestamp);
        let tx_micros = (len as u64 * 1_000_000) / self.bandwidth;
        let tx_done = tx_start + Duration::from_micros(tx_micros);
        self.next_tx_available = tx_done;
        Some(tx_done)
    }
}

struct Wire {
    queue: BinaryHeap<Packet>,
    latency: Duration,
    loss: f64,
    rng: ChaCha20Rng,
    next_id: u64,
}

impl Wire {
    fn new(latency: Duration, loss: f64, rng: ChaCha20Rng) -> Self {
        Self {
            queue: BinaryHeap::new(),
            latency,
            loss,
            rng,
            next_id: 0,
        }
    }

    fn push(&mut self, data: Vec<u8>, tx_done: Instant) {
        if self.rng.r#gen::<f64>() < self.loss {
            log::info!("PACKET LOST (wire)");
            return;
        }
        self.queue.push(Packet {
            data,
            id: self.next_id,
            timestamp: tx_done + self.latency,
        });
        self.next_id += 1;
    }

    fn peek_arrival(&self) -> Option<Instant> {
        self.queue.peek().map(|p| p.timestamp)
    }

    fn pop(&mut self) -> Vec<u8> {
        self.queue.pop().unwrap().data
    }
}

struct QueueDevice {
    bottleneck: Rc<RefCell<Bottleneck>>,
    tx_wire: Rc<RefCell<Wire>>,
    rx_wire: Rc<RefCell<Wire>>,
    medium: Medium,
}

impl QueueDevice {
    fn new(
        bottleneck: Rc<RefCell<Bottleneck>>,
        tx_wire: Rc<RefCell<Wire>>,
        rx_wire: Rc<RefCell<Wire>>,
        medium: Medium,
    ) -> Self {
        Self {
            bottleneck,
            tx_wire,
            rx_wire,
            medium,
        }
    }
}

impl Device for QueueDevice {
    type RxToken<'a>
        = RxToken
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken<'a>
    where
        Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.max_transmission_unit = 1514;
        caps.medium = self.medium;
        caps.checksum = ChecksumCapabilities::ignored();
        caps
    }

    fn receive(&mut self, timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let mut rx = self.rx_wire.borrow_mut();
        let arrival = rx.peek_arrival()?;
        if arrival > timestamp {
            return None;
        }
        let buffer = rx.pop();
        drop(rx);
        Some((
            RxToken { buffer },
            TxToken {
                bottleneck: &self.bottleneck,
                wire: &self.tx_wire,
                timestamp,
            },
        ))
    }

    fn transmit(&mut self, timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(TxToken {
            bottleneck: &self.bottleneck,
            wire: &self.tx_wire,
            timestamp,
        })
    }
}

struct RxToken {
    buffer: Vec<u8>,
}

impl phy::RxToken for RxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.buffer)
    }
}

struct TxToken<'a> {
    bottleneck: &'a Rc<RefCell<Bottleneck>>,
    wire: &'a Rc<RefCell<Wire>>,
    timestamp: Instant,
}

impl phy::TxToken for TxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut buffer = vec![0; len];
        let result = f(&mut buffer);

        if let Some(tx_done) = self
            .bottleneck
            .borrow_mut()
            .transmit(buffer.len(), self.timestamp)
        {
            self.wire.borrow_mut().push(buffer, tx_done);
        }

        result
    }
}

fn setup_logging() {
    env_logger::Builder::new()
        .format(move |buf, record| {
            let (elapsed, side) = *CLOCK.lock().unwrap();

            let timestamp = format!("[{elapsed} {side}]");
            if record.target().starts_with("smoltcp::") {
                writeln!(
                    buf,
                    "{} ({}): {}",
                    timestamp,
                    record.target().replace("smoltcp::", ""),
                    record.args()
                )
            } else if record.level() == log::Level::Trace {
                let message = format!("{}", record.args());
                writeln!(
                    buf,
                    "{} {}",
                    timestamp,
                    message.replace('\n', "\n             ")
                )
            } else {
                writeln!(
                    buf,
                    "{} ({}): {}",
                    timestamp,
                    record.target(),
                    record.args()
                )
            }
        })
        .parse_env("RUST_LOG")
        .try_init()
        .ok();
}
