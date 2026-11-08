// VM alerts deliver to Slack (services/observability/alerts.ts). Without a
// sink a triggered alert only becomes a Sentry/PostHog record
// (reportDroppedVmAlerts in services/observability/vmAlerts.ts), which pages
// nobody, so CMUX_ALERTS_SLACK_WEBHOOK_URL stays a required production key.
//
// Production may have a webhook after an operator provisions one. When it is
// absent, a bare requirement makes the audit red with no recorded owner, so
// the escape hatch is an explicit, plain-text acknowledgement in the
// deployment env: who decided to run without a sink and why. A fresh
// environment with neither key still fails.
export const ALERT_SINK_KEY = "CMUX_ALERTS_SLACK_WEBHOOK_URL";
export const ALERT_SINK_UNCONFIGURED_ACK_KEY = "CMUX_ALERTS_SINK_UNCONFIGURED_ACK";
export const alertSinkAuditEnvKeys = [ALERT_SINK_UNCONFIGURED_ACK_KEY];

const SENSITIVE_PLACEHOLDER = "[SENSITIVE]";

function nonEmpty(value) {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * Decides whether the missing-sink state is an audited, recorded decision.
 * `waivedRequiredKeys` lists the required keys the caller may drop from its
 * missing-required check; any problem fails the audit.
 */
export function auditAlertSink(env) {
  const configured = nonEmpty(env[ALERT_SINK_KEY]);
  const ackRaw = env[ALERT_SINK_UNCONFIGURED_ACK_KEY];
  const acknowledged = ackRaw !== undefined;
  const problems = [];
  let reason = null;
  if (acknowledged) {
    if (ackRaw === SENSITIVE_PLACEHOLDER) {
      problems.push(
        `${ALERT_SINK_UNCONFIGURED_ACK_KEY} is stored as a Sensitive env var, so the recorded ` +
          "reason cannot be audited; store it as a plain env var",
      );
    } else if (!nonEmpty(ackRaw)) {
      problems.push(
        `${ALERT_SINK_UNCONFIGURED_ACK_KEY} is set but empty; record who decided to run ` +
          "without a Slack alert sink and why, or unset it",
      );
    } else {
      reason = ackRaw.trim();
    }
    if (configured) {
      problems.push(
        `${ALERT_SINK_UNCONFIGURED_ACK_KEY} is set although ${ALERT_SINK_KEY} is configured; ` +
          "unset the stale acknowledgement",
      );
    }
  }
  const waived = !configured && acknowledged && problems.length === 0;
  return {
    configured,
    acknowledged,
    reason,
    acknowledgeKey: ALERT_SINK_UNCONFIGURED_ACK_KEY,
    waivedRequiredKeys: waived ? [ALERT_SINK_KEY] : [],
    problems,
  };
}
