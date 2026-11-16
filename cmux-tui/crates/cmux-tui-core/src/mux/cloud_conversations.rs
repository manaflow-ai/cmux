//! Hosting of the cloud conversations proxy (`cloud-conversations-v1`,
//! plans/cmux-next/home-cloud-proxy.md). The Durable Objects own the data;
//! the mux only holds the daemon's cloud link and publishes its events.

use super::*;
use crate::cloud_conversations::{CloudConversations, CloudEvent, HostReplica, Target};

/// Where the `appkv:<user>` stream's events go: the apps supervisor's synced
/// storage (apps/synced.rs). They never reach a client.
pub(crate) type AppKvSink = Arc<dyn Fn(&CloudEvent) + Send + Sync>;

/// The cloud services one binary installs once (absent without a cloud transport).
#[derive(Default)]
pub(crate) struct CloudServices {
    /// `cloud-conversations-v1`.
    conversations: OnceLock<CloudConversations>,
    /// `cloud-host-replica-v1` (server/cloud_host_replica.rs).
    host_replica: OnceLock<HostReplica>,
    /// `feed-client-v1` (feed_client.rs), made on the first `feed.*` op.
    pub(crate) feed: OnceLock<crate::feed_client::FeedClient>,
    /// How `feed.reports.reply` reaches acpmux, installed by the binary.
    pub(crate) feed_reply: OnceLock<crate::feed_client::ReplySender>,
    /// Synced app storage's stream events (set when the apps supervisor starts).
    appkv: OnceLock<AppKvSink>,
}

/// Whether `event` belongs to the daemon's own `appkv:<user>` stream.
fn is_appkv(event: &CloudEvent) -> bool {
    match event {
        CloudEvent::AppKvReset { .. } | CloudEvent::AppKvChanged { .. } => true,
        CloudEvent::SubscriptionState { target, .. } => *target == Target::AppKv,
        _ => false,
    }
}

impl Mux {
    /// Installs the cloud link once (the binary that has a cloud transport
    /// does this at startup) and routes its events to subscribers. A second
    /// install is refused and leaves the first in place. The synced app
    /// storage stream's events go only to the apps supervisor.
    pub fn install_cloud_conversations(self: &Arc<Self>, service: CloudConversations) -> bool {
        let weak = Arc::downgrade(self);
        service.set_sink(Arc::new(move |event| {
            if let Some(mux) = weak.upgrade() {
                if is_appkv(&event) {
                    if let Some(sink) = mux.cloud.appkv.get() {
                        sink(&event);
                    }
                    return;
                }
                mux.emit(MuxEvent::CloudConversation(Arc::new(event)));
            }
        }));
        self.cloud.conversations.set(service).is_ok()
    }

    /// Routes the `appkv:<user>` stream's events to synced app storage (once).
    pub(crate) fn set_appkv_sink(&self, sink: AppKvSink) {
        let _ = self.cloud.appkv.set(sink);
    }

    /// The installed cloud link, if any.
    pub fn cloud_conversations(&self) -> Option<&CloudConversations> {
        self.cloud.conversations.get()
    }

    /// The cloud services (the feed client lives here, server/feed_client_ops.rs).
    pub(crate) fn cloud_services(&self) -> &CloudServices {
        &self.cloud
    }

    /// The host replica publisher, if installed (server/cloud_host_replica.rs).
    pub fn host_replica(&self) -> Option<&HostReplica> {
        self.cloud.host_replica.get()
    }

    pub(crate) fn set_host_replica(&self, replica: HostReplica) -> Result<(), HostReplica> {
        self.cloud.host_replica.set(replica)
    }

    /// Ends a closed connection's cloud subscriptions.
    pub(crate) fn release_cloud_conversation_client(&self, client: u64) {
        if let Some(service) = self.cloud.conversations.get() {
            service.client_closed(client);
        }
    }
}
