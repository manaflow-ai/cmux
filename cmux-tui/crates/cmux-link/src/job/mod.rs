//! Copy jobs (finder.md 5.2) between the link's machine and an SFTP host,
//! or between two roots of one host.
//!
//! The destination owner runs the job. Bytes move through a bulk channel
//! with a credit window, so a slow destination slows the source instead of
//! filling memory. Each file is written to a temporary name and renamed on
//! completion; a cancel stops at the next chunk and removes the partial
//! file. Events carry a sequence number and progress is sent at most four
//! times a second.

pub mod endpoint;
#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc, watch};

use crate::bulk;
use crate::fs::{EntryKind, FsError, SftpRoot, WriteMode, components};
pub use endpoint::{Endpoint, Item, LocalRoot};

/// Most items one job may hold (finder.md 5.2).
pub const MAX_ITEMS: usize = 1_000_000;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConflictPolicy {
    Ask,
    Replace,
    Skip,
    KeepBoth,
}

/// A user's answer to a conflict.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Choice {
    Replace,
    Skip,
    KeepBoth,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileFacts {
    pub size: u64,
}

/// One job event (finder.md 5.2 `fs.job` stream).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum JobEventKind {
    Preparing {
        items_total: u64,
        bytes_total: u64,
    },
    Progress {
        bytes_done: u64,
        bytes_total: u64,
        items_done: u64,
        items_total: u64,
        current: Option<String>,
    },
    Conflict {
        item: String,
        existing: FileFacts,
        incoming: FileFacts,
    },
    Resolved,
    Cancelling,
    Done,
    Failed {
        error: FsError,
    },
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobEvent {
    pub job: String,
    pub seq: u64,
    #[serde(flatten)]
    pub kind: JobEventKind,
}

/// What to copy.
pub struct CopyRequest {
    pub from: Endpoint,
    /// Paths relative to the source root.
    pub paths: Vec<String>,
    pub to: Endpoint,
    /// Destination folder, relative to the destination root.
    pub destination: String,
    pub conflict: ConflictPolicy,
    pub window_bytes: usize,
}

struct Control {
    cancel: watch::Sender<bool>,
    resolve: Mutex<Option<mpsc::UnboundedSender<(Choice, bool)>>>,
}

/// A running job: its id, its events and its controls.
pub struct JobHandle {
    pub job: String,
    pub events: mpsc::UnboundedReceiver<JobEvent>,
    control: Arc<Control>,
}

impl JobHandle {
    /// `fs.job.cancel`: the owner stops at the next chunk.
    pub fn cancel(&self) {
        self.control.cancel.send_replace(true);
    }

    /// `fs.job.resolve` for the conflict the job is waiting on.
    pub async fn resolve(&self, choice: Choice, apply_to_all: bool) -> bool {
        match &*self.control.resolve.lock().await {
            Some(sender) => sender.send((choice, apply_to_all)).is_ok(),
            None => false,
        }
    }
}

/// Starts a copy job on the current Tokio runtime.
#[must_use]
pub fn start_copy(request: CopyRequest) -> JobHandle {
    let job = crate::ids::random_id("job_");
    let (events, receiver) = mpsc::unbounded_channel();
    let (resolve_sender, resolve_receiver) = mpsc::unbounded_channel();
    let control = Arc::new(Control {
        cancel: watch::channel(false).0,
        resolve: Mutex::new(Some(resolve_sender)),
    });
    let mut runner = Runner {
        emitter: Emitter { job: job.clone(), seq: 0, events },
        cancel: control.cancel.subscribe(),
        resolve: resolve_receiver,
        apply_to_all: None,
        last_progress: None,
    };
    tokio::spawn(async move {
        let result = runner.run(request).await;
        let kind = match result {
            Ok(()) => JobEventKind::Done,
            Err(FsError::Cancelled) => JobEventKind::Cancelled,
            Err(error) => JobEventKind::Failed { error },
        };
        runner.emitter.emit(kind);
    });
    JobHandle { job, events: receiver, control }
}

struct Emitter {
    job: String,
    seq: u64,
    events: mpsc::UnboundedSender<JobEvent>,
}

impl Emitter {
    fn emit(&mut self, kind: JobEventKind) {
        self.seq += 1;
        let _ = self.events.send(JobEvent { job: self.job.clone(), seq: self.seq, kind });
    }
}

#[derive(Default)]
struct Totals {
    items_total: u64,
    bytes_total: u64,
    items_done: u64,
    bytes_done: u64,
}

struct Runner {
    emitter: Emitter,
    cancel: watch::Receiver<bool>,
    resolve: mpsc::UnboundedReceiver<(Choice, bool)>,
    apply_to_all: Option<Choice>,
    last_progress: Option<Instant>,
}

impl Runner {
    async fn run(&mut self, request: CopyRequest) -> Result<(), FsError> {
        let items = prepare(&request.from, &request.paths).await?;
        let mut totals = Totals {
            items_total: items.len() as u64,
            bytes_total: items
                .iter()
                .filter(|item| item.kind == EntryKind::File)
                .map(|item| item.size)
                .sum(),
            ..Totals::default()
        };
        self.emitter.emit(JobEventKind::Preparing {
            items_total: totals.items_total,
            bytes_total: totals.bytes_total,
        });
        for item in &items {
            self.check_cancel()?;
            let target = join(&request.destination, &item.destination);
            match item.kind {
                EntryKind::Dir => request.to.ensure_directory(&target).await?,
                EntryKind::File => {
                    if let Some((target, mode)) = self.place(&request, item, &target).await? {
                        self.transfer(&request, item, &target, mode, &mut totals).await?;
                    }
                }
                // Symlinks and special files are not copied.
                EntryKind::Symlink | EntryKind::Other => {}
            }
            totals.items_done += 1;
            self.progress(&totals, Some(&item.destination), false);
        }
        self.progress(&totals, None, true);
        Ok(())
    }

    fn check_cancel(&mut self) -> Result<(), FsError> {
        if *self.cancel.borrow() {
            self.emitter.emit(JobEventKind::Cancelling);
            return Err(FsError::Cancelled);
        }
        Ok(())
    }

    fn progress(&mut self, totals: &Totals, current: Option<&str>, force: bool) {
        let now = Instant::now();
        if !force
            && self.last_progress.is_some_and(|last| now.duration_since(last) < PROGRESS_INTERVAL)
        {
            return;
        }
        self.last_progress = Some(now);
        self.emitter.emit(JobEventKind::Progress {
            bytes_done: totals.bytes_done,
            bytes_total: totals.bytes_total,
            items_done: totals.items_done,
            items_total: totals.items_total,
            current: current.map(str::to_owned),
        });
    }

    /// Decides where a file goes when the target exists; `None` skips it.
    async fn place(
        &mut self,
        request: &CopyRequest,
        item: &Item,
        target: &str,
    ) -> Result<Option<(String, WriteMode)>, FsError> {
        let Some((kind, size)) = request.to.kind_of(target).await? else {
            return Ok(Some((target.to_owned(), WriteMode::Create)));
        };
        let choice = match (request.conflict, self.apply_to_all) {
            (_, Some(choice)) => choice,
            (ConflictPolicy::Replace, _) => Choice::Replace,
            (ConflictPolicy::Skip, _) => Choice::Skip,
            (ConflictPolicy::KeepBoth, _) => Choice::KeepBoth,
            (ConflictPolicy::Ask, None) => {
                self.emitter.emit(JobEventKind::Conflict {
                    item: item.destination.clone(),
                    existing: FileFacts { size },
                    incoming: FileFacts { size: item.size },
                });
                let answer = tokio::select! {
                    answer = self.resolve.recv() => answer,
                    _ = self.cancel.wait_for(|cancelled| *cancelled) => None,
                };
                let Some((choice, apply_to_all)) = answer else {
                    self.emitter.emit(JobEventKind::Cancelling);
                    return Err(FsError::Cancelled);
                };
                self.emitter.emit(JobEventKind::Resolved);
                if apply_to_all {
                    self.apply_to_all = Some(choice);
                }
                choice
            }
        };
        match choice {
            Choice::Skip => Ok(None),
            Choice::Replace if kind == EntryKind::File => {
                Ok(Some((target.to_owned(), WriteMode::Overwrite)))
            }
            Choice::Replace => Err(FsError::Exists),
            Choice::KeepBoth => {
                Ok(Some((free_name(&request.to, target).await?, WriteMode::Create)))
            }
        }
    }

    async fn transfer(
        &mut self,
        request: &CopyRequest,
        item: &Item,
        target: &str,
        mode: WriteMode,
        totals: &mut Totals,
    ) -> Result<(), FsError> {
        let mut source = request.from.open_source(&item.source).await?;
        let mut sink = match request.to.create_sink(target).await {
            Ok(sink) => sink,
            Err(error) => {
                source.close().await;
                return Err(error);
            }
        };
        let (sender, mut receiver) = bulk::channel(request.window_bytes.max(1));
        let mut cancel = self.cancel.clone();
        let producer = tokio::spawn(async move {
            let result = async {
                while let Some(span) = source.next_span().await? {
                    if sender.send(span).await.is_err() {
                        return Err(FsError::Cancelled);
                    }
                }
                Ok(())
            }
            .await;
            source.close().await;
            result
        });
        let written = loop {
            let chunk = tokio::select! {
                chunk = receiver.recv() => chunk,
                _ = cancel.wait_for(|cancelled| *cancelled) => break Err(FsError::Cancelled),
            };
            match chunk {
                Ok(Some(chunk)) => {
                    let length = chunk.len();
                    if let Err(error) = sink.write(chunk).await {
                        break Err(error);
                    }
                    receiver.ack(length);
                    totals.bytes_done += length as u64;
                    self.progress(totals, Some(&item.destination), false);
                }
                Ok(None) => break Ok(()),
                Err(bulk::Closed) => break Err(FsError::Cancelled),
            }
        };
        receiver.close();
        let produced = producer
            .await
            .unwrap_or_else(|error| Err(FsError::Failure { message: error.to_string() }));
        let outcome = written.and(produced);
        match outcome {
            Ok(()) => sink.commit(mode).await,
            Err(error) => {
                sink.abort().await;
                if error == FsError::Cancelled {
                    self.emitter.emit(JobEventKind::Cancelling);
                }
                Err(error)
            }
        }
    }
}

/// Lists every item under the source paths, parents before children.
async fn prepare(from: &Endpoint, paths: &[String]) -> Result<Vec<Item>, FsError> {
    let mut items = Vec::new();
    for path in paths {
        let parts = components(path)?;
        let name = parts.last().ok_or(FsError::NameInvalid)?.to_string();
        let Some((kind, size)) = from.kind_of(path).await? else { return Err(FsError::NotFound) };
        let mut pending = vec![(parts.join("/"), name, kind, size)];
        while let Some((source, destination, kind, size)) = pending.pop() {
            if items.len() >= MAX_ITEMS {
                return Err(FsError::TooLarge { total: items.len() as u64 });
            }
            if kind == EntryKind::Dir {
                let mut children = from.children(&source).await?;
                children.sort_by(|left, right| right.0.cmp(&left.0));
                for (child, child_kind, child_size) in children {
                    pending.push((
                        format!("{source}/{child}"),
                        format!("{destination}/{child}"),
                        child_kind,
                        child_size,
                    ));
                }
            }
            items.push(Item { source, destination, kind, size });
        }
    }
    Ok(items)
}

/// `name 2.ext`, `name 3.ext`, … : the first name not taken in the folder.
async fn free_name(to: &Endpoint, target: &str) -> Result<String, FsError> {
    let (folder, name) =
        target.rsplit_once('/').map_or(("", target), |(folder, name)| (folder, name));
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    for number in 2..10_000 {
        let candidate = join(folder, &format!("{stem} {number}{extension}"));
        if to.kind_of(&candidate).await?.is_none() {
            return Ok(candidate);
        }
    }
    Err(FsError::Exists)
}

fn join(folder: &str, name: &str) -> String {
    let folder = folder.trim_matches('/');
    if folder.is_empty() || folder == "." { name.to_owned() } else { format!("{folder}/{name}") }
}

/// Removes `relative` and everything below it on an SFTP root (the root
/// itself never). Symlinks are removed, not followed.
pub async fn remove_tree(root: &SftpRoot, relative: &str) -> Result<(), FsError> {
    let parts = components(relative)?;
    if parts.is_empty() {
        return Err(FsError::NotInsideRoot);
    }
    let start = parts.join("/");
    let mut stack = vec![(start, false)];
    while let Some((path, visited)) = stack.pop() {
        let Some((kind, _)) = root.kind_of(&path).await? else { continue };
        if kind == EntryKind::Dir && !visited {
            stack.push((path.clone(), true));
            for entry in root.read_directory(&path).await?.0 {
                stack.push((format!("{path}/{}", entry.name), false));
            }
            continue;
        }
        root.remove(&path).await?;
    }
    Ok(())
}
