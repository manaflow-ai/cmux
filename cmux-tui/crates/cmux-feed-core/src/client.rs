//! The feed client (plans/cmux-next/feed-page.md): what Swift's
//! `CmuxNextFeed` owned, so the daemon serves it to the React Feed page and
//! to native callers. Pure, no I/O: the item model with its wire JSON, the
//! intents and their overlay, the mirror of the cloud owner plus the
//! in-memory integration owner, the ledger's order and counts, the Inbox
//! groups and filter, the row content, the choice check, the `FeedDO`
//! stream's state machine, the GitHub poster's mapping and state, and the
//! Reports basket. The daemon (cmux-tui-core `feed_client`) runs the socket,
//! the `gh` processes and the acpmux mailbox reader around it.

mod choice;
mod cloud;
mod filter;
pub mod github;
mod intent;
mod item;
mod ledger;
mod mirror;
mod owner;
mod prompt;
mod reports;
mod row;
mod view;

pub use choice::{ChoiceIssue, Selection, issues as choice_issues, normalized as normalize_choice};
pub use cloud::{
    CloudAction, CloudStream, FEED_WIRE_PATH, Frame, MAX_INTENT_IDS, op_params, reject,
};
pub use filter::{Category, Connection as FilterConnection, Filter, Matcher, fold, is_github};
pub use intent::{Intent, IntentKind};
pub use item::{FeedItem, Poster, Priority, State};
pub use ledger::Counts;
pub use mirror::{Commit, Connection, Mirror, Owner, Reject, Routed};
pub use owner::{IntegrationOwner, MAX_INTEGRATION_ITEMS, OwnerEvent, Posted};
pub use prompt::{ApproveType, ChoiceOption, ChoiceQuestion, Prompt};
pub use reports::{MailPage, REPORTS_LIMIT, Report, Reports};
pub use row::{Place, Row, agent_name};
pub use view::{Layout, MAX_VIEW_ENTRIES, ViewAccount, ViewContext, ViewRequest};

#[cfg(test)]
mod tests;
