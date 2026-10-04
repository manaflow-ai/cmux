//! What a reply to a connection that is not the local unix socket may not
//! carry: any token.

use serde_json::Value;

/// A remote-origin (Web) connection never learns a token: not the
/// dashboard link (`webUrl` carries this listener's token) and not the
/// userinfo, query or fragment of a peer's URL (a user may have written a
/// peer's token there). The local socket keeps both (`acpmux web`, the app's host).
pub(super) fn redact_for_remote(reply: &mut Value) {
    if let Some(obj) = reply.as_object_mut() {
        obj.remove("webUrl");
    }
    if let Some(peers) = reply.get_mut("peers").and_then(Value::as_array_mut) {
        for peer in peers {
            if let Some(url) = peer.get("url").and_then(Value::as_str) {
                peer["url"] = Value::String(url_without_secrets(url));
            }
        }
    }
}

/// `scheme://user:secret@host/path?q#f` -> `scheme://host/path`.
fn url_without_secrets(url: &str) -> String {
    let bare = url.split(['?', '#']).next().unwrap_or_default();
    let Some((scheme, rest)) = bare.split_once("://") else { return bare.to_owned() };
    let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    format!("{scheme}://{host}{path}")
}

#[cfg(test)]
mod tests {
    #[test]
    fn peer_urls_lose_userinfo_query_and_fragment() {
        let f = super::url_without_secrets;
        assert_eq!(f("ws://u:secret@host:1/p?token=x#y"), "ws://host:1/p");
        assert_eq!(f("ssh://me@box:22"), "ssh://box:22");
        assert_eq!(f("ws://host/"), "ws://host/");
    }
}
