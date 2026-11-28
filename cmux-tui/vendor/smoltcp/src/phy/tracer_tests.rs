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
