//! [`AutoCloud`] for the fake: each route is one call into the store. `wait` and `assignments`
//! are held until there is something to answer or the store's clock reaches their deadline. A
//! holder write first passes the install check of `devices.rs`.

use std::future::poll_fn;

use super::FakeAutoCloud;
use crate::cloud::{AutoCloud, CloudResult};
use crate::wire::{
    Assignment, CreateRequest, EventsAppend, EventsPage, Fence, Holder, InboxAck, InboxMessage,
    InboxPost, InboxPosted, LeaseAnswer, LeaseRequest, MachineSetting, MoveRequest, PutRequest,
    SessionList, SessionView, SnapshotAnswer, SnapshotPost,
};

impl FakeAutoCloud {
    /// `POST /` with the request's `keepInCloud`: a chat started with no laptop, made in Cloud
    /// mode when `keep_in_cloud` is true. [`AutoCloud::create`] is this with `false`. It counts
    /// as a `create` call.
    pub fn create_kept(
        &self,
        request: &CreateRequest,
        keep_in_cloud: bool,
    ) -> CloudResult<SessionView> {
        self.call("create", |store, caller| store.create(caller, request, keep_in_cloud))
    }
}

impl AutoCloud for FakeAutoCloud {
    async fn machine(&self) -> CloudResult<MachineSetting> {
        self.call("machine", |store, caller| store.machine(caller))
    }

    async fn set_machine(&self, setting: &MachineSetting) -> CloudResult<MachineSetting> {
        self.call("set_machine", |store, caller| store.set_machine(caller, setting))
    }

    async fn put(&self, id: &str, request: &PutRequest) -> CloudResult<SessionView> {
        if !request.auto || !super::check::device(&request.device) {
            return self.call("put", |store, caller| store.put(caller, id, request));
        }
        let holder = Holder::device(request.device.clone());
        self.holder_call("put", id, &holder, true, |store, caller| store.put(caller, id, request))
    }

    async fn create(&self, request: &CreateRequest) -> CloudResult<SessionView> {
        self.call("create", |store, caller| store.create(caller, request, false))
    }

    async fn list(&self, limit: Option<u32>, cursor: Option<&str>) -> CloudResult<SessionList> {
        self.call("list", |store, caller| store.list(caller, limit, cursor))
    }

    async fn get(&self, id: &str) -> CloudResult<SessionView> {
        self.call("get", |store, caller| store.get(caller, id))
    }

    async fn wait(&self, id: &str, after: u64, timeout_ms: u64) -> CloudResult<SessionView> {
        let deadline = self.deadline("wait", timeout_ms)?;
        poll_fn(|cx| {
            self.held(cx, deadline, |store, caller, due| match store.waited(caller, id) {
                // A closed chat answers at once: nothing more will change in it.
                Ok(session) if session.version <= after && session.auto && !due => None,
                answer => Some(answer),
            })
        })
        .await
    }

    async fn lease(&self, id: &str, request: &LeaseRequest) -> CloudResult<LeaseAnswer> {
        self.holder_call("lease", id, &request.holder, false, |store, caller| {
            store.lease(caller, id, request)
        })
    }

    async fn release(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        self.holder_call("release", id, &fence.holder, false, |store, caller| {
            store.release(caller, id, fence)
        })
    }

    async fn append_events(&self, id: &str, request: &EventsAppend) -> CloudResult<u64> {
        self.holder_call("append_events", id, &request.holder, false, |store, caller| {
            store.append_events(caller, id, request)
        })
    }

    async fn events(&self, id: &str, after: u64, limit: Option<u32>) -> CloudResult<EventsPage> {
        self.call("events", |store, caller| store.events(caller, id, after, limit))
    }

    async fn put_chunk(
        &self,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> CloudResult<()> {
        self.holder_call("put_chunk", id, &fence.holder, false, |store, caller| {
            store.put_chunk(caller, id, sha256, bytes, fence)
        })
    }

    async fn chunk(&self, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        self.call("chunk", |store, caller| store.chunk(caller, id, sha256))
    }

    async fn post_snapshot(&self, id: &str, request: &SnapshotPost) -> CloudResult<u64> {
        self.holder_call("post_snapshot", id, &request.holder, false, |store, caller| {
            store.post_snapshot(caller, id, request)
        })
    }

    async fn snapshot(&self, id: &str) -> CloudResult<SnapshotAnswer> {
        self.call("snapshot", |store, caller| store.snapshot(caller, id))
    }

    async fn post_inbox(&self, id: &str, message: &InboxPost) -> CloudResult<InboxPosted> {
        self.call("post_inbox", |store, caller| store.post_inbox(caller, id, message))
    }

    async fn inbox(&self, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        self.call("inbox", |store, caller| store.inbox(caller, id, after))
    }

    async fn ack_inbox(&self, id: &str, ack: &InboxAck) -> CloudResult<SessionView> {
        self.holder_call("ack_inbox", id, &ack.holder, false, |store, caller| {
            store.ack_inbox(caller, id, ack)
        })
    }

    async fn keep(&self, id: &str, keep_in_cloud: bool) -> CloudResult<SessionView> {
        self.call("keep", |store, caller| store.keep(caller, id, keep_in_cloud))
    }

    async fn move_(&self, id: &str, request: &MoveRequest) -> CloudResult<SessionView> {
        self.call("move", |store, caller| store.move_to(caller, id, request))
    }

    async fn give(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        self.call("give", |store, caller| store.give(caller, id, fence))
    }

    async fn assignments(&self, timeout_ms: u64) -> CloudResult<Vec<Assignment>> {
        let deadline = self.deadline("assignments", timeout_ms)?;
        poll_fn(|cx| {
            self.held(cx, deadline, |store, caller, due| match store.assignments(caller) {
                Ok(none) if none.is_empty() && !due => None,
                answer => Some(answer),
            })
        })
        .await
    }

    async fn ack_assignment(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        self.call("ack_assignment", |store, caller| store.ack_assignment(caller, id, fence))
    }
}
