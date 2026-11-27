//! Theme packs for cmux-next: a whole look (tokens, colors, backgrounds,
//! motion, tab shape, type, slot variants) as one folder that loads with no
//! rebuild, swaps at once, undoes and redoes as a unit, and can be edited
//! live.
//!
//! A pack is a folder with `cmux-pack.json` and, optionally, `assets/`:
//!
//! ```jsonc
//! {
//!   "cmuxPack": 1,
//!   "id": "leo/sakura",
//!   "name": "Sakura",
//!   "capabilities": ["tokens", "colors", "backgrounds", "motion", "components"],
//!   "look": { "appearance.accent": "pink", "appearance.background": "file:assets/petals.jpg" },
//!   "colors": { "background": "#1d1418", "foreground": "#f6e7ec" },
//!   "slots": { "chat.thinkingIndicator": "pulse" }
//! }
//! ```
//!
//! [`load`] reads and checks it: every value against the capability it needs
//! ([`Capability`]) and the settings schema, every asset against the pack's
//! own folder. What fails is dropped alone with a [`PackDiagnostic`]; the
//! pack is refused whole only when there is no pack to read. The result
//! compiles to a theme file (`cmux_config::theme_file`), which the app
//! already watches and repaints from, so applying a pack needs nothing new
//! in the app. [`Store`] keeps the generations for swap, undo, redo and live
//! edit ([`History`]).
//!
//! A pack carries no code. Its capabilities are the whole of what it can
//! change, and only look settings at that: the theme file reader refuses
//! anything else.

pub mod capability;
pub mod history;
pub mod load;
pub mod store;

pub use capability::Capability;
pub use history::{Generation, History, Step};
pub use load::{Context, LoadError, Pack, PackDiagnostic, load};
pub use store::{Store, StoreError};
