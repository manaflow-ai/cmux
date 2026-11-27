//! The rules of the macOS app's Screenshots pane (CmuxNextScreenshots), so they are one tested
//! implementation the app calls through `include/cmux_screenshots.h` (cmux-app-ffi).
//!
//! The app lists folders, reads preferences, watches the disk and draws the grid; this crate
//! decides what those mean:
//! - [`rule`]: which files a source lists and which subfolders it enters.
//! - [`listing`]: the newest-first list, kept sorted under live upserts and removes.
//! - [`tools`]: the screenshot tools the pane knows and where each saves.
//! - [`detect`]: the sources, in menu order, over a [`detect::Environment`] the app provides.
//! - [`settings`]: the `key=value` and JSON settings files tools save their folder in.
//! - [`reader`]: which directory entries a folder scan lists or enters, and the newest picture.
//! - [`pane`]: the pane's sources: what to read, watch, drop and look at after a watch event.
//! - [`page`], [`gate`], [`names`]: the page address, the access gate, dropped-image and rename names.

pub mod detect;
pub mod ffi;
pub mod gate;
pub mod listing;
pub mod names;
pub mod page;
pub mod pane;
pub mod reader;
pub mod rule;
pub mod settings;
pub mod tools;
