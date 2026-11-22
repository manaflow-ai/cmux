//! Durable provider notices: accepting, painting, expiring and dismissing
//! notices, and acknowledging them to the provider with backoff.

use std::time::Instant;

use crate::app::{
    App, DURABLE_NOTICE_DISPLAY_DURATION, DURABLE_NOTICE_QUEUE_CAPACITY,
    DURABLE_NOTICE_RECENT_CAPACITY, QueuedDurableNotice, RenderAction,
};
use crate::machine::{DurableNoticeDelivery, DurableNoticeLevel, DurableProviderNotice};

impl App {
    pub(super) fn accept_durable_notice(&mut self, notice: DurableProviderNotice) -> RenderAction {
        let delivery = notice.delivery.clone();
        if let Some(queued) =
            self.durable_notices.iter().find(|queued| queued.notice.delivery == delivery)
        {
            if queued.painted_at.is_some() {
                self.queue_durable_notice_ack(delivery);
            }
            return RenderAction::None;
        }
        if self.recent_durable_notices.contains(&delivery) {
            self.queue_durable_notice_ack(delivery);
            return RenderAction::None;
        }
        if self.durable_notices.len() >= DURABLE_NOTICE_QUEUE_CAPACITY {
            // A conforming provider has one delivery in flight, so this only
            // trips for a broken or hostile stream. Leave the new delivery
            // unacknowledged and reconnect so the durable cursor can replay it
            // after queued notices drain.
            self.schedule_machine_provider_reconnect();
            return RenderAction::None;
        }
        let level = match notice.level {
            DurableNoticeLevel::Error => "ERROR",
            DurableNoticeLevel::Warning => "WARN",
            DurableNoticeLevel::Info => "INFO",
        };
        crate::client_log::log(level, "provider-notice", &notice.message);
        self.durable_notices.push_back(QueuedDurableNotice { notice, painted_at: None });
        RenderAction::Draw
    }

    pub(crate) fn durable_notice(&self) -> Option<&DurableProviderNotice> {
        self.durable_notices.front().map(|queued| &queued.notice)
    }

    pub(crate) fn record_durable_notice_painted(&mut self, delivery: DurableNoticeDelivery) {
        self.painted_durable_notice_this_frame = Some(delivery);
    }

    pub(super) fn commit_successful_durable_notice_paint(&mut self) {
        let Some(delivery) = self.painted_durable_notice_this_frame.take() else {
            return;
        };
        let Some(front) = self.durable_notices.front_mut() else {
            return;
        };
        if front.notice.delivery != delivery || front.painted_at.is_some() {
            return;
        }
        front.painted_at = Some(Instant::now());
        self.remember_durable_notice(delivery.clone());
        self.queue_durable_notice_ack(delivery);
    }

    pub(super) fn dismiss_painted_durable_notice(&mut self) -> bool {
        if self.durable_notices.front().is_none_or(|front| front.painted_at.is_none()) {
            return false;
        }
        self.durable_notices.pop_front();
        true
    }

    pub(super) fn durable_notice_banner_row(&self) -> Option<u16> {
        self.durable_notices.front().and_then(|front| front.painted_at).and_then(|_| {
            let content_bottom = self.content_area.y.saturating_add(self.content_area.height);
            if self.surface_only.is_some() {
                content_bottom.checked_sub(1)
            } else {
                Some(content_bottom)
            }
        })
    }

    pub(super) fn advance_expired_durable_notice(&mut self) -> bool {
        let expired = self.durable_notices.front().is_some_and(|front| {
            front
                .painted_at
                .is_some_and(|painted_at| painted_at.elapsed() >= DURABLE_NOTICE_DISPLAY_DURATION)
        });
        if expired {
            self.durable_notices.pop_front();
        }
        expired
    }

    pub(super) fn remember_durable_notice(&mut self, delivery: DurableNoticeDelivery) {
        if self.recent_durable_notices.contains(&delivery) {
            return;
        }
        if self.recent_durable_notices.len() == DURABLE_NOTICE_RECENT_CAPACITY {
            self.recent_durable_notices.pop_front();
        }
        self.recent_durable_notices.push_back(delivery);
    }

    pub(super) fn queue_durable_notice_ack(&mut self, delivery: DurableNoticeDelivery) {
        if self.durable_notice_ack_in_flight.as_ref() == Some(&delivery)
            || self.pending_durable_notice_acks.contains(&delivery)
        {
            return;
        }
        self.pending_durable_notice_acks.push_back(delivery);
    }

    pub(super) fn submit_pending_durable_notice_ack(&mut self) {
        if self.durable_notice_ack_in_flight.is_some()
            || self.machine_action_in_flight
            || self.pending_machine_replacement.is_some()
        {
            return;
        }
        if let Some(retry_at) = self.durable_notice_ack_retry_at {
            if Instant::now() < retry_at {
                return;
            }
            self.durable_notice_ack_retry_at = None;
        }
        let Some(delivery) = self.pending_durable_notice_acks.pop_front() else {
            return;
        };
        let Some(worker) = self.machine_action_worker.as_ref() else {
            self.pending_durable_notice_acks.push_front(delivery);
            return;
        };
        let in_flight = delivery.clone();
        match worker.acknowledge_durable_notice(delivery) {
            Ok(()) => self.durable_notice_ack_in_flight = Some(in_flight),
            Err(delivery) => self.pending_durable_notice_acks.push_front(delivery),
        }
    }
}
