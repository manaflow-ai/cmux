// An in-memory `cmux.coderouter` provider for the browser dev loop (`/coderouter/?mock`) and tests.
// It is not the backend: the Mac host's accounts service owns detection, sign-in and CodeRouter.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { LINK_CLOSED, MockPageStreams } from "../shared/pageStreams";
import { CodeRouterActions, CodeRouterOps, type CodeRouterStatus, type ProviderRow } from "./types";

export interface MockCall {
  op: string;
  params: Record<string, unknown>;
}

export class MockCodeRouterProvider implements PageClient {
  readonly calls: MockCall[] = [];
  readonly page = new MockPageStreams();
  offline = false;
  signedIn: boolean;
  providers: ProviderRow[];

  constructor({ signedIn = true }: { signedIn?: boolean } = {}) {
    this.signedIn = signedIn;
    this.providers = sampleProviders(signedIn);
  }

  async call<R>(op: string, rawParams: unknown): Promise<R> {
    const params = (rawParams ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params });
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    switch (op) {
      case CodeRouterOps.status: {
        const status: CodeRouterStatus = this.signedIn
          ? { signed_in: true, scope: "personal", health: "ok" }
          : { signed_in: false, scope: null, health: "signed_out" };
        return status as R;
      }
      case CodeRouterOps.detect:
        return { providers: this.providers } as R;
      case CodeRouterOps.actionRun: {
        const action = String(params.action ?? "");
        if (action === CodeRouterActions.signIn) {
          this.signedIn = true;
          this.providers = sampleProviders(true);
        }
        return { ran: true } as R;
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    throw pageError("cmux.protocol.unknown_op", stream);
  }

  /** The host calls nothing on this page. */
  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }
}

/** Providers on a sample Mac: Codex signed in (linked when signed in to cmux), Claude expired. */
export function sampleProviders(signedIn: boolean): ProviderRow[] {
  return [
    {
      provider: "codex",
      name: "ChatGPT / Codex",
      status: "signed_in",
      account: "acct_codex1",
      label: "Pro",
      plan: "Pro",
      phase: "idle",
      can_connect: signedIn,
      linkable: true,
      linked: signedIn
        ? [{ id: "a1", account: "acct_codex1", label: "Pro", state: "active", visibility: "private" }]
        : [],
    },
    {
      provider: "claude",
      name: "Claude Code",
      status: "expired",
      account: "acct_claude1",
      label: "M…@e…",
      plan: "Max",
      phase: "idle",
      can_connect: false,
      linkable: true,
      linked: [],
    },
    {
      provider: "gemini",
      name: "Gemini",
      status: "missing",
      account: null,
      label: null,
      plan: null,
      phase: "idle",
      can_connect: false,
      linkable: false,
      linked: [],
    },
  ];
}
