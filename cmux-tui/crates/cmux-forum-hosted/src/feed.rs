//! The feed cursor for one (team, space): pull new events, cheaply when nothing changed.

use serde::{Deserialize, Serialize};

use crate::cache::ThreadCache;
use crate::client::{FeedResponse, ForumClient, ForumError};
use crate::model::FeedEvent;
use crate::transport::Transport;

/// Events per feed page.
pub const DEFAULT_PAGE_LIMIT: u32 = 100;
/// Pages per pull; past them the pull reports [`PullStatus::Behind`].
pub const DEFAULT_MAX_PAGES: u32 = 8;

/// Where a pull left the cursor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PullStatus {
    /// 304: nothing new; the cursor did not move.
    Unchanged,
    /// The cursor reached the head.
    CaughtUp { head: u64 },
    /// The page cap was hit before the head; pull again.
    Behind { next: u64, head: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pull {
    /// New events, oldest first. Delivery is at least once: a replayed event may appear again.
    pub events: Vec<FeedEvent>,
    pub status: PullStatus,
}

/// The cursor and etag for one team's feed, optionally one space. Serializable so the daemon can
/// persist it beside the [`ThreadCache`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedFollower {
    team: String,
    space: Option<String>,
    after: u64,
    /// Kept only while caught up: the etag moves with the head, so it says nothing about a cursor behind it.
    etag: Option<String>,
    page_limit: u32,
    max_pages: u32,
}

impl FeedFollower {
    pub fn new(team: impl Into<String>, space: Option<String>) -> Self {
        Self {
            team: team.into(),
            space,
            after: 0,
            etag: None,
            page_limit: DEFAULT_PAGE_LIMIT,
            max_pages: DEFAULT_MAX_PAGES,
        }
    }

    pub fn with_limits(mut self, page_limit: u32, max_pages: u32) -> Self {
        self.page_limit = page_limit.max(1);
        self.max_pages = max_pages.max(1);
        self
    }

    pub fn team(&self) -> &str {
        &self.team
    }

    pub fn space(&self) -> Option<&str> {
        self.space.as_deref()
    }

    /// The cursor: the last seq applied.
    pub fn after(&self) -> u64 {
        self.after
    }

    pub fn etag(&self) -> Option<&str> {
        self.etag.as_deref()
    }

    /// Moves the cursor (after a reload on [`ForumError::Gone`]) and drops the etag.
    pub fn reset(&mut self, after: u64) {
        self.after = after;
        self.etag = None;
    }

    /// Pulls up to the page cap. On any error the cursor and etag stay where they were.
    pub async fn pull<T: Transport>(
        &mut self,
        client: &ForumClient<T>,
    ) -> Result<Pull, ForumError> {
        if client.team() != self.team {
            return Err(ForumError::Invalid {
                code: "client.team_mismatch".to_owned(),
                message: format!(
                    "follower is for team {}, client for {}",
                    self.team,
                    client.team()
                ),
            });
        }
        let mut after = self.after;
        let mut events = Vec::new();
        let mut head = after;
        let mut caught_up_etag = None;
        let mut caught_up = false;
        for i in 0..self.max_pages {
            let if_none_match = if i == 0 { self.etag.as_deref() } else { None };
            match client.feed(after, self.space.as_deref(), self.page_limit, if_none_match).await? {
                FeedResponse::NotModified => {
                    if i == 0 {
                        return Ok(Pull { events: Vec::new(), status: PullStatus::Unchanged });
                    }
                    break;
                }
                FeedResponse::Page { page, etag } => {
                    events.extend(page.events);
                    let progressed = page.next > after;
                    after = after.max(page.next);
                    head = page.head;
                    if after >= head {
                        caught_up = true;
                        caught_up_etag = etag;
                        break;
                    }
                    if !progressed {
                        break;
                    }
                }
            }
        }
        self.after = after;
        self.etag = caught_up_etag;
        let status = if caught_up {
            PullStatus::CaughtUp { head }
        } else {
            PullStatus::Behind { next: after, head }
        };
        Ok(Pull { events, status })
    }

    /// [`Self::pull`], then applies the events to `cache`.
    pub async fn pull_into<T: Transport>(
        &mut self,
        client: &ForumClient<T>,
        cache: &mut ThreadCache,
    ) -> Result<PullStatus, ForumError> {
        let pull = self.pull(client).await?;
        cache.apply_all(&pull.events);
        Ok(pull.status)
    }
}
