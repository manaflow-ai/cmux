//! Braid's data classes (RFD 0164, slice B5).
//!
//! Every link in the app sends four kinds of data: input (keystrokes), interactive state
//! (the terminal screen, video), reliable ordered messages (control, RPC, tunnels) and bulk
//! transfers. Each stack named them on its own: cmux-remote's `Lane`, the phone link's
//! `SendClass`, cmux-wg's `Priority`. They agreed on the idea and not on the rules: which
//! class is repaired at what loss, which may drop, which goes first. This crate holds the
//! one enum ([`Class`]), its rules ([`Class::repair`], [`Class::drop_rule`]), the paths a
//! class rides ([`paths_for`]) and one class scheduler ([`Scheduler`]). Each stack maps its
//! own enum onto [`Class`] and asks here instead of deciding again.
//!
//! Sans-I/O and dependency-free: it builds for the Mac, the phone and the Worker target.

pub mod class;
pub mod paths;
pub mod scheduler;

pub use class::{Carried, Class, DropRule, Order, Repair, WireClassError};
pub use paths::{PathView, Pick, paths_for};
pub use scheduler::{Offer, Scheduler};
