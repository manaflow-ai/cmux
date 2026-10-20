//! The index on disk: `manifest.json` (strings, removed sources, keyed
//! docs, names, contexts, opens and focus history, segment ids with their
//! deleted bits) and one `seg-<id>.bin` image per sealed segment. With an
//! index directory, sealing writes the image right away and reads it back
//! on demand; `save` seals the live segment and rewrites the manifest.
//! Files are written to a temp name and renamed, the manifest last, so a
//! crash leaves the previous index whole.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::context::{ContextEntry, TargetContext};
use crate::engine::{EngineConfig, SearchEngine};
use crate::frecency::Frecency;
use crate::names::NameDoc;
use crate::segment::{Live, Sealed, Segment, Store, invalid};

const FORMAT: u32 = 2;

#[derive(Serialize, Deserialize)]
struct Manifest {
    format: u32,
    next_segment: u64,
    strings: Vec<String>,
    removed: Vec<u32>,
    keyed: Vec<(String, u64, u32)>,
    names: Vec<NameDoc>,
    contexts: Vec<(String, TargetContext)>,
    opens: Frecency,
    focus: Frecency,
    segments: Vec<(u64, Vec<u64>)>,
}

fn segment_path(dir: &Path, id: u64) -> PathBuf {
    dir.join(format!("seg-{id}.bin"))
}

/// Writes `image` to its file in `dir` and opens it; keeps it in memory
/// without a directory or when the write fails.
pub(crate) fn store_image(dir: Option<&Path>, id: u64, image: Vec<u8>) -> Store {
    let Some(dir) = dir else { return Store::Memory(image) };
    let path = segment_path(dir, id);
    let written = fs::create_dir_all(dir)
        .and_then(|()| write_atomic(&path, &image))
        .and_then(|()| File::open(&path));
    match written {
        Ok(file) => Store::File { file, path },
        Err(_) => Store::Memory(image),
    }
}

impl SearchEngine {
    /// Opens the index in `dir` (an empty one when `dir` holds none). Sealed
    /// segments are written there and read from there on demand.
    pub fn open(dir: &Path, config: EngineConfig) -> io::Result<Self> {
        let mut engine = Self::load(dir, config)?;
        engine.dir = Some(dir.to_path_buf());
        Ok(engine)
    }

    /// [`SearchEngine::open`].
    pub fn load(dir: &Path, config: EngineConfig) -> io::Result<Self> {
        let mut engine = SearchEngine::new(config);
        engine.dir = Some(dir.to_path_buf());
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
        for (id, deleted) in manifest.segments {
            let path = segment_path(dir, id);
            let file = File::open(&path)?;
            segments.push(Segment::Sealed(Sealed::open(id, Store::File { file, path }, deleted)?));
        }
        segments.push(Segment::Live(Live::new(manifest.next_segment)));
        engine.next_segment = manifest.next_segment + 1;
        engine.segments = segments;
        engine.keyed = manifest
            .keyed
            .into_iter()
            .map(|(key, segment, doc)| (key, (segment, doc)))
            .collect::<HashMap<_, _>>();
        for name in manifest.names {
            engine.names.upsert(name);
        }
        for (target, context) in manifest.contexts {
            engine.contexts.entries.insert(target, ContextEntry::new(context));
        }
        engine.opens = manifest.opens;
        engine.focus = manifest.focus;
        Ok(engine)
    }

    /// Seals the live segment and writes the index to `dir` (created when
    /// missing). Afterwards the engine reads its segments from `dir`.
    pub fn save(&mut self, dir: &Path) -> io::Result<()> {
        if self.dir.as_deref() != Some(dir) {
            self.dir = Some(dir.to_path_buf());
        }
        self.seal();
        fs::create_dir_all(dir)?;
        let mut listed = Vec::new();
        for segment in &mut self.segments {
            let Segment::Sealed(sealed) = segment else { continue };
            let path = segment_path(dir, sealed.id);
            let moved = match &sealed.store {
                Store::Memory(image) => Some(image.clone()),
                Store::File { path: current, .. } if *current != path => Some(fs::read(current)?),
                Store::File { .. } => None,
            };
            if let Some(image) = moved {
                write_atomic(&path, &image)?;
                sealed.store = Store::File { file: File::open(&path)?, path: path.clone() };
            }
            listed.push((sealed.id, sealed.deleted.clone()));
        }
        let live_id = self.segments.last().map_or(self.next_segment, Segment::id);
        let manifest = Manifest {
            format: FORMAT,
            next_segment: live_id,
            strings: self.strings.clone(),
            removed: (0..self.removed.len() as u32)
                .filter(|&id| self.removed[id as usize])
                .collect(),
            keyed: self
                .keyed
                .iter()
                .map(|(key, &(segment, doc))| (key.clone(), segment, doc))
                .collect(),
            names: self.names.iter().map(|entry| entry.doc.clone()).collect(),
            contexts: self
                .contexts
                .entries
                .iter()
                .map(|(target, entry)| (target.clone(), entry.context.clone()))
                .collect(),
            opens: self.opens.clone(),
            focus: self.focus.clone(),
            segments: listed.clone(),
        };
        let json = serde_json::to_vec(&manifest).map_err(io::Error::other)?;
        write_atomic(&dir.join("manifest.json"), &json)?;
        // Drop segment files the manifest does not name (a crashed seal's).
        let keep: Vec<String> = listed.iter().map(|(id, _)| format!("seg-{id}.bin")).collect();
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("seg-") && name.ends_with(".bin") && !keep.contains(&name) {
                let _ = fs::remove_file(entry.path());
            }
        }
        Ok(())
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = path.with_extension("tmp");
    {
        let mut file = File::create(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temp, path)
}
