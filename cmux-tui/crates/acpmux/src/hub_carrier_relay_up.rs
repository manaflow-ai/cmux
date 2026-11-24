//! When a relay comes back, the peers that failed on it redial at once.
//!
//! A peer link that dies again before it stayed up `stable_after` keeps its reconnect backoff
//! (`peer_link.rs` `Backoff`), so after a few short relay outages every redial waited out most of
//! the 60 s cap even though the relay accepted again within seconds (cmux#54814's
//! `hub_rejoin_duress` leg: p50 29-35 s, p95 50-57 s after a 3 s outage). Nothing woke the wait:
//! no client asked and no network changed.
//!
//! The carrier now watches a relay it could not reach. One watcher per relay asks its `/healthz`
//! (both cmux-relay and the Cloudflare relay serve it) on a short doubling schedule of its own,
//! and on the down-to-up edge it moves [`RelayUp`]'s generation. A peer that failed a hub dial
//! wakes from its backoff once the generation moves past the one it dialed under
//! (`Peer::relay_back`): one attempt, the backoff not started over, as a network change is.
//! A peer that stays down (its machine off, its slot offline) is no relay failure, so it never
//! starts a watcher and keeps its backoff; a watcher whose first answer is up was no relay
//! outage either and ends without a wake.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use url::Url;

/// The watcher's first wait after its relay answered down, doubling to [`WATCH_CAP`].
pub(crate) const WATCH_FIRST: Duration = Duration::from_millis(250);
/// The longest wait between two asks of a relay that stays down: one small GET per relay every
/// two seconds while it is down, and none once it is up.
pub(crate) const WATCH_CAP: Duration = Duration::from_secs(2);
/// One ask's bound: an answer slower than this is down.
const ASK_WAIT: Duration = Duration::from_secs(2);

/// The relay-up edges a carrier saw, as a generation peers wait on.
#[derive(Clone)]
pub(crate) struct RelayUp(Arc<Inner>);

struct Inner {
    generation: tokio::sync::watch::Sender<u64>,
    /// The relays a watcher asks now, by URL: one watcher each.
    watching: Mutex<HashSet<String>>,
}

impl Default for RelayUp {
    fn default() -> Self {
        Self(Arc::new(Inner {
            generation: tokio::sync::watch::channel(0).0,
            watching: Mutex::new(HashSet::new()),
        }))
    }
}

impl RelayUp {
    /// The generation now: a dial notes it first, and the peer's wait ends once it moves.
    pub(crate) fn generation(&self) -> u64 {
        *self.0.generation.borrow()
    }

    /// Resolves once a relay came back after `seen` (at once if one already did).
    pub(crate) async fn after(&self, seen: u64) {
        let mut rx = self.0.generation.subscribe();
        // The sender lives in `self`, so this only ends on a later generation.
        let _ = rx.wait_for(|now| *now > seen).await;
    }

    /// `relay` did not take a connect: watch it until it answers, unless a watcher already
    /// does. The watcher ends with the carrier (`alive`).
    pub(crate) fn failed(&self, relay: &str, alive: Weak<()>) {
        let Some(health) = health_url(relay) else { return };
        {
            let mut watching = self.0.watching.lock().unwrap_or_else(|e| e.into_inner());
            if !watching.insert(relay.to_owned()) {
                return;
            }
        }
        let client = match http_client() {
            Ok(client) => client,
            Err(e) => {
                tracing::debug!("hub carrier: no client to watch {relay}: {e}");
                self.done(relay);
                return;
            }
        };
        let me = self.clone();
        let relay = relay.to_owned();
        scope().spawn_named("hub carrier relay watch", async move {
            let ask = |client: reqwest::Client, url: Url| async move {
                matches!(
                    tokio::time::timeout(ASK_WAIT, client.get(url).send()).await,
                    Ok(Ok(answer)) if answer.status().is_success()
                )
            };
            me.watch(&relay, alive, || ask(client.clone(), health.clone())).await;
            me.done(&relay);
        });
    }

    /// Asks `up` until it answers yes or the carrier is gone. A first yes is no outage: the
    /// connect failed for another reason, and nothing wakes.
    async fn watch<F, Fut>(&self, relay: &str, alive: Weak<()>, mut up: F)
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = bool>,
    {
        if up().await {
            return;
        }
        let mut wait = WATCH_FIRST;
        loop {
            tokio::time::sleep(wait).await;
            if alive.upgrade().is_none() {
                return;
            }
            if up().await {
                self.0.generation.send_modify(|g| *g += 1);
                tracing::info!(
                    "hub carrier: relay {relay} accepts again; peers that failed on it redial now"
                );
                return;
            }
            wait = (wait * 2).min(WATCH_CAP);
        }
    }

    fn done(&self, relay: &str) {
        self.0.watching.lock().unwrap_or_else(|e| e.into_inner()).remove(relay);
    }
}

/// The relay's `/healthz`, over HTTP for the loopback `relay+ws` and HTTPS for the rest.
pub(crate) fn health_url(relay: &str) -> Option<Url> {
    let url = Url::parse(relay).ok()?;
    let scheme = match url.scheme() {
        "relay+ws" => "http",
        "relay+wss" | "relay+https" | "relay+do" => "https",
        _ => return None,
    };
    let (_, rest) = relay.split_once("://")?;
    let mut health = Url::parse(&format!("{scheme}://{rest}")).ok()?;
    health.set_path("/healthz");
    health.set_query(None);
    health.set_fragment(None);
    Some(health)
}

fn http_client() -> Result<reqwest::Client, reqwest::Error> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    crate::happy_dial::http_client().connect_timeout(ASK_WAIT).build()
}

fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier relay watch"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn health_url_maps_every_relay_scheme() {
        assert_eq!(
            health_url("relay+ws://127.0.0.1:9/v1/relay").unwrap().as_str(),
            "http://127.0.0.1:9/healthz"
        );
        assert_eq!(
            health_url("relay+wss://r.example/x?y=1").unwrap().as_str(),
            "https://r.example/healthz"
        );
        assert_eq!(
            health_url("relay+do://r.example").unwrap().as_str(),
            "https://r.example/healthz"
        );
        assert!(health_url("ws://r.example").is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn wakes_once_on_the_down_to_up_edge() {
        let up = RelayUp::default();
        let alive = Arc::new(());
        let asks = Arc::new(AtomicUsize::new(0));
        let seen = up.generation();
        let waiter = tokio::spawn({
            let up = up.clone();
            async move { up.after(seen).await }
        });
        let counted = asks.clone();
        // Down for the first three asks, then up.
        up.watch("r", Arc::downgrade(&alive), move || {
            let n = counted.fetch_add(1, Ordering::SeqCst);
            async move { n >= 3 }
        })
        .await;
        assert_eq!(asks.load(Ordering::SeqCst), 4);
        assert_eq!(up.generation(), seen + 1);
        waiter.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn a_relay_that_answers_at_once_wakes_nobody() {
        let up = RelayUp::default();
        let alive = Arc::new(());
        up.watch("r", Arc::downgrade(&alive), || async { true }).await;
        assert_eq!(up.generation(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn a_relay_that_stays_down_is_asked_at_most_every_cap_and_ends_with_the_carrier() {
        let up = RelayUp::default();
        let alive = Arc::new(());
        let asks = Arc::new(AtomicUsize::new(0));
        let counted = asks.clone();
        let watch = tokio::spawn({
            let up = up.clone();
            let alive = Arc::downgrade(&alive);
            async move {
                up.watch("r", alive, move || {
                    counted.fetch_add(1, Ordering::SeqCst);
                    async { false }
                })
                .await
            }
        });
        tokio::time::sleep(Duration::from_secs(60)).await;
        let asked = asks.load(Ordering::SeqCst);
        // 0, 0.25, 0.75, 1.75, then every 2 s: about 31 asks in a minute, never a tight loop.
        assert!((28..=34).contains(&asked), "{asked} asks in 60 s");
        drop(alive);
        tokio::time::sleep(WATCH_CAP * 2).await;
        assert!(watch.is_finished());
        assert_eq!(up.generation(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn a_wait_for_an_edge_already_seen_returns_at_once() {
        let up = RelayUp::default();
        up.0.generation.send_modify(|g| *g += 1);
        tokio::time::timeout(Duration::from_millis(1), up.after(0)).await.unwrap();
    }
}
