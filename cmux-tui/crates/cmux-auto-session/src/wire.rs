//! Every request and answer of the Cloud API (`/v1/auto-sessions`), as serde types. The JSON is
//! camelCase, exactly as `plans/cmux-next/auto-mode/DESIGN.md` ("Cloud API") writes it.
//!
//! A field the design marks optional (`standby?`, `keepInCloud?`, `title?`, `repo?`) is left out
//! of a request when it is None. An answer's unknown fields are ignored, so a newer store can add
//! one.

mod copy;
mod error;
mod holder;
mod inbox;
mod lease;
mod moves;
mod owner;
mod session;

pub use copy::{
    Cwd, EventsAppend, EventsAppended, EventsPage, Manifest, NativeFile, OpenTool, OpenTurn,
    QueuedPrompt, SeqRecord, SnapshotAnswer, SnapshotPost, SnapshotPosted,
};
pub use error::{ErrorBody, ErrorCode, ErrorEnvelope};
pub use holder::{Holder, HolderParseError};
pub use inbox::{Delivery, InboxAck, InboxMessage, InboxPage, InboxPost, InboxPosted};
pub use lease::{Fence, LeaseAnswer, LeaseRequest, Role};
pub use moves::{MoveRefusal, MoveRequest, MoveTo, MoveWish};
pub use owner::{
    Assignment, AssignmentKind, Assignments, CreateRequest, FirstMessage, KeepRequest,
    MachineSetting, PutRequest,
};
pub use session::{Blocked, Repo, SessionAnswer, SessionList, SessionView, State};

#[cfg(test)]
mod tests;
