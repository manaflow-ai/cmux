use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

#[cfg(not(unix))]
use std::time::UNIX_EPOCH;

use cmux_remote_protocol::{PageCursor, RpcError, WorkspaceId};
use tokio::sync::OnceCell;

use super::ClientScope;
use super::files::{DirectoryContinuation, SearchContinuation};
use super::git::DiffContinuation;
use super::path::WorkspaceRoot;

const QUERY_CONTINUATION_TTL: Duration = Duration::from_secs(60);
const MAX_QUERY_CONTINUATIONS: usize = 64;
const MAX_QUERY_CONTINUATION_BYTES: usize = 96 * 1024 * 1024;
const MAX_CURSOR_BYTES: usize = 128;
const FILE_HASH_TTL: Duration = Duration::from_secs(60);
const MAX_FILE_HASH_ENTRIES: usize = 256;
const MAX_FILE_HASH_KEY_BYTES: usize = 1024 * 1024;

pub(super) struct WorkspaceQueryContext<'a> {
    pub(super) service: &'a WorkspaceQueryService,
    pub(super) owner: &'a ClientScope,
    pub(super) root: &'a WorkspaceRoot,
}

impl<'a> WorkspaceQueryContext<'a> {
    pub(super) fn new(
        service: &'a WorkspaceQueryService,
        owner: &'a ClientScope,
        root: &'a WorkspaceRoot,
    ) -> Self {
        Self { service, owner, root }
    }
}

#[derive(Default)]
pub(super) struct WorkspaceQueryService {
    state: StdMutex<QueryState>,
}

#[derive(Default)]
struct QueryState {
    continuations: HashMap<String, StoredContinuation>,
    continuation_order: VecDeque<String>,
    continuation_bytes: usize,
    hashes: HashMap<FileHashKey, CachedHash>,
    hash_order: VecDeque<FileHashKey>,
    hash_key_bytes: usize,
}

struct StoredContinuation {
    owner: ClientScope,
    workspace: WorkspaceId,
    scope: String,
    last_used: Instant,
    charge: usize,
    value: QueryContinuation,
}

enum QueryContinuation {
    Directory(DirectoryContinuation),
    Search(SearchContinuation),
    Diff(DiffContinuation),
}

impl QueryContinuation {
    fn kind(&self) -> &'static str {
        match self {
            Self::Directory(_) => "directory",
            Self::Search(_) => "search",
            Self::Diff(_) => "diff",
        }
    }

    fn retained_bytes(&self) -> usize {
        match self {
            Self::Directory(state) => state.retained_bytes(),
            Self::Search(state) => state.retained_bytes(),
            Self::Diff(state) => state.retained_bytes(),
        }
    }
}

impl WorkspaceQueryService {
    pub(super) fn put_directory(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        state: DirectoryContinuation,
    ) -> Result<PageCursor, RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Directory(state))
    }

    pub(super) fn take_directory(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<DirectoryContinuation, RpcError> {
        match self.take(owner, workspace, scope, "directory", cursor)? {
            QueryContinuation::Directory(state) => Ok(state),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    pub(super) fn put_search(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        state: SearchContinuation,
    ) -> Result<PageCursor, RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Search(state))
    }

    pub(super) fn take_search(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<SearchContinuation, RpcError> {
        match self.take(owner, workspace, scope, "search", cursor)? {
            QueryContinuation::Search(state) => Ok(state),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    pub(super) fn put_diff(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        state: DiffContinuation,
    ) -> Result<PageCursor, RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Diff(state))
    }

    pub(super) fn take_diff(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<DiffContinuation, RpcError> {
        match self.take(owner, workspace, scope, "diff", cursor)? {
            QueryContinuation::Diff(state) => Ok(state),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    fn put(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        value: QueryContinuation,
    ) -> Result<PageCursor, RpcError> {
        let now = Instant::now();
        let kind = value.kind();
        let token = format!("q:{kind}:{}", uuid::Uuid::new_v4());
        let charge = value
            .retained_bytes()
            .saturating_add(token.len().saturating_mul(2))
            .saturating_add(scope.len())
            .saturating_add(owner.device_id.len())
            .saturating_add(workspace.0.len())
            .saturating_add(256);
        if charge > MAX_QUERY_CONTINUATION_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("{kind} continuation exceeds the retained query memory limit"),
            ));
        }
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.prune_continuations(now);
        while state.continuations.len() >= MAX_QUERY_CONTINUATIONS
            || state.continuation_bytes.saturating_add(charge) > MAX_QUERY_CONTINUATION_BYTES
        {
            if !state.evict_oldest_continuation() {
                return Err(RpcError::new(
                    "resource-exhausted",
                    "retained query memory is unavailable",
                ));
            }
        }
        state.continuation_bytes = state.continuation_bytes.saturating_add(charge);
        state.continuation_order.push_back(token.clone());
        state.continuations.insert(
            token.clone(),
            StoredContinuation {
                owner: owner.clone(),
                workspace: workspace.clone(),
                scope: scope.to_owned(),
                last_used: now,
                charge,
                value,
            },
        );
        Ok(PageCursor(token))
    }

    fn take(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        kind: &str,
        cursor: &PageCursor,
    ) -> Result<QueryContinuation, RpcError> {
        if cursor.0.len() > MAX_CURSOR_BYTES || !cursor.0.starts_with(&format!("q:{kind}:")) {
            return Err(invalid_cursor(kind));
        }
        let now = Instant::now();
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.prune_continuations(now);
        let Some(stored) = state.continuations.get(&cursor.0) else {
            return Err(RpcError::new(
                "invalid-cursor",
                format!("{kind} cursor expired, was evicted, or was already consumed"),
            ));
        };
        if stored.owner != *owner
            || stored.workspace != *workspace
            || stored.scope != scope
            || stored.value.kind() != kind
        {
            return Err(invalid_cursor(kind));
        }
        let stored =
            state.continuations.remove(&cursor.0).expect("validated continuation remains present");
        state.continuation_order.retain(|token| token != &cursor.0);
        state.continuation_bytes = state.continuation_bytes.saturating_sub(stored.charge);
        Ok(stored.value)
    }

    pub(super) fn hash_cell(&self, key: FileHashKey) -> Arc<OnceCell<String>> {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.prune_hashes(now);
        if state.hashes.contains_key(&key) {
            let cell = {
                let cached = state.hashes.get_mut(&key).expect("checked cache entry exists");
                cached.last_used = now;
                Arc::clone(&cached.cell)
            };
            state.hash_order.retain(|candidate| candidate != &key);
            state.hash_order.push_back(key);
            return cell;
        }

        let charge = key.retained_bytes().saturating_mul(2).saturating_add(128);
        if charge > MAX_FILE_HASH_KEY_BYTES {
            return Arc::new(OnceCell::new());
        }
        while state.hashes.len() >= MAX_FILE_HASH_ENTRIES
            || state.hash_key_bytes.saturating_add(charge) > MAX_FILE_HASH_KEY_BYTES
        {
            if !state.evict_oldest_hash() {
                return Arc::new(OnceCell::new());
            }
        }
        let cell = Arc::new(OnceCell::new());
        state.hash_key_bytes = state.hash_key_bytes.saturating_add(charge);
        state.hash_order.push_back(key.clone());
        state.hashes.insert(key, CachedHash { cell: Arc::clone(&cell), last_used: now, charge });
        cell
    }

    pub(super) fn close_client(&self, owner: &ClientScope) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let tokens = state
            .continuations
            .iter()
            .filter_map(|(token, stored)| (&stored.owner == owner).then_some(token.clone()))
            .collect::<Vec<_>>();
        for token in tokens {
            state.remove_continuation(&token);
        }
    }

    pub(super) fn close_client_workspace(&self, owner: &ClientScope, workspace: &WorkspaceId) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let tokens = state
            .continuations
            .iter()
            .filter_map(|(token, stored)| {
                (&stored.owner == owner && &stored.workspace == workspace).then_some(token.clone())
            })
            .collect::<Vec<_>>();
        for token in tokens {
            state.remove_continuation(&token);
        }
    }

    pub(super) fn close_workspace(&self, workspace: &WorkspaceId) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let tokens = state
            .continuations
            .iter()
            .filter_map(|(token, stored)| (&stored.workspace == workspace).then_some(token.clone()))
            .collect::<Vec<_>>();
        for token in tokens {
            state.remove_continuation(&token);
        }
        let hashes = state
            .hashes
            .keys()
            .filter(|key| &key.workspace == workspace)
            .cloned()
            .collect::<Vec<_>>();
        for key in hashes {
            state.remove_hash(&key);
        }
    }

    pub(super) fn clear(&self) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *state = QueryState::default();
    }
}

impl QueryState {
    fn prune_continuations(&mut self, now: Instant) {
        let expired = self
            .continuations
            .iter()
            .filter_map(|(token, stored)| {
                (now.saturating_duration_since(stored.last_used) >= QUERY_CONTINUATION_TTL)
                    .then_some(token.clone())
            })
            .collect::<Vec<_>>();
        for token in expired {
            self.remove_continuation(&token);
        }
    }

    fn evict_oldest_continuation(&mut self) -> bool {
        while let Some(token) = self.continuation_order.pop_front() {
            if let Some(stored) = self.continuations.remove(&token) {
                self.continuation_bytes = self.continuation_bytes.saturating_sub(stored.charge);
                return true;
            }
        }
        false
    }

    fn remove_continuation(&mut self, token: &str) {
        if let Some(stored) = self.continuations.remove(token) {
            self.continuation_bytes = self.continuation_bytes.saturating_sub(stored.charge);
        }
        self.continuation_order.retain(|candidate| candidate != token);
    }

    fn prune_hashes(&mut self, now: Instant) {
        let expired = self
            .hashes
            .iter()
            .filter_map(|(key, cached)| {
                (now.saturating_duration_since(cached.last_used) >= FILE_HASH_TTL)
                    .then_some(key.clone())
            })
            .collect::<Vec<_>>();
        for key in expired {
            self.remove_hash(&key);
        }
    }

    fn evict_oldest_hash(&mut self) -> bool {
        while let Some(key) = self.hash_order.pop_front() {
            if let Some(cached) = self.hashes.remove(&key) {
                self.hash_key_bytes = self.hash_key_bytes.saturating_sub(cached.charge);
                return true;
            }
        }
        false
    }

    fn remove_hash(&mut self, key: &FileHashKey) {
        if let Some(cached) = self.hashes.remove(key) {
            self.hash_key_bytes = self.hash_key_bytes.saturating_sub(cached.charge);
        }
        self.hash_order.retain(|candidate| candidate != key);
    }
}

fn invalid_cursor(kind: &str) -> RpcError {
    RpcError::new("invalid-cursor", format!("cursor does not belong to this {kind} request"))
}

struct CachedHash {
    cell: Arc<OnceCell<String>>,
    last_used: Instant,
    charge: usize,
}

#[derive(Clone, Debug, Eq)]
pub(super) struct FileHashKey {
    workspace: WorkspaceId,
    path: PathBuf,
    identity: FileIdentity,
}

impl FileHashKey {
    pub(super) fn new(workspace: WorkspaceId, path: PathBuf, metadata: &std::fs::Metadata) -> Self {
        Self { workspace, path, identity: FileIdentity::from_metadata(metadata) }
    }

    pub(super) fn matches(&self, path: &Path, metadata: &std::fs::Metadata) -> bool {
        self.path == path && self.identity == FileIdentity::from_metadata(metadata)
    }

    fn retained_bytes(&self) -> usize {
        self.workspace
            .0
            .len()
            .saturating_add(self.path.as_os_str().len())
            .saturating_add(size_of::<Self>())
    }
}

impl PartialEq for FileHashKey {
    fn eq(&self, other: &Self) -> bool {
        self.workspace == other.workspace
            && self.path == other.path
            && self.identity == other.identity
    }
}

impl Hash for FileHashKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.workspace.hash(state);
        self.path.hash(state);
        self.identity.hash(state);
    }
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
    mode: u32,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

#[cfg(unix)]
impl FileIdentity {
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt as _;

        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            mode: metadata.mode(),
            length: metadata.len(),
            modified_seconds: metadata.mtime(),
            modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
        }
    }
}

#[cfg(not(unix))]
#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct FileIdentity {
    length: u64,
    modified_nanoseconds: Option<u128>,
}

#[cfg(not(unix))]
impl FileIdentity {
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        let modified_nanoseconds = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos());
        Self { length: metadata.len(), modified_nanoseconds }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuation_store_binds_owner_scope_and_consumes_tokens_once() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let other_owner = ClientScope::new("other", cmux_remote_protocol::SessionId([2; 16]));
        let workspace = WorkspaceId("workspace".into());
        let cursor = service
            .put_directory(&owner, &workspace, "scope", DirectoryContinuation::for_test())
            .unwrap();
        assert!(service.take_directory(&owner, &workspace, "other", &cursor).is_err());
        assert!(service.take_directory(&other_owner, &workspace, "scope", &cursor).is_err());
        service.take_directory(&owner, &workspace, "scope", &cursor).unwrap();
        assert!(service.take_directory(&owner, &workspace, "scope", &cursor).is_err());
    }

    #[test]
    fn continuation_store_evicts_oldest_at_the_count_limit() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let workspace = WorkspaceId("workspace".into());
        let cursors = (0..=MAX_QUERY_CONTINUATIONS)
            .map(|index| {
                service
                    .put_directory(
                        &owner,
                        &workspace,
                        &format!("scope-{index}"),
                        DirectoryContinuation::for_test(),
                    )
                    .unwrap()
            })
            .collect::<Vec<_>>();
        assert!(service.take_directory(&owner, &workspace, "scope-0", &cursors[0]).is_err());
        service
            .take_directory(
                &owner,
                &workspace,
                &format!("scope-{MAX_QUERY_CONTINUATIONS}"),
                cursors.last().unwrap(),
            )
            .unwrap();
    }

    #[test]
    fn lifecycle_cleanup_removes_only_the_targeted_continuations() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let other_owner = ClientScope::new("other", cmux_remote_protocol::SessionId([2; 16]));
        let workspace = WorkspaceId("workspace".into());
        let other_workspace = WorkspaceId("other-workspace".into());
        let owned = service
            .put_directory(&owner, &workspace, "owned", DirectoryContinuation::for_test())
            .unwrap();
        let other = service
            .put_directory(
                &other_owner,
                &other_workspace,
                "other",
                DirectoryContinuation::for_test(),
            )
            .unwrap();

        service.close_client_workspace(&owner, &workspace);
        assert!(service.take_directory(&owner, &workspace, "owned", &owned).is_err());
        service.take_directory(&other_owner, &other_workspace, "other", &other).unwrap();
    }

    #[tokio::test]
    async fn file_hash_cells_singleflight_one_file_version() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("value.txt");
        std::fs::write(&path, b"value").unwrap();
        let metadata = std::fs::metadata(&path).unwrap();
        let key = FileHashKey::new(WorkspaceId("workspace".into()), path, &metadata);
        let service = WorkspaceQueryService::default();
        let first = service.hash_cell(key.clone());
        let second = service.hash_cell(key);
        assert!(Arc::ptr_eq(&first, &second));

        let computations = Arc::new(AtomicUsize::new(0));
        let first_count = Arc::clone(&computations);
        let second_count = Arc::clone(&computations);
        let (first_hash, second_hash) = tokio::join!(
            first.get_or_init(|| async move {
                first_count.fetch_add(1, Ordering::SeqCst);
                tokio::task::yield_now().await;
                "hash".to_string()
            }),
            second.get_or_init(|| async move {
                second_count.fetch_add(1, Ordering::SeqCst);
                "other".to_string()
            }),
        );
        assert_eq!(first_hash, "hash");
        assert_eq!(second_hash, "hash");
        assert_eq!(computations.load(Ordering::SeqCst), 1);
    }
}
