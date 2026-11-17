//! The pure parts of cutting a recording by the camera path: output aspects
//! and sizes, the YUV4MPEG2 stream header the cutter reads frames through,
//! fitting a signal trace to the video's pixels, and cropping a plane.

use std::str::FromStr;

use crate::{Event, Rect};

/// A vertical cut's shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aspect {
    /// 9:16, a phone's full screen.
    Tall,
    /// 4:5, a feed post.
    Portrait,
    /// 1:1.
    Square,
}

impl Aspect {
    /// Width over height.
    pub fn ratio(self) -> f64 {
        0.0
    }

    /// The output size for `width` pixels wide (even, for H.264).
    pub fn output_size(self, width: u32) -> (u32, u32) {
        let _ = width;
        (0, 0)
    }
}

impl FromStr for Aspect {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        Err(format!("unknown aspect {s}"))
    }
}

/// A YUV4MPEG2 stream's header line (without its newline).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Y4mHeader {
    pub w: usize,
    pub h: usize,
    pub fps_num: u64,
    pub fps_den: u64,
    /// The `C` tag, "420jpeg" when absent.
    pub chroma: String,
}

impl Y4mHeader {
    pub fn parse(line: &str) -> Result<Self, String> {
        Err(format!("not a YUV4MPEG2 header: {line}"))
    }

    /// Bytes of one frame's planes (after its FRAME line).
    pub fn frame_bytes(&self) -> Result<usize, String> {
        Err(format!("unsupported chroma {}", self.chroma))
    }
}

/// A trace fitted to a `video_w` x `video_h` recording: a trace that says
/// its screen size (a [`crate::Signal::Source`] event) is scaled from it to
/// the video's pixels, and its source events are dropped (the video's size
/// is the camera's source).
pub fn fit_trace(events: &[Event], video_w: f64, video_h: f64) -> Vec<Event> {
    let _ = (video_w, video_h);
    events.to_vec()
}

/// Samples `rect` of a `sw` x `sh` plane into `out` (`ow` x `oh`),
/// bilinear.
pub fn crop_plane(
    src: &[u8],
    sw: usize,
    sh: usize,
    rect: Rect,
    out: &mut [u8],
    ow: usize,
    oh: usize,
) {
    let _ = (src, sw, sh, rect, ow, oh);
    out.fill(0);
}
