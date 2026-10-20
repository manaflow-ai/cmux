// The Chief editor's calls (ChiefPage.tsx), the same in Home and in Settings: what the person
// changes goes to the Chief owner through the host's page relay (`cmux.chief.profile.*`, the
// person's gesture for create, undo and the gesture fields: personality, instructions, the grant,
// the backend, `locked`), and the backends through the host's harness center
// (`cmux.chief.backend.*`: acpmux's list, add, doctor). A bring-your-own key goes to the host in
// the one add call and to the Keychain from there; the page keeps no copy.
import { isPageError, type PageClient } from "../shared/pageClient";
import { chief as chiefRecord } from "./daemonPeople";
import type {
  HomeChief,
  HomeChiefBackend,
  HomeChiefByoBackend,
  HomeChiefDoctor,
  HomeChiefEngine,
  HomeChiefGrantChange,
  HomeChiefProfile,
  HomeChiefRevision,
} from "./types";

/** What one Save sends: the profile, and only the grant, backend and lock fields that changed. */
export interface ChiefSave {
  profile: HomeChiefProfile;
  grant?: HomeChiefGrantChange;
  engine?: Partial<HomeChiefEngine>;
  locked?: boolean;
  /** A picture to set, null to clear it, undefined for no change. */
  picture: { mediaType: string; data: string } | null | undefined;
}

/** The editor's data source: Home's sheets (HomeSheets) or Settings' Chiefs card. */
export interface ChiefEditorService {
  /** The host relays the person's gesture (create, undo, the gesture fields). */
  readonly grants: boolean;
  /** Makes a Chief; resolves true when it was made. */
  create(save: ChiefSave): Promise<boolean>;
  /** Saves a Chief; resolves true when every part was saved. */
  update(before: HomeChief, save: ChiefSave): Promise<boolean>;
  /** Leaves the editor. */
  close(): void;
  /** The Chief's revisions, newest first. */
  history(chief: string): Promise<HomeChiefRevision[]>;
  /** Makes the record equal to `toRev` (default: the revision before the current one). */
  undo(chief: HomeChief, toRev?: number): Promise<HomeChief | undefined>;
  /** The installed acpmux harnesses with their models. */
  backends(): Promise<HomeChiefBackend[]>;
  /** Adds a backend (the key goes to the Keychain through the host); resolves its harness id. */
  addBackend(backend: HomeChiefByoBackend): Promise<string>;
  /** A real hello turn on the harness (`doctor {id, prompt: true}`). */
  checkBackend(id: string): Promise<HomeChiefDoctor>;
}

const SELECTORS = { machine: "current", session: "current" };

export const describeError = (error: unknown) =>
  isPageError(error) || error instanceof Error ? error.message : String(error);

/** The record fields of a Save that need the person's gesture (sent through the host). */
export function gestureFields(before: HomeChief | undefined, save: ChiefSave): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  if (!before || save.profile.personality !== before.personality) fields.personality = save.profile.personality;
  if (!before || save.profile.instructions !== before.instructions) fields.instructions = save.profile.instructions;
  if (save.grant?.tools) fields.tools = [...save.grant.tools].sort();
  if (save.grant?.harnesses) fields.harnesses = [...save.grant.harnesses].sort();
  if (save.engine) for (const [key, value] of Object.entries(save.engine)) fields[key] = value ?? "";
  if (save.locked !== undefined) fields.locked = save.locked;
  return fields;
}

/** The engine fields that differ from the Chief's (the editor sends only those). */
export function engineChange(before: HomeChief | undefined, engine: HomeChiefEngine): Partial<HomeChiefEngine> {
  const change: Partial<HomeChiefEngine> = {};
  for (const key of ["harness", "model", "effort"] as const)
    if ((before?.[key] ?? "") !== engine[key]) change[key] = engine[key];
  return change;
}

/** The record fields one revision changed against the one before it (oldest has none). */
export const REVISION_FIELDS = [
  "name",
  "role",
  "avatar",
  "personality",
  "instructions",
  "tools",
  "harnesses",
  "engine",
  "selfEdit",
  "locked",
] as const;
export type RevisionField = (typeof REVISION_FIELDS)[number];

export function revisionChanges(revision: HomeChief, previous: HomeChief | undefined): RevisionField[] {
  if (!previous) return [];
  const value = (record: HomeChief, field: RevisionField): string => {
    switch (field) {
      case "engine":
        return [record.harness ?? "", record.model ?? "", record.effort ?? ""].join("/");
      case "tools":
      case "harnesses":
      case "selfEdit":
        return [...record[field]].sort().join();
      case "locked":
        return String(record.locked === true);
      default:
        return record[field] ?? "";
    }
  };
  return REVISION_FIELDS.filter((field) => value(revision, field) !== value(previous, field));
}

/** A `chief.profile.history` answer as revisions, newest first. */
export function parseHistory(answer: unknown): HomeChiefRevision[] {
  const list = (answer as { revisions?: unknown } | undefined)?.revisions;
  if (!Array.isArray(list)) return [];
  return list
    .filter((raw): raw is Record<string, unknown> => typeof raw === "object" && raw !== null)
    .map((raw) => ({
      rev: Number(raw.rev) || 0,
      at: typeof raw.at === "string" ? raw.at : "",
      actor: actorId(raw.actor),
      operation: typeof raw.operation === "string" ? raw.operation : "",
      record: chiefRecord((raw.record ?? {}) as Record<string, unknown>),
    }))
    .sort((a, b) => b.rev - a.rev);
}

/** A revision's actor: a Chief's id when a Chief made it, else empty (the person). */
function actorId(actor: unknown): string {
  if (typeof actor === "string") return /^(owner|user|person|terminal|page)?$/.test(actor) ? "" : actor;
  if (actor && typeof actor === "object") {
    const fields = actor as Record<string, unknown>;
    const id = fields.chief ?? fields.agent ?? (fields.kind === "chief" ? fields.id : undefined);
    return typeof id === "string" ? id : "";
  }
  return "";
}

/** `cmux.chief.backend.list` (`{harnesses: _acpmux/harnesses, models: _acpmux/models}`) as the
 * picker's rows: every chat harness acpmux lists (its default first, then by id), with its probed
 * models and each model's efforts. Terminal harnesses never run a Chief. */
export function parseBackends(answer: unknown): HomeChiefBackend[] {
  const fields = (answer ?? {}) as { harnesses?: unknown; models?: unknown };
  const listed = (fields.harnesses ?? {}) as { harnesses?: unknown; defaultHarness?: unknown };
  const map = (listed.harnesses ?? {}) as Record<string, Record<string, unknown>>;
  const models = new Map<string, HomeChiefBackend["models"]>();
  const probed = (fields.models as { harnesses?: unknown } | undefined)?.harnesses;
  for (const entry of Array.isArray(probed) ? (probed as Record<string, unknown>[]) : []) {
    if (typeof entry.harness !== "string" || !Array.isArray(entry.models)) continue;
    models.set(entry.harness, (entry.models as Record<string, unknown>[]).map(model));
  }
  const ids = Object.keys(map).sort((a, b) =>
    a === listed.defaultHarness ? -1 : b === listed.defaultHarness ? 1 : a < b ? -1 : a > b ? 1 : 0,
  );
  return ids
    .filter((id) => map[id]?.kind !== "terminal")
    .map((id) => {
      const entry = map[id] ?? {};
      const own = Array.isArray(entry.models) ? (entry.models as Record<string, unknown>[]).map(model) : [];
      const name = typeof entry.displayName === "string" && entry.displayName ? entry.displayName : id;
      const unavailable = typeof entry.unavailable === "string" && entry.unavailable ? entry.unavailable : undefined;
      return { id, name, models: own.length > 0 ? own : (models.get(id) ?? []), ...(unavailable ? { unavailable } : {}) };
    });
}

function model(raw: Record<string, unknown>): HomeChiefBackend["models"][number] {
  const id = String(raw.id ?? raw.modelId ?? "");
  const efforts = Array.isArray(raw.efforts) ? raw.efforts.filter((e): e is string => typeof e === "string") : [];
  return { id, name: typeof raw.name === "string" && raw.name ? raw.name : id, efforts };
}

function parseDoctor(answer: unknown): HomeChiefDoctor {
  const fields = (answer ?? {}) as { ok?: unknown; steps?: unknown };
  const steps = Array.isArray(fields.steps)
    ? (fields.steps as Record<string, unknown>[]).map((step) => ({
        name: String(step.name ?? ""),
        ok: step.ok === true,
        ...(typeof step.detail === "string" && step.detail ? { detail: step.detail } : {}),
        ...(typeof step.fix === "string" && step.fix ? { fix: step.fix } : {}),
      }))
    : [];
  return { ok: fields.ok === true, steps };
}

/** The host's Chief calls (the app's page relay and harness center), shared by Home and Settings. */
export class ChiefHost {
  private nextKey = 0;

  constructor(private readonly host: Pick<PageClient, "call">) {}

  key(kind: string): string {
    return `chief-${kind}-${Date.now().toString(36)}-${(this.nextKey++).toString(36)}`;
  }

  /** The Chief records, by the host's relay (Settings has no daemon connection of its own). */
  async list(): Promise<HomeChief[]> {
    const listed = await this.host.call<{ chiefs?: Record<string, unknown>[] }>("cmux.chief.profile.list", SELECTORS);
    return (listed.chiefs ?? []).map(chiefRecord);
  }

  /** The raw list (the Home page checks the relay reaches its own owner). */
  rawList(): Promise<{ chiefs?: Record<string, unknown>[] }> {
    return this.host.call("cmux.chief.profile.list", SELECTORS);
  }

  async picture(chief: string): Promise<{ mediaType: string; data: string } | null> {
    const read = await this.host.call<{ avatar?: Record<string, unknown> | null }>("cmux.chief.profile.avatar.get", {
      ...SELECTORS,
      chief,
    });
    const avatar = read.avatar;
    if (!avatar || typeof avatar.data !== "string") return null;
    return { mediaType: String(avatar.media_type ?? avatar.mediaType ?? "image/png"), data: avatar.data };
  }

  async setPicture(chief: string, picture: { mediaType: string; data: string } | null): Promise<void> {
    await this.host.call("cmux.chief.profile.avatar.set", {
      ...SELECTORS,
      chief,
      ...(picture ? { media_type: picture.mediaType, data: picture.data } : { clear: true }),
      idempotency_key: this.key("picture"),
    });
  }

  async create(fields: Record<string, unknown>): Promise<HomeChief> {
    const made = await this.host.call<{ value: Record<string, unknown> }>("cmux.chief.profile.create", {
      ...SELECTORS,
      ...fields,
      idempotency_key: this.key("create"),
    });
    return chiefRecord(made.value);
  }

  async update(chief: string, fields: Record<string, unknown>): Promise<HomeChief | undefined> {
    const changed = await this.host.call<{ value?: Record<string, unknown> }>("cmux.chief.profile.update", {
      ...SELECTORS,
      chief,
      ...fields,
      idempotency_key: this.key("update"),
    });
    return changed?.value ? chiefRecord(changed.value) : undefined;
  }

  async history(chief: string): Promise<HomeChiefRevision[]> {
    return parseHistory(await this.host.call("cmux.chief.profile.history", { ...SELECTORS, chief, limit: 100 }));
  }

  /** `chief.profile.undo`: back to `toRev`, else the revision before the current one, as a new
   * revision; `expected_rev` refuses it when the record changed since the editor read it. */
  async undo(chief: HomeChief, toRev?: number): Promise<HomeChief | undefined> {
    const changed = await this.host.call<{ value?: Record<string, unknown> }>("cmux.chief.profile.undo", {
      ...SELECTORS,
      chief: chief.id,
      expected_rev: chief.rev,
      ...(toRev !== undefined ? { to_rev: toRev } : {}),
      idempotency_key: this.key("undo"),
    });
    return changed?.value ? chiefRecord(changed.value) : undefined;
  }

  async backends(): Promise<HomeChiefBackend[]> {
    return parseBackends(await this.host.call("cmux.chief.backend.list", {}));
  }

  async addBackend(backend: HomeChiefByoBackend): Promise<string> {
    const added = await this.host.call<{ id?: unknown }>("cmux.chief.backend.add", backend);
    if (typeof added?.id !== "string" || !added.id) throw new Error("the host added no harness");
    return added.id;
  }

  async checkBackend(id: string): Promise<HomeChiefDoctor> {
    return parseDoctor(await this.host.call("cmux.chief.backend.doctor", { id, prompt: true }));
  }
}

/** The Settings Chiefs card's editor service: every call through the host. */
export class HostChiefEditor implements ChiefEditorService {
  readonly grants = true;

  constructor(
    private readonly host: ChiefHost,
    private readonly done: (saved: boolean) => void,
    private readonly fail: (message: string) => void,
  ) {}

  async create(save: ChiefSave): Promise<boolean> {
    try {
      const made = await this.host.create({
        display_name: save.profile.name.trim(),
        role: save.profile.role.trim(),
        ...gestureFields(undefined, save),
      });
      if (save.picture) await this.host.setPicture(made.id, save.picture);
      this.done(true);
      return true;
    } catch (error) {
      this.fail(describeError(error));
      return false;
    }
  }

  async update(before: HomeChief, save: ChiefSave): Promise<boolean> {
    try {
      const fields: Record<string, unknown> = gestureFields(before, save);
      if (save.profile.name.trim() !== before.name) fields.display_name = save.profile.name.trim();
      if (save.profile.role.trim() !== before.role) fields.role = save.profile.role.trim();
      if (Object.keys(fields).length > 0) await this.host.update(before.id, fields);
      if (save.picture !== undefined && (save.picture !== null || before.avatar))
        await this.host.setPicture(before.id, save.picture);
      this.done(true);
      return true;
    } catch (error) {
      this.fail(describeError(error));
      return false;
    }
  }

  close(): void {
    this.done(false);
  }

  history(chief: string): Promise<HomeChiefRevision[]> {
    return this.host.history(chief);
  }

  undo(chief: HomeChief, toRev?: number): Promise<HomeChief | undefined> {
    return this.host.undo(chief, toRev);
  }

  backends(): Promise<HomeChiefBackend[]> {
    return this.host.backends();
  }

  addBackend(backend: HomeChiefByoBackend): Promise<string> {
    return this.host.addBackend(backend);
  }

  checkBackend(id: string): Promise<HomeChiefDoctor> {
    return this.host.checkBackend(id);
  }
}
