use std::collections::{HashMap, HashSet, VecDeque};
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
    state: Arc<StdMutex<QueryState>>,
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
    leased: bool,
    predecessor: Option<String>,
    successor: Option<String>,
    value: Arc<QueryContinuation>,
}

#[derive(Clone)]
enum QueryContinuation {
    Directory(DirectoryContinuation),
    Search(SearchContinuation),
    Diff(DiffContinuation),
}

pub(super) struct ContinuationDelivery {
    state: Arc<StdMutex<QueryState>>,
    parent: Option<String>,
    clone_charge: usize,
    successor: Option<String>,
    successor_created: bool,
    finished: bool,
}

impl ContinuationDelivery {
    pub(super) fn finish_preparation(&mut self) {
        if self.clone_charge == 0 {
            return;
        }
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.continuation_bytes = state.continuation_bytes.saturating_sub(self.clone_charge);
        self.clone_charge = 0;
    }

    pub(super) fn commit(mut self) {
        self.finish(true);
    }

    fn finish(&mut self, delivered: bool) {
        if self.finished {
            return;
        }
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.continuation_bytes = state.continuation_bytes.saturating_sub(self.clone_charge);
        if let Some(successor) = &self.successor {
            if delivered || !self.successor_created {
                state.release_continuation(successor);
            } else {
                state.remove_continuation(successor);
            }
        }
        // A delivered parent remains replayable until the client proves it
        // received this page by presenting the successor cursor.
        if let Some(parent) = &self.parent {
            state.release_continuation(parent);
        }
        self.finished = true;
    }
}

impl Drop for ContinuationDelivery {
    fn drop(&mut self) {
        self.finish(false);
    }
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
        delivery: Option<ContinuationDelivery>,
    ) -> Result<(PageCursor, ContinuationDelivery), RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Directory(state), delivery)
    }

    pub(super) fn lease_directory(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<(DirectoryContinuation, ContinuationDelivery), RpcError> {
        match self.lease(owner, workspace, scope, "directory", cursor)? {
            (QueryContinuation::Directory(state), delivery) => Ok((state, delivery)),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    pub(super) fn put_search(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        state: SearchContinuation,
        delivery: Option<ContinuationDelivery>,
    ) -> Result<(PageCursor, ContinuationDelivery), RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Search(state), delivery)
    }

    pub(super) fn lease_search(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<(SearchContinuation, ContinuationDelivery), RpcError> {
        match self.lease(owner, workspace, scope, "search", cursor)? {
            (QueryContinuation::Search(state), delivery) => Ok((state, delivery)),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    pub(super) fn put_diff(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        state: DiffContinuation,
        delivery: Option<ContinuationDelivery>,
    ) -> Result<(PageCursor, ContinuationDelivery), RpcError> {
        self.put(owner, workspace, scope, QueryContinuation::Diff(state), delivery)
    }

    pub(super) fn lease_diff(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        cursor: &PageCursor,
    ) -> Result<(DiffContinuation, ContinuationDelivery), RpcError> {
        match self.lease(owner, workspace, scope, "diff", cursor)? {
            (QueryContinuation::Diff(state), delivery) => Ok((state, delivery)),
            _ => unreachable!("continuation kind was validated"),
        }
    }

    fn put(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        value: QueryContinuation,
        mut delivery: Option<ContinuationDelivery>,
    ) -> Result<(PageCursor, ContinuationDelivery), RpcError> {
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
        if let Some(delivery) = &delivery {
            let parent_is_leased = Arc::ptr_eq(&delivery.state, &self.state)
                && delivery.successor.is_none()
                && delivery.parent.as_ref().is_some_and(|parent| {
                    state.continuations.get(parent).is_some_and(|stored| stored.leased)
                });
            if !parent_is_leased {
                drop(state);
                return Err(cursor_lifecycle_error());
            }
        }
        let clone_charge = delivery.as_ref().map_or(0, |delivery| delivery.clone_charge);
        if let Some(parent) = delivery.as_ref().and_then(|delivery| delivery.parent.as_ref()) {
            let existing =
                state.continuations.get(parent).and_then(|stored| stored.successor.clone());
            if let Some(existing) = existing {
                if !state.continuations.contains_key(&existing) {
                    state
                        .continuations
                        .get_mut(parent)
                        .expect("validated parent continuation remains present")
                        .successor = None;
                } else {
                    let successor = state
                        .continuations
                        .get_mut(&existing)
                        .expect("checked successor continuation exists");
                    if successor.leased {
                        drop(state);
                        return Err(cursor_in_use(kind));
                    }
                    successor.leased = true;
                    successor.last_used = now;
                    state.continuation_order.retain(|token| token != &existing);
                    state.continuation_order.push_back(existing.clone());
                    state.continuation_bytes =
                        state.continuation_bytes.saturating_sub(clone_charge);
                    let mut delivery = delivery.take().expect("replay has a parent delivery");
                    delivery.clone_charge = 0;
                    delivery.successor = Some(existing.clone());
                    delivery.successor_created = false;
                    return Ok((PageCursor(existing), delivery));
                }
            }
        }
        while state.continuations.len() >= MAX_QUERY_CONTINUATIONS
            || state.continuation_bytes.saturating_sub(clone_charge).saturating_add(charge)
                > MAX_QUERY_CONTINUATION_BYTES
        {
            if !state.evict_oldest_continuation() {
                drop(state);
                return Err(RpcError::new(
                    "resource-exhausted",
                    "retained query memory is unavailable",
                ));
            }
        }
        state.continuation_bytes =
            state.continuation_bytes.saturating_sub(clone_charge).saturating_add(charge);
        let predecessor = delivery.as_ref().and_then(|delivery| delivery.parent.clone());
        state.continuation_order.push_back(token.clone());
        state.continuations.insert(
            token.clone(),
            StoredContinuation {
                owner: owner.clone(),
                workspace: workspace.clone(),
                scope: scope.to_owned(),
                last_used: now,
                charge,
                leased: true,
                predecessor: predecessor.clone(),
                successor: None,
                value: Arc::new(value),
            },
        );
        if let Some(parent) = &predecessor {
            state
                .continuations
                .get_mut(parent)
                .expect("validated parent continuation remains present")
                .successor = Some(token.clone());
        }
        let delivery = if let Some(mut delivery) = delivery.take() {
            delivery.clone_charge = 0;
            delivery.successor = Some(token.clone());
            delivery.successor_created = true;
            delivery
        } else {
            ContinuationDelivery {
                state: Arc::clone(&self.state),
                parent: None,
                clone_charge: 0,
                successor: Some(token.clone()),
                successor_created: true,
                finished: false,
            }
        };
        Ok((PageCursor(token), delivery))
    }

    fn lease(
        &self,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
        kind: &str,
        cursor: &PageCursor,
    ) -> Result<(QueryContinuation, ContinuationDelivery), RpcError> {
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
        if stored.leased {
            return Err(cursor_in_use(kind));
        }
        let (value, charge, predecessor) = {
            let stored = state
                .continuations
                .get_mut(&cursor.0)
                .expect("validated continuation remains present");
            stored.leased = true;
            stored.last_used = now;
            (Arc::clone(&stored.value), stored.charge, stored.predecessor.take())
        };
        if let Some(predecessor) = predecessor {
            state.remove_continuation(&predecessor);
        }
        while state.continuation_bytes.saturating_add(charge) > MAX_QUERY_CONTINUATION_BYTES {
            if !state.evict_oldest_continuation() {
                state
                    .continuations
                    .get_mut(&cursor.0)
                    .expect("leased continuation remains present")
                    .leased = false;
                return Err(RpcError::new(
                    "resource-exhausted",
                    "retained query memory is unavailable for a cursor lease",
                ));
            }
        }
        state.continuation_bytes = state.continuation_bytes.saturating_add(charge);
        state.continuation_order.retain(|token| token != &cursor.0);
        state.continuation_order.push_back(cursor.0.clone());
        drop(state);

        let delivery = ContinuationDelivery {
            state: Arc::clone(&self.state),
            parent: Some(cursor.0.clone()),
            clone_charge: charge,
            successor: None,
            successor_created: false,
            finished: false,
        };
        Ok((value.as_ref().clone(), delivery))
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
        state.remove_continuations_where(|stored| &stored.owner == owner);
    }

    pub(super) fn close_client_workspace(&self, owner: &ClientScope, workspace: &WorkspaceId) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.remove_continuations_where(|stored| {
            &stored.owner == owner && &stored.workspace == workspace
        });
    }

    pub(super) fn close_workspace(&self, workspace: &WorkspaceId) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.remove_continuations_where(|stored| &stored.workspace == workspace);
        state.remove_hashes_where(|key, _| &key.workspace == workspace);
    }

    pub(super) fn clear(&self) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *state = QueryState::default();
    }
}

impl QueryState {
    fn prune_continuations(&mut self, now: Instant) {
        self.remove_continuations_where(|stored| {
            !stored.leased
                && now.saturating_duration_since(stored.last_used) >= QUERY_CONTINUATION_TTL
        });
    }

    fn evict_oldest_continuation(&mut self) -> bool {
        for _ in 0..self.continuation_order.len() {
            let Some(token) = self.continuation_order.pop_front() else { break };
            if self.continuations.get(&token).is_some_and(|stored| stored.leased) {
                self.continuation_order.push_back(token);
                continue;
            }
            if self.continuations.contains_key(&token) {
                self.remove_continuation(&token);
                return true;
            }
        }
        false
    }

    fn remove_continuation(&mut self, token: &str) {
        if let Some(stored) = self.continuations.remove(token) {
            self.continuation_bytes = self.continuation_bytes.saturating_sub(stored.charge);
            if let Some(predecessor) = stored.predecessor
                && let Some(parent) = self.continuations.get_mut(&predecessor)
                && parent.successor.as_deref() == Some(token)
            {
                parent.successor = None;
            }
            if let Some(successor) = stored.successor
                && let Some(child) = self.continuations.get_mut(&successor)
                && child.predecessor.as_deref() == Some(token)
            {
                child.predecessor = None;
            }
        }
        self.continuation_order.retain(|candidate| candidate != token);
    }

    fn remove_continuations_where(
        &mut self,
        mut should_remove: impl FnMut(&StoredContinuation) -> bool,
    ) {
        let tokens = self
            .continuations
            .iter()
            .filter_map(|(token, stored)| should_remove(stored).then_some(token.clone()))
            .collect::<HashSet<_>>();
        if tokens.is_empty() {
            return;
        }
        for token in &tokens {
            if let Some(stored) = self.continuations.remove(token) {
                self.continuation_bytes = self.continuation_bytes.saturating_sub(stored.charge);
            }
        }
        for stored in self.continuations.values_mut() {
            if stored.predecessor.as_ref().is_some_and(|token| tokens.contains(token)) {
                stored.predecessor = None;
            }
            if stored.successor.as_ref().is_some_and(|token| tokens.contains(token)) {
                stored.successor = None;
            }
        }
        self.continuation_order.retain(|token| !tokens.contains(token));
    }

    fn release_continuation(&mut self, token: &str) {
        let Some(stored) = self.continuations.get_mut(token) else { return };
        stored.leased = false;
        stored.last_used = Instant::now();
        self.continuation_order.retain(|candidate| candidate != token);
        self.continuation_order.push_back(token.to_owned());
    }

    fn prune_hashes(&mut self, now: Instant) {
        self.remove_hashes_where(|_, cached| {
            now.saturating_duration_since(cached.last_used) >= FILE_HASH_TTL
        });
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

    fn remove_hashes_where(
        &mut self,
        mut should_remove: impl FnMut(&FileHashKey, &CachedHash) -> bool,
    ) {
        let keys = self
            .hashes
            .iter()
            .filter_map(|(key, cached)| should_remove(key, cached).then_some(key.clone()))
            .collect::<HashSet<_>>();
        if keys.is_empty() {
            return;
        }
        for key in &keys {
            if let Some(cached) = self.hashes.remove(key) {
                self.hash_key_bytes = self.hash_key_bytes.saturating_sub(cached.charge);
            }
        }
        self.hash_order.retain(|key| !keys.contains(key));
    }
}

fn invalid_cursor(kind: &str) -> RpcError {
    RpcError::new("invalid-cursor", format!("cursor does not belong to this {kind} request"))
}

fn cursor_lifecycle_error() -> RpcError {
    let mut error = RpcError::new(
        "invalid-cursor",
        "query cursor lifecycle ended before its successor was retained",
    );
    error.retryable = true;
    error
}

fn cursor_in_use(kind: &str) -> RpcError {
    let mut error =
        RpcError::new("cursor-in-use", format!("{kind} cursor is already serving another request"));
    error.retryable = true;
    error
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

    fn delivered_directory_cursor(
        service: &WorkspaceQueryService,
        owner: &ClientScope,
        workspace: &WorkspaceId,
        scope: &str,
    ) -> PageCursor {
        let (cursor, delivery) = service
            .put_directory(owner, workspace, scope, DirectoryContinuation::for_test(), None)
            .unwrap();
        delivery.commit();
        cursor
    }

    #[test]
    fn continuation_store_binds_scope_replays_pages_and_acknowledges_predecessors() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let other_owner = ClientScope::new("other", cmux_remote_protocol::SessionId([2; 16]));
        let workspace = WorkspaceId("workspace".into());
        let parent = delivered_directory_cursor(&service, &owner, &workspace, "scope");
        assert!(service.lease_directory(&owner, &workspace, "other", &parent).is_err());
        assert!(service.lease_directory(&other_owner, &workspace, "scope", &parent).is_err());

        let (continuation, parent_delivery) =
            service.lease_directory(&owner, &workspace, "scope", &parent).unwrap();
        let (successor, delivery) = service
            .put_directory(&owner, &workspace, "scope", continuation, Some(parent_delivery))
            .unwrap();
        delivery.commit();

        let (continuation, replay_delivery) =
            service.lease_directory(&owner, &workspace, "scope", &parent).unwrap();
        let (replayed_successor, delivery) = service
            .put_directory(&owner, &workspace, "scope", continuation, Some(replay_delivery))
            .unwrap();
        assert_eq!(replayed_successor, successor);
        delivery.commit();

        let (_, successor_delivery) =
            service.lease_directory(&owner, &workspace, "scope", &successor).unwrap();
        successor_delivery.commit();
        assert!(service.lease_directory(&owner, &workspace, "scope", &parent).is_err());
    }

    #[test]
    fn dropping_an_initial_prepared_page_discards_its_undelivered_cursor() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let workspace = WorkspaceId("workspace".into());
        let (cursor, delivery) = service
            .put_directory(&owner, &workspace, "scope", DirectoryContinuation::for_test(), None)
            .unwrap();

        drop(delivery);

        assert!(service.lease_directory(&owner, &workspace, "scope", &cursor).is_err());
    }

    #[test]
    fn dropping_a_successor_page_restores_its_parent_and_discards_the_successor() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let workspace = WorkspaceId("workspace".into());
        let parent = delivered_directory_cursor(&service, &owner, &workspace, "scope");
        let (continuation, parent_delivery) =
            service.lease_directory(&owner, &workspace, "scope", &parent).unwrap();
        let (successor, delivery) = service
            .put_directory(&owner, &workspace, "scope", continuation, Some(parent_delivery))
            .unwrap();

        drop(delivery);

        assert!(service.lease_directory(&owner, &workspace, "scope", &successor).is_err());
        let (_, parent_delivery) =
            service.lease_directory(&owner, &workspace, "scope", &parent).unwrap();
        parent_delivery.commit();
    }

    #[test]
    fn continuation_store_evicts_oldest_at_the_count_limit() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let workspace = WorkspaceId("workspace".into());
        let cursors = (0..=MAX_QUERY_CONTINUATIONS)
            .map(|index| {
                delivered_directory_cursor(&service, &owner, &workspace, &format!("scope-{index}"))
            })
            .collect::<Vec<_>>();
        assert!(service.lease_directory(&owner, &workspace, "scope-0", &cursors[0]).is_err());
        let (_, delivery) = service
            .lease_directory(
                &owner,
                &workspace,
                &format!("scope-{MAX_QUERY_CONTINUATIONS}"),
                cursors.last().unwrap(),
            )
            .unwrap();
        delivery.commit();
    }

    #[test]
    fn lifecycle_cleanup_removes_only_the_targeted_continuations() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let other_owner = ClientScope::new("other", cmux_remote_protocol::SessionId([2; 16]));
        let workspace = WorkspaceId("workspace".into());
        let other_workspace = WorkspaceId("other-workspace".into());
        let owned = delivered_directory_cursor(&service, &owner, &workspace, "owned");
        let other = delivered_directory_cursor(&service, &other_owner, &other_workspace, "other");

        service.close_client_workspace(&owner, &workspace);
        assert!(service.lease_directory(&owner, &workspace, "owned", &owned).is_err());
        let (_, delivery) =
            service.lease_directory(&other_owner, &other_workspace, "other", &other).unwrap();
        delivery.commit();
    }

    #[test]
    fn bulk_lifecycle_cleanup_keeps_lru_indexes_consistent() {
        let service = WorkspaceQueryService::default();
        let owner = ClientScope::new("device", cmux_remote_protocol::SessionId([1; 16]));
        let other_owner = ClientScope::new("other", cmux_remote_protocol::SessionId([2; 16]));
        let workspace = WorkspaceId("workspace".into());
        let other_workspace = WorkspaceId("other-workspace".into());
        for index in 0..16 {
            delivered_directory_cursor(&service, &owner, &workspace, &format!("target-{index}"));
            delivered_directory_cursor(
                &service,
                &other_owner,
                &other_workspace,
                &format!("survivor-{index}"),
            );
        }

        service.close_client(&owner);

        let state = service.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(state.continuations.len(), 16);
        assert_eq!(state.continuation_order.len(), 16);
        assert!(
            state.continuation_order.iter().all(|token| state.continuations.contains_key(token))
        );
        assert!(state.continuations.values().all(|stored| stored.owner == other_owner));
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
