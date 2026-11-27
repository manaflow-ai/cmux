//! Whether a page's cached image may be painted over its region of a window's launch image.
//!
//! Without the Screen Recording grant the window server's composite of our own window shows
//! terminals and chrome but only the fill of a Chromium page (its GPU process draws it). The app
//! never wakes or asks a page for a new image to fill that hole (a page capture measured 74.3/92.4
//! ms p50/p95 with a 9.5/10.8 ms main-thread turn, #45444); it reuses an image the app already
//! keeps (the hover-card picture, the agent pane's quit image). This decides, per region, whether
//! that image still shows the page: only then is it painted, else the region is plain (the theme's
//! fill, never a stale page's text).
//!
//! This is the capture-time half of the launch image's staleness. The launch-time half (build,
//! layout, scale, appearance, size) is cmux-launch-shell's `plan::Reason` (#45089).

/// The most a page image may lag the window composite it is painted into.
///
/// A page's picture version moves on a navigation or a load, not on every repaint (a clock, a
/// video, a streamed reply): an image of the same version but much older than the composite may
/// show text the page no longer has. Two minutes is past a typical read of one page and short of
/// a page left open while the person works elsewhere.
pub const MAX_PAGE_IMAGE_LAG_MS: u64 = crate::ffi::CMUX_LAUNCH_IMAGE_MAX_PAGE_IMAGE_LAG_MS;

/// One page region of a window at capture time. Times are milliseconds of one monotonic clock the
/// app passes (its `ContinuousClock`); versions are the page's picture version (it moves on each
/// navigation and load).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PageRegion {
    /// When the cached image was taken; `None`: the app has no image of this page.
    pub image_taken_ms: Option<u64>,
    /// The page's picture version the image was taken at; `None`: unknown (a blank or unversioned
    /// image), never painted.
    pub image_version: Option<u64>,
    /// The page's picture version now.
    pub page_version: u64,
    /// When the page last changed in a way it shows (navigation, load, a visible change the app
    /// heard of); `None`: none heard since it opened.
    pub page_changed_ms: Option<u64>,
    /// When the window composite this region is painted into was taken.
    pub composite_ms: u64,
}

/// Why a region is painted as it is. Only [`RegionReason::Image`] paints the cached image; every
/// other reason paints the region plain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RegionReason {
    /// The cached image shows the page as it is.
    Image = 0,
    /// The app keeps no image of the page.
    NoImage = 1,
    /// The page navigated or loaded since the image (or the image has no version).
    VersionDiffers = 2,
    /// The page changed after the image was taken.
    TakenBeforeChange = 3,
    /// The image is older than the composite by more than [`MAX_PAGE_IMAGE_LAG_MS`].
    TooOld = 4,
    /// The image is newer than the composite (the clocks disagree): not trusted.
    TakenAfterComposite = 5,
}

impl RegionReason {
    /// The cached image is painted over the region.
    pub fn paints_image(self) -> bool {
        self == Self::Image
    }
}

/// Decides one page region (see the module). Pure: the same region always gives the same reason.
pub fn page_region(region: &PageRegion) -> RegionReason {
    let Some(taken) = region.image_taken_ms else { return RegionReason::NoImage };
    if region.image_version != Some(region.page_version) {
        return RegionReason::VersionDiffers;
    }
    if region.page_changed_ms.is_some_and(|changed| taken < changed) {
        return RegionReason::TakenBeforeChange;
    }
    if taken > region.composite_ms {
        return RegionReason::TakenAfterComposite;
    }
    if region.composite_ms - taken > MAX_PAGE_IMAGE_LAG_MS {
        return RegionReason::TooOld;
    }
    RegionReason::Image
}

#[cfg(test)]
#[path = "region_tests.rs"]
mod tests;
