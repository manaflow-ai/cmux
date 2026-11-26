//! Settings › Import's card deck for the cmux macOS app (`CmuxNextImportSuggestions`' rules):
//! what the scan's file facts become, which cards show, the import jobs' steps and transitions,
//! iTerm2's profile colors and the classic import prompt's lines. The app reads the files and
//! renders the localized words; these modules decide. [`ops`] serves them over the app FFI.

pub mod deck;
pub mod iterm;
pub mod job;
pub mod model;
pub mod ops;
pub mod preview;
pub mod request;
pub mod scan;
pub mod state;
