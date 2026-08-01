// Minimal Resend REST client for audience/contact/broadcast management.
//
// The transactional welcome email keeps using the official `resend` SDK; this
// client exists because the newsletter tooling needs behaviors the SDK does
// not expose cleanly: explicit pagination with a no-progress guard (so a
// truncated listing fails loudly instead of silently syncing a partial
// audience), injectable fetch for tests, and a clear error when the API key
// is a sending-only restricted key.
//
// Broadcast SENDING is deliberately not implemented. Drafts are created via
// createBroadcast and the actual send stays a human action in the Resend
// dashboard.

export type ResendAudience = {
  id: string;
  name: string;
};

export type ResendContact = {
  id: string;
  email: string;
  first_name?: string | null;
  last_name?: string | null;
  unsubscribed: boolean;
};

export type FetchLike = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
  },
) => Promise<{
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
}>;

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

const API_BASE = "https://api.resend.com";
const PAGE_LIMIT = 100;
// Resend's default rate limit is 2 requests/second; space mutating calls so a
// large first sync does not trip it, and retry 429s with backoff regardless.
const WRITE_SPACING_MS = 600;
const MAX_ATTEMPTS = 5;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

type ListResponse<T> = {
  data?: T[];
  has_more?: boolean;
};

export class ResendClient {
  private readonly apiKey: string;
  private readonly fetchImpl: FetchLike;
  private readonly writeSpacingMs: number;
  private lastWriteAt = 0;

  constructor(options: {
    apiKey: string;
    fetchImpl?: FetchLike;
    writeSpacingMs?: number;
  }) {
    this.apiKey = options.apiKey;
    this.fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
    this.writeSpacingMs = options.writeSpacingMs ?? WRITE_SPACING_MS;
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    for (let attempt = 1; ; attempt += 1) {
      const response = await this.fetchImpl(`${API_BASE}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
      const text = await response.text();
      if (response.status === 429 && attempt < MAX_ATTEMPTS) {
        const retryAfter = Number(response.headers.get("retry-after"));
        const delayMs = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 1000 * attempt;
        await sleep(delayMs);
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
        // Resend returns 401 restricted_api_key when the key can only send
        // emails. Surface the fix instead of a bare 401 so the operator knows
        // this is a dashboard permission change, not a wrong key.
        if (apiError?.name === "restricted_api_key") {
          throw new ResendApiError(
            "The RESEND_API_KEY is restricted to sending emails only. " +
              "Audience, contact, and broadcast management require a key " +
              'with "Full access" permission (Resend dashboard -> API Keys).',
            response.status,
            apiError.name,
          );
        }
        throw new ResendApiError(
          `Resend ${method} ${path} failed with ${response.status}: ${
            apiError?.message ?? text.slice(0, 200)
          }`,
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
    body?: unknown,
  ): Promise<T> {
    const now = Date.now();
    const waitMs = this.lastWriteAt + this.writeSpacingMs - now;
    if (waitMs > 0) {
      await sleep(waitMs);
    }
    this.lastWriteAt = Date.now();
    return this.request<T>(method, path, body);
  }

  // Page through a Resend list endpoint. Resend list responses carry
  // `has_more`; the cursor is the last item's id passed back as `after`. If
  // the API reports more data but a follow-up page makes no progress, throw
  // instead of returning a silently truncated list.
  private async listAll<T extends { id: string }>(path: string): Promise<T[]> {
    const items: T[] = [];
    let after: string | null = null;
    for (;;) {
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
      if (!nextAfter || nextAfter === after) {
        throw new ResendApiError(
          `Resend reported more results for ${path} but pagination made no ` +
            "progress; refusing to continue with a truncated listing.",
          200,
        );
      }
      after = nextAfter;
    }
  }

  async listAudiences(): Promise<ResendAudience[]> {
    return this.listAll<ResendAudience>("/audiences");
  }

  // Resolve an audience by exact name. Zero matches returns null (the caller
  // decides whether to create it); more than one match is ambiguous and
  // always an error, because writing into "whichever came back first" could
  // target the wrong list.
  async findAudienceByName(name: string): Promise<ResendAudience | null> {
    const audiences = await this.listAudiences();
    const matches = audiences.filter((audience) => audience.name === name);
    if (matches.length > 1) {
      throw new ResendApiError(
        `Audience name "${name}" is ambiguous: ${matches.length} audiences ` +
          "share it. Rename or delete the duplicates in the Resend dashboard.",
        200,
      );
    }
    return matches[0] ?? null;
  }

  async createAudience(name: string): Promise<ResendAudience> {
    const created = await this.throttledWrite<{ id: string; name?: string }>(
      "POST",
      "/audiences",
      { name },
    );
    return { id: created.id, name: created.name ?? name };
  }

  async listContacts(audienceId: string): Promise<ResendContact[]> {
    return this.listAll<ResendContact>(
      `/audiences/${encodeURIComponent(audienceId)}/contacts`,
    );
  }

  // Point read used by the purchase-time webhook hook, where listing the
  // whole audience per event would be wasteful. Returns null on 404.
  async getContactByEmail(
    audienceId: string,
    email: string,
  ): Promise<ResendContact | null> {
    try {
      return await this.request<ResendContact>(
        "GET",
        `/audiences/${encodeURIComponent(audienceId)}/contacts/${encodeURIComponent(email)}`,
      );
    } catch (error) {
      if (error instanceof ResendApiError && error.status === 404) {
        return null;
      }
      throw error;
    }
  }

  // Create a contact. `unsubscribed` is intentionally not accepted: new
  // contacts default to subscribed, and no code path may ever write that
  // field (see reconcile.ts invariants).
  async createContact(
    audienceId: string,
    contact: { email: string; firstName?: string; lastName?: string },
  ): Promise<void> {
    await this.throttledWrite(
      "POST",
      `/audiences/${encodeURIComponent(audienceId)}/contacts`,
      {
        email: contact.email,
        ...(contact.firstName ? { first_name: contact.firstName } : {}),
        ...(contact.lastName ? { last_name: contact.lastName } : {}),
      },
    );
  }

  // Backfill missing name fields on an existing, still-subscribed contact.
  // Never sends `unsubscribed`, so it cannot resubscribe anyone.
  async updateContactName(
    audienceId: string,
    contactId: string,
    name: { firstName?: string; lastName?: string },
  ): Promise<void> {
    await this.throttledWrite(
      "PATCH",
      `/audiences/${encodeURIComponent(audienceId)}/contacts/${encodeURIComponent(contactId)}`,
      {
        ...(name.firstName ? { first_name: name.firstName } : {}),
        ...(name.lastName ? { last_name: name.lastName } : {}),
      },
    );
  }

  // Create a broadcast DRAFT tied to an audience. There is deliberately no
  // corresponding send method on this client; sending happens in the Resend
  // dashboard after human review.
  async createBroadcastDraft(broadcast: {
    audienceId: string;
    from: string;
    subject: string;
    html: string;
    name: string;
    replyTo?: string;
  }): Promise<{ id: string }> {
    return this.throttledWrite<{ id: string }>("POST", "/broadcasts", {
      audience_id: broadcast.audienceId,
      from: broadcast.from,
      subject: broadcast.subject,
      html: broadcast.html,
      name: broadcast.name,
      ...(broadcast.replyTo ? { reply_to: broadcast.replyTo } : {}),
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
      from: email.from,
      to: [email.to],
      subject: email.subject,
      html: email.html,
    });
  }
}
