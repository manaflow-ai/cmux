//! Auto mode end to end: one chat's journey between a laptop's daemon and a Cloud machine's.
//!
//! Two hubs run in this process, each with its own holder loop: the laptop as `device:<id>`
//! with the real importer, the machine as `vm:<machine>` behind its assignment reader
//! (`machine::attach_with`). Both reach one `FakeAutoCloud` (the real store's rules, in
//! memory): the laptop as the owner over a network the test cuts, the machine as its VM
//! install, the phone as the owner over a network of its own. Each loop runs on a clock the
//! test moves, together with the store's.
//!
//! - [`world`]: the two daemons, the store, the clocks and the laptop's checkout.
//! - [`logs`]: prompts sent to a hub and what its chat's log holds.
//! - [`steps`]: the steps more than one test takes.
//! - [`journey`]: the whole journey, step by step.
//! - [`variants`]: a chat kept in the Cloud, and a chat started with no laptop.
//! - [`moved`]: a chat the person moves by hand, to the machine and home, in the middle of a
//!   turn each time.
//! - [`native`]: the agent's own session file going with the copy, both ways.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "auto_journey/journey.rs"]
mod journey;
#[path = "auto_journey/logs.rs"]
mod logs;
#[path = "auto_journey/moved.rs"]
mod moved;
#[path = "auto_journey/native.rs"]
mod native;
#[path = "auto_journey/steps.rs"]
mod steps;
#[path = "auto_journey/variants.rs"]
mod variants;
#[path = "auto_journey/world.rs"]
mod world;
