use core::cmp::min;
#[cfg(feature = "async")]
use core::task::Waker;

use heapless::Vec;
use managed::ManagedSlice;

use crate::config::{DNS_MAX_NAME_SIZE, DNS_MAX_RESULT_COUNT, DNS_MAX_SERVER_COUNT};
use crate::socket::{Context, PollAt};
use crate::time::{Duration, Instant};
use crate::wire::dns::{Flags, Opcode, Packet, Question, Rcode, Record, RecordData, Repr, Type};
use crate::wire::{self, IpAddress, IpProtocol, IpRepr, UdpRepr};

#[cfg(feature = "async")]
use super::WakerRegistration;

const DNS_PORT: u16 = 53;
const MDNS_DNS_PORT: u16 = 5353;
const RETRANSMIT_DELAY: Duration = Duration::from_millis(1_000);
const MAX_RETRANSMIT_DELAY: Duration = Duration::from_millis(10_000);
const RETRANSMIT_TIMEOUT: Duration = Duration::from_millis(10_000); // Should generally be 2-10 secs

#[cfg(feature = "proto-ipv6")]
#[allow(unused)]
const MDNS_IPV6_ADDR: IpAddress = IpAddress::Ipv6(crate::wire::Ipv6Address::new(
    0xff02, 0, 0, 0, 0, 0, 0, 0xfb,
));

#[cfg(feature = "proto-ipv4")]
#[allow(unused)]
const MDNS_IPV4_ADDR: IpAddress = IpAddress::Ipv4(crate::wire::Ipv4Address::new(224, 0, 0, 251));

/// Error returned by [`Socket::start_query`]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum StartQueryError {
    NoFreeSlot,
    InvalidName,
    NameTooLong,
}

impl core::fmt::Display for StartQueryError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            StartQueryError::NoFreeSlot => write!(f, "No free slot"),
            StartQueryError::InvalidName => write!(f, "Invalid name"),
            StartQueryError::NameTooLong => write!(f, "Name too long"),
        }
    }
}

impl core::error::Error for StartQueryError {}

/// Error returned by [`Socket::get_query_result`]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum GetQueryResultError {
    /// Query is not done yet.
    Pending,
    /// Query failed.
    Failed,
}

impl core::fmt::Display for GetQueryResultError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            GetQueryResultError::Pending => write!(f, "Query is not done yet"),
            GetQueryResultError::Failed => write!(f, "Query failed"),
        }
    }
}

impl core::error::Error for GetQueryResultError {}

/// State for an in-progress DNS query.
///
/// The only reason this struct is public is to allow the socket state
/// to be allocated externally.
#[derive(Debug)]
pub struct DnsQuery {
    state: State,

    #[cfg(feature = "async")]
    waker: WakerRegistration,
}

impl DnsQuery {
    fn set_state(&mut self, state: State) {
        self.state = state;
        #[cfg(feature = "async")]
        self.waker.wake();
    }
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
enum State {
    Pending(PendingQuery),
    Completed(CompletedQuery),
    Failure,
}

#[derive(Debug)]
struct PendingQuery {
    name: Vec<u8, DNS_MAX_NAME_SIZE>,
    type_: Type,

    port: u16, // UDP port (src for request, dst for response)
    txid: u16, // transaction ID

    timeout_at: Option<Instant>,
    retransmit_at: Instant,
    delay: Duration,

    server_idx: usize,
    mdns: MulticastDns,
}

#[derive(Debug)]
pub enum MulticastDns {
    Disabled,
    #[cfg(feature = "socket-mdns")]
    Enabled,
}

#[derive(Debug)]
struct CompletedQuery {
    addresses: Vec<IpAddress, DNS_MAX_RESULT_COUNT>,
}

/// A handle to an in-progress DNS query.
#[derive(Clone, Copy)]
pub struct QueryHandle(usize);

/// A Domain Name System socket.
///
/// A UDP socket is bound to a specific endpoint, and owns transmit and receive
/// packet buffers.
#[derive(Debug)]
pub struct Socket<'a> {
    servers: Vec<IpAddress, DNS_MAX_SERVER_COUNT>,
    queries: ManagedSlice<'a, Option<DnsQuery>>,

    /// The time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    hop_limit: Option<u8>,
}

impl<'a> Socket<'a> {
    /// Create a DNS socket.
    ///
    /// Truncates the server list if `servers.len() > MAX_SERVER_COUNT`
    pub fn new<Q>(servers: &[IpAddress], queries: Q) -> Socket<'a>
    where
        Q: Into<ManagedSlice<'a, Option<DnsQuery>>>,
    {
        let truncated_servers = &servers[..min(servers.len(), DNS_MAX_SERVER_COUNT)];

        Socket {
            servers: Vec::from_slice(truncated_servers).unwrap(),
            queries: queries.into(),
            hop_limit: None,
        }
    }

    /// Update the list of DNS servers, will replace all existing servers
    ///
    /// Truncates the server list if `servers.len() > MAX_SERVER_COUNT`
    pub fn update_servers(&mut self, servers: &[IpAddress]) {
        if servers.len() > DNS_MAX_SERVER_COUNT {
            net_trace!("Max DNS Servers exceeded. Increase MAX_SERVER_COUNT");
            self.servers = Vec::from_slice(&servers[..DNS_MAX_SERVER_COUNT]).unwrap();
        } else {
            self.servers = Vec::from_slice(servers).unwrap();
        }
    }

    /// Return the time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    ///
    /// See also the [set_hop_limit](#method.set_hop_limit) method
    pub fn hop_limit(&self) -> Option<u8> {
        self.hop_limit
    }

    /// Set the time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    ///
    /// A socket without an explicitly set hop limit value uses the default [IANA recommended]
    /// value (64).
    ///
    /// # Panics
    ///
    /// This function panics if a hop limit value of 0 is given. See [RFC 1122 § 3.2.1.7].
    ///
    /// [IANA recommended]: https://www.iana.org/assignments/ip-parameters/ip-parameters.xhtml
    /// [RFC 1122 § 3.2.1.7]: https://tools.ietf.org/html/rfc1122#section-3.2.1.7
    pub fn set_hop_limit(&mut self, hop_limit: Option<u8>) {
        // A host MUST NOT send a datagram with a hop limit value of 0
        if let Some(0) = hop_limit {
            panic!("the time-to-live value of a packet must not be zero")
        }

        self.hop_limit = hop_limit
    }

    fn find_free_query(&mut self) -> Option<QueryHandle> {
        for (i, q) in self.queries.iter().enumerate() {
            if q.is_none() {
                return Some(QueryHandle(i));
            }
        }

        match &mut self.queries {
            ManagedSlice::Borrowed(_) => None,
            #[cfg(feature = "alloc")]
            ManagedSlice::Owned(queries) => {
                queries.push(None);
                let index = queries.len() - 1;
                Some(QueryHandle(index))
            }
        }
    }

    /// Start a query.
    ///
    /// `name` is specified in human-friendly format, such as `"rust-lang.org"`.
    /// It accepts names both with and without trailing dot, and they're treated
    /// the same (there's no support for DNS search path).
    pub fn start_query(
        &mut self,
        cx: &mut Context,
        name: &str,
        query_type: Type,
    ) -> Result<QueryHandle, StartQueryError> {
        let mut name = name.as_bytes();

        if name.is_empty() {
            net_trace!("invalid name: zero length");
            return Err(StartQueryError::InvalidName);
        }

        // Remove trailing dot, if any
        if name[name.len() - 1] == b'.' {
            name = &name[..name.len() - 1];
        }

        let mut raw_name: Vec<u8, DNS_MAX_NAME_SIZE> = Vec::new();

        let mut mdns = MulticastDns::Disabled;
        #[cfg(feature = "socket-mdns")]
        if name.split(|&c| c == b'.').next_back().unwrap() == b"local" {
            net_trace!("Starting a mDNS query");
            mdns = MulticastDns::Enabled;
        }

        for s in name.split(|&c| c == b'.') {
            if s.len() > 63 {
                net_trace!("invalid name: too long label");
                return Err(StartQueryError::InvalidName);
            }
            if s.is_empty() {
                net_trace!("invalid name: zero length label");
                return Err(StartQueryError::InvalidName);
            }

            // Push label
            raw_name
                .push(s.len() as u8)
                .map_err(|_| StartQueryError::NameTooLong)?;
            raw_name
                .extend_from_slice(s)
                .map_err(|_| StartQueryError::NameTooLong)?;
        }

        // Push terminator.
        raw_name
            .push(0x00)
            .map_err(|_| StartQueryError::NameTooLong)?;

        self.start_query_raw(cx, &raw_name, query_type, mdns)
    }

    /// Start a query with a raw (wire-format) DNS name.
    /// `b"\x09rust-lang\x03org\x00"`
    ///
    /// You probably want to use [`start_query`](Self::start_query) instead.
    pub fn start_query_raw(
        &mut self,
        cx: &mut Context,
        raw_name: &[u8],
        query_type: Type,
        mdns: MulticastDns,
    ) -> Result<QueryHandle, StartQueryError> {
        let handle = self.find_free_query().ok_or(StartQueryError::NoFreeSlot)?;

        self.queries[handle.0] = Some(DnsQuery {
            state: State::Pending(PendingQuery {
                name: Vec::from_slice(raw_name).map_err(|_| StartQueryError::NameTooLong)?,
                type_: query_type,
                txid: cx.rand().rand_u16(),
                port: cx.rand().rand_source_port(),
                delay: RETRANSMIT_DELAY,
                timeout_at: None,
                retransmit_at: Instant::ZERO,
                server_idx: 0,
                mdns,
            }),
            #[cfg(feature = "async")]
            waker: WakerRegistration::new(),
        });
        Ok(handle)
    }

    /// Get the result of a query.
    ///
    /// If the query is completed, the query slot is automatically freed.
    ///
    /// # Panics
    /// Panics if the QueryHandle corresponds to a free slot.
    pub fn get_query_result(
        &mut self,
        handle: QueryHandle,
    ) -> Result<Vec<IpAddress, DNS_MAX_RESULT_COUNT>, GetQueryResultError> {
        let slot = &mut self.queries[handle.0];
        let q = slot.as_mut().unwrap();
        match &mut q.state {
            // Query is not done yet.
            State::Pending(_) => Err(GetQueryResultError::Pending),
            // Query is done
            State::Completed(q) => {
                let res = q.addresses.clone();
                *slot = None; // Free up the slot for recycling.
                Ok(res)
            }
            State::Failure => {
                *slot = None; // Free up the slot for recycling.
                Err(GetQueryResultError::Failed)
            }
        }
    }

    /// Cancels a query, freeing the slot.
    ///
    /// # Panics
    ///
    /// Panics if the QueryHandle corresponds to an already free slot.
    pub fn cancel_query(&mut self, handle: QueryHandle) {
        let slot = &mut self.queries[handle.0];
        if slot.is_none() {
            panic!("Canceling query in a free slot.")
        }
        *slot = None; // Free up the slot for recycling.
    }

    /// Assign a waker to a query slot
    ///
    /// The waker will be woken when the query completes, either successfully or failed.
    ///
    /// # Panics
    ///
    /// Panics if the QueryHandle corresponds to an already free slot.
    #[cfg(feature = "async")]
    pub fn register_query_waker(&mut self, handle: QueryHandle, waker: &Waker) {
        self.queries[handle.0]
            .as_mut()
            .unwrap()
            .waker
            .register(waker);
    }

    pub(crate) fn accepts(&self, ip_repr: &IpRepr, udp_repr: &UdpRepr) -> bool {
        (udp_repr.src_port == DNS_PORT
            && self
                .servers
                .iter()
                .any(|server| *server == ip_repr.src_addr()))
            || (udp_repr.src_port == MDNS_DNS_PORT)
    }

    pub(crate) fn process(
        &mut self,
        _cx: &mut Context,
        ip_repr: &IpRepr,
        udp_repr: &UdpRepr,
        payload: &[u8],
    ) {
        debug_assert!(self.accepts(ip_repr, udp_repr));

        let size = payload.len();

        net_trace!(
            "receiving {} octets from {:?}:{}",
            size,
            ip_repr.src_addr(),
            udp_repr.dst_port
        );

        let p = match Packet::new_checked(payload) {
            Ok(x) => x,
            Err(_) => {
                net_trace!("dns packet malformed");
                return;
            }
        };
        if p.opcode() != Opcode::Query {
            net_trace!("unwanted opcode {:?}", p.opcode());
            return;
        }

        if !p.flags().contains(Flags::RESPONSE) {
            net_trace!("packet doesn't have response bit set");
            return;
        }

        if p.question_count() != 1 {
            net_trace!("bad question count {:?}", p.question_count());
            return;
        }

        // Find pending query
        for q in self.queries.iter_mut().flatten() {
            if let State::Pending(pq) = &mut q.state {
                if udp_repr.dst_port != pq.port || p.transaction_id() != pq.txid {
                    continue;
                }

                if p.rcode() == Rcode::NXDomain {
                    net_trace!("rcode NXDomain");
                    q.set_state(State::Failure);
                    continue;
                }

                let payload = p.payload();
                let (mut payload, question) = match Question::parse(payload) {
                    Ok(x) => x,
                    Err(_) => {
                        net_trace!("question malformed");
                        return;
                    }
                };

                if question.type_ != pq.type_ {
                    net_trace!("question type mismatch");
                    return;
                }

                match eq_names(p.parse_name(question.name), p.parse_name(&pq.name)) {
                    Ok(true) => {}
                    Ok(false) => {
                        net_trace!("question name mismatch");
                        return;
                    }
                    Err(_) => {
                        net_trace!("dns question name malformed");
                        return;
                    }
                }

                let mut addresses = Vec::new();

                for _ in 0..p.answer_record_count() {
                    let (payload2, r) = match Record::parse(payload) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!("dns answer record malformed");
                            return;
                        }
                    };
                    payload = payload2;

                    match eq_names(p.parse_name(r.name), p.parse_name(&pq.name)) {
                        Ok(true) => {}
                        Ok(false) => {
                            net_trace!("answer name mismatch: {:?}", r);
                            continue;
                        }
                        Err(_) => {
                            net_trace!("dns answer record name malformed");
                            return;
                        }
                    }

                    match r.data {
                        #[cfg(feature = "proto-ipv4")]
                        RecordData::A(addr) => {
                            net_trace!("A: {:?}", addr);
                            if addresses.push(addr.into()).is_err() {
                                net_trace!("too many addresses in response, ignoring {:?}", addr);
                            }
                        }
                        #[cfg(feature = "proto-ipv6")]
                        RecordData::Aaaa(addr) => {
                            net_trace!("AAAA: {:?}", addr);
                            if addresses.push(addr.into()).is_err() {
                                net_trace!("too many addresses in response, ignoring {:?}", addr);
                            }
                        }
                        RecordData::Cname(name) => {
                            net_trace!("CNAME: {:?}", name);

                            // When faced with a CNAME, recursive resolvers are supposed to
                            // resolve the CNAME and append the results for it.
                            //
                            // We update the query with the new name, so that we pick up the A/AAAA
                            // records for the CNAME when we parse them later.
                            // I believe it's mandatory the CNAME results MUST come *after* in the
                            // packet, so it's enough to do one linear pass over it.
                            if copy_name(&mut pq.name, p.parse_name(name)).is_err() {
                                net_trace!("dns answer cname malformed");
                                return;
                            }
                        }
                        RecordData::Other(type_, data) => {
                            net_trace!("unknown: {:?} {:?}", type_, data)
                        }
                    }
                }

                q.set_state(if addresses.is_empty() {
                    State::Failure
                } else {
                    State::Completed(CompletedQuery { addresses })
                });

                // If we get here, packet matched the current query, stop processing.
                return;
            }
        }

        // If we get here, packet matched with no query.
        net_trace!("no query matched");
    }

    pub(crate) fn dispatch<F, E>(&mut self, cx: &mut Context, emit: F) -> Result<(), E>
    where
        F: FnOnce(&mut Context, (IpRepr, UdpRepr, &[u8])) -> Result<(), E>,
    {
        let hop_limit = self.hop_limit.unwrap_or(64);

        for q in self.queries.iter_mut().flatten() {
            if let State::Pending(pq) = &mut q.state {
                // As per RFC 6762 any DNS query ending in .local. MUST be sent as mdns
                // so we internally overwrite the servers for any of those queries
                // in this function.
                let servers = match pq.mdns {
                    #[cfg(feature = "socket-mdns")]
                    MulticastDns::Enabled => &[
                        #[cfg(feature = "proto-ipv6")]
                        MDNS_IPV6_ADDR,
                        #[cfg(feature = "proto-ipv4")]
                        MDNS_IPV4_ADDR,
                    ],
                    MulticastDns::Disabled => self.servers.as_slice(),
                };

                let timeout = if let Some(timeout) = pq.timeout_at {
                    timeout
                } else {
                    let v = cx.now() + RETRANSMIT_TIMEOUT;
                    pq.timeout_at = Some(v);
                    v
                };

                // Check timeout
                if timeout < cx.now() {
                    // DNS timeout
                    pq.timeout_at = Some(cx.now() + RETRANSMIT_TIMEOUT);
                    pq.retransmit_at = Instant::ZERO;
                    pq.delay = RETRANSMIT_DELAY;

                    // Try next server. We check below whether we've tried all servers.
                    pq.server_idx += 1;
                }
                // Check if we've run out of servers to try.
                if pq.server_idx >= servers.len() {
                    net_trace!("already tried all servers.");
                    q.set_state(State::Failure);
                    continue;
                }

                // Check so the IP address is valid
                if servers[pq.server_idx].is_unspecified() {
                    net_trace!("invalid unspecified DNS server addr.");
                    q.set_state(State::Failure);
                    continue;
                }

                if pq.retransmit_at > cx.now() {
                    // query is waiting for retransmit
                    continue;
                }

                let repr = Repr {
                    transaction_id: pq.txid,
                    flags: Flags::RECURSION_DESIRED,
                    opcode: Opcode::Query,
                    question: Question {
                        name: &pq.name,
                        type_: pq.type_,
                    },
                };

                let mut payload = [0u8; 512];
                let payload = &mut payload[..repr.buffer_len()];
                repr.emit(&mut Packet::new_unchecked(payload));

                let dst_port = match pq.mdns {
                    #[cfg(feature = "socket-mdns")]
                    MulticastDns::Enabled => MDNS_DNS_PORT,
                    MulticastDns::Disabled => DNS_PORT,
                };

                let udp_repr = UdpRepr {
                    src_port: pq.port,
                    dst_port,
                };

                let dst_addr = servers[pq.server_idx];
                let src_addr = match cx.get_source_address(&dst_addr) {
                    Some(src_addr) => src_addr,
                    None => {
                        net_trace!("no source address for destination {}", dst_addr);
                        q.set_state(State::Failure);
                        continue;
                    }
                };

                let ip_repr = IpRepr::new(
                    src_addr,
                    dst_addr,
                    IpProtocol::Udp,
                    udp_repr.header_len() + payload.len(),
                    hop_limit,
                );

                net_trace!(
                    "sending {} octets to {} from port {}",
                    payload.len(),
                    ip_repr.dst_addr(),
                    udp_repr.src_port
                );

                emit(cx, (ip_repr, udp_repr, payload))?;

                pq.retransmit_at = cx.now() + pq.delay;
                pq.delay = MAX_RETRANSMIT_DELAY.min(pq.delay * 2);

                return Ok(());
            }
        }

        // Nothing to dispatch
        Ok(())
    }

    pub(crate) fn poll_at(&self, _cx: &Context) -> PollAt {
        self.queries
            .iter()
            .flatten()
            .filter_map(|q| match &q.state {
                State::Pending(pq) => Some(PollAt::Time(pq.retransmit_at)),
                State::Completed(_) => None,
                State::Failure => None,
            })
            .min()
            .unwrap_or(PollAt::Ingress)
    }
}

fn eq_names<'a>(
    mut a: impl Iterator<Item = wire::Result<&'a [u8]>>,
    mut b: impl Iterator<Item = wire::Result<&'a [u8]>>,
) -> wire::Result<bool> {
    loop {
        match (a.next(), b.next()) {
            // Handle errors
            (Some(Err(e)), _) => return Err(e),
            (_, Some(Err(e))) => return Err(e),

            // Both finished -> equal
            (None, None) => return Ok(true),

            // One finished before the other -> not equal
            (None, _) => return Ok(false),
            (_, None) => return Ok(false),

            // Got two labels, check if they're equal
            (Some(Ok(la)), Some(Ok(lb))) => {
                if la != lb {
                    return Ok(false);
                }
            }
        }
    }
}

fn copy_name<'a, const N: usize>(
    dest: &mut Vec<u8, N>,
    name: impl Iterator<Item = wire::Result<&'a [u8]>>,
) -> Result<(), wire::Error> {
    dest.truncate(0);

    for label in name {
        let label = label?;
        dest.push(label.len() as u8).map_err(|_| wire::Error)?;
        dest.extend_from_slice(label).map_err(|_| wire::Error)?;
    }

    // Write terminator 0x00
    dest.push(0).map_err(|_| wire::Error)?;

    Ok(())
}
