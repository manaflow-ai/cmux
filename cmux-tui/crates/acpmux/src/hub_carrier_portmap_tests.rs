use super::*;

/// A PCP server on loopback that grants `external` to every TCP MAP.
async fn pcp_server(external: SocketAddr) -> SocketAddr {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let at = socket.local_addr().unwrap();
    tokio::spawn(async move {
        let mut buf = [0u8; 1100];
        while let Ok((len, from)) = socket.recv_from(&mut buf).await {
            let request = &buf[..len];
            if len != 60 || request[1] != PCP_MAP || request[36] != TCP {
                continue;
            }
            let mut answer = request.to_vec();
            answer[1] = 0x80 | PCP_MAP;
            answer[3] = 0;
            let IpAddr::V4(ip) = external.ip() else { unreachable!() };
            answer[42..44].copy_from_slice(&external.port().to_be_bytes());
            answer[44..60].copy_from_slice(&ip.to_ipv6_mapped().octets());
            let _ = socket.send_to(&answer, from).await;
        }
    });
    at
}

#[tokio::test]
async fn a_pcp_gateway_maps_the_punch_port_for_tcp() {
    let external: SocketAddr = "203.0.113.7:41000".parse().unwrap();
    let gateway = pcp_server(external).await;
    let (mapped, lifetime) = map(gateway, Ipv4Addr::LOCALHOST, 40123).await.unwrap();
    assert_eq!(mapped, external);
    assert_eq!(lifetime, LIFETIME_S);
    assert!(public(mapped.ip()));
}

#[tokio::test]
async fn a_gateway_that_never_answers_maps_nothing_in_bounded_time() {
    let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let started = std::time::Instant::now();
    assert!(map(silent.local_addr().unwrap(), Ipv4Addr::LOCALHOST, 40123).await.is_none());
    // PCP's tries and NAT-PMP's: four waits.
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn the_encoders_ask_for_tcp() {
    let request = pcp_request(Ipv4Addr::new(192, 168, 1, 5), [7; 12], 40123, 60);
    assert_eq!(request.len(), 60);
    assert_eq!(request[36], 6);
    assert_eq!(u16::from_be_bytes([request[40], request[41]]), 40123);
    let request = natpmp_request(40123, 40123, 60);
    assert_eq!(request[1], 2);
    let mut answer = [0u8; 16];
    answer[1] = 130;
    answer[8..10].copy_from_slice(&40123u16.to_be_bytes());
    answer[10..12].copy_from_slice(&41000u16.to_be_bytes());
    answer[12..16].copy_from_slice(&60u32.to_be_bytes());
    assert_eq!(natpmp_map_answer(&answer, 40123), Some((41000, 60)));
    answer[1] = 129; // a UDP answer is not this mapping's
    assert_eq!(natpmp_map_answer(&answer, 40123), None);
}

/// Every parser reads a short or empty packet (or route dump) as nothing, never a panic:
/// the gateway, or anything answering from its address, chooses the bytes.
#[test]
fn short_answers_read_as_nothing() {
    let mut pcp = pcp_request(Ipv4Addr::new(192, 168, 1, 5), [7; 12], 40123, 60);
    pcp[1] = 0x80 | PCP_MAP;
    assert!(pcp_answer(&pcp, &[7; 12], 40123).is_some());
    let mut natpmp = [0u8; 16];
    natpmp[1] = 130;
    natpmp[8..10].copy_from_slice(&40123u16.to_be_bytes());
    let mut address = [0u8; 12];
    address[1] = 128;
    address[8..12].copy_from_slice(&[203, 0, 113, 7]);
    assert_eq!(natpmp_address_answer(&address), Some(Ipv4Addr::new(203, 0, 113, 7)));
    let mut error = [0u8; 4];
    error[1] = 0x80 | PCP_MAP;
    error[3] = 1;
    assert!(refused(&pcp_request(Ipv4Addr::LOCALHOST, [0; 12], 1, 1), &error));
    for len in 0..pcp.len() {
        assert_eq!(pcp_answer(&pcp[..len], &[7; 12], 40123), None, "pcp at {len}");
    }
    for len in 0..natpmp.len() {
        assert_eq!(natpmp_map_answer(&natpmp[..len], 40123), None, "nat-pmp at {len}");
    }
    for len in 0..address.len() {
        assert_eq!(natpmp_address_answer(&address[..len]), None, "address at {len}");
    }
    for len in 0..error.len() {
        assert!(!refused(&[0, PCP_MAP], &error[..len]), "refusal at {len}");
    }
    assert!(!refused(&[], &error));
    for header in [0, 4, 16, 92] {
        assert_eq!(rt_dump_gateway(&[], header), None);
        assert_eq!(rt_dump_gateway(&[200, 0, 0, 0], header), None);
    }
}
