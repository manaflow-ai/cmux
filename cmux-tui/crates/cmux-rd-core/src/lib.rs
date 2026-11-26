//! Pure core of the cmux remote desktop engine (`cmux-rd`): forward error
//! correction, packetizing and reassembly of frames, frame flow control,
//! delay-based congestion control, loss measurement, the resolution ladder,
//! input delivery, the viewer's upstream media sender, and the host's
//! session table with its access policy. No I/O; every function
//! that needs time takes it as an argument. Design: plans/cmux-next/remote-desktop.md.

pub mod bulk;
pub mod cc;
pub mod clock;
pub mod fec;
pub mod flow;
pub mod input;
pub mod ledger;
pub mod link;
pub mod loss;
pub mod pacer;
pub mod packetize;
pub mod policy;
pub mod probe;
pub mod profile;
#[cfg(feature = "app")]
pub mod rd_devices;
pub mod reassembly;
pub mod resolution;
pub mod screen_kit;
pub mod service;
pub mod session;
pub mod upstream;
