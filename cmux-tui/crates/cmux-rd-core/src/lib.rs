//! Pure core of the cmux remote desktop engine (`cmux-rd`): forward error
//! correction, packetizing and reassembly of frames, frame flow control,
//! delay-based congestion control, loss measurement, the quality ladder,
//! input delivery, the viewer's upstream media sender, and the host's
//! session table with its access policy. No I/O; every function
//! that needs time takes it as an argument. Design: plans/cmux-next/remote-desktop.md.

pub mod bulk;
pub mod cc;
pub mod clock;
pub mod fec;
pub mod flow;
pub mod input;
pub mod ladder;
pub mod loss;
pub mod packetize;
pub mod policy;
pub mod reassembly;
pub mod service;
pub mod session;
pub mod upstream;
