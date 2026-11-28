//! A cheap estimate of whether a chunk can shrink: order-0 byte entropy over
//! a few evenly spaced windows. Random, encrypted and compressed data reads
//! near 8 bits per byte; source text reads 4 to 5.5.

/// Counts one byte (a u8 always indexes the 256-entry table).
fn bump(counts: &mut [u32; 256], b: u8) {
    if let Some(c) = counts.get_mut(usize::from(b)) {
        *c += 1;
    }
}

/// Bits per byte of `bytes`, sampled from up to `sample` bytes in four windows.
pub fn bits_per_byte(bytes: &[u8], sample: usize) -> f64 {
    if bytes.is_empty() {
        return 0.0;
    }
    let mut counts = [0u32; 256];
    let mut total = 0u32;
    if bytes.len() <= sample {
        for b in bytes {
            bump(&mut counts, *b);
        }
        total = bytes.len() as u32;
    } else {
        let window = (sample / 4).max(1);
        let step = (bytes.len() - window) / 3;
        for i in 0..4 {
            for b in bytes.get(i * step..i * step + window).unwrap_or_default() {
                bump(&mut counts, *b);
            }
            total += window as u32;
        }
    }
    let total = f64::from(total);
    // A small sample of random bytes cannot show 8 bits: with n samples of 256 symbols the
    // plug-in estimate tops out near log2(n). Correct with Miller-Madow so the threshold means
    // the same at any sample size.
    let mut h = 0.0;
    let mut seen = 0u32;
    for c in counts {
        if c > 0 {
            seen += 1;
            let p = f64::from(c) / total;
            h -= p * p.log2();
        }
    }
    (h + (f64::from(seen) - 1.0) / (2.0 * total * std::f64::consts::LN_2)).min(8.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_reads_near_eight_and_text_low() {
        let mut x = 0x2545F4914F6CDD1Du64;
        let random: Vec<u8> = (0..1 << 20)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        assert!(bits_per_byte(&random, 8192) > 7.8, "{}", bits_per_byte(&random, 8192));
        let text = b"fn main() { println!(\"hello\"); }\n".repeat(1000);
        assert!(bits_per_byte(&text, 8192) < 5.5);
    }
}
