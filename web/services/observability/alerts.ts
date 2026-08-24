import { reportError } from "./report";

export type AlertSeverity = "critical" | "warning";

export type AlertInput = {
  readonly key: string;
  readonly title: string;
  readonly body: string;
  readonly severity: AlertSeverity;
};

export type AlertResult = {
  readonly sent: boolean;
  readonly status?: number;
  readonly error?: string;
};

export type AlertFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export async function sendAlert(
  input: AlertInput,
  options: {
    readonly fetch?: AlertFetch;
    readonly env?: Record<string, string | undefined>;
  } = {},
): Promise<AlertResult> {
  const env = options.env ?? process.env;
  const webhookUrl = env.CMUX_ALERTS_SLACK_WEBHOOK_URL?.trim();
  if (!webhookUrl) return { sent: false };

  const fetchImpl = options.fetch ?? fetch;
  try {
    const response = await fetchImpl(webhookUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: formatSlackMessage(input) }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      reportError(new Error(`Slack alert webhook returned HTTP ${response.status}`), {
        subsystem: "cloud_vm_alerts",
        alertKey: input.key,
        severity: input.severity,
        status: response.status,
      });
      return { sent: false, status: response.status };
    }
    return { sent: true, status: response.status };
  } catch (error) {
    reportError(error, {
      subsystem: "cloud_vm_alerts",
      alertKey: input.key,
      severity: input.severity,
    });
    return { sent: false, error: errorMessage(error) };
  }
}

function formatSlackMessage(input: AlertInput): string {
  const emoji = input.severity === "critical" ? "🔴" : "🟠";
  return `${emoji} ${input.title}\n${input.body}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
