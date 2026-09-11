use std::collections::VecDeque;
use std::fs::File;
use std::io::BufRead;
use std::io::BufReader;
use std::io::Read;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use memchr::memchr_iter;
use serde::Deserialize;
use serde::Serialize;
use sha2::Digest;
use sha2::Sha256;
use tokio::io::AsyncRead;
use tokio::io::AsyncReadExt;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
pub struct OutputLimits {
    pub inline_bytes: usize,
    pub preview_bytes: usize,
}

#[derive(Debug, Clone)]
pub struct OutputStore {
    root: PathBuf,
    limits: OutputLimits,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtifactSummary {
    pub r#ref: String,
    pub sha256: String,
    pub bytes: u64,
    pub lines: u64,
    pub inline: Option<String>,
    pub head: Option<String>,
    pub tail: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchMatch {
    pub line: u64,
    pub text: String,
}

impl OutputStore {
    pub async fn new(root: PathBuf, limits: OutputLimits) -> Result<Self> {
        tokio::fs::create_dir_all(root.join("blobs")).await?;
        Ok(Self { root, limits })
    }

    pub async fn spool_reader<R>(&self, reader: R) -> Result<ArtifactSummary>
    where
        R: AsyncRead + Unpin,
    {
        let root = self.root.clone();
        let limits = self.limits;
        let temp_name = format!("{}.tmp", Uuid::new_v4());
        let temp_path = root.join("blobs").join(temp_name);
        let mut file = tokio::fs::File::create(&temp_path)
            .await
            .with_context(|| format!("creating temp output file {}", temp_path.display()))?;
        let mut reader = reader;
        let mut buf = vec![0; 64 * 1024];
        let mut sha = Sha256::new();
        let mut bytes: u64 = 0;
        let mut line_offsets = vec![0_u64];
        let mut inline = Vec::new();
        let mut head = Vec::new();
        let mut tail = TailBuffer::new(limits.preview_bytes);

        loop {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            let chunk = &buf[..n];
            sha.update(chunk);
            file.write_all(chunk).await?;

            if inline.len() <= limits.inline_bytes {
                let remaining = limits
                    .inline_bytes
                    .saturating_add(1)
                    .saturating_sub(inline.len());
                inline.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            }
            if head.len() < limits.preview_bytes {
                let remaining = limits.preview_bytes - head.len();
                head.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            }
            tail.push(chunk);
            for idx in memchr_iter(b'\n', chunk) {
                line_offsets.push(bytes + idx as u64 + 1);
            }
            bytes += n as u64;
        }
        file.flush().await?;
        drop(file);

        if line_offsets.last().copied() != Some(bytes) {
            line_offsets.push(bytes);
        }

        let sha256 = hex::encode(sha.finalize());
        let blob_path = self.blob_path_for_sha(&sha256);
        if tokio::fs::try_exists(&blob_path).await? {
            let _ = tokio::fs::remove_file(&temp_path).await;
        } else {
            tokio::fs::rename(&temp_path, &blob_path).await?;
        }

        let idx_path = self.index_path_for_sha(&sha256);
        write_line_index(&idx_path, &line_offsets)
            .with_context(|| format!("writing line index {}", idx_path.display()))?;

        let inline = if inline.len() <= limits.inline_bytes {
            Some(lossy(&inline))
        } else {
            None
        };
        Ok(ArtifactSummary {
            r#ref: format!("blob:{sha256}"),
            sha256,
            bytes,
            lines: line_offsets.len().saturating_sub(1) as u64,
            inline,
            head: (!head.is_empty()).then(|| lossy(&head)),
            tail: (!tail.is_empty()).then(|| lossy(&tail.into_vec())),
        })
    }

    pub async fn ingest_file(&self, path: &Path) -> Result<ArtifactSummary> {
        let file = tokio::fs::File::open(path)
            .await
            .with_context(|| format!("opening {}", path.display()))?;
        self.spool_reader(file).await
    }

    pub fn read_bytes(&self, r#ref: &str, offset: u64, len: usize) -> Result<String> {
        let sha = parse_blob_ref(r#ref)?;
        let path = self.blob_path_for_sha(sha);
        let mut file = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
        file.seek(SeekFrom::Start(offset))?;
        let mut buf = vec![0; len];
        let n = file.read(&mut buf)?;
        buf.truncate(n);
        Ok(lossy(&buf))
    }

    pub fn read_lines(&self, r#ref: &str, start: u64, count: u64) -> Result<String> {
        let sha = parse_blob_ref(r#ref)?;
        let path = self.blob_path_for_sha(sha);
        let idx_path = self.index_path_for_sha(sha);
        let offsets = read_line_index_range(&idx_path, start, count)
            .with_context(|| format!("reading line index {}", idx_path.display()))?;
        if offsets.is_empty() {
            return Ok(String::new());
        }

        let mut file = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
        let start_offset = offsets[0];
        let end_offset = offsets
            .last()
            .copied()
            .filter(|last| *last > start_offset)
            .unwrap_or_else(|| file.metadata().map(|m| m.len()).unwrap_or(start_offset));
        file.seek(SeekFrom::Start(start_offset))?;
        let mut buf = vec![0; end_offset.saturating_sub(start_offset) as usize];
        file.read_exact(&mut buf)?;
        Ok(lossy(&buf))
    }

    pub fn search(
        &self,
        r#ref: &str,
        pattern: &str,
        max_matches: usize,
    ) -> Result<Vec<SearchMatch>> {
        if pattern.is_empty() {
            return Err(anyhow!("pattern must not be empty"));
        }
        let sha = parse_blob_ref(r#ref)?;
        let path = self.blob_path_for_sha(sha);
        let file = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
        let reader = BufReader::new(file);
        let mut matches = Vec::new();
        for (idx, line) in reader.split(b'\n').enumerate() {
            let line = line?;
            let text = lossy(&line);
            if text.contains(pattern) {
                matches.push(SearchMatch {
                    line: idx as u64,
                    text,
                });
                if matches.len() >= max_matches {
                    break;
                }
            }
        }
        Ok(matches)
    }

    fn blob_path_for_sha(&self, sha: &str) -> PathBuf {
        self.root.join("blobs").join(format!("{sha}.bin"))
    }

    fn index_path_for_sha(&self, sha: &str) -> PathBuf {
        self.root.join("blobs").join(format!("{sha}.idx"))
    }
}

fn parse_blob_ref(r#ref: &str) -> Result<&str> {
    let Some(sha) = r#ref.strip_prefix("blob:") else {
        return Err(anyhow!("unsupported output ref `{ref}`"));
    };
    if sha.len() != 64 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(anyhow!("invalid blob ref `{ref}`"));
    }
    Ok(sha)
}

fn write_line_index(path: &Path, offsets: &[u64]) -> Result<()> {
    let mut file = File::create(path)?;
    for offset in offsets {
        file.write_all(&offset.to_le_bytes())?;
    }
    Ok(())
}

fn read_line_index_range(path: &Path, start: u64, count: u64) -> Result<Vec<u64>> {
    if count == 0 {
        return Ok(Vec::new());
    }
    let mut file = File::open(path)?;
    let offset_count = file.metadata()?.len() / 8;
    if start >= offset_count {
        return Ok(Vec::new());
    }
    let desired = count.saturating_add(1);
    let available = offset_count.saturating_sub(start);
    let to_read = desired.min(available);
    file.seek(SeekFrom::Start(start * 8))?;
    let mut offsets = Vec::with_capacity(to_read as usize);
    for _ in 0..to_read {
        let mut buf = [0_u8; 8];
        file.read_exact(&mut buf)?;
        offsets.push(u64::from_le_bytes(buf));
    }
    Ok(offsets)
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

struct TailBuffer {
    max: usize,
    len: usize,
    chunks: VecDeque<Vec<u8>>,
}

impl TailBuffer {
    fn new(max: usize) -> Self {
        Self {
            max,
            len: 0,
            chunks: VecDeque::new(),
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        if self.max == 0 || bytes.is_empty() {
            return;
        }
        if bytes.len() >= self.max {
            self.chunks.clear();
            self.chunks
                .push_back(bytes[bytes.len() - self.max..].to_vec());
            self.len = self.max;
            return;
        }
        self.chunks.push_back(bytes.to_vec());
        self.len += bytes.len();
        while self.len > self.max {
            let overflow = self.len - self.max;
            let Some(front) = self.chunks.front_mut() else {
                break;
            };
            if front.len() <= overflow {
                self.len -= front.len();
                self.chunks.pop_front();
            } else {
                front.drain(..overflow);
                self.len -= overflow;
            }
        }
    }

    fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn into_vec(self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.len);
        for chunk in self.chunks {
            out.extend_from_slice(&chunk);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn spools_and_searches_output() {
        let temp = tempfile::tempdir().unwrap();
        let store = OutputStore::new(
            temp.path().join("out"),
            OutputLimits {
                inline_bytes: 8,
                preview_bytes: 16,
            },
        )
        .await
        .unwrap();
        let (mut tx, rx) = tokio::io::duplex(4096);
        tokio::spawn(async move {
            tx.write_all(b"alpha\nbeta error\ngamma\n").await.unwrap();
        });
        let summary = store.spool_reader(rx).await.unwrap();
        assert_eq!(summary.inline, None);
        assert_eq!(summary.lines, 3);
        let matches = store.search(&summary.r#ref, "error", 10).unwrap();
        assert_eq!(matches[0].line, 1);
        assert_eq!(matches[0].text, "beta error");
        assert_eq!(
            store.read_lines(&summary.r#ref, 1, 1).unwrap(),
            "beta error\n"
        );
    }
}
