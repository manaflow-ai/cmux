use super::*;

#[test]
fn iphc_fields() {
    let bytes = [
        0x7a, 0x33, // IPHC
        0x3a, // Next header
    ];

    let packet = Packet::new_unchecked(bytes);

    assert_eq!(packet.dispatch_field(), 0b011);
    assert_eq!(packet.tf_field(), 0b11);
    assert_eq!(packet.nh_field(), 0b0);
    assert_eq!(packet.hlim_field(), 0b10);
    assert_eq!(packet.cid_field(), 0b0);
    assert_eq!(packet.sac_field(), 0b0);
    assert_eq!(packet.sam_field(), 0b11);
    assert_eq!(packet.m_field(), 0b0);
    assert_eq!(packet.dac_field(), 0b0);
    assert_eq!(packet.dam_field(), 0b11);

    assert_eq!(
        packet.next_header(),
        NextHeader::Uncompressed(IpProtocol::Icmpv6)
    );

    assert_eq!(packet.src_address_size(), 0);
    assert_eq!(packet.dst_address_size(), 0);
    assert_eq!(packet.hop_limit(), 64);

    assert_eq!(
        packet.src_addr(),
        Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided))
    );
    assert_eq!(
        packet.dst_addr(),
        Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided))
    );

    let bytes = [
        0x7e, 0xf7, // IPHC,
        0x00, // CID
    ];

    let packet = Packet::new_unchecked(bytes);

    assert_eq!(packet.dispatch_field(), 0b011);
    assert_eq!(packet.tf_field(), 0b11);
    assert_eq!(packet.nh_field(), 0b1);
    assert_eq!(packet.hlim_field(), 0b10);
    assert_eq!(packet.cid_field(), 0b1);
    assert_eq!(packet.sac_field(), 0b1);
    assert_eq!(packet.sam_field(), 0b11);
    assert_eq!(packet.m_field(), 0b0);
    assert_eq!(packet.dac_field(), 0b1);
    assert_eq!(packet.dam_field(), 0b11);

    assert_eq!(packet.next_header(), NextHeader::Compressed);

    assert_eq!(packet.src_address_size(), 0);
    assert_eq!(packet.dst_address_size(), 0);
    assert_eq!(packet.hop_limit(), 64);

    assert_eq!(
        packet.src_addr(),
        Ok(UnresolvedAddress::WithContext((
            0,
            AddressMode::FullyElided
        )))
    );
    assert_eq!(
        packet.dst_addr(),
        Ok(UnresolvedAddress::WithContext((
            0,
            AddressMode::FullyElided
        )))
    );
}
