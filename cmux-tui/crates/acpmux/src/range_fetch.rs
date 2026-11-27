//! Range-parallel download of one large file (RFD 0067, build item 3).
//!
//! On a Freestyle VM one IPv4 stream from GitHub held 0.6-32 Mbit/s while 16 range requests together
//! gave 11x (measured, RFD 0067), because each flow loses packets on its own. [`fetch_to_file`]
//! probes the URL with a one-byte range request, follows redirects once (the signed
//! `objects.githubusercontent.com` URL of a release asset is then used for every range, and a slice
//! that the signed URL refuses with 401, 403 or 410 goes back to `url` for a fresh one), and, when the
//! server honours ranges and the file is at least [`Options::threshold`] bytes, reads `ranges`
//! slices at once into one file at their own offsets. A server that ignores `Range`, or a small
//! file, is read as one stream from the probe's own response; an empty file (416 to the probe) is
//! read the same way. Every slice's `Content-Range` and length are checked against what was asked
//! for, the whole file's length against the probe's, and the sha256 against
//! `Options::sha256` when one is given; the file appears at `dest` only after all of that, renamed
//! from `dest.part`.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

/// Ranges read at once by default (the 11x measurement of RFD 0067 was at 16).
pub const DEFAULT_RANGES: usize = 16;
/// Files under this many bytes are one stream: the probe costs more than ranges save.
pub const DEFAULT_THRESHOLD: u64 = 8 * 1024 * 1024;
/// A body that sends nothing for this long is given up on (and its slice retried).
const STALL: Duration = Duration::from_secs(30);
/// Tries per slice; a retry resumes after the bytes the slice already wrote.
const ATTEMPTS: usize = 4;

#[derive(Clone, Debug)]
pub struct Options {
    /// Parallel ranges for a file at or above `threshold`; 1 reads one stream always.
    pub ranges: usize,
    pub threshold: u64,
    /// Lowercase hex sha256 the file must have.
    pub sha256: Option<String>,
    /// None: split into `ranges` at once. Some: read one stream first, and only when it is slow
    /// split what is left (the fast path stays one stream).
    pub adaptive: Option<Adaptive>,
}

/// When a single stream is given up on for ranges.
#[derive(Clone, Copy, Debug)]
pub struct Adaptive {
    /// How long the stream runs before its rate is judged.
    pub after: Duration,
    /// A stream under this many bytes a second at that point is slow.
    pub min_bytes_per_sec: u64,
}

impl Adaptive {
    /// About 3 s, under 2 MB/s (RFD 0067: IPv4 on a Freestyle VM held 0.1-4 MB/s on one stream).
    pub const FALLBACK: Self = Self { after: Duration::from_secs(3), min_bytes_per_sec: 2_000_000 };
}

impl Default for Options {
    fn default() -> Self {
        Self { ranges: DEFAULT_RANGES, threshold: DEFAULT_THRESHOLD, sha256: None, adaptive: None }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub bytes: u64,
    /// 1 for a single stream.
    pub ranges: usize,
    pub elapsed: Duration,
}

/// A client that follows redirects and sends no cmux headers (the URL is a third party's).
pub fn client() -> Result<reqwest::Client> {
    // The workspace builds reqwest with `rustls-no-provider` (as `managed_codex::install`).
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::client_builder("acpmux::range_fetch")
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::limited(10))
        .connect_timeout(Duration::from_secs(15))
        .build()
        .context("build fetch client")
}

/// `(start, end)` inclusive byte slices covering `total` bytes in at most `n` near-equal parts.
fn split(total: u64, n: usize) -> Vec<(u64, u64)> {
    let n = (n.max(1) as u64).min(total.max(1));
    let size = total.div_ceil(n);
    (0..n)
        .map(|i| (i * size, ((i + 1) * size).min(total) - 1))
        .filter(|(start, end)| start <= end)
        .collect()
}

/// The total of a `Content-Range: bytes 0-0/TOTAL` header.
fn content_range_total(value: &str) -> Option<u64> {
    value.rsplit('/').next()?.trim().parse().ok()
}

/// The `(first, last)` bytes of a `Content-Range: bytes FIRST-LAST/TOTAL` header.
fn content_range_span(value: &str) -> Option<(u64, u64)> {
    let span = value.trim().strip_prefix("bytes")?.trim().split('/').next()?;
    let (first, last) = span.split_once('-')?;
    Some((first.trim().parse().ok()?, last.trim().parse().ok()?))
}

/// A signed redirect target that has expired (or was revoked) answers one of these.
fn signed_url_refused(status: reqwest::StatusCode) -> bool {
    matches!(status.as_u16(), 401 | 403 | 410)
}

/// Read `url` into `dest`; see the module doc.
pub async fn fetch_to_file(
    client: &reqwest::Client,
    url: &str,
    dest: &Path,
    opts: &Options,
) -> Result<Report> {
    let started = Instant::now();
    let part = part_path(dest);
    let result = fetch_part(client, url, &part, opts).await;
    let (bytes, ranges) = match result {
        Ok(done) => done,
        Err(e) => {
            let _ = std::fs::remove_file(&part);
            return Err(e);
        }
    };
    if let Some(want) = &opts.sha256 {
        let got = sha256_file(&part).await?;
        if !got.eq_ignore_ascii_case(want) {
            let _ = std::fs::remove_file(&part);
            bail!("{url} has sha256 {got}, not {want}, so it is not kept");
        }
    }
    std::fs::rename(&part, dest).with_context(|| format!("writing {}", dest.display()))?;
    Ok(Report { bytes, ranges, elapsed: started.elapsed() })
}

fn part_path(dest: &Path) -> PathBuf {
    let mut name = dest.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".part");
    dest.with_file_name(name)
}

async fn sha256_file(path: &Path) -> Result<String> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let mut file = std::fs::File::open(&path)?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                return Ok(format!("{:x}", hasher.finalize()));
            }
            hasher.update(buf.get(..n).unwrap_or_default());
        }
    })
    .await?
}

async fn fetch_part(
    client: &reqwest::Client,
    url: &str,
    part: &Path,
    opts: &Options,
) -> Result<(u64, usize)> {
    // One request does the probe: a one-byte range. 206 says ranges work and the total; 200 is the
    // whole body of a server that ignores Range, read below as the single stream.
    let probe = client
        .get(url)
        .header(reqwest::header::RANGE, "bytes=0-0")
        .send()
        .await
        .with_context(|| format!("GET {url}"))?;
    let status = probe.status();
    let final_url = probe.url().to_string();
    let total = if status == reqwest::StatusCode::PARTIAL_CONTENT {
        probe
            .headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(content_range_total)
    } else {
        None
    };
    match total {
        Some(total) if opts.ranges > 1 && total >= opts.threshold && total > 0 => {
            drop(probe);
            let file = std::fs::File::create(part)
                .with_context(|| format!("creating {}", part.display()))?;
            file.set_len(total)?;
            drop(file);
            // Adaptive: one stream first, judged after `after`; what it read is kept.
            let mut from = 0;
            if let Some(adaptive) = opts.adaptive {
                from = head_stream(client, &final_url, part, total, adaptive).await?;
            }
            let mut slices = Vec::new();
            if from < total {
                slices = split(total - from, opts.ranges)
                    .into_iter()
                    .map(|(s, e)| (s + from, e + from))
                    .collect();
            }
            let jobs = slices.iter().map(|&(s, e)| read_slice(client, url, &final_url, part, s, e));
            futures::future::try_join_all(jobs).await?;
            let len = std::fs::metadata(part)?.len();
            if len != total {
                bail!("{url} was {total} bytes, the file has {len}");
            }
            Ok((total, slices.len().max(1)))
        }
        _ => {
            // Single stream. A 206 probe is one byte, so ask again; a 416 probe is an empty file
            // (byte 0 does not exist), asked again without Range; a 200 probe is the body.
            let resp = if status == reqwest::StatusCode::PARTIAL_CONTENT
                || status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE
            {
                drop(probe);
                client.get(&final_url).send().await.with_context(|| format!("GET {url}"))?
            } else {
                probe
            };
            if !resp.status().is_success() {
                bail!("GET {url}: {}", resp.status());
            }
            let want = resp.content_length();
            let n = stream_to(resp, part, 0).await?;
            if let Some(want) = want
                && n != want
            {
                bail!("{url} sent {n} bytes of {want}");
            }
            Ok((n, 1))
        }
    }
}

/// Read `url` from byte 0 as one stream into `part`. At `adaptive.after` a stream that is
/// slower than the limit is dropped; either way the bytes written (all of them from 0) are
/// returned, `total` when the stream finished. A stream that fails or ends early also returns
/// what it wrote, and the caller reads the rest.
async fn head_stream(
    client: &reqwest::Client,
    url: &str,
    part: &Path,
    total: u64,
    adaptive: Adaptive,
) -> Result<u64> {
    // A server that does not even answer by the judging point is slow: ranges read it all.
    let request = client.get(url).header(reqwest::header::RANGE, "bytes=0-").send();
    let Ok(Ok(mut resp)) = tokio::time::timeout(adaptive.after, request).await else {
        return Ok(0);
    };
    if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return Ok(0);
    }
    let started = Instant::now();
    let mut file = tokio::fs::OpenOptions::new().write(true).truncate(false).open(part).await?;
    let mut written = 0u64;
    let mut judged = false;
    while written < total {
        // Until the stream is judged, wait no longer than the judging point: a stream that sends
        // nothing at all is the slowest kind and goes to ranges at `after`, not after STALL.
        let wait = if judged {
            STALL
        } else {
            adaptive.after.saturating_sub(started.elapsed()).max(Duration::from_millis(1))
        };
        let chunk = match tokio::time::timeout(wait, resp.chunk()).await {
            Ok(Ok(Some(chunk))) => chunk,
            Err(_) if !judged => {
                judged = true;
                let elapsed = started.elapsed().as_secs_f64();
                if (written as f64) < adaptive.min_bytes_per_sec as f64 * elapsed {
                    break;
                }
                continue;
            }
            _ => break,
        };
        let take = (chunk.len() as u64).min(total - written) as usize;
        file.write_all(chunk.get(..take).unwrap_or_default()).await?;
        written += take as u64;
        let elapsed = started.elapsed();
        if !judged && elapsed >= adaptive.after {
            judged = true;
            if (written as f64) < adaptive.min_bytes_per_sec as f64 * elapsed.as_secs_f64() {
                break;
            }
        }
    }
    file.flush().await?;
    Ok(written)
}

/// Write the body of `resp` into `part` from `offset`; the bytes written.
async fn stream_to(mut resp: reqwest::Response, part: &Path, offset: u64) -> Result<u64> {
    let mut file =
        tokio::fs::OpenOptions::new().write(true).create(true).truncate(false).open(part).await?;
    file.seek(std::io::SeekFrom::Start(offset)).await?;
    let mut written = 0u64;
    loop {
        match tokio::time::timeout(STALL, resp.chunk()).await {
            Err(_) => bail!("no bytes for {}s", STALL.as_secs()),
            Ok(Err(e)) => return Err(e.into()),
            Ok(Ok(None)) => break,
            Ok(Ok(Some(chunk))) => {
                file.write_all(&chunk).await?;
                written += chunk.len() as u64;
            }
        }
    }
    file.flush().await?;
    Ok(written)
}

/// Bytes `start..=end` of `signed` into `part` at `start`, retried from where it stopped. When the
/// signed URL is refused (it expired during a slow download), later tries go to `origin`, whose
/// redirect hands out a fresh one.
async fn read_slice(
    client: &reqwest::Client,
    origin: &str,
    signed: &str,
    part: &Path,
    start: u64,
    end: u64,
) -> Result<()> {
    let mut at = start;
    let mut last = anyhow!("no attempt");
    let mut url = signed;
    for attempt in 0..ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
        }
        match read_once(client, url, part, at, end).await {
            Ok(n) => {
                at += n;
                if at > end {
                    return Ok(());
                }
                last = anyhow!("range {start}-{end} ended at {at}");
            }
            Err((n, e)) => {
                at += n;
                if e.downcast_ref::<Refused>().is_some() {
                    url = origin;
                }
                last = e;
            }
        }
    }
    Err(last.context(format!("range {start}-{end} of {origin}")))
}

/// A range request the URL refused (an expired signed URL).
#[derive(Debug)]
struct Refused(reqwest::StatusCode);

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "range request refused with {}", self.0)
    }
}

impl std::error::Error for Refused {}

/// One try of `at..=end`; the bytes it wrote (also on failure).
async fn read_once(
    client: &reqwest::Client,
    url: &str,
    part: &Path,
    at: u64,
    end: u64,
) -> Result<u64, (u64, anyhow::Error)> {
    let fail = |e: anyhow::Error| (0, e);
    let resp = client
        .get(url)
        .header(reqwest::header::RANGE, format!("bytes={at}-{end}"))
        .send()
        .await
        .map_err(|e| fail(e.into()))?;
    if signed_url_refused(resp.status()) {
        return Err(fail(anyhow::Error::new(Refused(resp.status()))));
    }
    if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return Err(fail(anyhow!("range request answered {}", resp.status())));
    }
    let span = resp
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(content_range_span);
    if span != Some((at, end)) {
        return Err(fail(anyhow!("range {at}-{end} answered with bytes {span:?}")));
    }
    let want = end - at + 1;
    if resp.content_length().is_some_and(|n| n != want) {
        return Err(fail(anyhow!(
            "range of {want} bytes answered with {:?}",
            resp.content_length()
        )));
    }
    let n = stream_to_counting(resp, part, at, want).await?;
    Ok(n)
}

/// As [`stream_to`], at most `want` bytes, and the count survives an error.
async fn stream_to_counting(
    mut resp: reqwest::Response,
    part: &Path,
    offset: u64,
    want: u64,
) -> Result<u64, (u64, anyhow::Error)> {
    let mut written = 0u64;
    let run = async {
        let mut file = tokio::fs::OpenOptions::new().write(true).truncate(false).open(part).await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        loop {
            match tokio::time::timeout(STALL, resp.chunk()).await {
                Err(_) => bail!("no bytes for {}s", STALL.as_secs()),
                Ok(Err(e)) => return Err(e.into()),
                Ok(Ok(None)) => break,
                Ok(Ok(Some(chunk))) => {
                    if written + chunk.len() as u64 > want {
                        bail!("range sent more than the {want} bytes asked for");
                    }
                    file.write_all(&chunk).await?;
                    written += chunk.len() as u64;
                }
            }
        }
        file.flush().await?;
        anyhow::Ok(())
    }
    .await;
    match run {
        Err(e) => Err((written, e)),
        Ok(()) => Ok(written),
    }
}

#[cfg(test)]
#[path = "range_fetch_tests.rs"]
mod tests;
