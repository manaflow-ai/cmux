// The page's sheets (routes.ts) as view state: which route is open, what this connection may do
// (each entry hides when its capability is missing), the Chief records and their pictures. Writes
// go to the owner through the page's client (`cmux.home.*`), except what the daemon takes from a
// page only with the person's click: creating or archiving a Chief and changing its instructions,
// personality or grant go through the host (`cmux.chief.profile.*` on the host's page relay). A
// plain browser has no host: those show read-only ("Do this in the cmux app"), no Archive.
import { isPageError, type PageClient } from "../shared/pageClient";
import { ChiefHost, gestureFields, type ChiefEditorService, type ChiefSave } from "./chiefEditing";
import { parseRoute, routeHash, type HomeRoute } from "./routes";
import {
  chiefBackend,
  DEFAULT_CHIEF_BACKEND,
  HomeOps,
  type HomeCapabilities,
  type HomeChief,
  type HomeParticipant,
} from "./types";

export interface SheetsSnapshot {
  route?: HomeRoute;
  /** Capabilities and Chiefs were read (until then a route shows nothing, not a refusal). */
  ready: boolean;
  capabilities: HomeCapabilities;
  /** The host relays the person's click to the same registry (create, delete, instructions,
   * personality, the grant). */
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
  /** The host's Chief calls (the page relay and the harness center), when there is a host. */
  private readonly chiefHost: ChiefHost | null;
  private editorService?: { grants: boolean; service: ChiefEditorService };

  constructor(
    private readonly client: PageClient | null,
    private readonly host: PageClient | null,
    private readonly page: SheetsHost,
  ) {
    this.chiefHost = host ? new ChiefHost(host) : null;
  }

  getSnapshot = (): SheetsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** Reads what this connection may do, then the Chiefs. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ready: true });
    const capabilities = await this.client.call<HomeCapabilities>(HomeOps.capabilities, {}).catch(() => NONE);
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
      this.back = "#/";
      this.set({ route: undefined });
    }
    return route !== undefined;
  }

  /** Shows a route without the page URL (the gallery, which shares one window). */
  show(route: HomeRoute): void {
    this.set({ route });
  }

  /** Where the page goes when the open sheet closes: the hash it was opened from. */
  private back = "#/";

  /** Opens a route: the page URL's hash says it, so a reload and the host see the same. */
  open(route: HomeRoute): void {
    const hash = routeHash(route);
    // Back to the conversation the sheet opened over (never a message link: that would open it again).
    if (typeof window !== "undefined" && !parseRoute(window.location.hash))
      this.back = /^#\/conversation\/[A-Za-z0-9_]+/.exec(window.location.hash)?.[0] ?? "#/";
    if (typeof window !== "undefined" && window.location.hash !== hash) window.location.hash = hash;
    else this.set({ route });
  }

  close(): void {
    this.fromHash = false;
    this.set({ route: undefined });
    const back = this.back;
    this.back = "#/";
    if (typeof window !== "undefined" && parseRoute(window.location.hash)) {
      window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}${back}`);
      // The page's panes follow the hash (panes.ts); a replaced hash fires no event of its own.
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    }
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
      const listed = await this.chiefHost!.rawList();
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

  /** The Chief editor's service on this page (ChiefPage.tsx): the same object while the host's
   * relay stays as it is, so the editor's reads (backends, history) run once. */
  chiefEditor(): ChiefEditorService {
    const grants = this.snapshot.chiefGrants;
    if (this.editorService?.grants === grants) return this.editorService.service;
    const host = this.chiefHost;
    const none = () => Promise.reject(new Error("no host"));
    const service: ChiefEditorService = {
      grants,
      create: (save) => this.createChief(save).then(Boolean),
      update: (before, save) => this.updateChief(before, save),
      close: () => this.close(),
      history: (chief) => (host ? host.history(chief) : none()),
      undo: async (chief, toRev) => {
        if (!host || !this.snapshot.chiefGrants) return undefined;
        const record = await host.undo(chief, toRev);
        await this.loadChiefs();
        return record ?? this.snapshot.chiefs.get(chief.id);
      },
      backends: () => (host ? host.backends() : none()),
      addBackend: (backend) => (host ? host.addBackend(backend) : none()),
      checkBackend: (id) => (host ? host.checkBackend(id) : none()),
    };
    this.editorService = { grants, service };
    return service;
  }

  /** Makes a Chief through the host (the person's click: create is never the page's alone) with
   * this profile and, when given, a changed grant, backend and lock, in one request; then its
   * picture and its direct message from the page. Resolves the Chief, or undefined when refused. */
  async createChief(save: ChiefSave): Promise<HomeChief | undefined> {
    if (!this.client || !this.chiefHost || !this.snapshot.chiefGrants) return undefined;
    const fields = gestureFields(undefined, save);
    // The default engine alone is not named: the owner applies its own (as `cmux chief new`).
    if (typeof fields.harness === "string" && chiefBackend(fields.harness) === DEFAULT_CHIEF_BACKEND && !fields.model)
      delete fields.harness;
    try {
      const chief = await this.chiefHost.create({
        display_name: save.profile.name.trim(),
        role: save.profile.role.trim(),
        ...fields,
      });
      if (save.picture)
        await this.client.call(HomeOps.chiefAvatarSet, {
          chief: chief.id,
          ...save.picture,
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

  /** Saves a Chief's profile: what changed of personality, instructions, the grant, the backend
   * and the lock goes first, through the host (the person's click, one request); the name, role
   * and picture from the page. `picture` null clears it: the default shows again. */
  async updateChief(before: HomeChief, save: ChiefSave): Promise<boolean> {
    if (!this.client) return false;
    const { profile, picture } = save;
    const taught = gestureFields(before, save);
    try {
      if (Object.keys(taught).length > 0) {
        if (!this.chiefHost || !this.snapshot.chiefGrants) return false;
        await this.chiefHost.update(before.id, taught);
      }
      if (profile.name.trim() !== before.name || profile.role.trim() !== before.role)
        await this.client.call(HomeOps.chiefUpdate, {
          chief: before.id,
          name: profile.name,
          role: profile.role,
          idempotencyKey: this.key("profile"),
        });
      if (picture !== undefined && (picture !== null || before.avatar))
        await this.client.call(HomeOps.chiefAvatarSet, {
          chief: before.id,
          ...(picture ?? { clear: true }),
          idempotencyKey: this.key("picture"),
        });
      await this.loadChiefs();
      this.close();
      return true;
    } catch (error) {
      this.page.fail(describe(error));
      return false;
    }
  }

  /** Deletes a Chief for good (`chief.profile.delete` through the host: the person's click). */
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

  private key(kind: string): string {
    return `home-sheets-${kind}-${Date.now().toString(36)}-${(this.nextKey++).toString(36)}`;
  }

  private set(patch: Partial<SheetsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}
