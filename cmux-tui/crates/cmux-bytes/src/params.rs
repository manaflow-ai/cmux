//! Every tunable of the bytes path in one place, so the hill-climb loop can
//! change one and measure it on the same harness. `Params::default()` is the
//! current best; the hill-climb writes a winner back here by PR.

/// The bytes path's tunables.
#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    /// Average content-defined chunk size in bytes (min is a quarter, max four times).
    pub cdc_avg: usize,
    /// Bits per byte at or above which a chunk is stored without trying zstd.
    pub entropy_store_bits: f64,
    /// Bytes sampled for the entropy estimate.
    pub entropy_sample: usize,
    /// A compressed payload is kept only when it is at most this fraction of the raw size.
    pub keep_ratio: f64,
    /// Lowest and highest zstd level the policy picks.
    pub min_level: i32,
    pub max_level: i32,
    /// How much faster than the link the compressor must run (all cores) for a level to be used:
    /// above 1, the link stays the bottleneck.
    pub cpu_headroom: f64,
    /// Fewest parallel streams the transport opens.
    pub streams: usize,
    /// Most streams. Between the two, the probe picks enough to fill the link: probed bandwidth
    /// over one stream's ceiling (window/RTT, or loss for TCP).
    pub max_streams: usize,
    /// Bytes of hot files sent before the background fill starts.
    pub hot_budget: u64,
    /// Whether per-kind zstd dictionaries are trained and used for small chunks.
    pub dictionaries: bool,
    /// Chunks at or under this size use a dictionary when one exists for their kind.
    pub dict_max_chunk: usize,
    /// Dictionary size in bytes.
    pub dict_bytes: usize,
    /// Dictionaries train only on links at or under this many bytes per second: training is
    /// seconds of one core before any dictionary chunk can go, which a fast link never earns back.
    pub dict_max_bandwidth: f64,
    /// The bulk lanes ride a paced, loss-tolerant carrier (Braid RFD 0164 class 3, BBR-style)
    /// instead of TCP streams. Off: the same TCP the copy uses today, so a before/after compares
    /// codec and ordering alone. The hill-climb never flips it (the model would always pick it).
    pub paced: bool,
    /// Most bytes the prefetch holds ahead of a chat's reads ("what chats could possibly use").
    pub prefetch_budget: u64,
    /// Candidates less likely than this to be read are never prefetched.
    pub prefetch_min_likelihood: f64,
    /// Idle seconds between opening a chat on the machine and its first read: what the fill
    /// carries before the first turn.
    pub prefetch_window_s: f64,
}

impl Default for Params {
    fn default() -> Self {
        Self {
            cdc_avg: 64 * 1024,
            entropy_store_bits: 7.6,
            entropy_sample: 8 * 1024,
            keep_ratio: 0.97,
            min_level: 1,
            max_level: 19,
            cpu_headroom: 1.5,
            streams: 4,
            max_streams: 16,
            hot_budget: 4 * 1024 * 1024,
            dictionaries: true,
            dict_max_chunk: 16 * 1024,
            dict_bytes: 64 * 1024,
            dict_max_bandwidth: 50e6,
            paced: false,
            prefetch_budget: 64 << 20,
            prefetch_min_likelihood: 0.02,
            prefetch_window_s: 3.0,
        }
    }
}

impl Params {
    /// `key=value` pairs, as the harness and the hill-climb pass them.
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), String> {
        fn p<T: std::str::FromStr>(v: &str) -> Result<T, String> {
            v.parse().map_err(|_| format!("bad value {v:?}"))
        }
        match key {
            "cdc_avg" => self.cdc_avg = p(value)?,
            "entropy_store_bits" => self.entropy_store_bits = p(value)?,
            "entropy_sample" => self.entropy_sample = p(value)?,
            "keep_ratio" => self.keep_ratio = p(value)?,
            "min_level" => self.min_level = p(value)?,
            "max_level" => self.max_level = p(value)?,
            "cpu_headroom" => self.cpu_headroom = p(value)?,
            "streams" => self.streams = p(value)?,
            "max_streams" => self.max_streams = p(value)?,
            "hot_budget" => self.hot_budget = p(value)?,
            "dictionaries" => self.dictionaries = p(value)?,
            "dict_max_chunk" => self.dict_max_chunk = p(value)?,
            "dict_bytes" => self.dict_bytes = p(value)?,
            "dict_max_bandwidth" => self.dict_max_bandwidth = p(value)?,
            "paced" => self.paced = p(value)?,
            "prefetch_budget" => self.prefetch_budget = p(value)?,
            "prefetch_min_likelihood" => self.prefetch_min_likelihood = p(value)?,
            "prefetch_window_s" => self.prefetch_window_s = p(value)?,
            _ => return Err(format!("unknown param {key}")),
        }
        Ok(())
    }

    /// All params as `key=value`, in a fixed order (the findings log and the hill-climb state).
    pub fn pairs(&self) -> Vec<(&'static str, String)> {
        vec![
            ("cdc_avg", self.cdc_avg.to_string()),
            ("entropy_store_bits", self.entropy_store_bits.to_string()),
            ("entropy_sample", self.entropy_sample.to_string()),
            ("keep_ratio", self.keep_ratio.to_string()),
            ("min_level", self.min_level.to_string()),
            ("max_level", self.max_level.to_string()),
            ("cpu_headroom", self.cpu_headroom.to_string()),
            ("streams", self.streams.to_string()),
            ("max_streams", self.max_streams.to_string()),
            ("hot_budget", self.hot_budget.to_string()),
            ("dictionaries", self.dictionaries.to_string()),
            ("dict_max_chunk", self.dict_max_chunk.to_string()),
            ("dict_bytes", self.dict_bytes.to_string()),
            ("dict_max_bandwidth", self.dict_max_bandwidth.to_string()),
            ("paced", self.paced.to_string()),
            ("prefetch_budget", self.prefetch_budget.to_string()),
            ("prefetch_min_likelihood", self.prefetch_min_likelihood.to_string()),
            ("prefetch_window_s", self.prefetch_window_s.to_string()),
        ]
    }
}
