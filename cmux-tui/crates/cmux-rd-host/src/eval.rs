//! Opt-in local benchmark evidence, never a production transport policy.
use serde_json::{json, Value};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

const WIDTH: usize = 128;
const HEIGHT: usize = 64;
const X: usize = 128;
const Y: usize = 64;
const MAX_SAMPLES: usize = 5;
const MAX_AU: usize = 1_000_000;
const MAX_TIMINGS: usize = 120_000;

/// Bounded decode evidence. The adapter joins release_us to the host's true
/// captured-frame timestamp; the protocol timestamp alone is encode-start.
#[derive(Default)]
pub struct DecodeLog {
    pub records: Vec<Value>,
    pub truncated: bool,
}

impl DecodeLog {
    pub fn record(&mut self, frame: u32, release_us: u64, decoded_us: u64) {
        if self.records.len() == MAX_TIMINGS {
            self.truncated = true;
            return;
        }
        self.records
            .push(json!({"frame_id":frame,"release_us":release_us,"decoded_us":decoded_us}));
    }
}

pub fn roi(luma: &[u8], stride: usize) -> Option<Vec<u8>> {
    if stride < X + WIDTH || luma.len() < stride.checked_mul(Y + HEIGHT)? {
        return None;
    }
    Some(
        (Y..Y + HEIGHT)
            .flat_map(|y| luma[y * stride + X..y * stride + X + WIDTH].iter().copied())
            .collect(),
    )
}

pub struct Quality {
    dir: PathBuf,
    #[cfg(target_os = "macos")]
    sources: usize,
    #[cfg(target_os = "macos")]
    last_source_us: Option<u64>,
    pub samples: Vec<Value>,
}

impl Quality {
    pub fn from_env() -> Option<Self> {
        let dir = PathBuf::from(std::env::var_os("CMUX_RD_EVAL_QUALITY")?);
        if !dir.is_absolute() || !dir.is_dir() {
            return None;
        }
        Some(Self {
            dir,
            #[cfg(target_os = "macos")]
            sources: 0,
            #[cfg(target_os = "macos")]
            last_source_us: None,
            samples: Vec::new(),
        })
    }

    #[cfg(target_os = "macos")]
    pub fn wants_source(&self, capture_us: u64, au: &[u8]) -> bool {
        self.sources < MAX_SAMPLES
            && !au.is_empty()
            && au.len() <= MAX_AU
            && self.last_source_us.is_none_or(|last| capture_us.saturating_sub(last) >= 2_000_000)
    }

    #[cfg(target_os = "macos")]
    pub fn source(&mut self, capture_us: u64, au: &[u8], pixels: &[u8]) {
        if pixels.len() != WIDTH * HEIGHT || !self.wants_source(capture_us, au) {
            return;
        }
        let stem = self.dir.join(capture_us.to_string());
        let result = (|| -> std::io::Result<()> {
            write_new(&stem.with_extension("au"), au)?;
            write_new(&stem.with_extension("source.y8"), pixels)?;
            write_new(
                &stem.with_extension("source.json"),
                json!({"capture_us":capture_us,
                "roi":[X,Y,WIDTH,HEIGHT],"access_unit_bytes":au.len()})
                .to_string()
                .as_bytes(),
            )
        })();
        // Bound attempted writes too, including a full disk or an old sample collision.
        self.sources += 1;
        self.last_source_us = Some(capture_us);
        if let Err(error) = result {
            eprintln!("eval quality source: {error}");
        }
    }

    pub fn decoded(&mut self, frame_id: u64, capture_us: u64, au: &[u8], pixels: &[u8]) {
        if self.samples.len() >= MAX_SAMPLES || pixels.len() != WIDTH * HEIGHT || au.len() > MAX_AU
        {
            return;
        }
        let stem = self.dir.join(capture_us.to_string());
        let result = (|| -> Option<Value> {
            let meta: Value =
                serde_json::from_slice(&std::fs::read(stem.with_extension("source.json")).ok()?)
                    .ok()?;
            if meta["capture_us"].as_u64()? != capture_us
                || std::fs::read(stem.with_extension("au")).ok()? != au
            {
                return None;
            }
            let source = std::fs::read(stem.with_extension("source.y8")).ok()?;
            if source.len() != pixels.len() {
                return None;
            }
            let squared: u64 = source
                .iter()
                .zip(pixels)
                .map(|(&a, &b)| (i64::from(a) - i64::from(b)).pow(2) as u64)
                .sum();
            let mse = squared as f64 / pixels.len() as f64;
            let sample = json!({"frame_id":frame_id,"capture_us":capture_us,"identity_verified":true,
                "identity_method":"capture timestamp and exact encoded access-unit bytes", "roi":[X,Y,WIDTH,HEIGHT],
                "squared_error_sum":squared,"pixels":pixels.len(),"mse":mse,
                "psnr_db":if mse == 0.0 { None } else { Some(10.0*(255.0_f64.powi(2)/mse).log10()) }});
            write_new(&stem.with_extension("decoded.y8"), pixels).ok()?;
            write_new(&stem.with_extension("quality.json"), sample.to_string().as_bytes()).ok()?;
            Some(sample)
        })();
        if let Some(sample) = result {
            self.samples.push(sample);
        }
    }
}

fn write_new(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    OpenOptions::new().write(true).create_new(true).open(path)?.write_all(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_evidence_is_bounded_and_retains_frame_identity() {
        let mut log = DecodeLog::default();
        log.record(7, 12, 34);
        assert_eq!(log.records[0]["frame_id"], 7);
        assert_eq!(log.records[0]["release_us"], 12);
        assert_eq!(log.records[0]["decoded_us"], 34);
        log.records.resize(MAX_TIMINGS, Value::Null);
        log.record(8, 13, 35);
        assert!(log.truncated);
        assert_eq!(log.records.len(), MAX_TIMINGS);
    }

    #[test]
    fn quality_crop_honors_stride_and_rejects_short_planes() {
        let mut pixels = vec![0; 300 * 128];
        pixels[64 * 300 + 128] = 99;
        let crop = roi(&pixels, 300).unwrap();
        assert_eq!(crop.len(), 8192);
        assert_eq!(crop[0], 99);
        assert!(roi(&pixels[..100], 300).is_none());
        assert!(roi(&pixels, 127).is_none());
    }
}
