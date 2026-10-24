// A provider-neutral receipt contract for cmux and acpmux integrations.
// This module only builds requests. It never fetches a URL or stores a token,
// so the same code can run in a cmux app, an acpmux host, a Worker, or CI.

import { checkEgressUrl, parseHttpUrl } from "./egress.ts"

export type ReceiptStatus = "started" | "succeeded" | "failed" | "stopped"

/** The small, redacted-by-the-caller event shared by all delivery adapters. */
export interface CmuxReceipt {
  readonly id: string
  /** Stable operation name, for example `cloud.machine.created`. */
  readonly type: string
  /** A non-secret source URI, usually `cmux://machine/<id>`. */
  readonly source: string
  readonly status: ReceiptStatus
  readonly occurred_at: string
  readonly operation?: string
  readonly resource?: { readonly kind: string; readonly id: string }
  readonly duration_ms?: number
  /** Do not put credentials, tokens or raw command output here. */
  readonly details?: Readonly<Record<string, unknown>>
}

export interface ReceiptCloudEvent {
  readonly specversion: "1.0"
  readonly id: string
  readonly source: string
  readonly type: string
  readonly time: string
  readonly datacontenttype: "application/json"
  readonly data: CmuxReceipt
}

export interface ReceiptWebhookRequest {
  readonly url: string
  readonly method: "POST"
  /** Authentication is deliberately absent; the caller adds its own header. */
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
}

export type ReceiptEndpointErrorCode =
  | "receipt.invalid_endpoint"
  | "receipt.private_endpoint"
  | "receipt.credentials_in_url"
  | "receipt.https_required"

export class ReceiptEndpointError extends Error {
  constructor(readonly code: ReceiptEndpointErrorCode, message: string) {
    super(message)
  }
}

const endpoint = (value: string): string => {
  const parsed = parseHttpUrl(value)
  if (parsed === null) throw new ReceiptEndpointError("receipt.invalid_endpoint", "Receipt endpoint must be an http(s) URL")
  if (parsed.userinfo) throw new ReceiptEndpointError("receipt.credentials_in_url", "Receipt endpoint must not contain credentials")
  if (parsed.scheme !== "https") throw new ReceiptEndpointError("receipt.https_required", "Receipt endpoint must use HTTPS")
  const checked = checkEgressUrl(value)
  if (!checked.ok) {
    if (checked.code === "egress.credentials_in_url") throw new ReceiptEndpointError("receipt.credentials_in_url", "Receipt endpoint must not contain credentials")
    if (checked.code === "egress.private_target") throw new ReceiptEndpointError("receipt.private_endpoint", "Receipt endpoint must use a public host")
    throw new ReceiptEndpointError("receipt.invalid_endpoint", "Receipt endpoint is not a valid public URL")
  }
  return value
}

export const receiptCloudEvent = (receipt: CmuxReceipt): ReceiptCloudEvent => ({
  specversion: "1.0",
  id: receipt.id,
  source: receipt.source,
  type: receipt.type,
  time: receipt.occurred_at,
  datacontenttype: "application/json",
  data: receipt
})

const request = (url: string, body: unknown, contentType = "application/json"): ReceiptWebhookRequest => ({
  url: endpoint(url),
  method: "POST",
  headers: { "content-type": contentType },
  body: JSON.stringify(body)
})

/** Generic webhook / Vercel-style deploy hook payload (CloudEvents 1.0). */
export const buildReceiptWebhookRequest = (url: string, receipt: CmuxReceipt): ReceiptWebhookRequest =>
  request(url, receiptCloudEvent(receipt), "application/cloudevents+json")

/** GitHub repository-dispatch payload. The caller adds `Authorization: Bearer …`. */
export const buildGitHubDispatchRequest = (url: string, receipt: CmuxReceipt): ReceiptWebhookRequest =>
  request(url, { event_type: receipt.type, client_payload: receipt })

/** Slack incoming-webhook payload. The endpoint remains supplied by the caller. */
export const buildSlackWebhookRequest = (url: string, receipt: CmuxReceipt): ReceiptWebhookRequest => {
  const subject = receipt.resource ? `${receipt.resource.kind}/${receipt.resource.id}` : receipt.source
  return request(url, { text: `[cmux] ${receipt.type} ${receipt.status}: ${subject}` })
}
