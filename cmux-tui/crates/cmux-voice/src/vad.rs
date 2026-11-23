//! Local voice detection for the cascade's barge-in: when the person starts speaking over a
//! reading, the reading stops ([`crate::relay`]). Pure: frames in, edges out; no clock.
//!
//! An energy detector with an adaptive noise floor. Each frame's loudness (RMS, in dBFS) is
//! compared with the floor plus a margin; speech starts after `onset` of loud audio in a row and
//! stops after `hangover` of quiet. The floor follows quiet frames quickly and loud ones slowly,
//! so a fan or a hum becomes the floor instead of speech. While the agent's voice plays through
//! the speakers, the app passes the echo-cancelled microphone (the system's voice processing),
//! so the agent does not interrupt itself.

/// What a frame changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edge {
    SpeechStarted,
    SpeechStopped,
}

/// The detector's tuning.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VadConfig {
    pub sample_rate: u32,
    /// Loud audio in a row before speech starts, in ms.
    pub onset_ms: u32,
    /// Quiet audio in a row before speech stops, in ms.
    pub hangover_ms: u32,
    /// How far above the floor counts as speech, in dB.
    pub margin_db: f32,
    /// Nothing quieter than this is speech, whatever the floor, in dBFS.
    pub min_speech_dbfs: f32,
}

impl Default for VadConfig {
    /// 16 kHz; 150 ms to start (a word, not a click), 700 ms to stop (a pause between words is
    /// not the end), 12 dB above the floor, never below -50 dBFS.
    fn default() -> Self {
        Self {
            sample_rate: 16_000,
            onset_ms: 150,
            hangover_ms: 700,
            margin_db: 12.0,
            min_speech_dbfs: -50.0,
        }
    }
}

/// The floor a fresh detector assumes (a quiet room).
const INITIAL_FLOOR_DBFS: f32 = -60.0;
/// Silence, as dBFS.
const SILENCE_DBFS: f32 = -100.0;

/// One detector, fed the microphone in frames of any size.
#[derive(Debug, Clone, PartialEq)]
pub struct Vad {
    config: VadConfig,
    floor_dbfs: f32,
    speaking: bool,
    /// Samples of loud (while quiet) or quiet (while speaking) audio in a row.
    run: u64,
}

impl Vad {
    pub fn new(config: VadConfig) -> Self {
        Self { config, floor_dbfs: INITIAL_FLOOR_DBFS, speaking: false, run: 0 }
    }

    pub fn speaking(&self) -> bool {
        self.speaking
    }

    /// The noise floor now, in dBFS.
    pub fn floor_dbfs(&self) -> f32 {
        self.floor_dbfs
    }

    fn samples(&self, ms: u32) -> u64 {
        u64::from(self.config.sample_rate) * u64::from(ms) / 1000
    }

    /// Feeds one frame of PCM16 mono; the edge it caused, if any.
    pub fn push(&mut self, frame: &[i16]) -> Option<Edge> {
        if frame.is_empty() {
            return None;
        }
        let level = dbfs(frame);
        let threshold = (self.floor_dbfs + self.config.margin_db).max(self.config.min_speech_dbfs);
        let loud = level >= threshold;
        // Quiet frames pull the floor down fast; loud ones raise it slowly, and not at all while
        // the person speaks (their voice is not the room).
        if !loud {
            self.floor_dbfs += (level - self.floor_dbfs) * 0.2;
        } else if !self.speaking {
            self.floor_dbfs += (level - self.floor_dbfs) * 0.01;
        }
        let n = frame.len() as u64;
        if self.speaking == loud {
            self.run = 0;
            return None;
        }
        self.run += n;
        if !self.speaking && self.run >= self.samples(self.config.onset_ms) {
            self.speaking = true;
            self.run = 0;
            return Some(Edge::SpeechStarted);
        }
        if self.speaking && self.run >= self.samples(self.config.hangover_ms) {
            self.speaking = false;
            self.run = 0;
            return Some(Edge::SpeechStopped);
        }
        None
    }
}

/// The RMS loudness of `frame` in dBFS (full scale = 0).
pub fn dbfs(frame: &[i16]) -> f32 {
    if frame.is_empty() {
        return SILENCE_DBFS;
    }
    let sum: f64 = frame.iter().map(|&s| f64::from(s) * f64::from(s)).sum();
    #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
    let rms = (sum / frame.len() as f64).sqrt() / f64::from(i16::MAX);
    if rms <= 0.0 {
        return SILENCE_DBFS;
    }
    #[allow(clippy::cast_possible_truncation)]
    let db = (20.0 * rms.log10()) as f32;
    db.max(SILENCE_DBFS)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 20 ms of a tone at `amplitude` (0..=1 of full scale).
    fn frame(amplitude: f64) -> Vec<i16> {
        (0..320)
            .map(|i| {
                let t = f64::from(i) / 16_000.0;
                #[allow(clippy::cast_possible_truncation)]
                let s = (amplitude
                    * f64::from(i16::MAX)
                    * (2.0 * std::f64::consts::PI * 220.0 * t).sin())
                    as i16;
                s
            })
            .collect()
    }

    fn feed(vad: &mut Vad, amplitude: f64, frames: usize) -> Vec<Edge> {
        (0..frames).filter_map(|_| vad.push(&frame(amplitude))).collect()
    }

    #[test]
    fn levels() {
        assert_eq!(dbfs(&[]), SILENCE_DBFS);
        assert_eq!(dbfs(&[0; 10]), SILENCE_DBFS);
        let full = dbfs(&[i16::MAX; 10]);
        assert!(full.abs() < 0.01, "{full}");
        let tone = dbfs(&frame(0.1));
        assert!((tone - -23.0).abs() < 0.5, "{tone}"); // -20 dB, minus 3 dB for a sine's RMS
    }

    #[test]
    fn speech_starts_after_onset_and_stops_after_hangover() {
        let mut vad = Vad::new(VadConfig::default());
        assert!(feed(&mut vad, 0.0005, 50).is_empty());
        // 150 ms is 7.5 frames of 20 ms: the eighth loud frame starts it.
        assert!(feed(&mut vad, 0.1, 7).is_empty());
        assert_eq!(feed(&mut vad, 0.1, 1), vec![Edge::SpeechStarted]);
        assert!(vad.speaking());
        // A short pause between words is not the end.
        assert!(feed(&mut vad, 0.0005, 20).is_empty());
        assert!(feed(&mut vad, 0.1, 5).is_empty());
        // 700 ms of quiet is 35 frames.
        assert!(feed(&mut vad, 0.0005, 34).is_empty());
        assert_eq!(feed(&mut vad, 0.0005, 1), vec![Edge::SpeechStopped]);
    }

    #[test]
    fn a_click_is_not_speech() {
        let mut vad = Vad::new(VadConfig::default());
        feed(&mut vad, 0.0005, 20);
        assert!(feed(&mut vad, 0.5, 3).is_empty());
        assert!(feed(&mut vad, 0.0005, 20).is_empty());
        assert!(!vad.speaking());
    }

    #[test]
    fn a_steady_hum_becomes_the_floor() {
        let mut vad = Vad::new(VadConfig::default());
        // A hum 20 dB over the initial floor starts as "speech" but the floor catches up while
        // speech has stopped; after that the hum is the room.
        let hum = 0.003;
        let edges = feed(&mut vad, hum, 1500);
        let last = edges.last().copied();
        assert!(last.is_none() || last == Some(Edge::SpeechStopped), "{edges:?}");
        assert!(!vad.speaking());
        assert!(vad.floor_dbfs() > -55.0, "{}", vad.floor_dbfs());
        // Speech over the hum still counts.
        let mut edges = feed(&mut vad, 0.2, 10);
        edges.dedup();
        assert_eq!(edges, vec![Edge::SpeechStarted]);
    }

    #[test]
    fn quiet_speech_under_the_minimum_never_counts() {
        let mut vad = Vad::new(VadConfig::default());
        assert!(feed(&mut vad, 0.002, 200).is_empty()); // about -57 dBFS
    }
}
