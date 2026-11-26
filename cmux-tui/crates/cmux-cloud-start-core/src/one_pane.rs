//! How a Cloud start that fronts in place (a Mac tab that becomes the Cloud chat) shows the chat:
//! the Mac tab's own page, re-homed onto the Cloud machine's host, or (the kill switch) a second
//! page drawn for the Cloud tab that replaces it.
//!
//! Leo, 2026-11-25: "and then the rendering of stuff changes? the pane itself switches over when
//! you're in cloud". One renderer and one layout from Enter to the end: the page the person sent
//! from stays mounted and the remote transcript streams into it (their message, the working state
//! and the scroll stay; no remount, no flash).

use serde::{Deserialize, Serialize};

/// The facts the app reads for one start.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The start fronts in place: the Mac tab shows the Cloud chat from now (`CloudStartChat.frontsInPlace`).
    pub in_place: bool,
    /// The Mac tab has a live page (its view exists and is not closed).
    pub page_live: bool,
    /// The Cloud tab has no page of its own yet.
    pub cloud_page_free: bool,
    /// `CMUX_CLOUD_ONE_PANE` as set, if it is.
    #[serde(default)]
    pub kill_switch: Option<String>,
}

/// What the app does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Shown {
    /// The Mac tab's page becomes the Cloud tab's: same view, its host now the Cloud machine's.
    Rehome,
    /// The Cloud tab gets its own page, drawn off screen, and replaces the Mac tab's.
    Swap,
}

/// On by default; `CMUX_CLOUD_ONE_PANE=0` (or `off`, `false`, `no`) keeps the two-page swap.
pub fn shown(request: &Request) -> Shown {
    let off = request
        .kill_switch
        .as_deref()
        .map(|value| {
            matches!(value.trim().to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no")
        })
        .unwrap_or(false);
    if !off && request.in_place && request.page_live && request.cloud_page_free {
        Shown::Rehome
    } else {
        Shown::Swap
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(kill: Option<&str>) -> Request {
        Request {
            in_place: true,
            page_live: true,
            cloud_page_free: true,
            kill_switch: kill.map(str::to_owned),
        }
    }

    #[test]
    fn rehomes_by_default() {
        assert_eq!(shown(&request(None)), Shown::Rehome);
        assert_eq!(shown(&request(Some("1"))), Shown::Rehome);
        assert_eq!(shown(&request(Some(""))), Shown::Rehome);
    }

    #[test]
    fn kill_switch_keeps_the_swap() {
        for value in ["0", "off", "FALSE", " no "] {
            assert_eq!(shown(&request(Some(value))), Shown::Swap, "{value}");
        }
    }

    #[test]
    fn swaps_when_there_is_no_page_to_keep() {
        assert_eq!(shown(&Request { in_place: false, ..request(None) }), Shown::Swap);
        assert_eq!(shown(&Request { page_live: false, ..request(None) }), Shown::Swap);
        assert_eq!(shown(&Request { cloud_page_free: false, ..request(None) }), Shown::Swap);
    }
}
