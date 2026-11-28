use super::*;
use rstest::rstest;

#[rstest]
#[cfg(feature = "medium-ethernet")]
#[case((Medium::Ethernet, &[0u8; 6][..]), Ok(HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 0]))))]
#[cfg(feature = "medium-ethernet")]
#[case((Medium::Ethernet, &[1u8; 5][..]), Err(Error))]
#[cfg(feature = "medium-ethernet")]
#[case((Medium::Ethernet, &[1u8; 7][..]), Err(Error))]
#[cfg(feature = "medium-ieee802154")]
#[case((Medium::Ieee802154, &[0u8; 8][..]), Ok(HardwareAddress::Ieee802154(Ieee802154Address::Extended([0, 0, 0, 0, 0, 0, 0, 0]))))]
#[cfg(feature = "medium-ieee802154")]
#[case((Medium::Ieee802154, &[1u8; 2][..]), Err(Error))]
#[cfg(feature = "medium-ieee802154")]
#[case((Medium::Ieee802154, &[1u8; 1][..]), Err(Error))]
fn parse_hardware_address(
    #[case] input: (Medium, &[u8]),
    #[case] expected: Result<HardwareAddress>,
) {
    let (medium, input) = input;

    // NOTE: we check the length since `RawHardwareAddress::parse()` panics if the length is
    // invalid. MAX_HARDWARE_ADDRESS_LEN is based on the medium, and depending on the feature
    // flags, it can be different.
    if input.len() < MAX_HARDWARE_ADDRESS_LEN {
        let raw = RawHardwareAddress::from_bytes(input);
        assert_eq!(raw.parse(medium), expected);
    }
}
