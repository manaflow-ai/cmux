//! The Cloud store as a trait: one method per route of the design's "Cloud API" table.
//!
//! A transport implements it: the laptop's daemon as the owner, a Cloud machine's daemon through
//! the machine's Cloud agent. Code that drives a chat takes `impl AutoCloud` (or `Arc<C>` with
//! `C: AutoCloud`), so its tests run against [`crate::fake::FakeAutoCloud`].
//!
//! Every method returns a `Send` future, so a tokio task can hold one across an await. An
//! implementation may write `async fn`.
//!
//! Who may call a route (owner, machine, holder) is the design's table; a route the caller may
//! not use answers an error. Nothing here retries: [`AutoCloudError::retryable`] says whether
//! the caller may.

mod error;

use std::future::Future;

pub use error::AutoCloudError;

use crate::wire::{
    Assignment, CreateRequest, EventsAppend, EventsPage, Fence, InboxAck, InboxMessage, InboxPost,
    InboxPosted, LeaseAnswer, LeaseRequest, MachineSetting, MoveRequest, PutRequest, SessionList,
    SessionView, SnapshotAnswer, SnapshotPost,
};

pub type CloudResult<T> = Result<T, AutoCloudError>;

/// What a transport without the route answers: not retryable, and no `auto.*` code.
fn unrouted(route: &str) -> AutoCloudError {
    AutoCloudError::http(405, "method_not_allowed", format!("this transport has no {route} route"))
}

/// The Cloud store's routes. `id` is the chat's session id.
pub trait AutoCloud: Send + Sync {
    /// `GET /machine` (owner): the Auto machine, or `auto.no_machine`.
    fn machine(&self) -> impl Future<Output = CloudResult<MachineSetting>> + Send;

    /// `PUT /machine` (owner): set the Auto machine.
    fn set_machine(
        &self,
        setting: &MachineSetting,
    ) -> impl Future<Output = CloudResult<MachineSetting>> + Send;

    /// `PUT /:id` (owner): switch Auto on or off for a chat. The first call makes it, held by
    /// `device:<device>` at epoch 1; a later one updates what it names and opens a closed chat
    /// again, empty, at the next epoch. `auto: false` closes it and drops its Cloud copy:
    /// `auto.held_in_cloud` while a machine holds it, for a parked chat a machine ran last, and
    /// for a parked chat with an unread message.
    fn put(
        &self,
        id: &str,
        request: &PutRequest,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `POST /` (owner): a chat started with no laptop. The Auto machine holds it, with a
    /// `create` assignment; `auto.no_machine` without one. The chat's id comes from the first
    /// message's id, so the same request again answers the same chat.
    fn create(
        &self,
        request: &CreateRequest,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `GET /?limit=&cursor=` (owner): one page of the owner's open chats, newest first.
    fn list(
        &self,
        limit: Option<u32>,
        cursor: Option<&str>,
    ) -> impl Future<Output = CloudResult<SessionList>> + Send;

    /// `GET /:id` (owner, machine). A machine reads only a chat it holds; any other is 404.
    fn get(&self, id: &str) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `GET /:id/wait` (owner): the chat once its version passes `after` or it is closed, or
    /// as it is at the deadline. The store holds it at most [`crate::consts::WAIT_MAX_MS`].
    fn wait(
        &self,
        id: &str,
        after: u64,
        timeout_ms: u64,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `POST /:id/lease` (owner, machine): renew as the holder or as a laptop standing by. The
    /// answer is a [`Role`](crate::wire::Role), never `auto.stale_epoch`.
    fn lease(
        &self,
        id: &str,
        request: &LeaseRequest,
    ) -> impl Future<Output = CloudResult<LeaseAnswer>> + Send;

    /// `POST /:id/release` (holder): give the chat up. A machine's chat goes to the standby
    /// laptop. Otherwise it is parked, unless a message is unread: then it goes to the Auto
    /// machine, or stays with the Auto machine that released it, with a `deliver` to pick up.
    fn release(
        &self,
        id: &str,
        fence: &Fence,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `POST /:id/events` (holder): append events; answers the store's last seq. A repeat of
    /// stored seqs is accepted; a gap is `auto.seq_gap` with the store's last seq.
    fn append_events(
        &self,
        id: &str,
        request: &EventsAppend,
    ) -> impl Future<Output = CloudResult<u64>> + Send;

    /// `GET /:id/events?after=&limit=` (owner, machine).
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: Option<u32>,
    ) -> impl Future<Output = CloudResult<EventsPage>> + Send;

    /// `PUT /:id/chunks/:sha256` (holder): store one chunk; `auto.chunk_mismatch` when the
    /// bytes do not hash to `sha256`.
    fn put_chunk(
        &self,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> impl Future<Output = CloudResult<()>> + Send;

    /// `GET /:id/chunks/:sha256` (owner, machine).
    fn chunk(&self, id: &str, sha256: &str) -> impl Future<Output = CloudResult<Vec<u8>>> + Send;

    /// `POST /:id/snapshot` (holder): answers the snapshot's number;
    /// `auto.snapshot_incomplete` names the chunks the store lacks. It covers the chat only
    /// through the events the store has, so the events go first.
    fn post_snapshot(
        &self,
        id: &str,
        request: &SnapshotPost,
    ) -> impl Future<Output = CloudResult<u64>> + Send;

    /// `GET /:id/snapshot` (owner, machine): the newest snapshot, or `auto.no_snapshot`.
    fn snapshot(&self, id: &str) -> impl Future<Output = CloudResult<SnapshotAnswer>> + Send;

    /// `POST /:id/inbox` (owner): send a message to the chat. The same `id` again stores
    /// nothing new.
    fn post_inbox(
        &self,
        id: &str,
        message: &InboxPost,
    ) -> impl Future<Output = CloudResult<InboxPosted>> + Send;

    /// `GET /:id/inbox?after=` (owner, machine): the messages after number `after` that the
    /// holder has not acked, at most 64.
    fn inbox(
        &self,
        id: &str,
        after: u64,
    ) -> impl Future<Output = CloudResult<Vec<InboxMessage>>> + Send;

    /// `POST /:id/inbox/ack` (holder): every message up to `through` is taken.
    fn ack_inbox(
        &self,
        id: &str,
        ack: &InboxAck,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `POST /:id/keep` (owner): keep the chat in the Cloud (no handback), or stop keeping it.
    fn keep(
        &self,
        id: &str,
        keep_in_cloud: bool,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;

    /// `POST /:id/move` (owner): the person moves the chat now, to the Cloud machine or to a
    /// laptop that stands by. The answer's `session.move` is the wish its holder reads at its
    /// next renewal ([`LeaseAnswer::move_to`]) and answers with [`give`](Self::give); the chat
    /// is kept in the Cloud (`to: cloud`) or not (`to: local`) from the same write. A parked
    /// chat goes at once, and a chat that is already there only has its wish dropped. Refused
    /// `auto.no_machine`, or with a [`MoveRefusal`](crate::wire::MoveRefusal): `auto.off`,
    /// `auto.no_laptop`, `auto.not_copied` (a parked chat with no snapshot, to the Cloud).
    ///
    /// A transport that has not built the route yet answers 405 from the default body.
    fn move_(
        &self,
        id: &str,
        request: &MoveRequest,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send {
        let _unused = (id, request);
        std::future::ready(Err(unrouted("move")))
    }

    /// `POST /:id/give` (holder): hand the chat over as the person asked. The epoch grows by
    /// one, the wish goes, and the chat is the Auto machine's (a `takeover` to pick up) or the
    /// laptop's, which imports the Cloud copy first. Refused like every holder write, and
    /// `auto.no_machine`, or with a [`MoveRefusal`](crate::wire::MoveRefusal): `auto.no_move`
    /// (nobody asked, or the wish is over), `auto.not_copied` (store the events and a snapshot
    /// that covers the last one, then give again), `auto.no_laptop`.
    ///
    /// A transport that has not built the route yet answers 405 from the default body.
    fn give(
        &self,
        id: &str,
        fence: &Fence,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send {
        let _unused = (id, fence);
        std::future::ready(Err(unrouted("give")))
    }

    /// `GET /assignments?timeoutMs=` (machine): this machine's assignments, held until one
    /// exists or the deadline.
    fn assignments(
        &self,
        timeout_ms: u64,
    ) -> impl Future<Output = CloudResult<Vec<Assignment>>> + Send;

    /// `POST /:id/assignment/ack` (machine): the machine picked up what it was given. While an
    /// inbox message is unread it keeps a `deliver`, so the inbox is acked first.
    fn ack_assignment(
        &self,
        id: &str,
        fence: &Fence,
    ) -> impl Future<Output = CloudResult<SessionView>> + Send;
}
