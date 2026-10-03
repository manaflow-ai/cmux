//! The `fs.*` op shapes of finder.md, executed by the link on an SFTP root.
//!
//! The caller (the link's op handler) has already resolved the app's
//! `conn` and `root` handles to an [`SftpRoot`] and checked the scope and
//! the gesture; `conn` and `root` in `params` are ignored here.

use std::sync::Mutex;
use std::time::Instant;

use base64::Engine as _;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::FsError;
use super::listing::{Listings, MAX_BATCH};
use super::remote::{SftpRoot, WriteMode};
use super::sort::{Filter, Sort, sort_entries};

/// Largest snapshot one listing may hold (finder.md 4.2).
pub const MAX_LISTING_ENTRIES: usize = 1_000_000;

#[derive(Deserialize)]
struct ListParams {
    #[serde(default)]
    path: String,
    #[serde(default)]
    sort: Sort,
    #[serde(default)]
    filter: Filter,
    #[serde(default = "default_limit")]
    limit: usize,
    cursor: Option<String>,
    listing: Option<String>,
}

fn default_limit() -> usize {
    200
}

#[derive(Deserialize)]
struct PathParams {
    #[serde(default)]
    path: String,
}

#[derive(Deserialize)]
struct ReadParams {
    path: String,
    #[serde(default)]
    offset: u64,
    max_bytes: u64,
}

#[derive(Deserialize)]
struct WriteParams {
    path: String,
    text: Option<String>,
    bytes_base64: Option<String>,
    #[serde(flatten)]
    mode: WriteMode,
}

#[derive(Deserialize)]
struct NameParams {
    #[serde(default)]
    path: String,
    name: String,
}

#[derive(Deserialize)]
struct PathsParams {
    paths: Vec<String>,
    #[serde(default)]
    permanent: bool,
}

/// The link's file system owner for SSH roots: it keeps the listing
/// snapshots.
#[derive(Default)]
pub struct SftpFsOwner {
    listings: Mutex<Listings>,
}

impl SftpFsOwner {
    /// Runs one `fs.*` op. `owner_key` names the (app, conn) pair for
    /// listing ownership.
    pub async fn call(
        &self,
        owner_key: &str,
        root: &SftpRoot,
        op: &str,
        params: Value,
    ) -> Result<Value, FsError> {
        match op {
            "fs.list" => self.list(owner_key, root, parse(params)?).await,
            "fs.stat" => {
                let params: PathParams = parse(params)?;
                to_value(&root.stat(&params.path).await?)
            }
            "fs.read" => {
                let params: ReadParams = parse(params)?;
                to_value(&root.read(&params.path, params.offset, params.max_bytes).await?)
            }
            "fs.write" => {
                let params: WriteParams = parse(params)?;
                let data = match (params.text, params.bytes_base64) {
                    (Some(text), None) => text.into_bytes(),
                    (None, Some(encoded)) => base64::engine::general_purpose::STANDARD
                        .decode(encoded)
                        .map_err(|error| invalid(&error.to_string()))?,
                    _ => return Err(invalid("exactly one of text and bytes_base64")),
                };
                let entry = root.write(&params.path, &data, params.mode).await?;
                Ok(json!({ "entry": entry }))
            }
            "fs.mkdir" => {
                let params: NameParams = parse(params)?;
                Ok(json!({ "entry": root.mkdir(&params.path, &params.name).await? }))
            }
            "fs.rename" => {
                let params: NameParams = parse(params)?;
                Ok(json!({ "entry": root.rename(&params.path, &params.name).await? }))
            }
            "fs.trash" => {
                let params: PathsParams = parse(params)?;
                let job = crate::ids::random_id("job_");
                root.trash(&params.paths, &job).await?;
                Ok(json!({ "job": job }))
            }
            "fs.delete" => {
                let params: PathsParams = parse(params)?;
                if !params.permanent {
                    return Err(invalid("fs.delete needs permanent: true"));
                }
                for path in &params.paths {
                    crate::job::remove_tree(root, path).await?;
                }
                Ok(json!({}))
            }
            "fs.watch" => Err(FsError::WatchUnsupported),
            _ => Err(FsError::OpUnknown),
        }
    }

    async fn list(
        &self,
        owner_key: &str,
        root: &SftpRoot,
        params: ListParams,
    ) -> Result<Value, FsError> {
        if !(1..=MAX_BATCH).contains(&params.limit) {
            return Err(invalid("limit is 1..1000"));
        }
        if let Some(listing) = &params.listing {
            let page = self.lock().page(
                owner_key,
                listing,
                params.cursor.as_deref(),
                params.limit,
                Instant::now(),
            )?;
            return to_value(&page);
        }
        let (entries, revision) = root.read_directory(&params.path).await?;
        if entries.len() > MAX_LISTING_ENTRIES {
            return Err(FsError::TooLarge { total: entries.len() as u64 });
        }
        let mut entries: Vec<_> =
            entries.into_iter().filter(|entry| params.filter.admits(entry)).collect();
        sort_entries(&mut entries, params.sort);
        let page = self.lock().insert(owner_key, entries, revision, params.limit, Instant::now());
        to_value(&page)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Listings> {
        self.listings.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn parse<T: DeserializeOwned>(params: Value) -> Result<T, FsError> {
    serde_json::from_value(params).map_err(|error| invalid(&error.to_string()))
}

fn to_value<T: serde::Serialize>(value: &T) -> Result<Value, FsError> {
    serde_json::to_value(value).map_err(|error| FsError::Failure { message: error.to_string() })
}

fn invalid(message: &str) -> FsError {
    FsError::ParamsInvalid { message: message.to_owned() }
}
