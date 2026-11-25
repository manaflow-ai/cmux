//! The workload: tabs, favicons, thumbnails and terminal screens.

use super::Res;
use cmux_tab_snapshots::{
    FaviconInput, ImageInput, Kind, Mime, Observation, Producer, ScreenInput,
};
use std::path::{Path, PathBuf};

/// Assumed: 38,000 bytes at 516x688 scaled by area to 576x768.
pub const ASSUMED_THUMB_BYTES: usize = 47_351;
pub const ASSUMED_THUMB_W: u32 = 576;
pub const ASSUMED_THUMB_H: u32 = 768;
pub const ASSUMED_FAVICON_BYTES: usize = 2_200;
pub const SCREEN_COLS: u32 = 120;
pub const SCREEN_ROWS: u32 = 40;

pub struct Rng(u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub fn bytes(seed: u64, len: usize) -> Vec<u8> {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        (0..len).map(|_| (rng.next() >> 56) as u8).collect()
    }

    pub fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        let i = (self.next() % items.len().max(1) as u64) as usize;
        items.get(i).copied().unwrap_or_default()
    }
}

/// A 120x40 terminal screen of the kind a cmux tab shows: prompts, build
/// and test output, a directory listing. Trailing spaces are trimmed.
pub fn screen_text(seed: u64) -> String {
    let mut rng = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03) | 1);
    let crates = ["serde", "tokio", "cmux-link", "sha2", "hex", "cmux-tab-snapshots", "anyhow"];
    let tests = ["wire::tests::round_trips", "store::tests::dedupe", "session::tests::resume"];
    let files = ["Cargo.toml", "src", "README.md", "build.rs", "examples", "tests", "bench"];
    let mut lines = Vec::new();
    while lines.len() < SCREEN_ROWS as usize {
        let n = rng.next();
        let line = match n % 6 {
            0 => {
                format!("leo@mac ~/src/cmux (feat-cmux-next) $ cargo test -p {}", rng.pick(&crates))
            }
            1 => format!("   Compiling {} v0.{}.{}", rng.pick(&crates), n % 9, n % 31),
            2 => format!("test {}_{} ... ok", rng.pick(&tests), n % 97),
            3 => format!(
                "-rw-r--r--  1 leo  staff  {:>6} Nov 22 17:{:02} {}",
                n % 90_000,
                n % 60,
                rng.pick(&files)
            ),
            4 => format!(
                "warning: unused variable: `frame_{}`  --> src/session.rs:{}:{}",
                n % 50,
                n % 400,
                n % 80
            ),
            _ => format!(
                "    Finished `test` profile [optimized + debuginfo] target(s) in {}.{:02}s",
                n % 40,
                n % 100
            ),
        };
        lines.push(line.chars().take(SCREEN_COLS as usize).collect::<String>());
    }
    lines.join("\n")
}

pub struct Real {
    pub mime: Mime,
    pub bytes: Vec<u8>,
    pub size: Option<(u32, u32)>,
}

pub fn read_dir_files(dir: &Path) -> Res<Vec<Real>> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file())
        .collect();
    paths.sort();
    let mut out = Vec::new();
    for path in paths {
        let bytes = std::fs::read(&path)?;
        let mime = if bytes.starts_with(b"\x89PNG") { Mime::Png } else { Mime::Jpeg };
        let size = image_size(&bytes);
        out.push(Real { mime, bytes, size });
    }
    if out.is_empty() {
        return Err(format!("{} has no files", dir.display()).into());
    }
    Ok(out)
}

/// Width and height from a PNG IHDR or a JPEG SOF marker.
pub fn image_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let be32 = |at: usize| -> Option<u32> {
        Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
    };
    let be16 = |at: usize| -> Option<u32> {
        Some(u32::from(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
    };
    if bytes.starts_with(b"\x89PNG") {
        return Some((be32(16)?, be32(20)?));
    }
    let mut at = 2;
    while *bytes.get(at)? == 0xFF {
        let marker = *bytes.get(at + 1)?;
        let len = be16(at + 2)? as usize;
        if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
            return Some((be16(at + 7)?, be16(at + 5)?));
        }
        at += 2 + len;
    }
    None
}

pub struct Workload {
    pub tabs: usize,
    pub favicons_distinct: usize,
    pub terminal_every: usize,
    pub thumbs: Option<Vec<Real>>,
    pub favicons: Option<Vec<Real>>,
}

impl Workload {
    pub fn is_terminal(&self, i: usize) -> bool {
        self.terminal_every > 0 && i % self.terminal_every == self.terminal_every - 1
    }

    /// What tab `i` shows at `version` (a changed tab has a new version).
    pub fn observe(&self, i: usize, version: u64) -> Observation {
        let id = format!("tab-{i:03}");
        let seed = (i as u64 + 1) * 1000 + version;
        if self.is_terminal(i) {
            return Observation {
                tab_id: id,
                title: format!("zsh: ~/src/project-{i}"),
                kind: Kind::Terminal,
                favicon: None,
                thumb: None,
                screen: Some(ScreenInput {
                    text: screen_text(seed),
                    cols: SCREEN_COLS,
                    rows: SCREEN_ROWS,
                }),
                frame: None,
                captured_at_ms: 1_795_000_000_000 + version as i64,
            };
        }
        let fav_index = i % self.favicons_distinct.max(1);
        let favicon = match &self.favicons {
            Some(real) => real.get(fav_index % real.len()).map(|r| (r.mime, r.bytes.clone())),
            None => Some((Mime::Png, Rng::bytes(7_000 + fav_index as u64, ASSUMED_FAVICON_BYTES))),
        };
        let thumb = match &self.thumbs {
            Some(real) => real.get((i + version as usize) % real.len()).map(|r| {
                let (w, h) = r.size.unwrap_or((ASSUMED_THUMB_W, ASSUMED_THUMB_H));
                ImageInput { mime: r.mime, bytes: r.bytes.clone(), width: w, height: h }
            }),
            None => Some(ImageInput {
                mime: Mime::Jpeg,
                bytes: Rng::bytes(seed, ASSUMED_THUMB_BYTES),
                width: ASSUMED_THUMB_W,
                height: ASSUMED_THUMB_H,
            }),
        };
        Observation {
            tab_id: id,
            title: format!("Example page {i} - a typical page title of some length"),
            kind: Kind::Browser,
            favicon: favicon.map(|(mime, bytes)| FaviconInput { mime, bytes }),
            thumb,
            screen: None,
            frame: None,
            captured_at_ms: 1_795_000_000_000 + version as i64,
        }
    }

    pub fn producer(&self) -> Producer {
        let mut p = Producer::new("e1", 1_795_000_000_000, 256, 64);
        for i in 0..self.tabs {
            p.observe(self.observe(i, 0));
        }
        p
    }
}
