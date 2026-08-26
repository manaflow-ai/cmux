// Minimal Resend REST client for segment/contact/topic/broadcast management,
// targeting Resend's current data model: contacts are GLOBAL per account,
// segments group contacts for targeting, and topics carry per-lane
// subscription preferences (https://resend.com/docs/dashboard/segments/
// migrating-from-audiences-to-segments).
//
// The transactional welcome email keeps using the official `resend` SDK; this
// client exists because the newsletter tooling needs behaviors the SDK does
// not expose cleanly: explicit pagination with a no-progress guard (so a
// truncated listing fails loudly instead of silently syncing a partial
// segment), injectable fetch for tests, per-request timeouts so webhook-path
// callers stay bounded, and a clear error when the API key is a sending-only
// restricted key.
//
// Broadcast SENDING is deliberately not implemented. Drafts are created via
// createBroadcastDraft (which never sets `send`) and the actual send stays a
// human action in the Resend dashboard.

export type ResendSegment = {
  id: string;
  name: string;
};

export type ResendTopic = {
  id: string;
  name: string;
  // "opt_in" or "opt_out"; immutable after creation. Callers must fail
  // closed on anything but "opt_in" (see sync.ts): this tooling never
  // subscribes contacts to topics, so an opt-out-by-default topic would
  // silently suppress a broadcast for nearly the whole segment.
  defaultSubscription: string;
};

export type ResendContact = {
  id: string;
  email: string;
  first_name?: string | null;
  last_name?: string | null;
  unsubscribed: boolean;
  properties?: Record<string, unknown> | null;
};

export type FetchLike = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
  },
) => Promise<{
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
}>;

// status carries the HTTP status for API-response errors and 0 for
// client-side failures (timeout, pagination guard, ambiguous name), so
// branches like the 404 check in getContactByEmail stay unambiguous.
export class ResendApiError extends Error {
  readonly status: number;
  readonly apiName: string | undefined;

  constructor(message: string, status: number, apiName?: string) {
    super(message);
    this.name = "ResendApiError";
    this.status = status;
    this.apiName = apiName;
  }
}

// Resend has used both 409 and named validation errors when a contact is
// created concurrently. Callers can recover only this narrow race; unrelated
// API failures must still propagate.
export function isDuplicateContactError(error: unknown): boolean {
  if (!(error instanceof ResendApiError)) return false;
  const name = error.apiName?.toLowerCase() ?? "";
  return (
    error.status === 409 ||
    name.includes("already_exists") ||
    name.includes("already-exists") ||
    name.includes("duplicate")
  );
}

const API_BASE = "https://api.resend.com";
const PAGE_LIMIT = 100;
const MAX_PAGES = 10_000;
// Resend's default rate limit is 2 requests/second; space mutating calls so a
// large first sync does not trip it, and retry 429s with backoff regardless.
const WRITE_SPACING_MS = 600;
const MAX_ATTEMPTS = 5;
const NETWORK_BACKOFF_BASE_MS = 250;
// Cap both the per-request wall time and any server-suggested Retry-After so
// a Resend stall cannot hold a caller (notably the Stripe webhook) open
// indefinitely.
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_RETRY_AFTER_MS = 5_000;

function cancelledError(label: string): ResendApiError {
  return new ResendApiError(`Resend ${label} cancelled by caller`, 0);
}

// Signal-aware sleep: rejects immediately when the cancel signal fires so
// throttle pacing and 429 backoff cannot outlive a cancelled operation.
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(cancelledError("wait"));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(cancelledError("wait"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

type ListResponse<T> = {
  data?: T[];
  has_more?: boolean;
};

type RequestOptions = {
  body?: unknown;
  // PII-safe description used in error messages instead of the raw path,
  // which for contact endpoints embeds an email address. Errors (and
  // anything logging them) must never carry contact PII.
  redactedLabel?: string;
};

// Resend rate limits are account-wide, while webhook handlers construct short-
// lived clients. Share a lane by API key so clients for the same account cannot
// each believe they are the first writer during a purchase burst. The cap
// prevents a future multi-account tool from retaining an unbounded key map.
type WriteLane = {
  queue: Promise<void>;
  lastWriteAt: number;
};
const accountWriteLanes = new Map<string, WriteLane>();
const MAX_WRITE_LANES = 16;

function writeLaneFor(apiKey: string): WriteLane {
  const existing = accountWriteLanes.get(apiKey);
  if (existing) return existing;
  if (accountWriteLanes.size >= MAX_WRITE_LANES) {
    const oldest = accountWriteLanes.keys().next().value;
    if (oldest) accountWriteLanes.delete(oldest);
  }
  const lane: WriteLane = { queue: Promise.resolve(), lastWriteAt: 0 };
  accountWriteLanes.set(apiKey, lane);
  return lane;
}

export class ResendClient {
  private readonly apiKey: string;
  private readonly fetchImpl: FetchLike;
  private readonly writeSpacingMs: number;
  private readonly requestTimeoutMs: number;
  private readonly maxRetryAfterMs: number;
  private readonly cancelSignal: AbortSignal | undefined;
  private readonly writeLane: WriteLane;

  constructor(options: {
    apiKey: string;
    fetchImpl?: FetchLike;
    writeSpacingMs?: number;
    requestTimeoutMs?: number;
    maxRetryAfterMs?: number;
    // When provided, aborting this signal cancels in-flight requests AND
    // pending throttle/backoff waits, so a deadline-bounded caller (the
    // Stripe webhook) does not leave a detached retry loop running after
    // it gives up.
    cancelSignal?: AbortSignal;
  }) {
    this.apiKey = options.apiKey;
    this.fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
    this.writeSpacingMs = options.writeSpacingMs ?? WRITE_SPACING_MS;
    this.requestTimeoutMs = options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
    this.maxRetryAfterMs = options.maxRetryAfterMs ?? MAX_RETRY_AFTER_MS;
    this.cancelSignal = options.cancelSignal;
    this.writeLane = writeLaneFor(this.apiKey);
  }

  private async request<T>(
    method: string,
    path: string,
    options: RequestOptions = {},
  ): Promise<T> {
    const label = options.redactedLabel ?? path;
    for (let attempt = 1; ; attempt += 1) {
      if (this.cancelSignal?.aborted) {
        throw cancelledError(`${method} ${label}`);
      }
      const abort = new AbortController();
      const onCancel = () => abort.abort();
      this.cancelSignal?.addEventListener("abort", onCancel, { once: true });
      const timer = setTimeout(() => abort.abort(), this.requestTimeoutMs);
      let response: Awaited<ReturnType<FetchLike>> | undefined;
      let text = "";
      let networkFailure = false;
      try {
        response = await this.fetchImpl(`${API_BASE}${path}`, {
          method,
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            "Content-Type": "application/json",
          },
          signal: abort.signal,
          ...(options.body === undefined
            ? {}
            : { body: JSON.stringify(options.body) }),
        });
        text = await response.text();
      } catch {
        if (this.cancelSignal?.aborted) {
          throw cancelledError(`${method} ${label}`);
        }
        if (abort.signal.aborted) {
          throw new ResendApiError(
            `Resend ${method} ${label} timed out after ${this.requestTimeoutMs}ms`,
            0,
          );
        }
        // Connection-level failures are transient. Keep the error generic so
        // a CLI or webhook log never echoes a socket/URL/provider payload.
        networkFailure = true;
      } finally {
        clearTimeout(timer);
        this.cancelSignal?.removeEventListener("abort", onCancel);
      }
      if (networkFailure) {
        // A transport error is ambiguous for a write: the provider may have
        // accepted the POST before the connection dropped. Without an
        // idempotency key, retrying would duplicate emails, drafts, or
        // audience resources. Only retry idempotent reads here.
        if (method !== "GET" || attempt >= MAX_ATTEMPTS) {
          throw new ResendApiError(
            `Resend ${method} ${label} failed to reach the provider`,
            0,
          );
        }
        await sleep(
          Math.min(NETWORK_BACKOFF_BASE_MS * attempt, this.maxRetryAfterMs),
          this.cancelSignal,
        );
        continue;
      }
      if (!response) {
        throw new ResendApiError(`Resend ${method} ${label} failed`, 0);
      }
      if (response.status === 429 && attempt < MAX_ATTEMPTS) {
        const retryAfter = Number(response.headers.get("retry-after"));
        const suggestedMs = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 1000 * attempt;
        await sleep(
          Math.min(suggestedMs, this.maxRetryAfterMs),
          this.cancelSignal,
        );
        continue;
      }
      let parsed: unknown = null;
      if (text) {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = null;
        }
      }
      if (response.status >= 400) {
        const apiError = parsed as {
          message?: string;
          name?: string;
        } | null;
        // A restricted key cannot manage segments/contacts/topics. Keep the
        // diagnostic actionable without exposing provider or environment
        // implementation details in a user-facing error.
        if (apiError?.name === "restricted_api_key") {
          throw new ResendApiError(
            "Newsletter management requires a key with Full access permission.",
            response.status,
            apiError.name,
          );
        }
        // Upstream bodies can echo request data (for example a contact email)
        // and flow into CLI/webhook logs. Keep only a stable error name/status.
        const detail = apiError?.name ?? `http_${response.status}`;
        throw new ResendApiError(
          `Resend ${method} ${label} failed with ${response.status}: ${detail}`,
          response.status,
          apiError?.name,
        );
      }
      return parsed as T;
    }
  }

  // Space mutating calls out; reads are cheap and left unthrottled.
  private async throttledWrite<T>(
    method: string,
    path: string,
    options: RequestOptions = {},
  ): Promise<T> {
    // Reserve a queue slot before awaiting. Without this, concurrent callers
    // all observe the same lastWriteAt and wake together, defeating the rate
    // limit this throttle is meant to enforce.
    let release!: () => void;
    const previous = this.writeLane.queue;
    this.writeLane.queue = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      const now = Date.now();
      const waitMs = this.writeLane.lastWriteAt + this.writeSpacingMs - now;
      if (waitMs > 0) {
        await sleep(waitMs, this.cancelSignal);
      }
      this.writeLane.lastWriteAt = Date.now();
      return await this.request<T>(method, path, options);
    } finally {
      release();
    }
  }

  // Page through a Resend list endpoint (limit/after cursor protocol). If the
  // API reports more data but a follow-up page makes no progress, throw
  // instead of returning a silently truncated list.
  private async listAll<T extends { id: string }>(path: string): Promise<T[]> {
    const items: T[] = [];
    let after: string | null = null;
    const seenCursors = new Set<string>();
    let pageCount = 0;
    for (;;) {
      pageCount += 1;
      if (pageCount > MAX_PAGES) {
        throw new ResendApiError(
          `Resend pagination exceeded the safety page limit for ${path}; ` +
            "refusing to continue with an unbounded listing.",
          0,
        );
      }
      const separator = path.includes("?") ? "&" : "?";
      const pagedPath: string = after
        ? `${path}${separator}limit=${PAGE_LIMIT}&after=${encodeURIComponent(after)}`
        : `${path}${separator}limit=${PAGE_LIMIT}`;
      const page: ListResponse<T> = await this.request<ListResponse<T>>(
        "GET",
        pagedPath,
      );
      const data: T[] = page.data ?? [];
      items.push(...data);
      if (!page.has_more) {
        return items;
      }
      const nextAfter: string | null =
        data.length > 0 ? data[data.length - 1].id : null;
      // Guard against cursor cycles of any length, not just an immediately
      // repeated cursor.
      if (!nextAfter || seenCursors.has(nextAfter)) {
        throw new ResendApiError(
          `Resend reported more results for ${path} but pagination made no ` +
            "progress; refusing to continue with a truncated listing.",
          0,
        );
      }
      seenCursors.add(nextAfter);
      after = nextAfter;
    }
  }

  async listSegments(): Promise<ResendSegment[]> {
    return this.listAll<ResendSegment>("/segments");
  }

  // Resolve a segment by exact name. Zero matches returns null (the caller
  // decides whether to create it); more than one match is ambiguous and
  // always an error, because writing into "whichever came back first" could
  // target the wrong list.
  async findSegmentByName(name: string): Promise<ResendSegment | null> {
    const segments = await this.listSegments();
    const matches = segments.filter((segment) => segment.name === name);
    if (matches.length > 1) {
      throw new ResendApiError(
        `Segment name "${name}" is ambiguous: ${matches.length} segments ` +
          "share it. Rename or delete the duplicates in the Resend dashboard.",
        0,
      );
    }
    return matches[0] ?? null;
  }

  async createSegment(name: string): Promise<ResendSegment> {
    const created = await this.throttledWrite<{ id: string; name?: string }>(
      "POST",
      "/segments",
      { body: { name } },
    );
    return { id: created.id, name: created.name ?? name };
  }

  async listTopics(): Promise<ResendTopic[]> {
    const topics = await this.listAll<{
      id: string;
      name: string;
      default_subscription?: string;
    }>("/topics");
    return topics.map((topic) => ({
      id: topic.id,
      name: topic.name,
      defaultSubscription: topic.default_subscription ?? "unknown",
    }));
  }

  async findTopicByName(name: string): Promise<ResendTopic | null> {
    const topics = await this.listTopics();
    const matches = topics.filter((topic) => topic.name === name);
    if (matches.length > 1) {
      throw new ResendApiError(
        `Topic name "${name}" is ambiguous: ${matches.length} topics share ` +
          "it. Rename or delete the duplicates in the Resend dashboard.",
        0,
      );
    }
    return matches[0] ?? null;
  }

  // Topics are created opt-in-by-default: contacts who never touched their
  // preferences receive the topic's broadcasts, and anyone who opted out did
  // so explicitly. default_subscription cannot be changed after creation.
  async createTopic(topic: {
    name: string;
    description?: string;
  }): Promise<ResendTopic> {
    const created = await this.throttledWrite<{ id: string; name?: string }>(
      "POST",
      "/topics",
      {
        body: {
          name: topic.name,
          default_subscription: "opt_in",
          ...(topic.description ? { description: topic.description } : {}),
        },
      },
    );
    return {
      id: created.id,
      name: created.name ?? topic.name,
      defaultSubscription: "opt_in",
    };
  }

  // Account-wide contact listing.
  async listContacts(): Promise<ResendContact[]> {
    return this.listAll<ResendContact>("/contacts");
  }

  // One segment's membership, via the segment-scoped endpoint so a bad
  // segment id fails loudly instead of silently returning every contact.
  async listSegmentContacts(segmentId: string): Promise<ResendContact[]> {
    return this.listAll<ResendContact>(
      `/segments/${encodeURIComponent(segmentId)}/contacts`,
    );
  }

  // Point read used by the purchase-time webhook hook, where listing every
  // contact per event would be wasteful. Returns null on 404. The email is
  // kept out of error messages via redactedLabel.
  async getContactByEmail(email: string): Promise<ResendContact | null> {
    try {
      return await this.request<ResendContact>(
        "GET",
        `/contacts/${encodeURIComponent(email)}`,
        { redactedLabel: "/contacts/<email>" },
      );
    } catch (error) {
      if (error instanceof ResendApiError && error.status === 404) {
        return null;
      }
      throw error;
    }
  }

  async getContactById(contactId: string): Promise<ResendContact | null> {
    try {
      return await this.request<ResendContact>(
        "GET",
        `/contacts/${encodeURIComponent(contactId)}`,
        { redactedLabel: "/contacts/<id>" },
      );
    } catch (error) {
      if (error instanceof ResendApiError && error.status === 404) {
        return null;
      }
      throw error;
    }
  }

  // Create a global contact, optionally placing it into segments in the same
  // call. `unsubscribed` and topic subscriptions are intentionally not
  // accepted: new contacts default to subscribed with each topic's default
  // preference, and no code path may ever write subscription state (see
  // reconcile.ts invariants).
  async createContact(contact: {
    email: string;
    properties?: Record<string, unknown>;
    firstName?: string;
    lastName?: string;
    segmentIds?: string[];
  }): Promise<void> {
    await this.throttledWrite("POST", "/contacts", {
      redactedLabel: "/contacts (create)",
      body: {
        email: contact.email,
        ...(contact.properties ? { properties: contact.properties } : {}),
        ...(contact.firstName ? { first_name: contact.firstName } : {}),
        ...(contact.lastName ? { last_name: contact.lastName } : {}),
        // The API expects segment assignments as objects carrying the id.
        ...(contact.segmentIds && contact.segmentIds.length > 0
          ? { segments: contact.segmentIds.map((id) => ({ id })) }
          : {}),
      },
    });
  }

  // Backfill missing name fields on an existing, still-subscribed contact.
  // Never sends `unsubscribed` or topic preferences, so it cannot
  // resubscribe anyone to anything.
  async updateContactName(
    contactId: string,
    name: { firstName?: string; lastName?: string },
  ): Promise<void> {
    await this.throttledWrite(
      "PATCH",
      `/contacts/${encodeURIComponent(contactId)}`,
      {
        redactedLabel: "/contacts/<id> (name backfill)",
        body: {
          ...(name.firstName ? { first_name: name.firstName } : {}),
          ...(name.lastName ? { last_name: name.lastName } : {}),
        },
      },
    );
  }

  async updateContactEmail(contactId: string, email: string): Promise<void> {
    await this.throttledWrite(
      "PATCH",
      `/contacts/${encodeURIComponent(contactId)}`,
      {
        redactedLabel: "/contacts/<id> (email migration)",
        body: { email },
      },
    );
  }

  // Segment membership is additive metadata; it never changes subscription
  // state (global unsubscribe and topic opt-outs still suppress delivery).
  async addContactToSegment(
    contactId: string,
    segmentId: string,
  ): Promise<void> {
    await this.throttledWrite(
      "POST",
      `/contacts/${encodeURIComponent(contactId)}/segments/${encodeURIComponent(segmentId)}`,
      { redactedLabel: "/contacts/<id>/segments/<segment>" },
    );
  }

  async removeContactFromSegment(
    contactId: string,
    segmentId: string,
  ): Promise<void> {
    await this.throttledWrite(
      "DELETE",
      `/contacts/${encodeURIComponent(contactId)}/segments/${encodeURIComponent(segmentId)}`,
      { redactedLabel: "/contacts/<id>/segments/<segment> (revocation)" },
    );
  }

  // Create a broadcast DRAFT targeted at a segment, scoped to a topic so
  // per-topic opt-outs are honored. `send` is never set (Resend defaults it
  // to false), and there is deliberately no corresponding send method on
  // this client; sending happens in the Resend dashboard after human review.
  async createBroadcastDraft(broadcast: {
    segmentId: string;
    topicId: string;
    from: string;
    subject: string;
    html: string;
    name: string;
    replyTo?: string;
  }): Promise<{ id: string }> {
    return this.throttledWrite<{ id: string }>("POST", "/broadcasts", {
      body: {
        segment_id: broadcast.segmentId,
        topic_id: broadcast.topicId,
        from: broadcast.from,
        subject: broadcast.subject,
        html: broadcast.html,
        name: broadcast.name,
        ...(broadcast.replyTo ? { reply_to: broadcast.replyTo } : {}),
      },
    });
  }

  // One-off transactional send used only by the email:test preview command.
  async sendEmail(email: {
    from: string;
    to: string;
    subject: string;
    html: string;
  }): Promise<{ id: string }> {
    return this.throttledWrite<{ id: string }>("POST", "/emails", {
      redactedLabel: "/emails (test send)",
      body: {
        from: email.from,
        to: [email.to],
        subject: email.subject,
        html: email.html,
      },
    });
  }
}
