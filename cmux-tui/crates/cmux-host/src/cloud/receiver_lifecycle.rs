//! Original VM credential only; no replay key or caller-selected machine.
use cmux_server::cloud_http::RequestDeadline;

use cmux_cloud_wire::{
    CloudVmReceiverLifecycleError, CloudVmReceiverLifecycleOp, CloudVmReceiverLifecycleParams,
    CloudVmReceiverLifecycleParamsPhase as Phase, CloudVmReceiverLifecycleResult,
    CloudVmReceiverLifecycleResultPhase as State, Op, OpRequest, OpResponse,
};

use super::client::{CloudClient, Http};
use super::receiver::REQUEST_BUDGET;

const UNAVAILABLE: &str = "original VM receiving lifecycle unavailable";

impl<H: Http> CloudClient<H> {
    pub(super) fn receiver_lifecycle(
        &mut self,
        phase: Phase,
        expected: Option<String>,
        attempt: Option<String>,
        wall_ms: u64,
    ) -> Result<CloudVmReceiverLifecycleResult, String> {
        let deadline = RequestDeadline::after(REQUEST_BUDGET).ok_or(UNAVAILABLE)?;
        let token = self.token_until(wall_ms, Some(&deadline))?;
        let request =
            OpRequest::new::<CloudVmReceiverLifecycleOp>(CloudVmReceiverLifecycleParams {
                machine: self.bound().machine.clone(),
                phase: phase.clone(),
                expected: expected.clone(),
                attempt,
            });
        let body = serde_json::to_value(request).map_err(|_| UNAVAILABLE)?;
        let (status, bytes) =
            self.request_until("/v1/ops", Some(&body), Some(&token), &deadline)?;
        if status != 200 || bytes.len() > 8192 {
            self.clear_token();
            return Err(UNAVAILABLE.into());
        }
        let response: OpResponse<CloudVmReceiverLifecycleResult, CloudVmReceiverLifecycleError> =
            serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE)?;
        if !response.ok
            || response.error.is_some()
            || response.op != CloudVmReceiverLifecycleOp::NAME
            || response.replayed
            || !response.idempotency_key.is_empty()
            || response.revision.is_some()
            || !response.stream.is_empty()
            || response.sequence != 0
            || response.transaction.is_empty()
        {
            return Err(UNAVAILABLE.into());
        }
        let value = response.value.ok_or(UNAVAILABLE)?;
        if value.machine != self.bound().machine
            || value.generation.len() != 64
            || !value.generation.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(UNAVAILABLE.into());
        }
        let valid = match phase {
            Phase::Read => matches!(
                &value.phase,
                State::Idle | State::Starting | State::Ready | State::Stopped
            ),
            Phase::Begin => {
                value.phase == State::Starting && expected.as_ref() != Some(&value.generation)
            }
            Phase::Ready => {
                value.phase == State::Ready && expected.as_ref() == Some(&value.generation)
            }
            Phase::End => {
                value.phase == State::Stopped && expected.as_ref() == Some(&value.generation)
            }
            Phase::Unknown(_) => false,
        };
        if !valid {
            return Err(UNAVAILABLE.into());
        }
        Ok(value)
    }
}
