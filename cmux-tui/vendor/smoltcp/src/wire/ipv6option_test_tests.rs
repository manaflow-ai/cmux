use super::*;

static IPV6OPTION_BYTES_PAD1: [u8; 1] = [0x0];
static IPV6OPTION_BYTES_PADN: [u8; 3] = [0x1, 0x1, 0x0];
static IPV6OPTION_BYTES_UNKNOWN: [u8; 5] = [0xff, 0x3, 0x0, 0x0, 0x0];
static IPV6OPTION_BYTES_ROUTER_ALERT_MLD: [u8; 4] = [0x05, 0x02, 0x00, 0x00];
static IPV6OPTION_BYTES_ROUTER_ALERT_RSVP: [u8; 4] = [0x05, 0x02, 0x00, 0x01];
static IPV6OPTION_BYTES_ROUTER_ALERT_ACTIVE_NETWORKS: [u8; 4] = [0x05, 0x02, 0x00, 0x02];
static IPV6OPTION_BYTES_ROUTER_ALERT_UNKNOWN: [u8; 4] = [0x05, 0x02, 0xbe, 0xef];
#[cfg(feature = "proto-rpl")]
static IPV6OPTION_BYTES_RPL: [u8; 6] = [0x63, 0x04, 0x00, 0x1e, 0x08, 0x00];

#[test]
fn test_check_len() {
    let bytes = [0u8];
    // zero byte buffer
    assert_eq!(
        Err(Error),
        Ipv6Option::new_unchecked(&bytes[..0]).check_len()
    );
    // pad1
    assert_eq!(
        Ok(()),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1).check_len()
    );

    // padn with truncated data
    assert_eq!(
        Err(Error),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN[..2]).check_len()
    );
    // padn
    assert_eq!(
        Ok(()),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN).check_len()
    );

    // router alert with truncated data
    assert_eq!(
        Err(Error),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD[..3]).check_len()
    );
    // router alert
    assert_eq!(
        Ok(()),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD).check_len()
    );

    // unknown option type with truncated data
    assert_eq!(
        Err(Error),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN[..4]).check_len()
    );
    assert_eq!(
        Err(Error),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN[..1]).check_len()
    );
    // unknown type
    assert_eq!(
        Ok(()),
        Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN).check_len()
    );

    #[cfg(feature = "proto-rpl")]
    {
        assert_eq!(
            Ok(()),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL).check_len()
        );
    }
}

#[test]
#[should_panic(expected = "index out of bounds")]
fn test_data_len() {
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
    opt.data_len();
}

#[test]
fn test_option_deconstruct() {
    // one octet of padding
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
    assert_eq!(opt.option_type(), Type::Pad1);

    // two octets of padding
    let bytes: [u8; 2] = [0x1, 0x0];
    let opt = Ipv6Option::new_unchecked(&bytes);
    assert_eq!(opt.option_type(), Type::PadN);
    assert_eq!(opt.data_len(), 0);

    // three octets of padding
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN);
    assert_eq!(opt.option_type(), Type::PadN);
    assert_eq!(opt.data_len(), 1);
    assert_eq!(opt.data(), &[0]);

    // extra bytes in buffer
    let bytes: [u8; 10] = [0x1, 0x7, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0xff];
    let opt = Ipv6Option::new_unchecked(&bytes);
    assert_eq!(opt.option_type(), Type::PadN);
    assert_eq!(opt.data_len(), 7);
    assert_eq!(opt.data(), &[0, 0, 0, 0, 0, 0, 0]);

    // router alert
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD);
    assert_eq!(opt.option_type(), Type::RouterAlert);
    assert_eq!(opt.data_len(), 2);
    assert_eq!(opt.data(), &[0, 0]);

    // unrecognized option
    let bytes: [u8; 1] = [0xff];
    let opt = Ipv6Option::new_unchecked(&bytes);
    assert_eq!(opt.option_type(), Type::Unknown(255));

    // unrecognized option without length and data
    assert_eq!(Ipv6Option::new_checked(&bytes), Err(Error));

    #[cfg(feature = "proto-rpl")]
    {
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
        assert_eq!(opt.option_type(), Type::Rpl);
        assert_eq!(opt.data_len(), 4);
        assert_eq!(opt.data(), &[0x00, 0x1e, 0x08, 0x00]);
    }
}

#[test]
fn test_option_parse() {
    // one octet of padding
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
    let pad1 = Repr::parse(&opt).unwrap();
    assert_eq!(pad1, Repr::Pad1);
    assert_eq!(pad1.buffer_len(), 1);

    // two or more octets of padding
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN);
    let padn = Repr::parse(&opt).unwrap();
    assert_eq!(padn, Repr::PadN(1));
    assert_eq!(padn.buffer_len(), 3);

    // router alert (MLD)
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD);
    let alert = Repr::parse(&opt).unwrap();
    assert_eq!(
        alert,
        Repr::RouterAlert(RouterAlert::MulticastListenerDiscovery)
    );
    assert_eq!(alert.buffer_len(), 4);

    // router alert (RSVP)
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_RSVP);
    let alert = Repr::parse(&opt).unwrap();
    assert_eq!(alert, Repr::RouterAlert(RouterAlert::Rsvp));
    assert_eq!(alert.buffer_len(), 4);

    // router alert (active networks)
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_ACTIVE_NETWORKS);
    let alert = Repr::parse(&opt).unwrap();
    assert_eq!(alert, Repr::RouterAlert(RouterAlert::ActiveNetworks));
    assert_eq!(alert.buffer_len(), 4);

    // router alert (unknown)
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_UNKNOWN);
    let alert = Repr::parse(&opt).unwrap();
    assert_eq!(alert, Repr::RouterAlert(RouterAlert::Unknown(0xbeef)));
    assert_eq!(alert.buffer_len(), 4);

    // router alert (incorrect data length)
    let opt = Ipv6Option::new_unchecked(&[0x05, 0x03, 0x00, 0x00, 0x00]);
    let alert = Repr::parse(&opt);
    assert_eq!(alert, Err(Error));

    // unrecognized option type
    let data = [0u8; 3];
    let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN);
    let unknown = Repr::parse(&opt).unwrap();
    assert_eq!(
        unknown,
        Repr::Unknown {
            type_: Type::Unknown(255),
            length: 3,
            data: &data
        }
    );

    #[cfg(feature = "proto-rpl")]
    {
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
        let rpl = Repr::parse(&opt).unwrap();

        assert_eq!(
            rpl,
            Repr::Rpl(crate::wire::RplHopByHopRepr {
                down: false,
                rank_error: false,
                forwarding_error: false,
                instance_id: crate::wire::RplInstanceId::from(0x1e),
                sender_rank: 0x0800,
            })
        );
    }
}

#[test]
fn test_option_emit() {
    let repr = Repr::Pad1;
    let mut bytes = [255u8; 1]; // don't assume bytes are initialized to zero
    let mut opt = Ipv6Option::new_unchecked(&mut bytes);
    repr.emit(&mut opt);
    assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_PAD1);

    let repr = Repr::PadN(1);
    let mut bytes = [255u8; 3]; // don't assume bytes are initialized to zero
    let mut opt = Ipv6Option::new_unchecked(&mut bytes);
    repr.emit(&mut opt);
    assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_PADN);

    let repr = Repr::RouterAlert(RouterAlert::MulticastListenerDiscovery);
    let mut bytes = [255u8; 4]; // don't assume bytes are initialized to zero
    let mut opt = Ipv6Option::new_unchecked(&mut bytes);
    repr.emit(&mut opt);
    assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_ROUTER_ALERT_MLD);

    let data = [0u8; 3];
    let repr = Repr::Unknown {
        type_: Type::Unknown(255),
        length: 3,
        data: &data,
    };
    let mut bytes = [254u8; 5]; // don't assume bytes are initialized to zero
    let mut opt = Ipv6Option::new_unchecked(&mut bytes);
    repr.emit(&mut opt);
    assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_UNKNOWN);

    #[cfg(feature = "proto-rpl")]
    {
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
        let rpl = Repr::parse(&opt).unwrap();
        let mut bytes = [0u8; 6];
        rpl.emit(&mut Ipv6Option::new_unchecked(&mut bytes));

        assert_eq!(&bytes, &IPV6OPTION_BYTES_RPL);
    }
}

#[test]
fn test_failure_type() {
    let mut failure_type: FailureType = Type::Pad1.into();
    assert_eq!(failure_type, FailureType::Skip);
    failure_type = Type::PadN.into();
    assert_eq!(failure_type, FailureType::Skip);
    failure_type = Type::RouterAlert.into();
    assert_eq!(failure_type, FailureType::Skip);
    failure_type = Type::Unknown(0b01000001).into();
    assert_eq!(failure_type, FailureType::Discard);
    failure_type = Type::Unknown(0b10100000).into();
    assert_eq!(failure_type, FailureType::DiscardSendAll);
    failure_type = Type::Unknown(0b11000100).into();
    assert_eq!(failure_type, FailureType::DiscardSendUnicast);
}

#[test]
fn test_options_iter() {
    let options = [
        0x00, 0x01, 0x01, 0x00, 0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x11, 0x00, 0x05, 0x02,
        0x00, 0x01, 0x01, 0x08, 0x00,
    ];

    let iterator = Ipv6OptionsIterator::new(&options);
    for (i, opt) in iterator.enumerate() {
        match (i, opt) {
            (0, Ok(Repr::Pad1)) => continue,
            (1, Ok(Repr::PadN(1))) => continue,
            (2, Ok(Repr::PadN(2))) => continue,
            (3, Ok(Repr::PadN(0))) => continue,
            (4, Ok(Repr::Pad1)) => continue,
            (
                5,
                Ok(Repr::Unknown {
                    type_: Type::Unknown(0x11),
                    length: 0,
                    ..
                }),
            ) => continue,
            (6, Ok(Repr::RouterAlert(RouterAlert::Rsvp))) => continue,
            (7, Err(Error)) => continue,
            (i, res) => panic!("Unexpected option `{res:?}` at index {i}"),
        }
    }
}
