//! Counter and window checks for the compositor observer. These deliberately do not
//! know which remote-display protocol rendered the window.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

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

    #[test]
    fn observe_reports_nearest_rank_over_all_samples() {
        assert_eq!(percentiles(&[]), None);
        assert_eq!(percentiles(&[9000, 1000, 3000, 2000]), Some((2.0, 9.0)));
        assert_eq!(percentiles(&[3500]), Some((3.5, 3.5)));
    }
}
