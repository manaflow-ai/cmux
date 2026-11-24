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
#[path = "observe_tests.rs"]
mod tests;
