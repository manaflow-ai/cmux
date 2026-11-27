//! The Mac app's Mac Screen rules (`CmuxNextMacScreen`): what a viewer's offer asks the host
//! for ([`offer`]), where a connect is ([`stage`]), and one session's state from the
//! moment it asks the hub to the end of its stream ([`session`]). The app keeps the platform
//! work (the link process, sockets, the decoder, timers) and the localized words; these rules
//! decide, [`rd_host`] serves this Mac's screen to an approved viewer, and [`ops`] serves them to it over JSON (`mac_screen_*`).

pub mod offer;
pub mod ops;
pub mod rd_host;
pub mod session;
pub mod stage;
