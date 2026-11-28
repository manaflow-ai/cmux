use super::*;

struct AuthenticatingSource {
    started: tokio::time::Instant,
    authentication: Duration,
    previously_spent: Duration,
}

#[async_trait]
impl ReconnectGroupSource for AuthenticatingSource {
    fn resolution_time_excluded(&self) -> Duration {
        self.previously_spent + self.started.elapsed().min(self.authentication)
    }

    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        std::future::pending().await
    }
}

#[tokio::test(start_paused = true)]
async fn resolution_excludes_only_authentication_during_this_attempt() {
    for authentication in [Duration::ZERO, Duration::from_secs(3)] {
        let source = AuthenticatingSource {
            started: tokio::time::Instant::now(),
            authentication,
            previously_spent: Duration::from_secs(90),
        };
        let budget = Duration::from_secs(1);
        assert!(resolve_reconnect_group(&source, budget).await.is_none());
        assert_eq!(source.started.elapsed(), budget + authentication);
    }
}

#[tokio::test(start_paused = true)]
async fn resolution_can_be_cancelled_while_authenticating() {
    let source = AuthenticatingSource {
        started: tokio::time::Instant::now(),
        authentication: Duration::from_secs(300),
        previously_spent: Duration::ZERO,
    };
    assert!(
        tokio::time::timeout(
            Duration::from_secs(2),
            resolve_reconnect_group(&source, Duration::from_secs(1)),
        )
        .await
        .is_err()
    );
    assert_eq!(source.started.elapsed(), Duration::from_secs(2));
}
