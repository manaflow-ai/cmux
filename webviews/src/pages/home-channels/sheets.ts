// The page's sheets (routes.ts) as view state: which route is open, what this connection may do
// (each entry hides when its capability is missing), the Chief records and their pictures. Every
// write goes to the owner through the page's client (`cmux.home.*`); a Chief's grant (tools,
// harnesses) and a delete go through the host instead (`cmux.chief.profile.*` on the host's page
// relay), because the daemon takes them from a page only with the person's click. A plain browser
// has no host: the sheet shows the grant read-only and no Archive.
import { isPageError, type PageClient } from "../shared/pageClient";
import { parseRoute, routeHash, type HomeRoute } from "./routes";
import {
  HomeOps,
  type HomeCapabilities,
  type HomeChief,
  type HomeChiefGrant,
  type HomeChiefProfile,
  type HomeParticipant,
} from "./types";

export interface SheetsSnapshot {
  route?: HomeRoute;
  /** Capabilities and Chiefs were read (until then a route shows nothing, not a refusal). */
  ready: boolean;
  capabilities: HomeCapabilities;
  /** The host relays the person's click for a Chief's grant and delete to the same registry. */
  chiefGrants: boolean;
  /** The Chief records, by id. */
  chiefs: ReadonlyMap<string, HomeChief>;
  /** Chief pictures as data URLs, by Chief id. */
  pictures: ReadonlyMap<string, string>;
}

/** What the sheets need from the page's store. */
export interface SheetsHost {
  /** Reads the inbox again and opens `conversation`. */
  open(conversation: string): Promise<void>;
  /** Shows an owner's refusal on the page. */
  fail(message: string): void;
}

const NONE: HomeCapabilities = { start: false, invite: false, chiefs: false };
const SELECTORS = { machine: "current", session: "current" };

const describe = (error: unknown) => (isPageError(error) || error instanceof Error ? error.message : String(error));

/** A picture file the daemon takes, as base64, or why not. */
export async function readPicture(
  file: File,
): Promise<{ mediaType: string; data: string } | { error: "type" | "size" }> {
  if (!["image/png", "image/jpeg", "image/gif", "image/webp"].includes(file.type)) return { error: "type" };
  if (file.size > 1024 * 1024) return { error: "size" };
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return { mediaType: file.type, data: btoa(binary) };
}

export class HomeSheets {
  private snapshot: SheetsSnapshot = {
    ready: false,
    capabilities: NONE,
    chiefGrants: false,
    chiefs: new Map(),
    pictures: new Map(),
  };
  private readonly listeners = new Set<() => void>();
  private nextKey = 0;
  /** The open route came from the page URL's hash. */
  private fromHash = false;
  /** Picture hashes already read, by Chief id (one read per hash). */
  private readonly pictureHashes = new Map<string, string>();

  constructor(
    private readonly client: PageClient | null,
    private readonly host: PageClient | null,
    private readonly page: SheetsHost,
  ) {}

  getSnapshot = (): SheetsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** Reads what this connection may do, then the Chiefs. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ready: true });
    const capabilities = await this.client
      .call<HomeCapabilities>(HomeOps.capabilities, {})
      .catch(() => NONE);
    this.set({ capabilities });
    if (capabilities.chiefs) await this.loadChiefs();
    this.set({ ready: true });
  }

  /** The route in `hash`, if it names one (true). A hash that leaves a route closes its sheet. */
  follow(hash: string): boolean {
    const route = parseRoute(hash);
    if (route) {
      this.fromHash = true;
      this.set({ route });
    } else if (this.fromHash) {
      this.fromHash = false;
      this.set({ route: undefined });
    }
    return route !== undefined;
  }

  /** Shows a route without the page URL (the gallery, which shares one window). */
  show(route: HomeRoute): void {
    this.set({ route });
  }

  /** Opens a route: the page URL's hash says it, so a reload and the host see the same. */
  open(route: HomeRoute): void {
    const hash = routeHash(route);
    if (typeof window !== "undefined" && window.location.hash !== hash) window.location.hash = hash;
    else this.set({ route });
  }

  close(): void {
    this.fromHash = false;
    this.set({ route: undefined });
    if (typeof window !== "undefined" && parseRoute(window.location.hash))
      window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}#/`);
  }

  async loadChiefs(): Promise<void> {
    if (!this.client) return;
    try {
      const { chiefs } = await this.client.call<{ chiefs: HomeChief[] }>(HomeOps.chiefs, {});
      this.set({ chiefs: new Map(chiefs.map((chief) => [chief.id, chief])) });
      void this.probeHost(chiefs);
      for (const chief of chiefs) void this.loadPicture(chief);
    } catch (error) {
      this.page.fail(describe(error));
    }
  }

  /** The host's page relay reaches the same registry: its list matches this one record for record. */
  private async probeHost(chiefs: readonly HomeChief[]): Promise<void> {
    if (!this.host) return;
    const mark = (list: readonly { id: string; rev: number; createdAt: string }[]) =>
      list
        .map((chief) => `${chief.id}:${chief.rev}:${chief.createdAt}`)
        .sort()
        .join();
    try {
      const listed = await this.host.call<{ chiefs?: Record<string, unknown>[] }>(
        "cmux.chief.profile.list",
        SELECTORS,
      );
      const theirs = (listed.chiefs ?? []).map((raw) => ({
        id: String(raw.id),
        rev: Number(raw.rev) || 0,
        createdAt: String(raw.created_at ?? ""),
      }));
      this.set({ chiefGrants: theirs.length > 0 && mark(theirs) === mark(chiefs) });
    } catch {
      this.set({ chiefGrants: false });
    }
  }

  private async loadPicture(chief: HomeChief): Promise<void> {
    if (!this.client) return;
    if (!chief.avatar) {
      if (this.snapshot.pictures.has(chief.id)) {
        const pictures = new Map(this.snapshot.pictures);
        pictures.delete(chief.id);
        this.pictureHashes.delete(chief.id);
        this.set({ pictures });
      }
      return;
    }
    if (this.pictureHashes.get(chief.id) === chief.avatar) return;
    this.pictureHashes.set(chief.id, chief.avatar);
    try {
      const { avatar } = await this.client.call<{ avatar: { mediaType: string; data: string } | null }>(
        HomeOps.chiefAvatar,
        { chief: chief.id },
      );
      const pictures = new Map(this.snapshot.pictures);
      if (avatar) pictures.set(chief.id, `data:${avatar.mediaType};base64,${avatar.data}`);
      else pictures.delete(chief.id);
      this.set({ pictures });
    } catch {
      this.pictureHashes.delete(chief.id);
    }
  }

  /** Everyone the person may add (people met so far and the Chiefs, not me). */
  async directory(): Promise<HomeParticipant[]> {
    if (!this.client) return [];
    try {
      const { people } = await this.client.call<{ people: HomeParticipant[] }>(HomeOps.directory, {});
      return people;
    } catch (error) {
      this.page.fail(describe(error));
      return [];
    }
  }

  /** A new message: my direct message with one person or Chief, else a new conversation (a channel
   * with a title). Resolves true when it opened. */
  async startConversation(participants: readonly string[], title: string): Promise<boolean> {
    if (!this.client || participants.length === 0) return false;
    try {
      const { conversation } = await this.client.call<{ conversation: string }>(HomeOps.startConversation, {
        participants,
        title,
        idempotencyKey: this.key("start"),
      });
      this.close();
      await this.page.open(conversation);
      return true;
    } catch (error) {
      this.page.fail(describe(error));
      return false;
    }
  }

  async invite(conversation: string, participants: readonly string[]): Promise<boolean> {
    if (!this.client || participants.length === 0) return false;
    try {
      await this.client.call(HomeOps.invite, { conversation, participants, idempotencyKey: this.key("invite") });
      this.close();
      await this.page.open(conversation);
      return true;
    } catch (error) {
      this.page.fail(describe(error));
      return false;
    }
  }

  /** Makes a Chief with this profile (the default grant unless the host takes a changed one), its
   * picture, then opens its direct message. Resolves the Chief, or undefined when the owner refused. */
  async createChief(
    profile: HomeChiefProfile,
    grant: HomeChiefGrant | undefined,
    picture: { mediaType: string; data: string } | undefined,
  ): Promise<HomeChief | undefined> {
    if (!this.client) return undefined;
    try {
      const { chief } = await this.client.call<{ chief: HomeChief }>(HomeOps.chiefCreate, {
        ...profile,
        idempotencyKey: this.key("chief"),
      });
      if (grant && this.snapshot.chiefGrants) await this.setGrant(chief.id, grant);
      if (picture)
        await this.client.call(HomeOps.chiefAvatarSet, {
          chief: chief.id,
          ...picture,
          idempotencyKey: this.key("picture"),
        });
      await this.loadChiefs();
      const { conversation } = await this.client.call<{ conversation: string }>(HomeOps.startConversation, {
        participants: [chief.id],
        title: "",
        idempotencyKey: this.key("dm"),
      });
      this.close();
      await this.page.open(conversation);
      return chief;
    } catch (error) {
      this.page.fail(describe(error));
      return undefined;
    }
  }

  async updateChief(
    id: string,
    profile: HomeChiefProfile,
    grant: HomeChiefGrant | undefined,
    picture: { mediaType: string; data: string } | undefined,
  ): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(HomeOps.chiefUpdate, { chief: id, ...profile, idempotencyKey: this.key("profile") });
      if (grant && this.snapshot.chiefGrants) await this.setGrant(id, grant);
      if (picture)
        await this.client.call(HomeOps.chiefAvatarSet, { chief: id, ...picture, idempotencyKey: this.key("picture") });
      await this.loadChiefs();
      this.close();
      return true;
    } catch (error) {
      this.page.fail(describe(error));
      return false;
    }
  }

  /** Archives a Chief (`chief.profile.delete` through the host: the person's click). */
  async archiveChief(id: string): Promise<boolean> {
    if (!this.host || !this.snapshot.chiefGrants) return false;
    try {
      await this.host.call("cmux.chief.profile.delete", {
        ...SELECTORS,
        chief: id,
        idempotency_key: this.key("archive"),
      });
      await this.loadChiefs();
      this.close();
      return true;
    } catch (error) {
      this.page.fail(describe(error));
      return false;
    }
  }

  private async setGrant(id: string, grant: HomeChiefGrant): Promise<void> {
    await this.host?.call("cmux.chief.profile.update", {
      ...SELECTORS,
      chief: id,
      tools: [...grant.tools].sort(),
      harnesses: [...grant.harnesses].sort(),
      idempotency_key: this.key("grant"),
    });
  }

  private key(kind: string): string {
    return `home-sheets-${kind}-${Date.now().toString(36)}-${(this.nextKey++).toString(36)}`;
  }

  private set(patch: Partial<SheetsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}
