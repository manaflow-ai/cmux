use core::result::Result;
use heapless::{LinearMap, Vec};

use super::{Interface, InterfaceInner};
#[cfg(any(feature = "proto-ipv4", feature = "proto-ipv6"))]
use super::{IpPayload, Packet, check};
use crate::config::{IFACE_MAX_ADDR_COUNT, IFACE_MAX_MULTICAST_GROUP_COUNT};
use crate::phy::{Device, PacketMeta};
use crate::wire::*;

/// Error type for `join_multicast_group`, `leave_multicast_group`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum MulticastError {
    /// The table of joined multicast groups is already full.
    GroupTableFull,
    /// Cannot join/leave the given multicast group.
    Unaddressable,
}

#[cfg(feature = "proto-ipv4")]
pub(crate) enum IgmpReportState {
    Inactive,
    ToGeneralQuery {
        version: IgmpVersion,
        timeout: crate::time::Instant,
        interval: crate::time::Duration,
        next_index: usize,
    },
    ToSpecificQuery {
        version: IgmpVersion,
        timeout: crate::time::Instant,
        group: Ipv4Address,
    },
}

#[cfg(feature = "proto-ipv6")]
pub(crate) enum MldReportState {
    Inactive,
    ToGeneralQuery {
        timeout: crate::time::Instant,
    },
    ToSpecificQuery {
        group: Ipv6Address,
        timeout: crate::time::Instant,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GroupState {
    /// Joining group, we have to send the join packet.
    Joining,
    /// We've already sent the join packet, we have nothing to do.
    Joined,
    /// We want to leave the group, we have to send a leave packet.
    Leaving,
}

pub(crate) struct State {
    groups: LinearMap<IpAddress, GroupState, IFACE_MAX_MULTICAST_GROUP_COUNT>,
    /// When to report for (all or) the next multicast group membership via IGMP
    #[cfg(feature = "proto-ipv4")]
    igmp_report_state: IgmpReportState,
    #[cfg(feature = "proto-ipv6")]
    mld_report_state: MldReportState,
}

impl State {
    pub(crate) fn new() -> Self {
        Self {
            groups: LinearMap::new(),
            #[cfg(feature = "proto-ipv4")]
            igmp_report_state: IgmpReportState::Inactive,
            #[cfg(feature = "proto-ipv6")]
            mld_report_state: MldReportState::Inactive,
        }
    }

    pub(crate) fn has_multicast_group<T: Into<IpAddress>>(&self, addr: T) -> bool {
        // Return false if we don't have the multicast group,
        // or we're leaving it.
        match self.groups.get(&addr.into()) {
            None => false,
            Some(GroupState::Joining) => true,
            Some(GroupState::Joined) => true,
            Some(GroupState::Leaving) => false,
        }
    }
}

impl core::fmt::Display for MulticastError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            MulticastError::GroupTableFull => write!(f, "GroupTableFull"),
            MulticastError::Unaddressable => write!(f, "Unaddressable"),
        }
    }
}

impl core::error::Error for MulticastError {}

impl Interface {
    /// Add an address to a list of subscribed multicast IP addresses.
    pub fn join_multicast_group<T: Into<IpAddress>>(
        &mut self,
        addr: T,
    ) -> Result<(), MulticastError> {
        let addr = addr.into();
        if !addr.is_multicast() {
            return Err(MulticastError::Unaddressable);
        }

        if let Some(state) = self.inner.multicast.groups.get_mut(&addr) {
            *state = match state {
                GroupState::Joining => GroupState::Joining,
                GroupState::Joined => GroupState::Joined,
                GroupState::Leaving => GroupState::Joined,
            };
        } else {
            self.inner
                .multicast
                .groups
                .insert(addr, GroupState::Joining)
                .map_err(|_| MulticastError::GroupTableFull)?;
        }
        Ok(())
    }

    /// Remove an address from the subscribed multicast IP addresses.
    pub fn leave_multicast_group<T: Into<IpAddress>>(
        &mut self,
        addr: T,
    ) -> Result<(), MulticastError> {
        let addr = addr.into();
        if !addr.is_multicast() {
            return Err(MulticastError::Unaddressable);
        }

        if let Some(state) = self.inner.multicast.groups.get_mut(&addr) {
            let delete;
            (*state, delete) = match state {
                GroupState::Joining => (GroupState::Joined, true),
                GroupState::Joined => (GroupState::Leaving, false),
                GroupState::Leaving => (GroupState::Leaving, false),
            };
            if delete {
                self.inner.multicast.groups.remove(&addr);
            }
        }
        Ok(())
    }

    /// Check whether the interface listens to given destination multicast IP address.
    pub fn has_multicast_group<T: Into<IpAddress>>(&self, addr: T) -> bool {
        self.inner.has_multicast_group(addr)
    }

    #[cfg(feature = "proto-ipv6")]
    pub(super) fn update_solicited_node_groups(&mut self) {
        // Remove old solicited-node multicast addresses
        let removals: Vec<_, IFACE_MAX_MULTICAST_GROUP_COUNT> = self
            .inner
            .multicast
            .groups
            .keys()
            .cloned()
            .filter(|a| matches!(a, IpAddress::Ipv6(a) if a.is_solicited_node_multicast() && !self.inner.has_solicited_node(*a)))
            .collect();
        for removal in removals {
            let _ = self.leave_multicast_group(removal);
        }

        let cidrs: Vec<IpCidr, IFACE_MAX_ADDR_COUNT> = Vec::from_slice(self.ip_addrs()).unwrap();
        for cidr in cidrs {
            if let IpCidr::Ipv6(cidr) = cidr {
                let _ = self.join_multicast_group(cidr.address().solicited_node());
            }
        }
    }

    /// Do multicast egress.
    ///
    /// - Send join/leave packets according to the multicast group state.
    /// - Depending on `igmp_report_state` and the therein contained
    ///   timeouts, send IGMP membership reports.
    pub(crate) fn multicast_egress(&mut self, device: &mut (impl Device + ?Sized)) {
        // Process multicast joins.
        while let Some((&addr, _)) = self
            .inner
            .multicast
            .groups
            .iter()
            .find(|&(_, &state)| state == GroupState::Joining)
        {
            match addr {
                #[cfg(feature = "proto-ipv4")]
                IpAddress::Ipv4(addr) => {
                    if let Some(pkt) = self.inner.igmp_report_packet(IgmpVersion::Version2, addr) {
                        let Some(tx_token) = device.transmit(self.inner.now) else {
                            break;
                        };

                        // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                        self.inner
                            .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                            .unwrap();
                    }
                }
                #[cfg(feature = "proto-ipv6")]
                IpAddress::Ipv6(addr) => {
                    if let Some(pkt) = self.inner.mldv2_report_packet(&[MldAddressRecordRepr::new(
                        MldRecordType::ChangeToInclude,
                        addr,
                    )]) {
                        let Some(tx_token) = device.transmit(self.inner.now) else {
                            break;
                        };

                        // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                        self.inner
                            .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                            .unwrap();
                    }
                }
            }

            // NOTE(unwrap): this is always replacing an existing entry, so it can't fail due to the map being full.
            self.inner
                .multicast
                .groups
                .insert(addr, GroupState::Joined)
                .unwrap();
        }

        // Process multicast leaves.
        while let Some((&addr, _)) = self
            .inner
            .multicast
            .groups
            .iter()
            .find(|&(_, &state)| state == GroupState::Leaving)
        {
            match addr {
                #[cfg(feature = "proto-ipv4")]
                IpAddress::Ipv4(addr) => {
                    if let Some(pkt) = self.inner.igmp_leave_packet(addr) {
                        let Some(tx_token) = device.transmit(self.inner.now) else {
                            break;
                        };

                        // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                        self.inner
                            .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                            .unwrap();
                    }
                }
                #[cfg(feature = "proto-ipv6")]
                IpAddress::Ipv6(addr) => {
                    if let Some(pkt) = self.inner.mldv2_report_packet(&[MldAddressRecordRepr::new(
                        MldRecordType::ChangeToExclude,
                        addr,
                    )]) {
                        let Some(tx_token) = device.transmit(self.inner.now) else {
                            break;
                        };

                        // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                        self.inner
                            .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                            .unwrap();
                    }
                }
            }

            self.inner.multicast.groups.remove(&addr);
        }

        #[cfg(feature = "proto-ipv4")]
        match self.inner.multicast.igmp_report_state {
            IgmpReportState::ToSpecificQuery {
                version,
                timeout,
                group,
            } if self.inner.now >= timeout => {
                if let Some(pkt) = self.inner.igmp_report_packet(version, group) {
                    // Send initial membership report
                    if let Some(tx_token) = device.transmit(self.inner.now) {
                        // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                        self.inner
                            .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                            .unwrap();
                        self.inner.multicast.igmp_report_state = IgmpReportState::Inactive;
                    }
                }
            }
            IgmpReportState::ToGeneralQuery {
                version,
                timeout,
                interval,
                next_index,
            } if self.inner.now >= timeout => {
                let addr = self
                    .inner
                    .multicast
                    .groups
                    .iter()
                    .filter_map(|(addr, _)| match addr {
                        IpAddress::Ipv4(addr) => Some(*addr),
                        #[allow(unreachable_patterns)]
                        _ => None,
                    })
                    .nth(next_index);

                match addr {
                    Some(addr) => {
                        if let Some(pkt) = self.inner.igmp_report_packet(version, addr) {
                            // Send initial membership report
                            if let Some(tx_token) = device.transmit(self.inner.now) {
                                // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                                self.inner
                                    .dispatch_ip(
                                        tx_token,
                                        PacketMeta::default(),
                                        pkt,
                                        &mut self.fragmenter,
                                    )
                                    .unwrap();

                                let next_timeout = (timeout + interval).max(self.inner.now);
                                self.inner.multicast.igmp_report_state =
                                    IgmpReportState::ToGeneralQuery {
                                        version,
                                        timeout: next_timeout,
                                        interval,
                                        next_index: next_index + 1,
                                    };
                            }
                        }
                    }
                    None => {
                        self.inner.multicast.igmp_report_state = IgmpReportState::Inactive;
                    }
                }
            }
            _ => {}
        }
        #[cfg(feature = "proto-ipv6")]
        match self.inner.multicast.mld_report_state {
            MldReportState::ToGeneralQuery { timeout } if self.inner.now >= timeout => {
                let records = self
                    .inner
                    .multicast
                    .groups
                    .iter()
                    .filter_map(|(addr, _)| match addr {
                        IpAddress::Ipv6(addr) => Some(MldAddressRecordRepr::new(
                            MldRecordType::ModeIsExclude,
                            *addr,
                        )),
                        #[allow(unreachable_patterns)]
                        _ => None,
                    })
                    .collect::<heapless::Vec<_, IFACE_MAX_MULTICAST_GROUP_COUNT>>();
                if let Some(pkt) = self.inner.mldv2_report_packet(&records)
                    && let Some(tx_token) = device.transmit(self.inner.now)
                {
                    self.inner
                        .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                        .unwrap();
                };
                self.inner.multicast.mld_report_state = MldReportState::Inactive;
            }
            MldReportState::ToSpecificQuery { group, timeout } if self.inner.now >= timeout => {
                let record = MldAddressRecordRepr::new(MldRecordType::ModeIsExclude, group);
                if let Some(pkt) = self.inner.mldv2_report_packet(&[record])
                    && let Some(tx_token) = device.transmit(self.inner.now)
                {
                    // NOTE(unwrap): packet destination is multicast, which is always routable and doesn't require neighbor discovery.
                    self.inner
                        .dispatch_ip(tx_token, PacketMeta::default(), pkt, &mut self.fragmenter)
                        .unwrap();
                }
                self.inner.multicast.mld_report_state = MldReportState::Inactive;
            }
            _ => {}
        }
    }
}

impl InterfaceInner {
    /// Host duties of the **IGMPv2** protocol.
    ///
    /// Sets up `igmp_report_state` for responding to IGMP general/specific membership queries.
    /// Membership must not be reported immediately in order to avoid flooding the network
    /// after a query is broadcasted by a router; this is not currently done.
    #[cfg(feature = "proto-ipv4")]
    pub(super) fn process_igmp<'frame>(
        &mut self,
        ipv4_repr: Ipv4Repr,
        ip_payload: &'frame [u8],
    ) -> Option<Packet<'frame>> {
        use crate::time::Duration;

        let igmp_packet = check!(IgmpPacket::new_checked(ip_payload));
        let igmp_repr = check!(IgmpRepr::parse(&igmp_packet));

        // FIXME: report membership after a delay
        match igmp_repr {
            IgmpRepr::MembershipQuery {
                group_addr,
                version,
                max_resp_time,
            } => {
                // General query
                if group_addr.is_unspecified() && ipv4_repr.dst_addr == IPV4_MULTICAST_ALL_SYSTEMS {
                    let ipv4_multicast_group_count = self
                        .multicast
                        .groups
                        .keys()
                        .filter(|a| matches!(a, IpAddress::Ipv4(_)))
                        .count();

                    // Are we member in any groups?
                    if ipv4_multicast_group_count != 0 {
                        let interval = match version {
                            IgmpVersion::Version1 => Duration::from_millis(100),
                            IgmpVersion::Version2 => {
                                // No dependence on a random generator
                                // (see [#24](https://github.com/m-labs/smoltcp/issues/24))
                                // but at least spread reports evenly across max_resp_time.
                                let intervals = ipv4_multicast_group_count as u32 + 1;
                                max_resp_time / intervals
                            }
                        };
                        self.multicast.igmp_report_state = IgmpReportState::ToGeneralQuery {
                            version,
                            timeout: self.now + interval,
                            interval,
                            next_index: 0,
                        };
                    }
                } else {
                    // Group-specific query
                    if self.has_multicast_group(group_addr) && ipv4_repr.dst_addr == group_addr {
                        // Don't respond immediately
                        let timeout = max_resp_time / 4;
                        self.multicast.igmp_report_state = IgmpReportState::ToSpecificQuery {
                            version,
                            timeout: self.now + timeout,
                            group: group_addr,
                        };
                    }
                }
            }
            // Ignore membership reports
            IgmpRepr::MembershipReport { .. } => (),
            // Ignore hosts leaving groups
            IgmpRepr::LeaveGroup { .. } => (),
        }

        None
    }

    #[cfg(feature = "proto-ipv4")]
    fn igmp_report_packet<'any>(
        &self,
        version: IgmpVersion,
        group_addr: Ipv4Address,
    ) -> Option<Packet<'any>> {
        let iface_addr = self.ipv4_addr()?;
        let igmp_repr = IgmpRepr::MembershipReport {
            group_addr,
            version,
        };
        let pkt = Packet::new_ipv4(
            Ipv4Repr {
                src_addr: iface_addr,
                // Send to the group being reported
                dst_addr: group_addr,
                next_header: IpProtocol::Igmp,
                payload_len: igmp_repr.buffer_len(),
                hop_limit: 1,
                // [#183](https://github.com/m-labs/smoltcp/issues/183).
            },
            IpPayload::Igmp(igmp_repr),
        );
        Some(pkt)
    }

    #[cfg(feature = "proto-ipv4")]
    fn igmp_leave_packet<'any>(&self, group_addr: Ipv4Address) -> Option<Packet<'any>> {
        self.ipv4_addr().map(|iface_addr| {
            let igmp_repr = IgmpRepr::LeaveGroup { group_addr };
            Packet::new_ipv4(
                Ipv4Repr {
                    src_addr: iface_addr,
                    dst_addr: IPV4_MULTICAST_ALL_ROUTERS,
                    next_header: IpProtocol::Igmp,
                    payload_len: igmp_repr.buffer_len(),
                    hop_limit: 1,
                },
                IpPayload::Igmp(igmp_repr),
            )
        })
    }

    /// Host duties of the **MLDv2** protocol.
    ///
    /// Sets up `mld_report_state` for responding to MLD general/specific membership queries.
    /// Membership must not be reported immediately in order to avoid flooding the network
    /// after a query is broadcasted by a router; Currently the delay is fixed and not randomized.
    #[cfg(feature = "proto-ipv6")]
    pub(super) fn process_mldv2<'frame>(
        &mut self,
        ip_repr: Ipv6Repr,
        repr: MldRepr<'frame>,
    ) -> Option<Packet<'frame>> {
        match repr {
            MldRepr::Query {
                mcast_addr,
                max_resp_code,
                ..
            } => {
                // Do not respond immediately to the query, but wait a random time
                let delay = if max_resp_code > 0 {
                    (self.rand.rand_u16() % max_resp_code).into()
                } else {
                    0
                };
                let delay = crate::time::Duration::from_millis(delay);
                // General query
                if mcast_addr.is_unspecified()
                    && (ip_repr.dst_addr == IPV6_LINK_LOCAL_ALL_NODES
                        || self.has_ip_addr(ip_repr.dst_addr))
                {
                    let ipv6_multicast_group_count = self
                        .multicast
                        .groups
                        .keys()
                        .filter(|a| matches!(a, IpAddress::Ipv6(_)))
                        .count();
                    if ipv6_multicast_group_count != 0 {
                        self.multicast.mld_report_state = MldReportState::ToGeneralQuery {
                            timeout: self.now + delay,
                        };
                    }
                }
                if self.has_multicast_group(mcast_addr) && ip_repr.dst_addr == mcast_addr {
                    self.multicast.mld_report_state = MldReportState::ToSpecificQuery {
                        group: mcast_addr,
                        timeout: self.now + delay,
                    };
                }
                None
            }
            MldRepr::Report { .. } => None,
            MldRepr::ReportRecordReprs { .. } => None,
        }
    }
}
