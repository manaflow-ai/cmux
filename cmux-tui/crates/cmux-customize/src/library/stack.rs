//! Code layers built as one series (cmuxterm-hq RFD 0038, phase 4 step 11).
//!
//! A code layer's web part is a whole bundle, not a patch, so only one can be
//! served at a time: with two PR layers on, the top one used to win and the
//! other was silently missing. Two diffs can both apply, though. The stack is
//! every on web layer's change, bottom first, applied onto one app commit and
//! built once by CI (a quilt series); the library serves that build while the
//! layers it was built from are the ones on, in that order.
//!
//! An item names one change at the commit it was built from:
//! `pr:N@HEAD` for a pull request, `sha:HEAD` for a branch or a commit of
//! manaflow-ai/cmux. A folder (built here) and a fork (built in the fork) are
//! no item: with one of them on, there is no stack and the top layer serves
//! alone, as before.
//!
//! CI publishes a stack at
//! `files.cmux.com/cmux-next-web/stack/<id>/<base>.json`, where `<id>` is
//! [`StackLayer::id`] of its items (cmux-next-web-bundle-publish.yml, input
//! `stack`).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::code::{CodeKind, CodeLayer};
use super::{Changed, Entry, LibraryFile};
use crate::{Customize, Error};

/// One CI build of every on web layer's change, bottom first, on `base`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StackLayer {
    /// `pr:N@HEAD` or `sha:HEAD`, bottom first.
    pub items: Vec<String>,
    /// The app commit the series was applied onto.
    pub base: String,
    /// The published web bundle key the build made.
    pub web: String,
    /// The web ABI the bundles need.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub abi: Option<u32>,
}

impl StackLayer {
    /// The name CI publishes a series under: the first 24 hex of the
    /// sha256 of its items, one per line.
    pub fn id(items: &[String]) -> String {
        let digest = Sha256::digest(items.join("\n").as_bytes());
        digest.iter().take(12).map(|b| format!("{b:02x}")).collect()
    }
}

/// The item that names `code`'s change for CI, if CI can build it.
pub fn item(code: &CodeLayer) -> Option<String> {
    if code.repo != "manaflow-ai/cmux" || !is_sha(&code.head) {
        return None;
    }
    match code.kind {
        CodeKind::Pr if code.pr > 0 => Some(format!("pr:{}@{}", code.pr, code.head)),
        CodeKind::Branch | CodeKind::Sha => Some(format!("sha:{}", code.head)),
        _ => None,
    }
}

/// The series the on web layers make, bottom first: `None` with fewer than
/// two, or when one of them is a change CI does not build (a folder, a fork).
pub fn items(entries: &[Entry]) -> Option<Vec<String>> {
    let layers: Vec<&CodeLayer> =
        entries.iter().filter(|entry| entry.on).filter_map(Entry::web_layer).collect();
    if layers.len() < 2 {
        return None;
    }
    layers.iter().rev().map(|code| item(code)).collect()
}

/// The web bundle key web-dev.json serves: the stack's while the on web
/// layers are the ones it was built from, in that order, else the top one's.
pub(super) fn web_key(entries: &[Entry], stack: Option<&StackLayer>) -> Option<String> {
    if let (Some(stack), Some(items)) = (stack, items(entries))
        && stack.items == items
    {
        return Some(stack.web.clone());
    }
    super::web_top(entries).map(|code| code.web.clone())
}

/// Whether the stack serves now in place of the top layer.
pub(super) fn serving<'a>(entries: &[Entry], stack: Option<&'a StackLayer>) -> Option<&'a StackLayer> {
    let stack = stack?;
    (items(entries).as_ref() == Some(&stack.items)).then_some(stack)
}

fn is_sha(text: &str) -> bool {
    text.len() == 40 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl Customize {
    /// The series the on web layers make, and the stack the library has
    /// built for it, if it has one.
    pub fn library_stack(&self) -> Result<(Option<Vec<String>>, Option<StackLayer>), Error> {
        let library = self.read_library()?;
        let items = items(&library.entries);
        let built = library.stack.filter(|stack| Some(&stack.items) == items.as_ref());
        Ok((items, built))
    }

    /// Serves `stack` (its bundles fetched into its layer folder) in place
    /// of the top layer, while its items are the on web layers.
    pub fn library_set_stack(
        &self,
        stack: StackLayer,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        if !super::code::valid_key(&stack.web) {
            return Err(Error::Library(format!("{} is no web bundle key", stack.web)));
        }
        if !self.layer_ready(&stack.web) {
            return Err(Error::Library("the stack's web bundles are not on this computer".into()));
        }
        self.library_change("stack", origin, now_ms, |library: &mut LibraryFile| {
            if items(&library.entries).as_ref() != Some(&stack.items) {
                return Err(Error::Library(
                    "the layers that are on changed while the stack was built; it was not served"
                        .into(),
                ));
            }
            library.stack = Some(stack);
            Ok(())
        })
    }
}
