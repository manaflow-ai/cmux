//! Counter and window checks for the compositor observer. These deliberately do not
//! know which remote-display protocol rendered the window.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use std::collections::VecDeque;

/// A marker decoded on the capture callback thread. `display_us` is the
/// ScreenCaptureKit display timestamp converted to the protocol clock; it is
/// absent when SCK did not provide one. `arrived_us` is always the callback
/// arrival time on that clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PresentedMarkerSample {
    pub counter: Option<u16>,
    pub nonce: Option<[u8; 16]>,
    pub display_us: Option<u64>,
    pub arrived_us: u64,
}

/// A bounded callback-to-observer queue. Overflow is sticky and must be
/// reported by the caller; a dropped callback is never silently treated as a
/// frame-rate result.
#[derive(Debug)]
pub struct PresentedSampleQueue {
    samples: VecDeque<PresentedMarkerSample>,
    capacity: usize,
    overflowed: bool,
}

impl PresentedSampleQueue {
    pub fn with_capacity(capacity: usize) -> Self {
        Self { samples: VecDeque::with_capacity(capacity), capacity, overflowed: false }
    }

    pub fn push(&mut self, sample: PresentedMarkerSample) {
        if self.samples.len() >= self.capacity {
            self.overflowed = true;
        } else {
            self.samples.push_back(sample);
        }
    }

    pub fn take(&mut self) -> Vec<PresentedMarkerSample> {
        self.samples.drain(..).collect()
    }

    pub fn overflowed(&self) -> bool {
        self.overflowed
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.samples.len()
    }
}

/// The observer-side counter accounting for a passive presented-frame series.
/// Counter gaps are dropped frames and are recorded rather than failing the
/// interval. Repeated and invalid samples remain diagnostics.
#[derive(Debug, Default)]
pub struct PresentedSeries {
    last: Option<u16>,
    expected_nonce: Option<[u8; 16]>,
    pub presented_frames: u64,
    pub gaps: u64,
    pub repeated: u64,
    pub invalid: u64,
    pub nonce_mismatch: u64,
    pub reversed: u64,
    pub first_counter: Option<u16>,
    pub last_counter: Option<u16>,
    pub first_display_us: Option<u64>,
    pub last_display_us: Option<u64>,
    pub first_arrived_us: Option<u64>,
    pub last_arrived_us: Option<u64>,
}

impl PresentedSeries {
    #[cfg(test)]
    pub fn with_baseline(baseline: Option<u16>) -> Self {
        Self { last: baseline, ..Self::default() }
    }

    pub fn with_baseline_and_nonce(
        baseline: Option<u16>,
        expected_nonce: Option<[u8; 16]>,
    ) -> Self {
        Self { last: baseline, expected_nonce, ..Self::default() }
    }

    pub fn ingest(&mut self, sample: PresentedMarkerSample) {
        if let Some(expected) = self.expected_nonce {
            if sample.nonce != Some(expected) {
                self.nonce_mismatch += 1;
                return;
            }
        }
        if sample.display_us.is_none() {
            self.invalid += 1;
            return;
        }
        let Some(counter) = sample.counter else {
            self.invalid += 1;
            return;
        };
        if let Some(last) = self.last {
            let distance = counter.wrapping_sub(last);
            if distance == 0 {
                self.repeated += 1;
                return;
            }
            if distance >= 32768 {
                self.reversed += 1;
                return;
            }
            self.gaps += u64::from(distance.saturating_sub(1));
        }
        self.last = Some(counter);
        self.presented_frames += 1;
        self.first_counter.get_or_insert(counter);
        self.last_counter = Some(counter);
        if let Some(display) = sample.display_us {
            self.first_display_us.get_or_insert(display);
            self.last_display_us = Some(display);
        }
        self.first_arrived_us.get_or_insert(sample.arrived_us);
        self.last_arrived_us = Some(sample.arrived_us);
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Window {
    pub id: u32,
    pub pid: i32,
    pub rect: [f64; 4],
}

/// Window-server order is front to back. A second window of the same process
/// must not be mistaken for the connection the caller selected.
pub fn unobscured(windows: &[Window], id: u32, pid: i32, points: &[(f64, f64)]) -> bool {
    !points.is_empty()
        && points.iter().all(|&(x, y)| {
            windows
                .iter()
                .find(|w| {
                    let [left, top, width, height] = w.rect;
                    x >= left && x < left + width && y >= top && y < top + height
                })
                .is_some_and(|w| w.id == id && w.pid == pid)
        })
}

/// Read each cell's center; refuse ambiguous compression/scaling values, wrong
/// guards and a marker outside the plane rather than interpreting them as zero.
pub fn read_marker(y: &[u8], stride: usize, origin: (usize, usize), cell: usize) -> Option<u16> {
    if cell < 2 || stride == 0 {
        return None;
    }
    let row = origin.1.checked_add(cell / 2)?.checked_mul(stride)?;
    let mut bits = [false; 20];
    for (i, bit) in bits.iter_mut().enumerate() {
        let x = origin.0.checked_add(i.checked_mul(cell)?)?.checked_add(cell / 2)?;
        if x >= stride {
            return None;
        }
        *bit = match *y.get(row.checked_add(x)?)? {
            0..=60 => false,
            190..=255 => true,
            _ => return None,
        };
    }
    if bits[16..] != [true, false, true, false] {
        return None;
    }
    Some(bits[..16].iter().enumerate().fold(0, |v, (i, &bit)| v | (u16::from(bit) << i)))
}

/// Read the counter row and eight nonce rows. Each row is the same 16-bit
/// counter marker layout; nonce words are concatenated little-endian.
pub fn read_marker_nonce(
    y: &[u8],
    stride: usize,
    origin: (usize, usize),
    cell: usize,
) -> Option<(u16, [u8; 16])> {
    let counter = read_marker(y, stride, origin, cell)?;
    let mut nonce = [0u8; 16];
    for row in 0..8 {
        let word =
            read_marker(y, stride, (origin.0, origin.1.checked_add((row + 1) * cell)?), cell)?;
        nonce[row * 2..row * 2 + 2].copy_from_slice(&word.to_le_bytes());
    }
    Some((counter, nonce))
}

/// Where a viewer window draws the marker, in capture pixels: what `--marker-origin`,
/// `--cell-size` and `--at` otherwise give by hand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Calibration {
    pub origin: (usize, usize),
    pub cell: usize,
    /// The input point: the marker's gray pad (cells 20..23) when it lies in the region,
    /// else a cell below the marker's rows. Never inside the marker.
    pub at: (usize, usize),
}

/// Smallest and largest cell `locate_marker` tries: a 32 px host cell shown at an eighth, and
/// at four times.
const LOCATE_CELLS: std::ops::RangeInclusive<usize> = 4..=128;

/// Finds the marker inside `region` (x, y, width, height in capture pixels) of a luma plane
/// `width` x `height` with `stride` bytes a row, so `observe` needs no hand-measured geometry.
/// `rows` is 1 for the counter alone, 9 when eight nonce rows follow it (the scene's layout);
/// every row must read.
///
/// For each cell size it takes the first position (top to bottom, left to right) from which all
/// 20 cell centres read with the guard 1,0,1,0, then measures how far that position can move
/// and still read: the run is about one cell long for the true size, and shorter by about 19
/// pixels for each pixel a size is off, since the error adds up across the 20 cells. The size
/// with the largest runs wins, and the origin is the middle of its runs, which is the marker's
/// top-left (the centres then sit mid-cell). A region with no such marker is an error, never a
/// guess.
pub fn locate_marker(
    y: &[u8],
    stride: usize,
    width: usize,
    height: usize,
    region: (usize, usize, usize, usize),
    rows: usize,
) -> Result<Calibration, &'static str> {
    let rows = rows.max(1);
    let width = width.min(stride);
    if y.len() < stride.saturating_mul(height) {
        return Err("capture plane is shorter than its size");
    }
    let left = region.0.min(width);
    let top = region.1.min(height);
    let right = region.0.saturating_add(region.2).min(width);
    let bottom = region.1.saturating_add(region.3).min(height);
    let reads = |x: usize, yy: usize, cell: usize| -> bool {
        if rows == 9 {
            read_marker_nonce(y, stride, (x, yy), cell).is_some()
        } else {
            read_marker(y, stride, (x, yy), cell).is_some()
        }
    };
    // The run of positions along one axis from `start` that still read.
    let run = |x: usize, yy: usize, cell: usize, horizontal: bool| -> (usize, usize) {
        let ok = |v: usize| if horizontal { reads(v, yy, cell) } else { reads(x, v, cell) };
        let start = if horizontal { x } else { yy };
        let (low_limit, high_limit) = if horizontal { (left, right) } else { (top, bottom) };
        let mut low = start;
        while low > low_limit && ok(low - 1) {
            low -= 1;
        }
        let mut high = start;
        while high + 1 < high_limit && ok(high + 1) {
            high += 1;
        }
        (low, high)
    };
    let mut best: Option<(usize, Calibration)> = None;
    for cell in LOCATE_CELLS {
        let span_x = cell * 20;
        let span_y = cell * rows;
        if right < left + span_x || bottom < top + span_y {
            break;
        }
        // A step under a third of a cell cannot step over the true size's run.
        let step = (cell / 3).max(1);
        // The first position (top to bottom, left to right) that reads and leaves room to move
        // a quarter cell each way; a chance hit in text or noise reads at one spot only.
        let need = (cell / 4).max(2);
        let mut hit = None;
        let mut yy = top;
        'scan: while yy + span_y <= bottom {
            let mut x = left;
            while x + span_x <= right {
                if reads(x, yy, cell) {
                    let (x0, x1) = run(x, yy, cell, true);
                    let mid_x = (x0 + x1) / 2;
                    let (y0, y1) = run(mid_x, yy, cell, false);
                    let mid_y = (y0 + y1) / 2;
                    if x1 - x0 + 1 >= need && y1 - y0 + 1 >= need && reads(mid_x, mid_y, cell) {
                        hit = Some((x0, x1, y0, y1, mid_x, mid_y));
                        break 'scan;
                    }
                }
                x += step;
            }
            yy += step;
        }
        let Some((x0, x1, y0, y1, mid_x, mid_y)) = hit else { continue };
        let score = (x1 - x0 + 1) * (y1 - y0 + 1);
        if best.as_ref().is_none_or(|(s, _)| score > *s) {
            let pad = (mid_x + 22 * cell, mid_y + cell / 2);
            let below = (mid_x + 10 * cell, mid_y + rows * cell + cell / 2);
            let inside =
                |p: (usize, usize)| p.0 >= left && p.0 < right && p.1 >= top && p.1 < bottom;
            let at = if inside(pad) {
                pad
            } else if inside(below) {
                below
            } else {
                continue;
            };
            best = Some((score, Calibration { origin: (mid_x, mid_y), cell, at }));
        }
    }
    best.map(|(_, c)| c).ok_or("no marker visible in the viewer window")
}

/// Exactly one input is outstanding. Frames timestamped before the input and
/// unchanged counters are not responses; skipped counters invalidate the run.
pub fn response(
    before: u16,
    sent_us: u64,
    counter: u16,
    shown_us: u64,
) -> Result<Option<u64>, &'static str> {
    if shown_us <= sent_us || counter == before {
        return Ok(None);
    }
    if counter != before.wrapping_add(1) {
        return Err("unexpected marker counter; another input or scene changed the run");
    }
    Ok(Some(shown_us - sent_us))
}

/// Nearest rank, including every successful input. An incomplete run never calls this.
pub fn percentiles(samples_us: &[u64]) -> Option<(f64, f64)> {
    if samples_us.is_empty() {
        return None;
    }
    let mut sorted = samples_us.to_vec();
    sorted.sort_unstable();
    let rank =
        |p: usize| sorted.get((sorted.len() * p).div_ceil(100) - 1).map(|x| *x as f64 / 1000.0);
    Some((rank(50)?, rank(95)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observe_requires_exact_next_counter_and_post_input_timestamp() {
        assert_eq!(response(7, 1000, 8, 999), Ok(None));
        assert_eq!(response(7, 1000, 8, 1000), Ok(None));
        assert_eq!(response(7, 1000, 7, 1100), Ok(None));
        assert_eq!(response(7, 1000, 8, 3500), Ok(Some(2500)));
        assert_eq!(response(u16::MAX, 1000, 0, 3500), Ok(Some(2500)));
        assert!(response(7, 1000, 9, 3500).is_err());
    }

    #[test]
    fn observe_rejects_other_connection_and_occlusion() {
        let target = Window { id: 2, pid: 40, rect: [0.0, 0.0, 100.0, 100.0] };
        let cover = Window { id: 3, pid: 40, rect: [50.0, 0.0, 50.0, 100.0] };
        assert!(unobscured(&[target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
        assert!(!unobscured(&[cover, target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
        assert!(!unobscured(&[target], 2, 41, &[(10.0, 10.0)]));
        assert!(!unobscured(&[target], 2, 40, &[(100.0, 10.0)]));
        assert!(!unobscured(&[target], 2, 40, &[]));
    }

    #[test]
    fn observe_marker_guards_bounds_and_scaled_cells() {
        let stride = 100;
        let mut plane = vec![16; stride * 8];
        for (i, on) in crate::marker::cells(257).iter().enumerate() {
            plane[4 * stride + 3 + i * 4 + 2] = if *on { 235 } else { 16 };
        }
        assert_eq!(read_marker(&plane, stride, (3, 2), 4), Some(257));
        plane[4 * stride + 3 + 18 * 4 + 2] = 128;
        assert_eq!(read_marker(&plane, stride, (3, 2), 4), None);
        assert_eq!(read_marker(&plane, stride, (usize::MAX, 2), 4), None);
        assert_eq!(read_marker(&plane, stride, (90, 2), 4), None);
    }

    /// A viewer capture: background `bg`, the marker (counter, then `nonce_rows` rows of word
    /// 0x5aa5) at a fractional origin and cell, as a scaled viewer draws it, its edges softened by
    /// a one-pixel blend, then four gray pad cells.
    fn viewer_plane(
        width: usize,
        height: usize,
        origin: (f64, f64),
        cell: f64,
        counter: u32,
        nonce_rows: usize,
        bg: u8,
    ) -> Vec<u8> {
        let mut plane = vec![bg; width * height];
        let value = |px: f64, py: f64| -> Option<u8> {
            let col = ((px - origin.0) / cell).floor();
            let row = ((py - origin.1) / cell).floor();
            if col < 0.0 || row < 0.0 || col >= 24.0 || row as usize > nonce_rows {
                return None;
            }
            let (col, row) = (col as usize, row as usize);
            if col >= 20 {
                return (row == 0).then_some(128);
            }
            let word = if row == 0 { counter } else { 0x5aa5 };
            Some(if crate::marker::cells(word)[col] { 235 } else { 16 })
        };
        for py in 0..height {
            for px in 0..width {
                // Average of the pixel's four quarter points: a scaled edge blends.
                let mut sum = 0u32;
                for (dx, dy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    sum += u32::from(value(px as f64 + dx, py as f64 + dy).unwrap_or(bg));
                }
                plane[py * width + px] = (sum / 4) as u8;
            }
        }
        plane
    }

    #[test]
    fn locate_finds_a_native_marker_and_its_pad() {
        let (w, h) = (1200, 300);
        let plane = viewer_plane(w, h, (100.0, 40.0), 32.0, 0xa5c3, 0, 128);
        let found = locate_marker(&plane, w, w, h, (0, 0, w, h), 1).expect("marker");
        assert_eq!(found.cell, 32);
        assert!(found.origin.0.abs_diff(100) <= 1 && found.origin.1.abs_diff(40) <= 1, "{found:?}");
        assert_eq!(read_marker(&plane, w, found.origin, found.cell), Some(0xa5c3));
        assert_eq!(found.at, (found.origin.0 + 22 * 32, found.origin.1 + 16));
    }

    #[test]
    fn locate_handles_a_scaled_fractional_cell() {
        let (w, h) = (900, 400);
        let plane = viewer_plane(w, h, (37.3, 61.6), 13.6, 0x00ff, 0, 40);
        let found = locate_marker(&plane, w, w, h, (0, 0, w, h), 1).expect("marker");
        assert!(found.cell.abs_diff(14) <= 1, "{found:?}");
        assert_eq!(read_marker(&plane, w, found.origin, found.cell), Some(0x00ff));
        // The counter must still read one step later: every centre stays inside its cell.
        let next = viewer_plane(w, h, (37.3, 61.6), 13.6, 0x0100, 0, 40);
        assert_eq!(read_marker(&next, w, found.origin, found.cell), Some(0x0100));
    }

    #[test]
    fn locate_reads_the_nonce_rows_when_asked() {
        let (w, h) = (1000, 400);
        let plane = viewer_plane(w, h, (12.0, 30.0), 20.0, 7, 8, 200);
        let found = locate_marker(&plane, w, w, h, (0, 0, w, h), 9).expect("marker");
        assert_eq!(found.cell, 20);
        let (counter, nonce) =
            read_marker_nonce(&plane, w, found.origin, found.cell).expect("nonce");
        assert_eq!(counter, 7);
        assert_eq!(nonce, [0xa5, 0x5a].repeat(8)[..]);
    }

    #[test]
    fn locate_stays_inside_the_region_and_fails_closed() {
        let (w, h) = (1200, 300);
        let plane = viewer_plane(w, h, (100.0, 40.0), 32.0, 3, 0, 128);
        // A window that does not contain the marker: no guess.
        assert!(locate_marker(&plane, w, w, h, (0, 120, w, 180), 1).is_err());
        let blank = vec![128u8; w * h];
        assert!(locate_marker(&blank, w, w, h, (0, 0, w, h), 1).is_err());
        // Black and white noise (text on a page) is not a marker.
        let mut rng = crate::clock::Rng::new(7);
        let noise: Vec<u8> =
            (0..w * h).map(|_| if rng.range(0, 1) == 0 { 0 } else { 255 }).collect();
        assert!(locate_marker(&noise, w, w, h, (0, 0, w, h), 1).is_err());
    }

    #[test]
    fn observe_reports_nearest_rank_over_all_samples() {
        assert_eq!(percentiles(&[]), None);
        assert_eq!(percentiles(&[9000, 1000, 3000, 2000]), Some((2.0, 9.0)));
        assert_eq!(percentiles(&[3500]), Some((3.5, 3.5)));
    }

    #[test]
    fn passive_series_accepts_wrap_and_reports_gaps() {
        let mut series = PresentedSeries::with_baseline(Some(u16::MAX));
        for counter in [u16::MAX, 0, 2] {
            series.ingest(PresentedMarkerSample {
                counter: Some(counter),
                nonce: None,
                display_us: Some(u64::from(counter)),
                arrived_us: u64::from(counter),
            });
        }
        assert_eq!(series.presented_frames, 2);
        assert_eq!(series.gaps, 1);
        assert_eq!(series.first_counter, Some(0));
        assert_eq!(series.last_counter, Some(2));
    }

    #[test]
    fn passive_series_ignores_repeats_and_counts_invalid_samples() {
        let mut series = PresentedSeries::with_baseline(Some(4));
        let sample = |counter| PresentedMarkerSample {
            counter,
            nonce: None,
            display_us: Some(10),
            arrived_us: 20,
        };
        series.ingest(sample(Some(4)));
        series.ingest(sample(Some(5)));
        series.ingest(sample(Some(5)));
        series.ingest(sample(None));
        assert_eq!(series.presented_frames, 1);
        assert_eq!(series.repeated, 2);
        assert_eq!(series.invalid, 1);
    }

    #[test]
    fn passive_queue_reports_bounded_overflow() {
        let mut queue = PresentedSampleQueue::with_capacity(1);
        let sample = PresentedMarkerSample {
            counter: Some(1),
            nonce: None,
            display_us: None,
            arrived_us: 0,
        };
        queue.push(sample);
        queue.push(sample);
        assert_eq!(queue.len(), 1);
        assert!(queue.overflowed());
        assert_eq!(queue.take(), vec![sample]);
    }

    #[test]
    fn passive_series_requires_a_post_start_counter() {
        let mut series = PresentedSeries::with_baseline(Some(9));
        series.ingest(PresentedMarkerSample {
            counter: Some(9),
            nonce: None,
            display_us: Some(100),
            arrived_us: 100,
        });
        assert_eq!(series.presented_frames, 0);
        series.ingest(PresentedMarkerSample {
            counter: Some(10),
            nonce: None,
            display_us: Some(110),
            arrived_us: 111,
        });
        assert_eq!(series.presented_frames, 1);
        assert_eq!(series.first_arrived_us, Some(111));
    }

    #[test]
    fn passive_nonce_rows_are_little_endian_and_guarded() {
        let stride = 200;
        let cell = 4;
        let mut plane = vec![16; stride * 40];
        let words = [0x1100, 0x3322, 0x5544, 0x7766, 0x9988, 0xbbaa, 0xddcc, 0xffee];
        for (row, word) in std::iter::once(0x0042).chain(words).enumerate() {
            for (index, on) in crate::marker::cells(word).iter().enumerate() {
                plane[(row * cell + cell / 2) * stride + index * cell + cell / 2] =
                    if *on { 235 } else { 16 };
            }
        }
        let (_, nonce) = read_marker_nonce(&plane, stride, (0, 0), cell).expect("nonce");
        assert_eq!(nonce, *b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff");
    }

    #[test]
    fn passive_series_rejects_wrong_expected_nonce() {
        let expected = [7u8; 16];
        let mut series = PresentedSeries::with_baseline_and_nonce(Some(1), Some(expected));
        series.ingest(PresentedMarkerSample {
            counter: Some(2),
            nonce: Some([8u8; 16]),
            display_us: Some(10),
            arrived_us: 11,
        });
        assert_eq!(series.presented_frames, 0);
        assert_eq!(series.nonce_mismatch, 1);
        series.ingest(PresentedMarkerSample {
            counter: Some(2),
            nonce: Some(expected),
            display_us: Some(12),
            arrived_us: 13,
        });
        assert_eq!(series.presented_frames, 1);
    }

    #[test]
    fn passive_baseline_gap_and_backwards_are_not_frames() {
        let mut series = PresentedSeries::with_baseline(Some(100));
        let sample = |counter| PresentedMarkerSample {
            counter: Some(counter),
            nonce: None,
            display_us: Some(1000),
            arrived_us: 1001,
        };
        series.ingest(sample(103));
        assert_eq!(series.gaps, 2);
        series.ingest(sample(102));
        assert_eq!(series.reversed, 1);
        assert_eq!(series.presented_frames, 1);
        series.ingest(PresentedMarkerSample { display_us: None, ..sample(104) });
        assert_eq!(series.invalid, 1);
        assert_eq!(series.presented_frames, 1);
    }
}
