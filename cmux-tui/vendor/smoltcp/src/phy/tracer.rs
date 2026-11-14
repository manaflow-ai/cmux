use core::fmt;

use crate::phy::{self, Device, DeviceCapabilities, Medium};
use crate::time::Instant;
use crate::wire::pretty_print::{PrettyIndent, PrettyPrint};

/// A tracer device.
///
/// A tracer is a device that pretty prints all packets traversing it
/// using the provided writer function, and then passes them to another
/// device.
pub struct Tracer<D: Device> {
    inner: D,
    writer: fn(Instant, TracerPacket),
}

impl<D: Device> Tracer<D> {
    /// Create a tracer device.
    pub fn new(inner: D, writer: fn(timestamp: Instant, packet: TracerPacket)) -> Tracer<D> {
        Tracer { inner, writer }
    }

    /// Get a reference to the underlying device.
    ///
    /// Even if the device offers reading through a standard reference, it is inadvisable to
    /// directly read from the device as doing so will circumvent the tracing.
    pub fn get_ref(&self) -> &D {
        &self.inner
    }

    /// Get a mutable reference to the underlying device.
    ///
    /// It is inadvisable to directly read from the device as doing so will circumvent the tracing.
    pub fn get_mut(&mut self) -> &mut D {
        &mut self.inner
    }

    /// Return the underlying device, consuming the tracer.
    pub fn into_inner(self) -> D {
        self.inner
    }
}

impl<D: Device> Device for Tracer<D> {
    type RxToken<'a>
        = RxToken<D::RxToken<'a>>
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken<D::TxToken<'a>>
    where
        Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        self.inner.capabilities()
    }

    fn receive(&mut self, timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let medium = self.inner.capabilities().medium;
        self.inner.receive(timestamp).map(|(rx_token, tx_token)| {
            let rx = RxToken {
                token: rx_token,
                writer: self.writer,
                medium,
                timestamp,
            };
            let tx = TxToken {
                token: tx_token,
                writer: self.writer,
                medium,
                timestamp,
            };
            (rx, tx)
        })
    }

    fn transmit(&mut self, timestamp: Instant) -> Option<Self::TxToken<'_>> {
        let medium = self.inner.capabilities().medium;
        self.inner.transmit(timestamp).map(|tx_token| TxToken {
            token: tx_token,
            medium,
            writer: self.writer,
            timestamp,
        })
    }
}

#[doc(hidden)]
pub struct RxToken<Rx: phy::RxToken> {
    token: Rx,
    writer: fn(Instant, TracerPacket),
    medium: Medium,
    timestamp: Instant,
}

impl<Rx: phy::RxToken> phy::RxToken for RxToken<Rx> {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        self.token.consume(|buffer| {
            (self.writer)(
                self.timestamp,
                TracerPacket {
                    buffer,
                    medium: self.medium,
                    direction: TracerDirection::RX,
                },
            );
            f(buffer)
        })
    }

    fn meta(&self) -> phy::PacketMeta {
        self.token.meta()
    }
}

#[doc(hidden)]
pub struct TxToken<Tx: phy::TxToken> {
    token: Tx,
    writer: fn(Instant, TracerPacket),
    medium: Medium,
    timestamp: Instant,
}

impl<Tx: phy::TxToken> phy::TxToken for TxToken<Tx> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        self.token.consume(len, |buffer| {
            let result = f(buffer);
            (self.writer)(
                self.timestamp,
                TracerPacket {
                    buffer,
                    medium: self.medium,
                    direction: TracerDirection::TX,
                },
            );
            result
        })
    }

    fn set_meta(&mut self, meta: phy::PacketMeta) {
        self.token.set_meta(meta)
    }
}

/// Packet which is being traced by [Tracer](struct.Tracer.html) device.
#[derive(Debug, Clone, Copy)]
pub struct TracerPacket<'a> {
    /// Packet buffer
    pub buffer: &'a [u8],
    /// Packet medium
    pub medium: Medium,
    /// Direction in which packet is being traced
    pub direction: TracerDirection,
}

/// Direction on which packet is being traced
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TracerDirection {
    /// Packet is received by Smoltcp interface
    RX,
    /// Packet is transmitted by Smoltcp interface
    TX,
}

impl<'a> fmt::Display for TracerPacket<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let prefix = match self.direction {
            TracerDirection::RX => "<- ",
            TracerDirection::TX => "-> ",
        };

        let mut indent = PrettyIndent::new(prefix);
        match self.medium {
            #[cfg(feature = "medium-ethernet")]
            Medium::Ethernet => crate::wire::EthernetFrame::<&'static [u8]>::pretty_print(
                &self.buffer,
                f,
                &mut indent,
            ),
            #[cfg(feature = "medium-ip")]
            Medium::Ip => match crate::wire::IpVersion::of_packet(self.buffer) {
                #[cfg(feature = "proto-ipv4")]
                Ok(crate::wire::IpVersion::Ipv4) => {
                    crate::wire::Ipv4Packet::<&'static [u8]>::pretty_print(
                        &self.buffer,
                        f,
                        &mut indent,
                    )
                }
                #[cfg(feature = "proto-ipv6")]
                Ok(crate::wire::IpVersion::Ipv6) => {
                    crate::wire::Ipv6Packet::<&'static [u8]>::pretty_print(
                        &self.buffer,
                        f,
                        &mut indent,
                    )
                }
                _ => f.write_str("unrecognized IP version"),
            },
            #[cfg(feature = "medium-ieee802154")]
            Medium::Ieee802154 => Ok(()), // XXX
        }
    }
}

#[cfg(test)]
mod tests {
    use core::cell::RefCell;
    use std::collections::VecDeque;

    use super::*;

    use crate::phy::ChecksumCapabilities;
    use crate::{
        phy::{Device, Loopback, RxToken, TxToken},
        time::Instant,
    };

    #[cfg(any(
        feature = "medium-ethernet",
        feature = "medium-ip",
        feature = "medium-ieee802154"
    ))]
    #[test]
    fn test_tracer() {
        type TracerEvent = (Instant, Vec<u8>, Medium, TracerDirection);
        thread_local! {
            static TRACE_EVENTS: RefCell<VecDeque<TracerEvent>> = const { RefCell::new(VecDeque::new()) };
        }
        TRACE_EVENTS.replace(VecDeque::new());

        let medium = Medium::default();

        let loopback_device = Loopback::new(medium);
        let mut tracer_device = Tracer::new(loopback_device, |instant, packet| {
            TRACE_EVENTS.with_borrow_mut(|events| {
                events.push_back((
                    instant,
                    packet.buffer.to_owned(),
                    packet.medium,
                    packet.direction,
                ))
            });
        });

        let expected_payload = [1, 2, 3, 4, 5, 6, 7, 8];

        let tx_instant = Instant::from_secs(1);
        let tx_token = tracer_device.transmit(tx_instant).unwrap();

        tx_token.consume(expected_payload.len(), |buf| {
            buf.copy_from_slice(&expected_payload)
        });
        let last_event = TRACE_EVENTS.with_borrow_mut(|events| events.pop_front());
        assert_eq!(
            last_event,
            Some((
                tx_instant,
                expected_payload.into(),
                medium,
                TracerDirection::TX
            ))
        );
        let last_event = TRACE_EVENTS.with_borrow_mut(|events| events.pop_front());
        assert_eq!(last_event, None);

        let rx_instant = Instant::from_secs(2);
        let (rx_token, _) = tracer_device.receive(rx_instant).unwrap();
        let mut rx_pkt = [0; 8];
        rx_token.consume(|buf| rx_pkt.copy_from_slice(buf));

        assert_eq!(rx_pkt, expected_payload);

        let last_event = TRACE_EVENTS.with_borrow_mut(|events| events.pop_front());
        assert_eq!(
            last_event,
            Some((
                rx_instant,
                expected_payload.into(),
                medium,
                TracerDirection::RX
            ))
        );
        let last_event = TRACE_EVENTS.with_borrow_mut(|events| events.pop_front());
        assert_eq!(last_event, None);
    }

    #[cfg(feature = "medium-ethernet")]
    #[test]
    fn test_tracer_packet_display_ether() {
        use crate::wire::{EthernetAddress, EthernetProtocol, EthernetRepr};

        let repr = EthernetRepr {
            src_addr: EthernetAddress([0, 1, 2, 3, 4, 5]),
            dst_addr: EthernetAddress([5, 4, 3, 2, 1, 0]),
            ethertype: EthernetProtocol::Unknown(0),
        };
        let mut buffer = vec![0_u8; repr.buffer_len()];
        {
            use crate::wire::EthernetFrame;

            let mut frame = EthernetFrame::new_unchecked(&mut buffer);
            repr.emit(&mut frame);
        }

        let pkt = TracerPacket {
            buffer: &buffer,
            medium: Medium::Ethernet,
            direction: TracerDirection::RX,
        };

        let pkt_pretty = pkt.to_string();
        assert_eq!(
            pkt_pretty,
            "<- EthernetII src=00-01-02-03-04-05 dst=05-04-03-02-01-00 type=0x0000"
        );
    }

    #[cfg(all(feature = "medium-ip", feature = "proto-ipv4"))]
    #[test]
    fn test_tracer_packet_display_ip() {
        use crate::wire::{IpProtocol, Ipv4Address, Ipv4Repr};

        let repr = Ipv4Repr {
            src_addr: Ipv4Address::new(10, 0, 0, 1),
            dst_addr: Ipv4Address::new(10, 0, 0, 2),
            next_header: IpProtocol::Unknown(255),
            payload_len: 0,
            hop_limit: 64,
        };

        let mut buffer = vec![0_u8; repr.buffer_len()];
        {
            use crate::wire::Ipv4Packet;

            let mut packet = Ipv4Packet::new_unchecked(&mut buffer);
            repr.emit(&mut packet, &ChecksumCapabilities::default());
        }

        let pkt = TracerPacket {
            buffer: &buffer,
            medium: Medium::Ip,
            direction: TracerDirection::TX,
        };

        let pkt_pretty = pkt.to_string();
        assert_eq!(pkt_pretty, "-> IPv4 src=10.0.0.1 dst=10.0.0.2 proto=0xff");
    }
}
