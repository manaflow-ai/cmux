use std::collections::VecDeque;

use crate::iface::*;
use crate::phy::{self, Device, DeviceCapabilities, Medium};
use crate::time::Instant;
use crate::wire::*;

pub(crate) fn setup<'a>(medium: Medium) -> (Interface, SocketSet<'a>, TestingDevice) {
    let mut device = TestingDevice::new(medium);
    let iface = setup_with_device(medium, &mut device);
    (iface, SocketSet::new(vec![]), device)
}

fn setup_with_device(medium: Medium, device: &mut impl Device) -> Interface {
    let config = Config::new(match medium {
        #[cfg(feature = "medium-ethernet")]
        Medium::Ethernet => {
            HardwareAddress::Ethernet(EthernetAddress([0x02, 0x02, 0x02, 0x02, 0x02, 0x02]))
        }
        #[cfg(feature = "medium-ip")]
        Medium::Ip => HardwareAddress::Ip,
        #[cfg(feature = "medium-ieee802154")]
        Medium::Ieee802154 => HardwareAddress::Ieee802154(Ieee802154Address::Extended([
            0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        ])),
    });

    let mut iface = Interface::new(config, device, Instant::ZERO);

    #[cfg(feature = "proto-ipv4")]
    {
        iface.update_ip_addrs(|ip_addrs| {
            ip_addrs
                .push(IpCidr::new(IpAddress::v4(192, 168, 1, 1), 24))
                .unwrap();
            ip_addrs
                .push(IpCidr::new(IpAddress::v4(127, 0, 0, 1), 8))
                .unwrap();
        });
    }

    #[cfg(feature = "proto-ipv6")]
    {
        iface.update_ip_addrs(|ip_addrs| {
            ip_addrs
                .push(IpCidr::new(IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1), 64))
                .unwrap();
            ip_addrs
                .push(IpCidr::new(IpAddress::v6(0, 0, 0, 0, 0, 0, 0, 1), 128))
                .unwrap();
            ip_addrs
                .push(IpCidr::new(IpAddress::v6(0xfdbe, 0, 0, 0, 0, 0, 0, 1), 64))
                .unwrap();
        });
    }
    iface
}

/// A testing device.
#[derive(Debug)]
pub struct TestingDevice {
    pub(crate) tx_queue: VecDeque<Vec<u8>>,
    pub(crate) rx_queue: VecDeque<Vec<u8>>,
    max_transmission_unit: usize,
    medium: Medium,
}

#[allow(clippy::new_without_default)]
impl TestingDevice {
    /// Creates a testing device.
    ///
    /// Every packet transmitted through this device will be received through it
    /// in FIFO order.
    pub fn new(medium: Medium) -> Self {
        TestingDevice {
            tx_queue: VecDeque::new(),
            rx_queue: VecDeque::new(),
            max_transmission_unit: match medium {
                #[cfg(feature = "medium-ethernet")]
                Medium::Ethernet => 1514,
                #[cfg(feature = "medium-ip")]
                Medium::Ip => 1500,
                #[cfg(feature = "medium-ieee802154")]
                Medium::Ieee802154 => 1500,
            },
            medium,
        }
    }
}

impl Device for TestingDevice {
    type RxToken<'a> = RxToken;
    type TxToken<'a> = TxToken<'a>;

    fn capabilities(&self) -> DeviceCapabilities {
        DeviceCapabilities {
            medium: self.medium,
            max_transmission_unit: self.max_transmission_unit,
            ..DeviceCapabilities::default()
        }
    }

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        self.rx_queue.pop_front().map(move |buffer| {
            let rx = RxToken { buffer };
            let tx = TxToken {
                queue: &mut self.tx_queue,
            };
            (rx, tx)
        })
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(TxToken {
            queue: &mut self.tx_queue,
        })
    }
}

#[doc(hidden)]
pub struct RxToken {
    buffer: Vec<u8>,
}

impl phy::RxToken for RxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.buffer)
    }
}

#[doc(hidden)]
#[derive(Debug)]
pub struct TxToken<'a> {
    queue: &'a mut VecDeque<Vec<u8>>,
}

impl<'a> phy::TxToken for TxToken<'a> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut buffer = vec![0; len];
        let result = f(&mut buffer);
        self.queue.push_back(buffer);
        result
    }
}

#[cfg(feature = "segmentation-offload")]
pub(crate) mod segmentation_offload {
    use std::collections::VecDeque;

    use crate::iface::*;
    use crate::phy::{
        self, Checksum, ChecksumCapabilities, Device, DeviceCapabilities, Medium, PacketMeta,
        SegmentationCapabilities,
    };
    use crate::time::Instant;
    use crate::wire::*;

    use super::{RxToken, TestingDevice, setup_with_device};

    // The value is chosen to allow dispatching unsegmented packets whose sizes
    // exceed the length field in the IP header.
    pub const MAX_SEGMENTABLE_SIZE: usize =
        ETHERNET_HEADER_LEN + IPV6_HEADER_LEN + (u16::MAX as usize) + 1;

    pub fn setup_segmenting<'a>(
        medium: Medium,
    ) -> (Interface, SocketSet<'a>, SegmentationOffloadTestingDevice) {
        let mut device = SegmentationOffloadTestingDevice::new(TestingDevice::new(medium));
        let iface = setup_with_device(medium, &mut device);
        (iface, SocketSet::new(vec![]), device)
    }

    /// A segmentation offload testing device.
    #[derive(Debug)]
    pub struct SegmentationOffloadTestingDevice {
        pub(crate) testing_device: TestingDevice,
        pub(crate) checksum: ChecksumCapabilities,
        pub(crate) segmentation: SegmentationCapabilities,
    }

    impl SegmentationOffloadTestingDevice {
        pub(crate) fn new(testing_device: TestingDevice) -> Self {
            Self {
                testing_device,
                checksum: ChecksumCapabilities {
                    tcp: Checksum::Rx,
                    ..Default::default()
                },
                segmentation: SegmentationCapabilities {
                    tcpv4: Some(MAX_SEGMENTABLE_SIZE.try_into().unwrap()),
                    tcpv6: Some(MAX_SEGMENTABLE_SIZE.try_into().unwrap()),
                },
            }
        }
    }

    impl Device for SegmentationOffloadTestingDevice {
        type RxToken<'a> = RxToken;
        type TxToken<'a> = SegmentingTxToken<'a>;

        fn receive(
            &mut self,
            timestamp: Instant,
        ) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
            let (rx_token, _) = self.testing_device.receive(timestamp).unzip();
            rx_token.map(|rx_token| {
                (
                    rx_token,
                    SegmentingTxToken {
                        medium: self.testing_device.medium,
                        queue: &mut self.testing_device.tx_queue,
                        meta: PacketMeta::default(),
                    },
                )
            })
        }

        fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
            Some(SegmentingTxToken {
                medium: self.testing_device.medium,
                queue: &mut self.testing_device.tx_queue,
                meta: PacketMeta::default(),
            })
        }

        fn capabilities(&self) -> DeviceCapabilities {
            DeviceCapabilities {
                segmentation: self.segmentation.clone(),
                checksum: self.checksum.clone(),
                ..self.testing_device.capabilities()
            }
        }
    }

    #[doc(hidden)]
    #[derive(Debug)]
    pub struct SegmentingTxToken<'a> {
        pub(crate) queue: &'a mut VecDeque<Vec<u8>>,
        pub(crate) medium: Medium,
        pub(crate) meta: PacketMeta,
    }

    impl<'a> phy::TxToken for SegmentingTxToken<'a> {
        fn consume<R, F>(self, len: usize, f: F) -> R
        where
            F: FnOnce(&mut [u8]) -> R,
        {
            let mut buffer = vec![0; len];
            let result = f(&mut buffer);

            if let Some(segmentation_offload_size) = self
                .meta
                .segmentation_offload_size
                .map(|size| size.get().into())
            {
                net_debug!("Segmenting testing device will not actually fill in checksums");
                let ip_buffer = match self.medium {
                    #[cfg(feature = "medium-ethernet")]
                    Medium::Ethernet => EthernetFrame::new_checked(buffer.as_slice())
                        .unwrap()
                        .payload(),
                    #[cfg(feature = "medium-ip")]
                    Medium::Ip => buffer.as_slice(),
                    #[cfg(feature = "medium-ieee802154")]
                    Medium::Ieee802154 => todo!(),
                };
                let (next_header, transport_buffer) = match IpVersion::of_packet(ip_buffer).unwrap()
                {
                    #[cfg(feature = "proto-ipv4")]
                    IpVersion::Ipv4 => {
                        let packet = Ipv4Packet::new_checked(ip_buffer).unwrap();
                        (packet.next_header(), packet.payload())
                    }
                    #[cfg(feature = "proto-ipv6")]
                    IpVersion::Ipv6 => {
                        let packet = Ipv6Packet::new_checked(ip_buffer).unwrap();
                        (packet.next_header(), packet.payload())
                    }
                };
                assert_eq!(
                    next_header,
                    IpProtocol::Tcp,
                    "segmentation offload requested for an unsupported protocol"
                );
                let transport_payload = TcpPacket::new_checked(transport_buffer).unwrap().payload();
                let headers_size = buffer.element_offset(&transport_payload[0]).unwrap();
                self.queue
                    .extend(transport_buffer.chunks(segmentation_offload_size).map(
                        |segment_payload| {
                            let mut segment =
                                Vec::with_capacity(headers_size + segmentation_offload_size);
                            segment.extend_from_slice(&buffer[..headers_size]);
                            segment.extend_from_slice(segment_payload);
                            segment
                        },
                    ));
            } else {
                self.queue.push_back(buffer);
            }

            result
        }

        fn set_meta(&mut self, meta: PacketMeta) {
            self.meta = meta
        }
    }
}
