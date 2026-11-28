use super::*;
#[cfg(all(feature = "proto-ipv4", not(feature = "proto-ipv6")))]
use crate::wire::ipv4::test::{MOCK_IP_ADDR_1, MOCK_IP_ADDR_2, MOCK_IP_ADDR_3, MOCK_IP_ADDR_4};
#[cfg(feature = "proto-ipv6")]
use crate::wire::ipv6::test::{MOCK_IP_ADDR_1, MOCK_IP_ADDR_2, MOCK_IP_ADDR_3, MOCK_IP_ADDR_4};

use crate::wire::EthernetAddress;

const HADDR_A: HardwareAddress = HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 1]));
const HADDR_B: HardwareAddress = HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 2]));
const HADDR_C: HardwareAddress = HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 3]));
const HADDR_D: HardwareAddress = HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 4]));

#[test]
fn test_fill() {
    let mut cache = Cache::new();

    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0))
            .found()
    );
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(0))
            .found()
    );

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::Found(HADDR_A)
    );
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(0))
            .found()
    );
    assert!(
        !cache
            .lookup(
                &MOCK_IP_ADDR_1.into(),
                Instant::from_millis(0) + Cache::ENTRY_LIFETIME * 2
            )
            .found(),
    );

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(0));
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(0))
            .found()
    );
}

#[test]
fn test_expire() {
    let mut cache = Cache::new();

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::Found(HADDR_A)
    );
    assert!(
        !cache
            .lookup(
                &MOCK_IP_ADDR_1.into(),
                Instant::from_millis(0) + Cache::ENTRY_LIFETIME * 2
            )
            .found(),
    );
}

#[test]
fn test_replace() {
    let mut cache = Cache::new();

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::Found(HADDR_A)
    );
    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_B, Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::Found(HADDR_B)
    );
}

#[test]
fn test_evict() {
    let mut cache = Cache::new();

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(100));
    cache.fill(MOCK_IP_ADDR_2.into(), HADDR_B, Instant::from_millis(50));
    cache.fill(MOCK_IP_ADDR_3.into(), HADDR_C, Instant::from_millis(200));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(1000)),
        Answer::Found(HADDR_B)
    );
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_4.into(), Instant::from_millis(1000))
            .found()
    );

    cache.fill(MOCK_IP_ADDR_4.into(), HADDR_D, Instant::from_millis(300));
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(1000))
            .found()
    );
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_4.into(), Instant::from_millis(1000)),
        Answer::Found(HADDR_D)
    );
}

#[test]
fn test_hush() {
    let mut cache = Cache::new();

    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::NotFound
    );

    cache.limit_rate(Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(100)),
        Answer::RateLimited
    );
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(2000)),
        Answer::NotFound
    );
}

#[test]
fn test_flush() {
    let mut cache = Cache::new();

    cache.fill(MOCK_IP_ADDR_1.into(), HADDR_A, Instant::from_millis(0));
    assert_eq!(
        cache.lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0)),
        Answer::Found(HADDR_A)
    );
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_2.into(), Instant::from_millis(0))
            .found()
    );

    cache.flush();
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0))
            .found()
    );
    assert!(
        !cache
            .lookup(&MOCK_IP_ADDR_1.into(), Instant::from_millis(0))
            .found()
    );
}
