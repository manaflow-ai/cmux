//! The index on disk: `manifest.json` (strings, removed sources, names,
//! frecency, segment files) and one `seg-<n>.bin` per sealed segment. Save
//! seals the live segment first. Every file is written to a temp name and
//! renamed, the manifest last, so a crash leaves the previous index whole.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::engine::{EngineConfig, SearchEngine};
use crate::frecency::Frecency;
use crate::names::NameDoc;
use crate::segment::{BlockMeta, DocMeta, Postings, Segment};

const MAGIC: &[u8; 8] = b"CMXSEG01";
const FORMAT: u32 = 1;

#[derive(Serialize, Deserialize)]
struct Manifest {
    format: u32,
    strings: Vec<String>,
    removed: Vec<u32>,
    names: Vec<NameDoc>,
    frecency: Frecency,
    segments: Vec<String>,
}

impl SearchEngine {
    /// Writes the index to `dir` (created when missing).
    pub fn save(&mut self, dir: &Path) -> io::Result<()> {
        self.seal();
        fs::create_dir_all(dir)?;
        let mut files = Vec::new();
        for (index, segment) in self.segments.iter().enumerate() {
            if segment.docs.is_empty() || !segment.is_sealed() {
                continue;
            }
            let name = format!("seg-{index}.bin");
            let path = dir.join(&name);
            // A sealed segment never changes except its deleted bits, so
            // rewriting it is only needed when they did; v1 always rewrites.
            write_atomic(&path, &encode_segment(segment))?;
            files.push(name);
        }
        let manifest = Manifest {
            format: FORMAT,
            strings: self.strings.clone(),
            removed: (0..self.removed.len() as u32)
                .filter(|&id| self.removed[id as usize])
                .collect(),
            names: self.names.iter().map(|entry| entry.doc.clone()).collect(),
            frecency: self.frecency.clone(),
            segments: files.clone(),
        };
        let json = serde_json::to_vec(&manifest).map_err(io::Error::other)?;
        write_atomic(&dir.join("manifest.json"), &json)?;
        // Drop segment files no manifest names (an earlier save's).
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("seg-") && name.ends_with(".bin") && !files.contains(&name) {
                let _ = fs::remove_file(entry.path());
            }
        }
        Ok(())
    }

    /// Opens the index saved in `dir`; an empty engine when `dir` holds none.
    pub fn load(dir: &Path, config: EngineConfig) -> io::Result<Self> {
        let mut engine = SearchEngine::new(config);
        let manifest_path = dir.join("manifest.json");
        if !manifest_path.exists() {
            return Ok(engine);
        }
        let manifest: Manifest =
            serde_json::from_slice(&fs::read(&manifest_path)?).map_err(invalid)?;
        if manifest.format != FORMAT {
            return Err(invalid(format!("index format {} is not {FORMAT}", manifest.format)));
        }
        engine.removed = vec![false; manifest.strings.len()];
        for &id in &manifest.removed {
            if let Some(flag) = engine.removed.get_mut(id as usize) {
                *flag = true;
            }
        }
        for (id, value) in manifest.strings.iter().enumerate() {
            if !engine.removed[id] {
                engine.string_ids.entry(value.clone()).or_insert(id as u32);
            }
        }
        engine.strings = manifest.strings;
        let mut segments = Vec::new();
        for name in &manifest.segments {
            segments.push(decode_segment(&fs::read(dir.join(name))?)?);
        }
        segments.push(Segment::new_live());
        engine.segments = segments;
        for (segment_index, segment) in engine.segments.iter().enumerate() {
            for (doc_index, doc) in segment.docs.iter().enumerate() {
                if doc.key != crate::segment::NONE_U32 && !segment.is_deleted(doc_index as u32) {
                    let key = engine.strings[doc.key as usize].clone();
                    engine.keyed.insert(key, (segment_index as u32, doc_index as u32));
                }
            }
        }
        for name in manifest.names {
            engine.names.upsert(name);
        }
        engine.frecency = manifest.frecency;
        Ok(engine)
    }
}

fn invalid(error: impl ToString) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temp, path)
}

fn encode_segment(segment: &Segment) -> Vec<u8> {
    let Postings::Sealed { keys, counts, offsets, data } = &segment.postings else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(segment.text.len() + data.len() + segment.docs.len() * 48);
    out.extend_from_slice(MAGIC);
    put_bytes(&mut out, &segment.text);
    put_u64(&mut out, segment.docs.len() as u64);
    for doc in &segment.docs {
        out.push(doc.kind);
        for value in [doc.source, doc.target, doc.title, doc.key, doc.start, doc.len] {
            out.extend_from_slice(&value.to_le_bytes());
        }
        out.extend_from_slice(&doc.position.to_le_bytes());
        out.extend_from_slice(&doc.at_ms.to_le_bytes());
    }
    put_u64(&mut out, segment.blocks.len() as u64);
    for block in &segment.blocks {
        for value in [block.first_doc, block.end_doc, block.text_start] {
            out.extend_from_slice(&value.to_le_bytes());
        }
        out.extend_from_slice(&block.kinds.to_le_bytes());
    }
    for list in [keys, counts, offsets] {
        put_u64(&mut out, list.len() as u64);
        for value in list {
            out.extend_from_slice(&value.to_le_bytes());
        }
    }
    put_bytes(&mut out, data);
    put_u64(&mut out, segment.deleted.len() as u64);
    for word in &segment.deleted {
        out.extend_from_slice(&word.to_le_bytes());
    }
    out
}

fn put_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    put_u64(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> io::Result<&'a [u8]> {
        let end = self.at.checked_add(count).filter(|&end| end <= self.bytes.len());
        let end = end.ok_or_else(|| invalid("segment file is truncated"))?;
        let slice = &self.bytes[self.at..end];
        self.at = end;
        Ok(slice)
    }

    fn array<const N: usize>(&mut self) -> io::Result<[u8; N]> {
        let mut array = [0u8; N];
        array.copy_from_slice(self.take(N)?);
        Ok(array)
    }

    fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_le_bytes(self.array()?))
    }

    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.array()?))
    }

    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.array()?))
    }

    fn i64(&mut self) -> io::Result<i64> {
        Ok(i64::from_le_bytes(self.array()?))
    }

    fn len(&mut self) -> io::Result<usize> {
        let value = self.u64()?;
        // No count can exceed the bytes left; this rejects corrupt lengths.
        usize::try_from(value)
            .ok()
            .filter(|&value| value <= self.bytes.len())
            .ok_or_else(|| invalid("segment file has a bad length"))
    }

    fn u32s(&mut self) -> io::Result<Vec<u32>> {
        let count = self.len()?;
        (0..count).map(|_| self.u32()).collect()
    }
}

fn decode_segment(bytes: &[u8]) -> io::Result<Segment> {
    let mut reader = Reader { bytes, at: 0 };
    if reader.take(MAGIC.len())? != MAGIC {
        return Err(invalid("not a cmux search segment"));
    }
    let text_len = reader.len()?;
    let text = reader.take(text_len)?.to_vec();
    let doc_count = reader.len()?;
    let mut docs = Vec::with_capacity(doc_count);
    for _ in 0..doc_count {
        let kind = reader.take(1)?[0];
        let source = reader.u32()?;
        let target = reader.u32()?;
        let title = reader.u32()?;
        let key = reader.u32()?;
        let start = reader.u32()?;
        let len = reader.u32()?;
        let position = reader.i64()?;
        let at_ms = reader.i64()?;
        if start as usize + len as usize > text.len() {
            return Err(invalid("segment doc is out of range"));
        }
        docs.push(DocMeta { kind, source, target, title, key, position, at_ms, start, len });
    }
    let block_count = reader.len()?;
    let mut blocks = Vec::with_capacity(block_count);
    for _ in 0..block_count {
        let first_doc = reader.u32()?;
        let end_doc = reader.u32()?;
        let text_start = reader.u32()?;
        let kinds = reader.u16()?;
        if first_doc > end_doc || end_doc as usize > docs.len() {
            return Err(invalid("segment block is out of range"));
        }
        blocks.push(BlockMeta { first_doc, end_doc, kinds, text_start });
    }
    let keys = reader.u32s()?;
    let counts = reader.u32s()?;
    let offsets = reader.u32s()?;
    let data_len = reader.len()?;
    let data = reader.take(data_len)?.to_vec();
    if counts.len() != keys.len()
        || offsets.len() != keys.len() + 1
        || offsets.iter().any(|&offset| offset as usize > data.len())
    {
        return Err(invalid("segment postings are inconsistent"));
    }
    let deleted_len = reader.len()?;
    let deleted = (0..deleted_len).map(|_| reader.u64()).collect::<io::Result<Vec<u64>>>()?;
    Ok(Segment {
        text,
        docs,
        blocks,
        postings: Postings::Sealed { keys, counts, offsets, data },
        deleted,
    })
}
