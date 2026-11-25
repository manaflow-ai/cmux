use std::cell::RefCell;
use std::io;
use std::os::unix::io::{AsRawFd, RawFd};
use std::rc::Rc;
use std::vec::Vec;

use crate::phy::{self, Device, DeviceCapabilities, Medium, sys};
use crate::time::Instant;

/// A socket that captures or transmits the complete frame.
#[derive(Debug)]
pub struct RawSocket {
    medium: Medium,
    lower: Rc<RefCell<sys::RawSocketDesc>>,
    mtu: usize,
}

impl AsRawFd for RawSocket {
    fn as_raw_fd(&self) -> RawFd {
        self.lower.borrow().as_raw_fd()
    }
}

impl RawSocket {
    /// Creates a raw socket, bound to the interface called `name`.
    ///
    /// This requires superuser privileges or a corresponding capability bit
    /// set on the executable.
    pub fn new(name: &str, medium: Medium) -> io::Result<RawSocket> {
        let mut lower = sys::RawSocketDesc::new(name, medium)?;
        lower.bind_interface()?;

        let mut mtu = lower.interface_mtu()?;

        #[cfg(feature = "medium-ieee802154")]
        if medium == Medium::Ieee802154 {
            // SIOCGIFMTU returns 127 - (ACK_PSDU - FCS - 1) - FCS.
            //                    127 - (5 - 2 - 1) - 2 = 123
            // For IEEE802154, we want to add (ACK_PSDU - FCS - 1), since that is what SIOCGIFMTU
            // uses as the size of the link layer header.
            //
            // https://github.com/torvalds/linux/blob/7475e51b87969e01a6812eac713a1c8310372e8a/net/mac802154/iface.c#L541
            mtu += 2;
        }

        #[cfg(feature = "medium-ethernet")]
        if medium == Medium::Ethernet {
            // SIOCGIFMTU returns the IP MTU (typically 1500 bytes.)
            // smoltcp counts the entire Ethernet packet in the MTU, so add the Ethernet header size to it.
            mtu += crate::wire::EthernetFrame::<&[u8]>::header_len()
        }

        Ok(RawSocket {
            medium,
            lower: Rc::new(RefCell::new(lower)),
            mtu,
        })
    }
}

impl Device for RawSocket {
    type RxToken<'a>
        = RxToken
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken
    where
        Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        DeviceCapabilities {
            max_transmission_unit: self.mtu,
            medium: self.medium,
            ..DeviceCapabilities::default()
        }
    }

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let mut lower = self.lower.borrow_mut();
        let mut buffer = vec![0; self.mtu];
        match lower.recv(&mut buffer[..]) {
            Ok(size) => {
                buffer.resize(size, 0);
                let rx = RxToken { buffer };
                let tx = TxToken {
                    lower: self.lower.clone(),
                };
                Some((rx, tx))
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => None,
            Err(err) => panic!("{}", err),
        }
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(TxToken {
            lower: self.lower.clone(),
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
        f(&self.buffer[..])
    }
}

#[doc(hidden)]
pub struct TxToken {
    lower: Rc<RefCell<sys::RawSocketDesc>>,
}

impl phy::TxToken for TxToken {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut lower = self.lower.borrow_mut();
        let mut buffer = vec![0; len];
        let result = f(&mut buffer);
        match lower.send(&buffer[..]) {
            Ok(_) => {}
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                net_debug!("phy: tx failed due to WouldBlock")
            }
            Err(err) => panic!("{}", err),
        }
        result
    }
}
