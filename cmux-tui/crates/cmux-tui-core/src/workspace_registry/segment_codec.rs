//! The stored form of a sealed journal segment: a `[r1,r2,...]` JSON array,
//! compressed. Sealing and the output cleanup write `zstd-json-v1`; readers
//! accept it and the older `gzip-json-v1`, which stays readable forever.
//!
//! gzip's 32 KiB window sees about four 7 KB records, so a segment of
//! repeated records compressed 10.6x on a real registry (43.5 GB of JSON in
//! 4.08 GB, 2026-11-09). A zstd frame's window covers the whole segment: the
//! latest 31,000 `personal.session.put` records of that registry (202 MB)
//! compressed to 365 KB at level 3 against 2.52 MB with gzip -6. Per-record
//! frames with a trained dictionary were measured too and lost (103x), so a
//! segment is one frame with no dictionary.

use std::io::Read as _;

use anyhow::Context as _;
use flate2::read::GzDecoder;

pub(crate) const GZIP_JSON_V1: &str = "gzip-json-v1";
pub(crate) const ZSTD_JSON_V1: &str = "zstd-json-v1";
/// The codec new segments are written with.
pub(crate) const SEAL_CODEC: &str = ZSTD_JSON_V1;
/// zstd level 3 compresses at hundreds of MB/s on one core, so a 16 MiB
/// segment costs tens of milliseconds on the maintenance thread; the higher
/// levels doubled the ratio of an already 500x stream for 30x the CPU.
const ZSTD_LEVEL: i32 = 3;

pub(crate) fn is_known(codec: &str) -> bool {
    codec == GZIP_JSON_V1 || codec == ZSTD_JSON_V1
}

/// `json` as a segment's stored content in [`SEAL_CODEC`].
pub(crate) fn encode(json: &[u8]) -> anyhow::Result<Vec<u8>> {
    zstd::bulk::compress(json, ZSTD_LEVEL).context("compress journal segment")
}

/// The JSON of a stored segment, at most `limit` bytes: a longer stream is
/// returned cut at `limit + 1` bytes, so the caller's length check fails.
pub(crate) fn decode(codec: &str, compressed: &[u8], limit: usize) -> anyhow::Result<Vec<u8>> {
    let mut json = Vec::with_capacity(limit);
    match codec {
        GZIP_JSON_V1 => {
            GzDecoder::new(compressed)
                .take(u64::try_from(limit)?.saturating_add(1))
                .read_to_end(&mut json)?;
        }
        ZSTD_JSON_V1 => {
            zstd::stream::read::Decoder::with_buffer(compressed)?
                .take(u64::try_from(limit)?.saturating_add(1))
                .read_to_end(&mut json)?;
        }
        _ => anyhow::bail!("unknown journal segment codec {codec}"),
    }
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_codecs_round_trip_and_zstd_wins_on_repeated_records() {
        let record = format!(
            r#"{{"kind":"personal.session.put","payload":{{"capabilities":{}}}}}"#,
            serde_json::to_string(&(0..280).map(|i| format!("cap-{i}-v1")).collect::<Vec<_>>())
                .unwrap()
        );
        let json = format!("[{}]", vec![record; 1024].join(","));
        let zstd = encode(json.as_bytes()).unwrap();
        let mut gzip =
            flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
        std::io::Write::write_all(&mut gzip, json.as_bytes()).unwrap();
        let gzip = gzip.finish().unwrap();
        println!(
            "segment_codec: json={} gzip-json-v1={} zstd-json-v1={}",
            json.len(),
            gzip.len(),
            zstd.len()
        );
        assert_eq!(decode(ZSTD_JSON_V1, &zstd, json.len()).unwrap(), json.as_bytes());
        assert_eq!(decode(GZIP_JSON_V1, &gzip, json.len()).unwrap(), json.as_bytes());
        assert!(zstd.len() * 20 < gzip.len());
        // A stream longer than its stated length comes back one byte long.
        assert_eq!(decode(ZSTD_JSON_V1, &zstd, 10).unwrap().len(), 11);
        assert!(decode("brotli-json-v1", &zstd, json.len()).is_err());
    }
}
