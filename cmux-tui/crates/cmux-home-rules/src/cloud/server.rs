//! `HomeCloudServer`: the chat server the Cloud source reaches. The type is
//! [`super::link::Server`] (the link's state machine already carries it);
//! this module adds the one rule the app derives from it.

pub use super::link::Server;

/// Whether the daemon sends the server the Stack account's token: only the
/// hosted cmux Cloud takes it; a self-hosted server knows the person by
/// their Tailscale login.
pub fn sends_token(server: &Server) -> bool {
    matches!(server, Server::Hosted)
}

/// The self-hosted server's URL, or nil for the hosted Cloud.
pub fn self_hosted_url(server: &Server) -> Option<&str> {
    match server {
        Server::Hosted => None,
        Server::SelfHosted { url } => Some(url),
    }
}
