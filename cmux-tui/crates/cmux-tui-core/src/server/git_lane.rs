//! The git lane: where the daemon runs the git requests of its connections
//! (`git.*` and `diff.comments.*`, `git_ops::handles`).
//!
//! A git request runs git as a child process and waits for it: seconds in a
//! large repository on a loaded machine, up to the 20 s limit of one read
//! run (`cmux_git::run`) and the 120 s limit of a commit or a push
//! (`git_ops::user_run`). A connection's reader thread must not wait that
//! long (perf-lead.md rule D1: no child process on a request path), or every
//! later request of that connection waits too: the `git.status` of the view
//! a person looks at, behind the `git.diff` that warms a hidden chat's page.
//!
//! So the reader only puts the request here and reads its next line. The
//! lane runs it on a `mux-git` thread and answers through the connection's
//! writer. Its rules:
//!
//! - **A bound for the whole daemon.** At most [`MAX_READ_RUNS`] reads and
//!   [`MAX_MUTATION_RUNS`] mutations run at one time, whatever the count of
//!   connections. A request runs its git children one after the other, so
//!   that is also the bound of git children. Agents end their turns in
//!   bursts, and each end asks for a diff: without the bound, 50 of them
//!   start 50 git processes on a machine that is busy already. Mutations
//!   have places of their own: a person's commit does not wait for the reads
//!   of a burst, and a push that takes its 120 s holds no read.
//! - **A short read does not wait for long ones.** A diff, a file list or
//!   search, the branches and a checkpoint list with its candidates are
//!   long reads ([`Class::of`]): their git work grows with the change, the
//!   tree or the count of branches. They take at most
//!   [`MAX_LONG_READ_RUNS`] of the read places, so one place is kept for
//!   the short reads (a status, a checkpoint row, the comments). The wire does
//!   not say who asks, but the operation says how long the answer takes:
//!   the `git.status` of the view a person opens starts while the diffs of
//!   a burst hold their places and wait in the queue.
//! - **Equal reads share one run.** A read that waits takes in each later
//!   read of its connection with the same operation and params. The run
//!   starts after the last of them came, so its result is new enough for
//!   each, and each gets it under its own id. The copies go to the
//!   connection one after the other: a copy waits for room in the
//!   connection's reply queue ([`SHARED_REPLY_WAIT`] at most for all the
//!   copies of a run), because the copies of a large reply at one time are
//!   above that queue's bound and the daemon closes a connection above it.
//!   Before the lane, a git run was between two replies. That wait holds
//!   no place: the run ended, so its place goes to the next request before
//!   the first copy waits ([`Class::Copies`]). A connection that reads
//!   slowly holds back only requests of its own: its next shared run, and
//!   its next mutation with the reads behind it. A connection has at most
//!   [`MAX_READ_RUNS`] runs whose copies wait, each with one reply, so
//!   what waits for it has a bound in bytes. A read with other params is a
//!   different question and is never cancelled: the wire does not say who
//!   asks, and its caller waits for an answer.
//! - **A mutation keeps its connection's order.** It starts when every
//!   earlier git request of its connection ended, and the later ones start
//!   after it: a read behind a commit sees the commit, as it did when the
//!   reader ran them in turn. Requests of different connections have no
//!   order, as before.
//! - **The limits stay.** A git past its limit is ended by its runner, the
//!   request gets that error, and the end of a run frees its place.
//! - **A connection's end.** After a clean end of its input the requests it
//!   sent still run and answer, while the client can read them
//!   ([`GitLane::drain`]): a client that ended only its writes waits for its
//!   replies. When nobody reads a reply (a broken end, a client that closed
//!   its whole end, a writer that closed while the daemon waited), its reads
//!   that wait are dropped and its mutations that wait still run, as when
//!   the reader ran each line it read ([`GitLane::abandon`]). The connection
//!   does not wait for them, so the client stops being a client at once.
//! - **Nothing starts after the shutdown began.** A daemon that shuts down
//!   or hands its session over refuses each line it reads as "not executed"
//!   (`connection_frame.rs`), so the client sends it again to the next
//!   daemon. A request that still waits here has not run either: it gets
//!   that refusal and does not start ([`GitLane::start_ready`]).
//!
//! Requests of one class start in the order they came (among those their
//! connection's order lets start); the lane knows no other priority.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::MessageWriter;
use super::ResourceRequestId;
use super::incognito_orphans::answered_ok;
use super::send_resource_response;
use crate::Mux;
use crate::diagnostics::request_log;
use crate::panic_free::RecoverPoison;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use crate::stream_interrupt::StreamInterrupt;

/// Git reads that run at one time, in the whole daemon. Small and fixed:
/// each is a git process that reads a repository, and the machine also runs
/// the person's agents and terminals. Four keep a view's read from waiting
/// behind one slow diff without a burst of git processes.
const MAX_READ_RUNS: usize = 4;

/// The read places that long reads may take at one time. One less than
/// [`MAX_READ_RUNS`]: the place they leave is where a short read starts
/// while long reads hold every place of theirs.
const MAX_LONG_READ_RUNS: usize = 3;

/// Git mutations (a commit, a push, a worktree) that run at one time, in the
/// whole daemon, beside the reads. They are a person's own actions and few.
const MAX_MUTATION_RUNS: usize = 2;

/// Git runs of one connection that wait for a place (a run is one request
/// and the equal reads that share it, [`SHARED_READS`] at most). One more
/// gets an error and does not run: a client that asks faster than git
/// answers must ask less.
const QUEUED_PER_CLIENT: usize = 512;

/// Equal reads that share one run. One more waits as a request of its own.
const SHARED_READS: usize = 64;

/// The longest the copies of one shared reply wait, all together, for room
/// in their connection's reply queue. The wait holds no place of the lane
/// ([`Class::Copies`]); it holds the reply, so it has an end. A client whose
/// queue has no room for this long gets no error reply: the daemon closes
/// its connection, as it closes any connection whose queue is full.
const SHARED_REPLY_WAIT: Duration = Duration::from_secs(10);

/// What a git request is to the order rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    /// A read whose git work is small: a status, a checkpoint row or list,
    /// the comments, the state of a worktree's setup.
    ShortRead,
    /// A read whose git work grows with the size of the change, of the tree
    /// or of the repository: a diff, a file list or search, the branches (a
    /// git child for each branch), a checkpoint list with its candidates
    /// (the untracked and the ignored paths of the tree).
    LongRead,
    /// A request that changes the repository or the daemon's git records.
    Mutation,
    /// A read that ended: the copies of its reply wait for room in their
    /// connection's reply queue. It holds no place. No request has this
    /// class when it waits ([`Schedule::copies`]).
    Copies,
}

impl Class {
    /// The class of `operation` with the params `fields`.
    fn of(operation: ResourceOperation, fields: &Map<String, Value>) -> Self {
        if operation.is_mutation() {
            return Self::Mutation;
        }
        match operation {
            ResourceOperation::GitDiff
            | ResourceOperation::GitCheckpointDiff
            | ResourceOperation::GitFilesList
            | ResourceOperation::GitFilesSearch
            | ResourceOperation::GitBranches => Self::LongRead,
            ResourceOperation::GitCheckpointList
                if fields.get("include_candidates").and_then(Value::as_bool) == Some(true) =>
            {
                Self::LongRead
            }
            _ => Self::ShortRead,
        }
    }

    fn is_mutation(self) -> bool {
        self == Self::Mutation
    }
}

/// One request that waits, as the order rules see it.
struct Entry<J> {
    client: u64,
    class: Class,
    /// A later equal read joined it: its run has copies to send.
    shared: bool,
    job: J,
}

/// One request that runs.
struct Running {
    run: u64,
    client: u64,
    class: Class,
}

/// The lane's order: which request may start, with no I/O and no clock.
struct Schedule<J> {
    queue: VecDeque<Entry<J>>,
    running: Vec<Running>,
    next_run: u64,
}

impl<J> Default for Schedule<J> {
    fn default() -> Self {
        Self { queue: VecDeque::new(), running: Vec::new(), next_run: 0 }
    }
}

impl<J> Schedule<J> {
    /// The requests of `client` that wait.
    fn queued(&self, client: u64) -> usize {
        self.queue.iter().filter(|entry| entry.client == client).count()
    }

    /// Whether `client` has a request that waits or runs.
    fn busy(&self, client: u64) -> bool {
        self.queue.iter().any(|entry| entry.client == client)
            || self.running.iter().any(|running| running.client == client)
    }

    /// The newest read of `client` that waits and that `equal` accepts, when
    /// no mutation of `client` came after it: a read that joins it runs in
    /// its place, and must not run before a mutation it came after.
    fn waiting_read(&mut self, client: u64, equal: impl Fn(&J) -> bool) -> Option<&mut J> {
        for entry in self.queue.iter_mut().rev().filter(|entry| entry.client == client) {
            if entry.class.is_mutation() {
                return None;
            }
            if equal(&entry.job) {
                entry.shared = true;
                return Some(&mut entry.job);
            }
        }
        None
    }

    fn push(&mut self, client: u64, class: Class, job: J) {
        self.queue.push_back(Entry { client, class, shared: false, job });
    }

    /// The first request that may start now, taken from the queue and
    /// counted as running. A mutation may start when nothing of its
    /// connection runs or waits before it; a read, when no mutation of its
    /// connection runs or waits before it. A long read also needs one of
    /// the places long reads may take. A read that equal reads joined does
    /// not start while copies of its connection wait: a connection holds
    /// the reply of one shared run at a time (and of those that ran with it).
    fn start_next(&mut self) -> Option<(u64, J)> {
        let count = |class: Class| self.running.iter().filter(|run| run.class == class).count();
        let (mutations, long_reads) = (count(Class::Mutation), count(Class::LongRead));
        let reads = self.running.len().saturating_sub(mutations + count(Class::Copies));
        if reads >= MAX_READ_RUNS && mutations >= MAX_MUTATION_RUNS {
            return None;
        }
        // Connections with an earlier request that still waits, and those
        // whose earlier request that waits is a mutation.
        let mut waiting: Vec<u64> = Vec::new();
        let mut barred: Vec<u64> = Vec::new();
        let mut found = None;
        for (index, entry) in self.queue.iter().enumerate() {
            let client = entry.client;
            // Whether a run of this connection is one that `wanted` accepts.
            let of_client = |wanted: fn(Class) -> bool| {
                let mut runs = self.running.iter().filter(|running| running.client == client);
                runs.any(|running| wanted(running.class))
            };
            let may_start = if entry.class.is_mutation() {
                mutations < MAX_MUTATION_RUNS && !waiting.contains(&client) && !of_client(|_| true)
            } else {
                reads < MAX_READ_RUNS
                    && (entry.class == Class::ShortRead || long_reads < MAX_LONG_READ_RUNS)
                    && !barred.contains(&client)
                    && !of_client(Class::is_mutation)
                    && !(entry.shared && of_client(|class| class == Class::Copies))
            };
            if may_start {
                found = Some(index);
                break;
            }
            if !waiting.contains(&client) {
                waiting.push(client);
            }
            if entry.class.is_mutation() && !barred.contains(&client) {
                barred.push(client);
            }
        }
        let entry = self.queue.remove(found?)?;
        let run = self.next_run;
        self.next_run = self.next_run.wrapping_add(1);
        self.running.push(Running { run, client: entry.client, class: entry.class });
        Some((run, entry.job))
    }

    fn finish(&mut self, run: u64) {
        self.running.retain(|running| running.run != run);
    }

    /// The read `run` ended and the copies of its reply wait for room: it
    /// gives its place back, and its connection stays busy until
    /// [`Schedule::finish`].
    fn copies(&mut self, run: u64) {
        for running in self.running.iter_mut().filter(|running| running.run == run) {
            running.class = Class::Copies;
        }
    }

    /// Takes the reads of `client` that wait. Its mutations stay: the
    /// daemon took them, so they run in their turn.
    fn take_waiting_reads(&mut self, client: u64) -> Vec<J> {
        let (taken, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.queue)
            .into_iter()
            .partition(|entry| entry.client == client && !entry.class.is_mutation());
        self.queue = kept.into();
        taken.into_iter().map(|entry| entry.job).collect()
    }

    /// Takes each request that waits, of every connection.
    fn take_waiting(&mut self) -> Vec<J> {
        std::mem::take(&mut self.queue).into_iter().map(|entry| entry.job).collect()
    }
}

/// Who waits for a run's result.
struct Waiter {
    id: ResourceRequestId,
    /// When the reader gave the request to the lane: its counted time
    /// (`server-stats` section `commands`) runs from here to its reply.
    arrived: Instant,
    /// The request's slow-log record, off the reader thread.
    slow_log: Option<request_log::Parked>,
}

impl Waiter {
    fn new(id: ResourceRequestId) -> Self {
        Self { id, arrived: Instant::now(), slow_log: request_log::park() }
    }
}

/// One run: a request, and the equal reads that share its result.
struct Job {
    client: u64,
    writer: MessageWriter,
    request: ParsedResourceRequest,
    first: Waiter,
    joined: Vec<Waiter>,
}

impl Job {
    /// Whether `request` asks what this read asks: the same operation and
    /// params from the same actor, with nothing else on its envelope.
    fn same_read(&self, request: &ParsedResourceRequest) -> bool {
        let (own, other) = (&self.request.envelope, &request.envelope);
        self.joined.len() < SHARED_READS
            && own.operation == other.operation
            && own.params == other.params
            && self.request.actor == request.actor
            && [own, other].iter().all(|envelope| {
                envelope.idempotency_key.is_none()
                    && envelope.origin.is_none()
                    && envelope.credential.is_none()
            })
    }

    fn run(self, place: &Place) {
        let mux = &place.mux;
        let Self { client, writer, request, mut first, joined } = self;
        let operation = request.envelope.operation;
        // A read whose connection closed has no reader. A mutation is work
        // the daemon took, so it runs.
        if !operation.is_mutation() && !writer.is_open() {
            return;
        }
        let mut scope = Some(request_log::resume(first.slow_log.take()));
        let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            crate::resource_router::handle_parsed_resource_request(mux, request)
        }))
        .unwrap_or_else(|_| {
            let name = operation.wire_name();
            eprintln!("cmux-tui: the git request {name} of connection {client} panicked");
            Err(ResourceError::operation_failed(name, "the git request panicked", json!({})))
        });
        let commands = mux.connection_stats().commands();
        let mut handled = Some(handled);
        let mut left = joined.len() + 1;
        // Until when the copies of this reply wait for room in the connection's queue.
        let room_by = Instant::now() + SHARED_REPLY_WAIT;
        for (index, waiter) in std::iter::once(first).chain(joined).enumerate() {
            left -= 1;
            if index == 1 {
                // The run is over and its first reply went. The copies can
                // wait for room, so the place goes to the next request first.
                place.copies();
            }
            let _scope = match scope.take() {
                Some(scope) => scope,
                None => request_log::resume(waiter.slow_log),
            };
            let outcome = if left == 0 { handled.take() } else { handled.clone() };
            match outcome {
                Some(Ok(mut response)) => {
                    if index > 0
                        && let Some(envelope) = response.as_object_mut()
                    {
                        envelope.insert("id".to_string(), json!(waiter.id));
                    }
                    // A remote device's reply leaves out incognito rows (#31210).
                    super::incognito_remote::prune_reply(mux, client, &mut response);
                    let code = response.get("error").and_then(|error| error.get("code"));
                    request_log::reply_follows(
                        answered_ok(&response),
                        code.and_then(Value::as_str),
                    );
                    let _ = if index == 0 {
                        writer.send_control(&response)
                    } else {
                        writer.send_control_backpressured(&response, room_by)
                    };
                }
                // Only a response that cannot be encoded, or a panic.
                Some(Err(error)) => {
                    let _ = send_resource_response(&writer, waiter.id, operation, Err(error));
                }
                None => {}
            }
            commands.record_since(operation.wire_name(), &writer.kind, waiter.arrived);
        }
    }

    /// The run never started: each waiter gets the error `error` makes.
    fn fail(self, error: impl Fn(ResourceOperation) -> ResourceError) {
        let operation = self.request.envelope.operation;
        for waiter in std::iter::once(self.first).chain(self.joined) {
            let _scope = request_log::resume(waiter.slow_log);
            let _ =
                send_resource_response(&self.writer, waiter.id, operation, Err(error(operation)));
        }
    }
}

/// The daemon's git lane (`ClientRegistry::git_lane`).
#[derive(Default)]
pub(super) struct GitLane {
    schedule: Mutex<Schedule<Job>>,
    /// A run ended, requests that waited were dropped, or the writer of a
    /// connection in [`GitLane::drain`] closed: the drain looks again.
    changed: Condvar,
}

/// Takes one git request of `client` off its reader thread: the lane answers
/// it. Returns whether the connection stays open.
pub(super) fn submit(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let lane = &mux.control_clients.git_lane;
    let operation = request.envelope.operation;
    let id = request.envelope.id.clone();
    let class = Class::of(operation, &request.fields);
    {
        let mut schedule = lane.schedule.lock().recover_poison();
        let shared = if class.is_mutation() {
            None
        } else {
            schedule.waiting_read(client, |job| job.same_read(&request))
        };
        if let Some(job) = shared {
            crate::diagnostics::answered_later();
            job.joined.push(Waiter::new(id));
            return true;
        }
        if schedule.queued(client) >= QUEUED_PER_CLIENT {
            drop(schedule);
            let error = ResourceError::operation_failed(
                operation.wire_name(),
                "too many git requests of this connection wait",
                json!({"reason_code":"git_queue_capacity","scope":"client","limit":QUEUED_PER_CLIENT}),
            );
            return send_resource_response(writer, id, operation, Err(error));
        }
        crate::diagnostics::answered_later();
        let first = Waiter::new(id);
        let job = Job { client, writer: writer.clone(), request, first, joined: Vec::new() };
        schedule.push(client, class, job);
    }
    lane.start_ready(mux);
    true
}

/// A run's place in the lane, given back when the run ends, however it ends.
struct Place {
    mux: Arc<Mux>,
    run: u64,
}

impl Place {
    /// Gives the place back while this thread still sends the copies of the
    /// run's reply. The connection stays busy until the drop.
    fn copies(&self) {
        let lane = &self.mux.control_clients.git_lane;
        lane.schedule.lock().recover_poison().copies(self.run);
        lane.start_ready(&self.mux);
    }
}

impl Drop for Place {
    fn drop(&mut self) {
        let lane = &self.mux.control_clients.git_lane;
        lane.schedule.lock().recover_poison().finish(self.run);
        lane.changed.notify_all();
        lane.start_ready(&self.mux);
    }
}

impl GitLane {
    /// Starts each request that may start now, on a thread of its own.
    ///
    /// After the shutdown or a handoff began, none: each request that waits
    /// gets the refusal of a line read after that ("not executed"). The runs
    /// that started before go on to their end. A run that ends calls this,
    /// and a request waits only while one runs, so each gets its refusal.
    fn start_ready(&self, mux: &Arc<Mux>) {
        loop {
            if mux.daemon_shutdown_requested() || mux.daemon_handoff_in_progress() {
                let refused = self.schedule.lock().recover_poison().take_waiting();
                for job in refused {
                    job.fail(super::pending_handoff::not_executed);
                }
                // After the refusals: a connection that waits in `drain` closes next.
                self.changed.notify_all();
                return;
            }
            let started = self.schedule.lock().recover_poison().start_next();
            let Some((run, job)) = started else { return };
            // The job stays reachable when the thread does not start.
            let slot = Arc::new(Mutex::new(Some(job)));
            let (worker_slot, worker_mux) = (slot.clone(), mux.clone());
            let spawned = std::thread::Builder::new().name("mux-git".into()).spawn(move || {
                let place = Place { mux: worker_mux, run };
                let job = worker_slot.lock().recover_poison().take();
                if let Some(job) = job {
                    job.run(&place);
                }
            });
            if let Err(error) = spawned {
                self.schedule.lock().recover_poison().finish(run);
                self.changed.notify_all();
                if let Some(job) = slot.lock().recover_poison().take() {
                    let reason = format!("could not start the git thread: {error}");
                    job.fail(|operation| {
                        ResourceError::operation_failed(operation.wire_name(), &reason, json!({}))
                    });
                }
            }
        }
    }

    /// Waits until no git request of `client` waits or runs: a connection
    /// that ended its input in order gets each reply before it closes. The
    /// wait also ends when `writer` closes (a reply could not be written):
    /// from then nobody reads a reply, and a request that still waits could
    /// keep the wait until it got a place. Each run ends at its limit, so
    /// the wait has an end.
    pub(super) fn drain(mux: &Arc<Mux>, client: u64, writer: &MessageWriter) {
        let lane = &mux.control_clients.git_lane;
        // The close is an event, not a poll. Its waker takes the lock the
        // wait is under, so a wait that just looked cannot miss it.
        let closed = StreamInterrupt::new();
        let waker = Arc::downgrade(mux);
        closed.on_fire(move || {
            if let Some(mux) = waker.upgrade() {
                let lane = &mux.control_clients.git_lane;
                let _schedule = lane.schedule.lock().recover_poison();
                lane.changed.notify_all();
            }
        });
        // Not under the lock: a writer that is closed fires here.
        writer.register_interrupt(&closed);
        let mut schedule = lane.schedule.lock().recover_poison();
        while schedule.busy(client) && !closed.is_fired() {
            schedule = lane.changed.wait(schedule).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Drops the git reads of `client` that wait: nobody reads their
    /// replies (its connection broke, the client is gone, or its writer
    /// closed). Its mutations that wait still run, and the requests that run
    /// end by themselves.
    pub(super) fn abandon(&self, client: u64) {
        let dropped = self.schedule.lock().recover_poison().take_waiting_reads(client);
        self.changed.notify_all();
        drop(dropped);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn started(schedule: &mut Schedule<&'static str>) -> Vec<&'static str> {
        std::iter::from_fn(|| schedule.start_next()).map(|(_, job)| job).collect()
    }

    fn run_of(schedule: &Schedule<&'static str>, client: u64) -> u64 {
        schedule.running.iter().find(|running| running.client == client).unwrap().run
    }

    #[test]
    fn fifty_reads_start_at_most_the_bound_and_each_end_starts_one_more() {
        let mut schedule = Schedule::default();
        for number in 0..50u64 {
            // 2 connections, 25 reads each.
            schedule.push(number % 2, Class::ShortRead, number);
        }
        let mut order: Vec<u64> =
            std::iter::from_fn(|| schedule.start_next()).map(|(_, job)| job).collect();
        assert_eq!(order, [0u64, 1, 2, 3], "the bound of runs");
        assert_eq!(schedule.queue.len(), 46);
        while let Some(run) = schedule.running.first().map(|running| running.run) {
            schedule.finish(run);
            assert!(schedule.running.len() < MAX_READ_RUNS);
            if let Some((_, job)) = schedule.start_next() {
                order.push(job);
            }
            assert!(schedule.start_next().is_none(), "one end frees one place");
        }
        assert_eq!(order, (0..50u64).collect::<Vec<_>>(), "each read ran, in the order it came");
    }

    #[test]
    fn a_mutation_waits_for_its_connections_earlier_reads_and_holds_its_later_ones() {
        let mut schedule = Schedule::default();
        schedule.push(1, Class::ShortRead, "read before");
        schedule.push(1, Class::Mutation, "commit");
        schedule.push(1, Class::ShortRead, "read after");
        schedule.push(2, Class::ShortRead, "other connection");
        assert_eq!(started(&mut schedule), ["read before", "other connection"]);
        let before = run_of(&schedule, 1);
        schedule.finish(before);
        assert_eq!(started(&mut schedule), ["commit"], "after the read before it ended");
        let commit = run_of(&schedule, 1);
        schedule.finish(commit);
        assert_eq!(started(&mut schedule), ["read after"], "after the commit ended");
    }

    #[test]
    fn mutations_of_one_connection_run_one_at_a_time_in_order() {
        let mut schedule = Schedule::default();
        schedule.push(1, Class::Mutation, "commit");
        schedule.push(1, Class::Mutation, "push");
        assert_eq!(started(&mut schedule), ["commit"]);
        let commit = run_of(&schedule, 1);
        schedule.finish(commit);
        assert_eq!(started(&mut schedule), ["push"]);
    }

    #[test]
    fn mutations_have_places_of_their_own_beside_the_reads() {
        let mut schedule = Schedule::default();
        for client in (0u64..).take(MAX_READ_RUNS + 1) {
            schedule.push(client, Class::ShortRead, "read");
        }
        for client in (100u64..).take(MAX_MUTATION_RUNS + 1) {
            schedule.push(client, Class::Mutation, "commit");
        }
        let ran = started(&mut schedule);
        let count = |name: &str| ran.iter().filter(|job| **job == name).count();
        assert_eq!(count("read"), MAX_READ_RUNS, "{ran:?}");
        assert_eq!(
            count("commit"),
            MAX_MUTATION_RUNS,
            "a commit starts beside a full set of reads"
        );
        assert_eq!(schedule.queue.len(), 2, "one read and one commit wait");
    }

    #[test]
    fn an_equal_read_joins_one_that_waits_but_not_across_a_mutation() {
        let mut schedule = Schedule::default();
        schedule.push(1, Class::ShortRead, "status");
        schedule.push(2, Class::ShortRead, "status");
        schedule.push(1, Class::ShortRead, "diff");
        let status = |job: &&str| *job == "status";
        assert_eq!(schedule.waiting_read(1, status).copied(), Some("status"));
        assert_eq!(schedule.waiting_read(3, status).copied(), None, "its own connection only");
        schedule.push(1, Class::Mutation, "commit");
        let joined = schedule.waiting_read(1, status).copied();
        assert_eq!(joined, None, "a read after the commit must see the commit");
        // A read that runs is not joined: it may have started before the caller asked.
        let mut schedule = Schedule::default();
        schedule.push(1, Class::ShortRead, "status");
        assert_eq!(started(&mut schedule), ["status"]);
        assert_eq!(schedule.waiting_read(1, status).copied(), None);
    }

    #[test]
    fn a_broken_connections_waiting_requests_are_taken_and_the_rest_stay() {
        let mut schedule = Schedule::default();
        for client in (0u64..).take(MAX_READ_RUNS) {
            schedule.push(client, Class::ShortRead, "runs");
        }
        assert_eq!(started(&mut schedule).len(), MAX_READ_RUNS);
        schedule.push(1, Class::ShortRead, "waits of 1");
        schedule.push(2, Class::ShortRead, "waits of 2");
        assert!(schedule.busy(1));
        assert_eq!(schedule.take_waiting_reads(1), ["waits of 1"]);
        assert_eq!(schedule.queued(1), 0);
        assert!(schedule.busy(1), "its run still runs");
        let run = run_of(&schedule, 1);
        schedule.finish(run);
        assert!(!schedule.busy(1));
        assert_eq!(started(&mut schedule), ["waits of 2"]);
    }

    #[test]
    fn a_broken_connections_waiting_mutation_stays_and_runs_in_its_turn() {
        let mut schedule = Schedule::default();
        schedule.push(1, Class::LongRead, "diff");
        assert_eq!(started(&mut schedule), ["diff"]);
        schedule.push(1, Class::Mutation, "commit");
        schedule.push(1, Class::ShortRead, "status after");
        assert!(started(&mut schedule).is_empty(), "the commit waits for the diff before it");
        // Connection 1 breaks: nobody reads its replies, but the daemon took its commit.
        assert_eq!(schedule.take_waiting_reads(1), ["status after"]);
        assert_eq!(schedule.queued(1), 1, "the commit still waits");
        let diff = run_of(&schedule, 1);
        schedule.finish(diff);
        assert_eq!(started(&mut schedule), ["commit"]);
    }

    #[test]
    fn a_short_read_starts_while_long_reads_hold_their_places_and_wait() {
        let mut schedule = Schedule::default();
        for number in 0..24u64 {
            schedule.push(number % 3, Class::LongRead, "diff");
        }
        schedule.push(1, Class::ShortRead, "status");
        schedule.push(2, Class::ShortRead, "branches");
        let ran = started(&mut schedule);
        assert_eq!(ran, ["diff", "diff", "diff", "status"], "one place is not for long reads");
        assert_eq!(schedule.queue.len(), 22, "21 diffs and the second short read wait");
        let status = schedule.running.iter().find(|run| run.class == Class::ShortRead).unwrap().run;
        schedule.finish(status);
        assert_eq!(started(&mut schedule), ["branches"], "the place goes to the next short read");
        let diff = schedule.running.iter().find(|run| run.class == Class::LongRead).unwrap().run;
        schedule.finish(diff);
        assert_eq!(started(&mut schedule), ["diff"], "a long read's place goes to a long read");
    }

    #[test]
    fn short_reads_may_take_every_read_place() {
        let mut schedule = Schedule::default();
        for client in (0u64..).take(MAX_READ_RUNS + 1) {
            schedule.push(client, Class::ShortRead, "status");
        }
        schedule.push(9, Class::LongRead, "diff");
        assert_eq!(started(&mut schedule).len(), MAX_READ_RUNS);
        assert_eq!(schedule.queue.len(), 2);
    }

    #[test]
    fn copies_that_wait_hold_no_place_and_hold_back_only_their_own_connection() {
        let mut schedule = Schedule::default();
        let mut runs = Vec::new();
        let mut start = |schedule: &mut Schedule<&'static str>| {
            let started: Vec<_> = std::iter::from_fn(|| schedule.start_next()).collect();
            runs.extend(started.iter().copied());
            started.into_iter().map(|(_, job)| job).collect::<Vec<_>>()
        };
        schedule.push(1, Class::LongRead, "equal diffs");
        assert!(schedule.waiting_read(1, |job| *job == "equal diffs").is_some(), "one joins");
        schedule.push(1, Class::LongRead, "diff a");
        schedule.push(1, Class::LongRead, "diff b");
        schedule.push(2, Class::LongRead, "diff of 2");
        assert_eq!(start(&mut schedule), ["equal diffs", "diff a", "diff b"]);

        // The run of the equal diffs ended; its copies wait for room.
        schedule.copies(0);
        assert_eq!(start(&mut schedule), ["diff of 2"], "the place of the run is free");
        assert!(schedule.busy(1), "the connection has copies to get");

        schedule.push(1, Class::LongRead, "equal diffs again");
        assert!(schedule.waiting_read(1, |job| *job == "equal diffs again").is_some());
        schedule.push(1, Class::ShortRead, "status");
        schedule.push(1, Class::Mutation, "commit");
        assert_eq!(start(&mut schedule), ["status"], "a read nobody joined starts");
        for run in [1, 2, 3, 4] {
            schedule.finish(run);
        }
        assert!(
            start(&mut schedule).is_empty(),
            "a shared read and a mutation wait for the copies"
        );

        schedule.finish(0);
        assert_eq!(start(&mut schedule), ["equal diffs again"]);
        schedule.finish(5);
        assert_eq!(start(&mut schedule), ["commit"]);
        assert_eq!(runs.len(), 7);
    }

    #[test]
    fn the_class_of_an_operation() {
        let plain = Map::new();
        let class = |operation| Class::of(operation, &plain);
        assert_eq!(class(ResourceOperation::GitStatus), Class::ShortRead);
        assert_eq!(class(ResourceOperation::DiffCommentsList), Class::ShortRead);
        assert_eq!(class(ResourceOperation::GitCheckpointGet), Class::ShortRead);
        assert_eq!(class(ResourceOperation::GitDiff), Class::LongRead);
        assert_eq!(class(ResourceOperation::GitCheckpointDiff), Class::LongRead);
        assert_eq!(class(ResourceOperation::GitFilesSearch), Class::LongRead);
        // A git child for each branch: work of the size of the repository.
        assert_eq!(class(ResourceOperation::GitBranches), Class::LongRead);
        assert_eq!(class(ResourceOperation::GitCommit), Class::Mutation);
        assert_eq!(class(ResourceOperation::DiffCommentsSave), Class::Mutation);
        // A checkpoint list is short, but not with the candidates: they are
        // the untracked and the ignored paths of the whole tree.
        let list = ResourceOperation::GitCheckpointList;
        assert_eq!(class(list), Class::ShortRead);
        let mut fields = Map::new();
        fields.insert("include_candidates".to_string(), json!(false));
        assert_eq!(Class::of(list, &fields), Class::ShortRead);
        fields.insert("include_candidates".to_string(), json!(true));
        assert_eq!(Class::of(list, &fields), Class::LongRead);
    }
}
