//! A relay capacity refusal is not a dial's answer: every service dial
//! ([`HubCarrier::dial_service_report_early`]) rides the pair's open cheap kept circuit or waits
//! the relay out.

use std::time::Duration;

use super::{CircuitLane, CircuitService, DialReport, HubCarrier, HubStream};

impl HubCarrier {
    /// [`Self::dial_service_report`] whose stream starts with `early` (at most
    /// [`mux::EARLY_BYTES`]): behind the OPEN on a kept circuit, else written once answered.
    /// A relay capacity refusal ([`capacity_refusal`]) is not the dial's answer: the dial rides
    /// the pair's open cheap kept circuit, which asks the relay for nothing, or tries again after
    /// each of [`CAPACITY_WAITS`] ([`dial_past_capacity`]). The relay refuses before any of
    /// `early` leaves, so a second try sends nothing twice. Every service dial comes here: a
    /// machine call, a peer link, a move's pages, a forwarded port.
    pub(super) async fn dial_service_report_early(
        &self,
        daemon: &str,
        service: CircuitService,
        lane: CircuitLane,
        early: &[u8],
        report: &mut DialReport,
    ) -> Result<HubStream, String> {
        let (stream, last) = dial_past_capacity(
            || async move {
                let mut try_report = DialReport::default();
                self.dial_service_once(daemon, service, lane, early, &mut try_report)
                    .await
                    .map(|stream| (stream, try_report))
            },
            || async move {
                if lane == CircuitLane::Cheap || !self.kept_live(daemon, CircuitLane::Cheap) {
                    return None;
                }
                let mut try_report = DialReport::default();
                Some(
                    self.dial_service_once(
                        daemon,
                        service,
                        CircuitLane::Cheap,
                        early,
                        &mut try_report,
                    )
                    .await
                    .map(|stream| (stream, try_report)),
                )
            },
            &CAPACITY_WAITS,
        )
        .await?;
        *report = last;
        Ok(stream)
    }
}

/// How a relay words a circuit it refused for the far machine's slot capacity: the slot's circuit
/// quota or its allocation rate (relay `abuse.rs`, code `slot-circuit-capacity`), or a busy slot
/// (`slot-busy`). The relay marks both retryable; a lease, a pending join or the minute's window
/// frees room within seconds.
const CAPACITY_CODES: [&str; 2] = ["(relay code slot-circuit-capacity)", "(relay code slot-busy)"];

/// The waits between a dial's tries while the relay answers with a capacity refusal: about 16 s in
/// all, inside a move's own wait (`hub/transfer_pull.rs` `MOVE_WAIT`). Before, the first refusal
/// failed the move (`transfer.unreachable: ... slot-circuit-capacity`, a lane VM's round-trip
/// probe, 2026-11-27), and after cmux#62004 every dial but the move's page dial still did (a
/// machine call, a peer link, a send).
pub(crate) const CAPACITY_WAITS: [Duration; 6] = [
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
];

/// Whether `error` is the relay's capacity refusal ([`CAPACITY_CODES`]).
pub(crate) fn capacity_refusal(error: &str) -> bool {
    CAPACITY_CODES.iter().any(|code| error.contains(code))
}

/// `dial`, and on a capacity refusal ([`capacity_refusal`]): first `kept`, a stream on a kept
/// circuit already open (None: there is none), then `dial` again after each of `waits`. Any other
/// error is the dial's answer at once. A refusal past the last wait says how long it was retried.
pub(crate) async fn dial_past_capacity<T, D, DF, K, KF>(
    mut dial: D,
    mut kept: K,
    waits: &[Duration],
) -> Result<T, String>
where
    D: FnMut() -> DF,
    DF: std::future::Future<Output = Result<T, String>>,
    K: FnMut() -> KF,
    KF: std::future::Future<Output = Option<Result<T, String>>>,
{
    let mut waited = Duration::ZERO;
    let mut waits = waits.iter();
    loop {
        let error = match dial().await {
            Ok(stream) => return Ok(stream),
            Err(error) if capacity_refusal(&error) => error,
            Err(error) => return Err(error),
        };
        match kept().await {
            Some(Ok(stream)) => {
                tracing::info!(
                    "hub carrier: the relay refused a circuit for capacity ({error}); the dial rides \
                     the kept circuit"
                );
                return Ok(stream);
            }
            Some(Err(why)) => {
                tracing::debug!("hub carrier: the kept circuit took no stream: {why}");
            }
            None => {}
        }
        let Some(wait) = waits.next() else {
            return Err(format!(
                "{error}; refused again after {} ms of retries",
                waited.as_millis()
            ));
        };
        tracing::info!("hub carrier: the relay refused a circuit for capacity; again in {wait:?}");
        tokio::time::sleep(*wait).await;
        waited += *wait;
    }
}
