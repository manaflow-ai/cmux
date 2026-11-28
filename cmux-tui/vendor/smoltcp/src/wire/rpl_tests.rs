use super::Repr as RplRepr;
use super::options::{Packet as OptionPacket, Repr as OptionRepr};
use super::*;
use crate::phy::ChecksumCapabilities;
use crate::wire::{icmpv6::*, *};

#[test]
fn dag_metric_container_option_is_rejected() {
    // Option type 0x02 (DAG Metric Container) must parse to an error, not panic.
    let option = OptionPacket::new_unchecked(&[0x02, 0x00][..]);
    assert_eq!(OptionRepr::parse(&option), Err(Error));
}

#[test]
fn short_option_is_rejected() {
    // A 2-byte RPL Target option (type 0x05) must be rejected, not read
    // byte 3 out of bounds.
    assert_eq!(
        OptionRepr::parse(&OptionPacket::new_unchecked(&[0x05, 0x00][..])),
        Err(Error)
    );
    assert!(OptionPacket::new_checked(&[0x05, 0x00][..]).is_err());
}

#[test]
fn padn_emit_does_not_underflow() {
    // PadN length byte 254 must re-emit without option_length underflow.
    let repr = OptionRepr::parse(&OptionPacket::new_unchecked(&[0x01, 0xFE][..])).unwrap();
    let mut buffer = vec![0u8; repr.buffer_len()];
    repr.emit(&mut OptionPacket::new_unchecked(&mut buffer[..]));
    assert_eq!(buffer[1], 254);
}

#[test]
fn dis_packet() {
    let data = [0x7a, 0x3b, 0x3a, 0x1a, 0x9b, 0x00, 0x00, 0x00, 0x00, 0x00];

    let ll_src_address =
        Ieee802154Address::Extended([0x9e, 0xd3, 0xa2, 0x9c, 0x57, 0x1a, 0x4f, 0xe4]);
    let ll_dst_address = Ieee802154Address::Short([0xff, 0xff]);

    let packet = SixlowpanIphcPacket::new_checked(&data).unwrap();
    let repr =
        SixlowpanIphcRepr::parse(&packet, Some(ll_src_address), Some(ll_dst_address), &[]).unwrap();

    let icmp_repr = match repr.next_header {
        SixlowpanNextHeader::Uncompressed(IpProtocol::Icmpv6) => {
            let icmp_packet = Icmpv6Packet::new_checked(packet.payload()).unwrap();
            match Icmpv6Repr::parse(
                &repr.src_addr,
                &repr.dst_addr,
                &icmp_packet,
                &ChecksumCapabilities::ignored(),
            ) {
                Ok(icmp @ Icmpv6Repr::Rpl(RplRepr::DodagInformationSolicitation { .. })) => icmp,
                _ => unreachable!(),
            }
        }
        _ => unreachable!(),
    };

    // We also try to emit the packet:
    let mut buffer = vec![0u8; repr.buffer_len() + icmp_repr.buffer_len()];
    repr.emit(&mut SixlowpanIphcPacket::new_unchecked(
        &mut buffer[..repr.buffer_len()],
    ));
    icmp_repr.emit(
        &repr.src_addr.into(),
        &repr.dst_addr.into(),
        &mut Icmpv6Packet::new_unchecked(
            &mut buffer[repr.buffer_len()..][..icmp_repr.buffer_len()],
        ),
        &ChecksumCapabilities::ignored(),
    );

    assert_eq!(&data[..], &buffer[..]);
}

/// Parsing of DIO packets.
#[test]
fn dio_packet() {
    let data = [
        0x9b, 0x01, 0x00, 0x00, 0x00, 0xf0, 0x00, 0x80, 0x08, 0xf0, 0x00, 0x00, 0xfd, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x04, 0x0e,
        0x00, 0x08, 0x0c, 0x00, 0x04, 0x00, 0x00, 0x80, 0x00, 0x01, 0x00, 0x1e, 0x00, 0x3c, 0x08,
        0x1e, 0x40, 0x40, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    ];

    let addr = Address::from_octets([
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x01,
    ]);

    let dest_prefix = [
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    ];

    let packet = Packet::new_checked(&data[..]).unwrap();
    assert_eq!(packet.msg_type(), Message::RplControl);
    assert_eq!(
        RplControlMessage::from(packet.msg_code()),
        RplControlMessage::DodagInformationObject
    );

    let mut dio_repr = RplRepr::parse(&packet).unwrap();
    match dio_repr {
        RplRepr::DodagInformationObject {
            rpl_instance_id,
            version_number,
            rank,
            grounded,
            mode_of_operation,
            dodag_preference,
            dtsn,
            dodag_id,
            ..
        } => {
            assert_eq!(rpl_instance_id, InstanceId::from(0));
            assert_eq!(version_number, 240);
            assert_eq!(rank, 128);
            assert!(!grounded);
            assert_eq!(mode_of_operation, ModeOfOperation::NonStoringMode);
            assert_eq!(dodag_preference, 0);
            assert_eq!(dtsn, 240);
            assert_eq!(dodag_id, addr);
        }
        _ => unreachable!(),
    }

    let option = OptionPacket::new_unchecked(packet.options().unwrap());
    let dodag_conf_option = OptionRepr::parse(&option).unwrap();
    match dodag_conf_option {
        OptionRepr::DodagConfiguration {
            authentication_enabled,
            path_control_size,
            dio_interval_doublings,
            dio_interval_min,
            dio_redundancy_constant,
            max_rank_increase,
            minimum_hop_rank_increase,
            objective_code_point,
            default_lifetime,
            lifetime_unit,
        } => {
            assert!(!authentication_enabled);
            assert_eq!(path_control_size, 0);
            assert_eq!(dio_interval_doublings, 8);
            assert_eq!(dio_interval_min, 12);
            assert_eq!(dio_redundancy_constant, 0);
            assert_eq!(max_rank_increase, 1024);
            assert_eq!(minimum_hop_rank_increase, 128);
            assert_eq!(objective_code_point, 1);
            assert_eq!(default_lifetime, 30);
            assert_eq!(lifetime_unit, 60);
        }
        _ => unreachable!(),
    }

    let option = OptionPacket::new_unchecked(option.next_option().unwrap());
    let prefix_info_option = OptionRepr::parse(&option).unwrap();
    match prefix_info_option {
        OptionRepr::PrefixInformation {
            prefix_length,
            on_link,
            autonomous_address_configuration,
            valid_lifetime,
            preferred_lifetime,
            destination_prefix,
            ..
        } => {
            assert_eq!(prefix_length, 64);
            assert!(!on_link);
            assert!(autonomous_address_configuration);
            assert_eq!(valid_lifetime, u32::MAX);
            assert_eq!(preferred_lifetime, u32::MAX);
            assert_eq!(destination_prefix, &dest_prefix[..]);
        }
        _ => unreachable!(),
    }

    let mut options_buffer =
        vec![0u8; dodag_conf_option.buffer_len() + prefix_info_option.buffer_len()];

    dodag_conf_option.emit(&mut OptionPacket::new_unchecked(
        &mut options_buffer[..dodag_conf_option.buffer_len()],
    ));
    prefix_info_option.emit(&mut OptionPacket::new_unchecked(
        &mut options_buffer[dodag_conf_option.buffer_len()..][..prefix_info_option.buffer_len()],
    ));

    dio_repr.set_options(&options_buffer[..]);

    let mut buffer = vec![0u8; dio_repr.buffer_len()];
    dio_repr.emit(&mut Packet::new_unchecked(&mut buffer[..]));

    assert_eq!(&data[..], &buffer[..]);
}

/// Parsing of DAO packets.
#[test]
fn dao_packet() {
    let data = [
        0x9b, 0x02, 0x00, 0x00, 0x00, 0x80, 0x00, 0xf1, 0x05, 0x12, 0x00, 0x80, 0xfd, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x02, 0x06, 0x14,
        0x00, 0x00, 0x00, 0x1e, 0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x01,
    ];

    let target_prefix = [
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00,
        0x02,
    ];

    let parent_addr = Address::from_octets([
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x01,
    ]);

    let packet = Packet::new_checked(&data[..]).unwrap();
    let mut dao_repr = RplRepr::parse(&packet).unwrap();
    match dao_repr {
        RplRepr::DestinationAdvertisementObject {
            rpl_instance_id,
            expect_ack,
            sequence,
            dodag_id,
            ..
        } => {
            assert_eq!(rpl_instance_id, InstanceId::from(0));
            assert!(expect_ack);
            assert_eq!(sequence, 241);
            assert_eq!(dodag_id, None);
        }
        _ => unreachable!(),
    }

    let option = OptionPacket::new_unchecked(packet.options().unwrap());

    let rpl_target_option = OptionRepr::parse(&option).unwrap();
    match rpl_target_option {
        OptionRepr::RplTarget {
            prefix_length,
            prefix,
        } => {
            assert_eq!(prefix_length, 128);
            assert_eq!(prefix.octets(), target_prefix);
        }
        _ => unreachable!(),
    }

    let option = OptionPacket::new_unchecked(option.next_option().unwrap());
    let transit_info_option = OptionRepr::parse(&option).unwrap();
    match transit_info_option {
        OptionRepr::TransitInformation {
            external,
            path_control,
            path_sequence,
            path_lifetime,
            parent_address,
        } => {
            assert!(!external);
            assert_eq!(path_control, 0);
            assert_eq!(path_sequence, 0);
            assert_eq!(path_lifetime, 30);
            assert_eq!(parent_address, Some(parent_addr));
        }
        _ => unreachable!(),
    }

    let mut options_buffer =
        vec![0u8; rpl_target_option.buffer_len() + transit_info_option.buffer_len()];

    rpl_target_option.emit(&mut OptionPacket::new_unchecked(
        &mut options_buffer[..rpl_target_option.buffer_len()],
    ));
    transit_info_option.emit(&mut OptionPacket::new_unchecked(
        &mut options_buffer[rpl_target_option.buffer_len()..][..transit_info_option.buffer_len()],
    ));

    dao_repr.set_options(&options_buffer[..]);

    let mut buffer = vec![0u8; dao_repr.buffer_len()];
    dao_repr.emit(&mut Packet::new_unchecked(&mut buffer[..]));

    assert_eq!(&data[..], &buffer[..]);
}

/// Parsing of DAO-ACK packets.
#[test]
fn dao_ack_packet() {
    let data = [0x9b, 0x03, 0x00, 0x00, 0x00, 0x00, 0xf1, 0x00];

    let packet = Packet::new_checked(&data[..]).unwrap();
    let dao_ack_repr = RplRepr::parse(&packet).unwrap();
    match dao_ack_repr {
        RplRepr::DestinationAdvertisementObjectAck {
            rpl_instance_id,
            sequence,
            status,
            dodag_id,
            ..
        } => {
            assert_eq!(rpl_instance_id, InstanceId::from(0));
            assert_eq!(sequence, 241);
            assert_eq!(status, 0);
            assert_eq!(dodag_id, None);
        }
        _ => unreachable!(),
    }

    let mut buffer = vec![0u8; dao_ack_repr.buffer_len()];
    dao_ack_repr.emit(&mut Packet::new_unchecked(&mut buffer[..]));

    assert_eq!(&data[..], &buffer[..]);

    let data = [
        0x9b, 0x03, 0x0, 0x0, 0x1e, 0x80, 0xf0, 0x00, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ];

    let packet = Packet::new_checked(&data[..]).unwrap();
    let dao_ack_repr = RplRepr::parse(&packet).unwrap();
    match dao_ack_repr {
        RplRepr::DestinationAdvertisementObjectAck {
            rpl_instance_id,
            sequence,
            status,
            dodag_id,
            ..
        } => {
            assert_eq!(rpl_instance_id, InstanceId::from(30));
            assert_eq!(sequence, 240);
            assert_eq!(status, 0x0);
            assert_eq!(
                dodag_id,
                Some(Ipv6Address::new(0xfe80, 0, 0, 0, 0x0200, 0, 0, 1))
            );
        }
        _ => unreachable!(),
    }

    let mut buffer = vec![0u8; dao_ack_repr.buffer_len()];
    dao_ack_repr.emit(&mut Packet::new_unchecked(&mut buffer[..]));

    assert_eq!(&data[..], &buffer[..]);
}
