//! Pure values used by native control frames; kept outside the dispatcher.
use super::*;

/// `machine-usage` result and `machine-usage-changed` payload body: `usage`
/// is the readout object or null when the daemon has none.
pub(super) fn machine_usage_json(usage: Option<&MachineUsage>) -> Value {
    json!({
        "usage": usage.map(|usage| json!({
            "vm_id": usage.vm_id,
            "period_days": usage.period_days,
            "total_tokens": usage.total_tokens,
            "api_equivalent_usd": usage.api_equivalent_usd,
            "as_of": usage.as_of,
        })),
    })
}

pub(super) fn json_line_payload_len(line: &str) -> usize {
    line.strip_suffix('\n').map_or(line.len(), str::len)
}

pub(super) fn default_renderer_capability_ttl_ms() -> u64 {
    30_000
}
