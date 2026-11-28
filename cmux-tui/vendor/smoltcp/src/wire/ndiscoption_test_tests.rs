use super::Error;
use super::{NdiscOption, PrefixInfoFlags, PrefixInformation, Repr, Type};
use crate::time::Duration;
use crate::wire::Ipv6Address;

#[cfg(feature = "medium-ethernet")]
use crate::wire::EthernetAddress;
#[cfg(all(not(feature = "medium-ethernet"), feature = "medium-ieee802154"))]
use crate::wire::Ieee802154Address;

static PREFIX_OPT_BYTES: [u8; 32] = [
    0x03, 0x04, 0x40, 0xc0, 0x00, 0x00, 0x03, 0x84, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
];

#[test]
fn test_deconstruct() {
    let opt = NdiscOption::new_unchecked(&PREFIX_OPT_BYTES[..]);
    assert_eq!(opt.option_type(), Type::PrefixInformation);
    assert_eq!(opt.data_len(), 4);
    assert_eq!(opt.prefix_len(), 64);
    assert_eq!(
        opt.prefix_flags(),
        PrefixInfoFlags::ON_LINK | PrefixInfoFlags::ADDRCONF
    );
    assert_eq!(opt.valid_lifetime(), Duration::from_secs(900));
    assert_eq!(opt.preferred_lifetime(), Duration::from_secs(1000));
    assert_eq!(opt.prefix(), Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1));
}

#[test]
fn test_construct() {
    let mut bytes = [0x00; 32];
    let mut opt = NdiscOption::new_unchecked(&mut bytes[..]);
    opt.set_option_type(Type::PrefixInformation);
    opt.set_data_len(4);
    opt.set_prefix_len(64);
    opt.set_prefix_flags(PrefixInfoFlags::ON_LINK | PrefixInfoFlags::ADDRCONF);
    opt.set_valid_lifetime(Duration::from_secs(900));
    opt.set_preferred_lifetime(Duration::from_secs(1000));
    opt.set_prefix(Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1));
    assert_eq!(&PREFIX_OPT_BYTES[..], &*opt.into_inner());
}

#[test]
fn test_short_packet() {
    assert_eq!(NdiscOption::new_checked(&[0x00, 0x00]), Err(Error));
    let bytes = [0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    assert_eq!(NdiscOption::new_checked(&bytes), Err(Error));
}

#[cfg(feature = "medium-ethernet")]
#[test]
fn test_repr_parse_link_layer_opt_ethernet() {
    let mut bytes = [0x01, 0x01, 0x54, 0x52, 0x00, 0x12, 0x23, 0x34];
    let addr = EthernetAddress([0x54, 0x52, 0x00, 0x12, 0x23, 0x34]);
    {
        assert_eq!(
            Repr::parse(&NdiscOption::new_unchecked(&bytes)),
            Ok(Repr::SourceLinkLayerAddr(addr.into()))
        );
    }
    bytes[0] = 0x02;
    {
        assert_eq!(
            Repr::parse(&NdiscOption::new_unchecked(&bytes)),
            Ok(Repr::TargetLinkLayerAddr(addr.into()))
        );
    }
}

#[cfg(all(not(feature = "medium-ethernet"), feature = "medium-ieee802154"))]
#[test]
fn test_repr_parse_link_layer_opt_ieee802154() {
    let mut bytes = [
        0x01, 0x02, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    ];
    let addr = Ieee802154Address::Extended([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
    {
        assert_eq!(
            Repr::parse(&NdiscOption::new_unchecked(&bytes)),
            Ok(Repr::SourceLinkLayerAddr(addr.into()))
        );
    }
    bytes[0] = 0x02;
    {
        assert_eq!(
            Repr::parse(&NdiscOption::new_unchecked(&bytes)),
            Ok(Repr::TargetLinkLayerAddr(addr.into()))
        );
    }
}

#[test]
fn test_repr_parse_prefix_info() {
    let repr = Repr::PrefixInformation(PrefixInformation {
        prefix_len: 64,
        flags: PrefixInfoFlags::ON_LINK | PrefixInfoFlags::ADDRCONF,
        valid_lifetime: Duration::from_secs(900),
        preferred_lifetime: Duration::from_secs(1000),
        prefix: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
    });
    assert_eq!(
        Repr::parse(&NdiscOption::new_unchecked(&PREFIX_OPT_BYTES)),
        Ok(repr)
    );
}

#[test]
fn test_repr_emit_prefix_info() {
    let mut bytes = [0x2a; 32];
    let repr = Repr::PrefixInformation(PrefixInformation {
        prefix_len: 64,
        flags: PrefixInfoFlags::ON_LINK | PrefixInfoFlags::ADDRCONF,
        valid_lifetime: Duration::from_secs(900),
        preferred_lifetime: Duration::from_secs(1000),
        prefix: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
    });
    let mut opt = NdiscOption::new_unchecked(&mut bytes);
    repr.emit(&mut opt);
    assert_eq!(&opt.into_inner()[..], &PREFIX_OPT_BYTES[..]);
}

#[test]
fn test_repr_parse_mtu() {
    let bytes = [0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x05, 0xdc];
    assert_eq!(
        Repr::parse(&NdiscOption::new_unchecked(&bytes)),
        Ok(Repr::Mtu(1500))
    );
}
