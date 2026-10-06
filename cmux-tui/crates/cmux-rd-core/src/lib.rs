//! Pure core of the cmux remote desktop engine (`cmux-rd`): forward error
//! correction, packetizing and reassembly of frames, frame flow control,
//! delay-based congestion control, the quality ladder, input delivery, and
//! the host's session table with its access policy. No I/O; every function
//! that needs time takes it as an argument. Design: plans/cmux-next/remote-desktop.md.

pub mod cc;
pub mod fec;
pub mod flow;
pub mod input;
pub mod ladder;
pub mod packetize;
pub mod policy;
pub mod reassembly;
pub mod service;
pub mod session;
