//! Which display a session captures: `main`, an index counted left to right, or `id:<n>`, a
//! CGDirectDisplayID (a run's virtual display, from a screen link). Pure: no ScreenCaptureKit call.

use crate::Res;

/// The index in `ids` (CGDirectDisplayIDs, left to right) that `which` names: `main`, an index,
/// or `id:<n>` (see `capture::pick`). An `id:<n>` no longer listed (the run
/// that made the display ended) picks the main display, so an old link still shows something.
pub(super) fn pick_index(ids: &[u32], main: u32, which: &str) -> Res<usize> {
    let main_index = || {
        ids.iter()
            .position(|&d| d == main)
            .or((!ids.is_empty()).then_some(0))
            .ok_or_else(|| "no display to capture (is Screen Recording allowed?)".into())
    };
    if which == "main" {
        return main_index();
    }
    if let Some(id) = which.strip_prefix("id:") {
        let id: u32 =
            id.parse().map_err(|_| format!("--display {which}: id:<CGDirectDisplayID>"))?;
        return ids.iter().position(|&d| d == id).map_or_else(main_index, Ok);
    }
    let index: usize =
        which.parse().map_err(|_| format!("--display {which}: use main, an index or id:<n>"))?;
    if index < ids.len() {
        Ok(index)
    } else {
        Err(format!("no display {index}").into())
    }
}

#[cfg(test)]
#[path = "display_pick_pick_tests.rs"]
mod pick_tests;
