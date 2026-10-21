//! Hosting of the cloud conversations proxy (`cloud-conversations-v1`,
//! plans/cmux-next/home-cloud-proxy.md). The Durable Objects own the data;
//! the mux only holds the daemon's cloud link and publishes its events.

use super::*;
use crate::cloud_conversations::{CloudConversations, HostReplica};

/// The cloud services one binary installs once (absent without a cloud transport).
#[derive(Default)]
pub(crate) struct CloudServices {
    /// `cloud-conversations-v1`.
    conversations: OnceLock<CloudConversations>,
    /// `cloud-host-replica-v1` (server/cloud_host_replica.rs).
    host_replica: OnceLock<HostReplica>,
}

impl Mux {
    /// Installs the cloud link once (the binary that has a cloud transport
    /// does this at startup) and routes its events to subscribers. A second
    /// install is refused and leaves the first in place.
    pub fn install_cloud_conversations(self: &Arc<Self>, service: CloudConversations) -> bool {
        let weak = Arc::downgrade(self);
        service.set_sink(Arc::new(move |event| {
            if let Some(mux) = weak.upgrade() {
                mux.emit(MuxEvent::CloudConversation(Arc::new(event)));
            }
        }));
        self.cloud.conversations.set(service).is_ok()
    }

    /// The installed cloud link, if any.
    pub fn cloud_conversations(&self) -> Option<&CloudConversations> {
        self.cloud.conversations.get()
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
