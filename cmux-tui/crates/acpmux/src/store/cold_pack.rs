//! Opt-in packed cold history. The pack stores the concatenated log, while the
//! stub keeps the archive's original file boundaries, hashes and compaction marker.
use super::*;
use cmux_session_cloud::{Cloud, fetch, offload, stub};
use cmux_session_pack as pack;

const CACHE: &str = "cold-pack-cache";

#[derive(Serialize, Deserialize)]
struct PackedArchive {
    #[serde(flatten)]
    history: stub::Packed,
    header: Header,
    hashes: Vec<String>,
    marker: Vec<u8>,
}

impl LocalStore {
    /// Offload an existing cold archive as a session pack. The batch offloader still
    /// selects the single-blob format unless a caller explicitly selects this method.
    pub fn offload_cold_packed(&self, id: &str, tail_turns: usize) -> Result<Option<u64>> {
        let archive = self.cold_path(id);
        if !self.is_cold(id) || !crate::home_fs::try_exists_nofollow(&archive)? {
            return Ok(None);
        }
        let Some(cloud) = self.cloud()? else { return Ok(None) };
        let stage = tempfile::tempdir_in(self.dir(id))?;
        let lines = stage.path().join("log");
        let mut log = crate::home_fs::create_file(&lines)?;
        let mut marker = Vec::new();
        let (header, hashes) = decode_files(&archive, &mut |entry, part, hash| {
            if entry.name == super::super::compact::MARKER {
                copy_hashed(part, &mut marker, hash)
            } else {
                copy_hashed(part, &mut log, hash)
            }
        })?;
        drop(log);
        let source = pack::Store::new(stage.path());
        pack::pack(&source, id, &[lines], &Default::default(), true)
            .map_err(anyhow::Error::from_boxed)?;
        let history = offload::upload_pack(&source, id, tail_turns, &cloud)?;
        let record = PackedArchive { history, header, hashes, marker };

        let _cold = self.cold.lock(id);
        let _sealed = self.unsealed(id)?;
        if self.held_has_segment(id)? || !crate::home_fs::try_exists_nofollow(&archive)? {
            return Ok(None);
        }
        let (header, hashes) = decode(&archive, &mut |_| Ok(None))?;
        if header != record.header || hashes != record.hashes {
            return Ok(None);
        }
        let freed = crate::home_fs::symlink_metadata(&archive)?.len();
        crate::config::write_atomic(&self.cloud_stub_path(id), &serde_json::to_vec(&record)?)?;
        sync_directory(&self.dir(id))?;
        // On a failed root update the local archive still wins, including after a restart.
        self.register_cloud_root_in(&cloud, &record.history.blobs().collect::<Vec<_>>())?;
        crate::home_fs::remove_file(&archive)?;
        sync_directory(&self.dir(id))?;
        Ok(Some(freed))
    }

    fn packed_cache(&self, id: &str) -> Result<pack::Store> {
        let path = self.dir(id).join(CACHE);
        crate::config::private_state_dir(&path)?;
        Ok(pack::Store::new(path))
    }

    /// Latest visible records, without thawing the chat. None selects the normal local
    /// or legacy archive reader. Reading an older range uses the same durable chunk cache.
    pub fn open_packed_cold_tail(&self, id: &str) -> Result<Option<Vec<EventRecord>>> {
        let _cold = self.cold.lock(id);
        let _sealed = self.unsealed(id)?;
        let path = self.cloud_stub_path(id);
        if !crate::home_fs::try_exists_nofollow(&path)?
            || crate::home_fs::try_exists_nofollow(self.cold_path(id))?
            || self.held_has_segment(id)?
        {
            return Ok(None);
        }
        let stub::History::Pack(record) = self.cloud_history(id)? else { return Ok(None) };
        let cloud = self.cloud()?.context("cloud history is not configured")?;
        let pack = fetch::open_pack(&record, &self.packed_cache(id)?, &cloud)?;
        anyhow::ensure!(pack.manifest.name == id, "history belongs to another chat");
        let lines = pack
            .read_lines(record.first_line..pack.manifest.lines)
            .map_err(anyhow::Error::from_boxed)?;
        Ok(Some(lines.iter().map(|line| parse_record(line)).collect::<serde_json::Result<_>>()?))
    }

    /// Rebuild every original events file into the private thaw directory before publishing it.
    pub(super) fn thaw_packed(&self, id: &str, cloud: &Cloud, thaw: &Path) -> Result<Header> {
        let record: PackedArchive =
            serde_json::from_reader(crate::home_fs::private_state_file(self.cloud_stub_path(id))?)?;
        let cache = self.packed_cache(id)?;
        let pack = fetch::open_pack(&record.history, &cache, cloud)?;
        anyhow::ensure!(pack.manifest.name == id, "history belongs to another chat");
        let ids = pack.manifest.chunk_ids().map_err(anyhow::Error::from_boxed)?;
        fetch::backfill(&record.history, &cache, &ids, cloud)?;
        let mut log = tempfile::tempfile_in(thaw)?;
        pack.cat(&mut log).map_err(anyhow::Error::from_boxed)?;
        std::io::Seek::rewind(&mut log)?;
        anyhow::ensure!(
            record.header.files.len() == record.hashes.len(),
            "incomplete archive layout"
        );
        for (entry, expected) in record.header.files.iter().zip(&record.hashes) {
            anyhow::ensure!(log_file(&entry.name), "invalid archive entry");
            let mut file = open_private_append(&thaw.join(&entry.name))?;
            let mut hash = Sha256::new();
            let copied = if entry.name == super::super::compact::MARKER {
                copy_hashed(&mut record.marker.as_slice(), &mut file, &mut hash)?
            } else {
                copy_hashed(&mut Read::take(&mut log, entry.len), &mut file, &mut hash)?
            };
            anyhow::ensure!(
                copied == entry.len && hex(&hash.finalize()) == *expected,
                "packed history differs from archived {}",
                entry.name
            );
            file.sync_all()?;
        }
        anyhow::ensure!(log.read(&mut [0])? == 0, "history exceeds archive layout");
        Ok(record.header)
    }

    pub(super) fn remove_packed_cache(&self, id: &str) {
        let _ = crate::home_fs::remove_dir_all(self.dir(id).join(CACHE));
    }
}
