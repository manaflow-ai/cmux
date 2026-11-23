//! One method per route of the store, as the owner sends it.

use std::time::Duration;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::chunks;
use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use cmux_auto_session::consts::{EPOCH_HEADER, HOLDER_HEADER, WAIT_MAX_MS};
use cmux_auto_session::wire::{
    Assignment, Assignments, CreateRequest, EventsAppend, EventsAppended, EventsPage, Fence,
    InboxAck, InboxMessage, InboxPage, InboxPost, InboxPosted, KeepRequest, LeaseAnswer,
    LeaseRequest, MachineSetting, PutRequest, SessionAnswer, SessionList, SessionView,
    SnapshotAnswer, SnapshotPost, SnapshotPosted,
};
use reqwest::Method;
use zeroize::Zeroizing;

use super::{CHUNK_TIMEOUT, Call, HELD_MARGIN, OwnerAutoCloud, OwnerSignIn, chat};
use crate::http::Body;

/// A chunk's name as a path part: 64 lowercase hex digits and nothing else.
fn chunk_name(sha256: &str) -> CloudResult<&str> {
    if chunks::is_name(sha256) {
        Ok(sha256)
    } else {
        Err(AutoCloudError::http(400, "invalid_request", "not a chunk name"))
    }
}

/// The time the store holds a request open, and the deadline of the call around it.
fn held(timeout_ms: u64) -> (String, Duration) {
    let held = timeout_ms.min(WAIT_MAX_MS);
    (held.to_string(), Duration::from_millis(held).saturating_add(HELD_MARGIN))
}

impl<S: OwnerSignIn> AutoCloud for OwnerAutoCloud<S> {
    async fn machine(&self) -> CloudResult<MachineSetting> {
        self.json(Call::get(&["machine"])).await
    }

    async fn set_machine(&self, setting: &MachineSetting) -> CloudResult<MachineSetting> {
        self.json(Call::with(Method::PUT, &["machine"], setting)?).await
    }

    async fn put(&self, id: &str, request: &PutRequest) -> CloudResult<SessionView> {
        let answer: SessionAnswer =
            self.json(Call::with(Method::PUT, &[chat(id)?], request)?).await?;
        Ok(answer.session)
    }

    async fn create(&self, request: &CreateRequest) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.json(Call::post(&[], request)?).await?;
        Ok(answer.session)
    }

    async fn list(&self, limit: Option<u32>, cursor: Option<&str>) -> CloudResult<SessionList> {
        let mut query = Vec::new();
        if let Some(limit) = limit {
            query.push(("limit", limit.to_string()));
        }
        if let Some(cursor) = cursor {
            query.push(("cursor", cursor.to_owned()));
        }
        self.json(Call::get(&[]).query(&query)).await
    }

    async fn get(&self, id: &str) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.json(Call::get(&[chat(id)?])).await?;
        Ok(answer.session)
    }

    async fn wait(&self, id: &str, after: u64, timeout_ms: u64) -> CloudResult<SessionView> {
        let (held, deadline) = held(timeout_ms);
        let query = [("after", after.to_string()), ("timeoutMs", held)];
        let after = [chat(id)?, "wait"];
        let call = Call::get(&after).query(&query).timeout(deadline);
        let answer: SessionAnswer = self.json(call).await?;
        Ok(answer.session)
    }

    async fn lease(&self, id: &str, request: &LeaseRequest) -> CloudResult<LeaseAnswer> {
        self.json(Call::post(&[chat(id)?, "lease"], request)?).await
    }

    async fn release(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.json(Call::post(&[chat(id)?, "release"], fence)?).await?;
        Ok(answer.session)
    }

    async fn append_events(&self, id: &str, request: &EventsAppend) -> CloudResult<u64> {
        let answer: EventsAppended =
            self.json(Call::post(&[chat(id)?, "events"], request)?).await?;
        Ok(answer.last_seq)
    }

    async fn events(&self, id: &str, after: u64, limit: Option<u32>) -> CloudResult<EventsPage> {
        let mut query = vec![("after", after.to_string())];
        if let Some(limit) = limit {
            query.push(("limit", limit.to_string()));
        }
        self.json(Call::get(&[chat(id)?, "events"]).query(&query)).await
    }

    async fn put_chunk(
        &self,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> CloudResult<()> {
        // The store reads the writer from these two headers: a holder's name and a number, no
        // key (http.rs `send_named`).
        let headers =
            [(HOLDER_HEADER, fence.holder.to_string()), (EPOCH_HEADER, fence.epoch.to_string())];
        let after = [chat(id)?, "chunks", chunk_name(sha256)?];
        let call = Call {
            method: Method::PUT,
            body: Some(Body::Bytes(Zeroizing::new(bytes.to_vec()), "application/octet-stream")),
            headers: &headers,
            timeout: CHUNK_TIMEOUT,
            ..Call::get(&after)
        };
        self.send(call).await.map(|_| ())
    }

    async fn chunk(&self, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        let after = [chat(id)?, "chunks", chunk_name(sha256)?];
        self.send(Call::get(&after).timeout(CHUNK_TIMEOUT)).await
    }

    async fn post_snapshot(&self, id: &str, request: &SnapshotPost) -> CloudResult<u64> {
        let answer: SnapshotPosted =
            self.json(Call::post(&[chat(id)?, "snapshot"], request)?).await?;
        Ok(answer.snapshot)
    }

    async fn snapshot(&self, id: &str) -> CloudResult<SnapshotAnswer> {
        self.json(Call::get(&[chat(id)?, "snapshot"])).await
    }

    async fn post_inbox(&self, id: &str, message: &InboxPost) -> CloudResult<InboxPosted> {
        self.json(Call::post(&[chat(id)?, "inbox"], message)?).await
    }

    async fn inbox(&self, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        let query = [("after", after.to_string())];
        let page: InboxPage = self.json(Call::get(&[chat(id)?, "inbox"]).query(&query)).await?;
        Ok(page.messages)
    }

    async fn ack_inbox(&self, id: &str, ack: &InboxAck) -> CloudResult<SessionView> {
        let answer: SessionAnswer =
            self.json(Call::post(&[chat(id)?, "inbox", "ack"], ack)?).await?;
        Ok(answer.session)
    }

    async fn keep(&self, id: &str, keep_in_cloud: bool) -> CloudResult<SessionView> {
        let body = KeepRequest { keep_in_cloud };
        let answer: SessionAnswer = self.json(Call::post(&[chat(id)?, "keep"], &body)?).await?;
        Ok(answer.session)
    }

    /// A machine's route: the store refuses the owner (403), as it would any caller that is
    /// not the Auto machine's VM install.
    async fn assignments(&self, timeout_ms: u64) -> CloudResult<Vec<Assignment>> {
        let (held, deadline) = held(timeout_ms);
        let query = [("timeoutMs", held)];
        let after = ["assignments"];
        let call = Call::get(&after).query(&query).timeout(deadline);
        let answer: Assignments = self.json(call).await?;
        Ok(answer.assignments)
    }

    /// A machine's route, as [`AutoCloud::assignments`] is.
    async fn ack_assignment(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        let answer: SessionAnswer =
            self.json(Call::post(&[chat(id)?, "assignment", "ack"], fence)?).await?;
        Ok(answer.session)
    }
}
