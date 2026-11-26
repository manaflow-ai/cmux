//! One typed message contract for people and agents in cmux (cmuxterm-hq RFD 0170, "Native
//! people-to-people and people-to-agent messaging in cmux", phase 0).
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put in
//! fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! The hosted forum stays the durable record, a room stays the live session record, and presence is a
//! lease that never becomes history. This crate is the one typed view cmux has over them:
//!
//! - [`model`]: the RFD's records: [`Team`], [`Principal`], [`Space`], [`Thread`], [`Message`],
//!   [`Feedback`] and [`SharedDocument`].
//! - [`refs`]: stable references ([`StableRef`]) to an RFD, session, thread, PR, issue, Slack thread,
//!   file or shared document, with one canonical string form, and [`refs::LinkGraph`]: every link
//!   between an RFD, a session and a thread is readable from both ends, and a link never widens who
//!   can read the thread.
//! - [`identity`]: a person, an agent with its `on_behalf_of` owner, and a bridge author (`via Slack`)
//!   that holds no cmux rights; an agent never posts as its owner; `@handle` resolution.
//! - [`permission`]: what a principal may do in a space is the intersection of the team's grants,
//!   the space's membership and the principal's home-team grants; `wake` is granted by the agent's
//!   owner per space and nothing else can grant it.
//! - [`delivery`]: `fyi`, `ask` and `wake`, and what each does to each recipient (ask-first: only a
//!   granted `wake` starts an agent turn, and a person-to-person message never wakes an agent); the
//!   `sent`, `stored`, `delivered`, `read` and `handled` states, which only move forward; an agent
//!   answer's `accepted`, `needs-work` or `blocked`.
//! - [`feedback`]: comments and votes; one current vote per person per target, agent votes advisory,
//!   a changed vote appends an event.
//! - [`backend`]: the seams to the forum, rooms and presence as traits; [`forum`] and [`presence`]
//!   adapt the existing `cmux-forum-hosted` and `cmux-sync` types to this model; [`fake`] holds
//!   in-memory backends for tests.
//! - [`service::Messenger`]: preview a draft (destination, audience, wake mode, before send), then
//!   send it once: the same idempotency key is the same message.
//!
//! - [`directory`] (phase 1): the team navigator, the composer's recipient picker and Session Info's
//!   participant and link sections, each a per-viewer projection of the records above.
//!
//! Nothing here does I/O, reads a clock or draws UI, and nothing in the app calls it yet: phase 1
//! wires these views behind `team_messaging`.

pub mod backend;
pub mod delivery;
pub mod directory;
pub mod fake;
pub mod feedback;
pub mod forum;
pub mod identity;
pub mod model;
pub mod permission;
pub mod presence;
pub mod refs;
pub mod service;

pub use backend::{BackendError, ForumBackend, PresenceBackend, RoomBackend, StoredMessage};
pub use delivery::{AnswerState, DeliveryMode, DeliveryState, Route, route};
pub use directory::{Candidate, Directory, Navigator, SessionInfo};
pub use feedback::{FeedbackKind, VoteBoard, VoteSummary};
pub use identity::{Bridge, IdentityError, PrincipalKind, Resolved, resolve_handle};
pub use model::{
    Feedback, Message, Principal, RootKind, SharedDocument, Space, SpaceKind, Team, Thread,
    ThreadState,
};
pub use permission::{Capability, Grants, effective};
pub use refs::{LinkGraph, RefKind, RefSource, StableRef};
pub use service::{Draft, Messenger, Preview, Receipt, SendError};
