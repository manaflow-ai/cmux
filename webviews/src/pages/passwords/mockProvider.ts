// An in-memory `cmux.passwords` provider for the browser dev loop (`/passwords/?mock`) and tests.
// It is not the backend: the app's PasswordsPageProvider owns the gates (gesture, native sheet,
// device owner authentication). The mock keeps the same op contract and stands in for those gates
// with switches, and, like the app, never returns a password.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import {
  PasswordCodes,
  PasswordOps,
  type ChangedEvent,
  type PasswordException,
  type Profile,
  type SavedPasskey,
  type SavedPassword,
  type Sections,
  type StateResult,
} from "./types";

export interface MockData {
  profiles: Profile[];
  sections: Sections;
  passwords: Record<string, SavedPassword[]>;
  passkeys: Record<string, SavedPasskey[]>;
  exceptions: Record<string, PasswordException[]>;
}

export interface MockCall {
  op: string;
  params: Record<string, unknown>;
}

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 1);

export function sampleData(sections: Partial<Sections> = {}): MockData {
  const row = (id: string, site: string, username: string, extra: Partial<SavedPassword> = {}): SavedPassword => ({
    id,
    site,
    url: `https://${site}/`,
    username,
    created: NOW - 90 * DAY,
    last_used: NOW - DAY,
    times_used: 3,
    weak: false,
    reused: false,
    ...extra,
  });
  return {
    profiles: [
      { id: "default", name: "Default" },
      { id: "work", name: "Work" },
    ],
    sections: { passwords: true, passkeys: true, exceptions: true, export: true, ...sections },
    passwords: {
      default: [
        row("p1", "github.com", "octo@example.com", { times_used: 41 }),
        row("p2", "github.com", "octo-work", { reused: true, last_used: NOW - 3 * DAY }),
        row("p3", "example.org", "sample", { weak: true, reused: true, last_used: null, times_used: 0 }),
        row("p4", "news.example.com", "", { last_used: NOW - 10 * DAY, times_used: 1 }),
      ],
      work: [row("w1", "jira.example.com", "me@work.example")],
    },
    passkeys: {
      default: [{ id: "cred-1", rp_id: "webauthn.io", user_name: "sample", user_display_name: "Sample Person" }],
      work: [],
    },
    exceptions: { default: [{ id: "e1", site: "bank.example.com" }], work: [] },
  };
}

/** Sample data with every section the build cannot serve yet, as the app ships before fork API 18. */
export function shippingData(): MockData {
  return sampleData({ passwords: false, exceptions: false, export: false });
}

export class MockPasswordsProvider implements PageClient {
  readonly calls: MockCall[] = [];
  readonly streams = new MockPageStreams();
  /** The person's click or key reached the page (the app's gesture record). */
  gesture = true;
  /** The person's answer to the native confirmation sheet. */
  confirm = true;
  /** Device owner authentication succeeds. */
  authenticate = true;
  /** How many times the native reveal sheet was shown (the mock never returns a password). */
  revealed = 0;
  copied = 0;
  exported = 0;
  private readonly changed = new Set<(data: unknown, seq: number) => void>();
  private seq = 0;
  private revision = 0;
  private readonly replies = new Map<string, unknown>();

  constructor(public data: MockData = sampleData()) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    const p = (params ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params: p });
    const key = typeof p.idempotency_key === "string" ? p.idempotency_key : undefined;
    if (key && this.replies.has(key)) return { ...(this.replies.get(key) as object), replayed: true } as R;
    const value = await this.answer(op, p);
    if (key) this.replies.set(key, value);
    return value as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const page = this.streams.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (page) return page;
    if (stream !== PasswordOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = onEvent as (data: unknown, seq: number) => void;
    this.changed.add(listener);
    return () => void this.changed.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** Another writer changed a profile's store (a save in a browser tab). */
  emitChanged(profile: string): void {
    const event: ChangedEvent = { profile, revision: ++this.revision };
    for (const listener of this.changed) listener(event, ++this.seq);
  }

  private async answer(op: string, p: Record<string, unknown>): Promise<unknown> {
    const profile = typeof p.profile === "string" ? p.profile : "default";
    if (op !== PasswordOps.state && !this.data.profiles.some((known) => known.id === profile)) {
      throw pageError("cmux.protocol.invalid_params", `unknown profile ${profile}`);
    }
    switch (op) {
      case PasswordOps.state:
        return {
          profiles: this.data.profiles,
          profile: this.data.profiles[0]?.id ?? "default",
          sections: this.data.sections,
        } satisfies StateResult;
      case PasswordOps.list:
        this.need("passwords");
        return { passwords: this.data.passwords[profile] ?? [] };
      case PasswordOps.passkeysList:
        this.need("passkeys");
        return { passkeys: this.data.passkeys[profile] ?? [] };
      case PasswordOps.exceptionsList:
        this.need("exceptions");
        return { exceptions: this.data.exceptions[profile] ?? [] };
      case PasswordOps.usernameSet: {
        this.gate();
        this.need("passwords");
        const row = (this.data.passwords[profile] ?? []).find((r) => r.id === p.id);
        if (!row) throw pageError(PasswordCodes.notFound, "This item is no longer saved.");
        row.username = String(p.username ?? "");
        this.emitChanged(profile);
        return {};
      }
      case PasswordOps.remove: {
        this.gate();
        this.need("passwords");
        this.sheet();
        const ids = Array.isArray(p.ids) ? p.ids : [];
        const before = this.data.passwords[profile] ?? [];
        const after = before.filter((r) => !ids.includes(r.id));
        this.data.passwords[profile] = after;
        this.emitChanged(profile);
        return { removed: before.length - after.length };
      }
      case PasswordOps.passkeyRemove:
        this.gate();
        this.need("passkeys");
        this.sheet();
        this.data.passkeys[profile] = (this.data.passkeys[profile] ?? []).filter((r) => r.id !== p.id);
        this.emitChanged(profile);
        return { removed: true };
      case PasswordOps.exceptionRemove:
        this.gate();
        this.need("exceptions");
        this.sheet();
        this.data.exceptions[profile] = (this.data.exceptions[profile] ?? []).filter((r) => r.id !== p.id);
        this.emitChanged(profile);
        return { removed: true };
      case PasswordOps.reveal:
        this.gate();
        this.need("passwords");
        this.auth();
        this.revealed += 1;
        return { shown: true };
      case PasswordOps.copy:
        this.gate();
        this.need("passwords");
        this.auth();
        this.copied += 1;
        return { copied: true };
      case PasswordOps.export:
        this.gate();
        this.need("export");
        this.sheet();
        this.auth();
        this.exported += 1;
        return { exported: (this.data.passwords[profile] ?? []).length };
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  private need(section: keyof Sections): void {
    if (!this.data.sections[section]) throw pageError(PasswordCodes.unavailable, "Available after the next update");
  }

  private gate(): void {
    if (!this.gesture) throw pageError(PasswordCodes.userOnly, "Only you can do this.");
  }

  private sheet(): void {
    if (!this.confirm) throw pageError(PasswordCodes.cancelled, "cancelled");
  }

  private auth(): void {
    if (!this.authenticate) throw pageError(PasswordCodes.authFailed, "cmux could not confirm that it is you.");
  }
}
