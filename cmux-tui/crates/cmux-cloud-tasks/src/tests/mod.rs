//! The follower's cases, run through [`sim::Sim`], which does what the app's thin Swift side does
//! with each effect (polls, waiters, the saved list, the banners) against a scripted server.

mod handoffs;
mod incognito;
mod reads;
mod runs;
mod sim;
