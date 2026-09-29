// Offline golden generator for the ChatGPT / Codex browser-use AX text
// (`tab.ax.get()` / `tab.ax.write()`).
//
// It drives headless Google Chrome through Playwright on a throwaway profile,
// rebuilds the accessibility snapshot JSON that the browser-use service feeds
// its renderer (clean-room reimplementation, see
// docs/browser-repl/chatgpt-ax-spec.md), and renders it with the renderer
// WebAssembly that ships in the user's installed Codex Chrome plugin. The WASM
// is read from the plugin at runtime and is never copied into this repo.
//
// CLI:
//   node chatgpt-ax-reference.mjs <url-or-fixture-path> [--full] [--tab-id N]
//        [--then '<js evaluated in page>' ...] [--click 'css' ...]
//   A path that starts with "/" is served from tests/browser-parity/fixtures.
//   Every --then/--click step is followed by another capture (diff mode unless
//   --full), so the output shows the revision diff format.
//   --json prints the snapshot input JSON instead of rendered text.
//
// Module:
//   const core = await loadChatGPTAccessibilityCore();
//   const ref = new ChatGPTAxReference(page, core, { tabId: 1 });
//   const text = await ref.state({ disableDiffing: false });
//
// Env: CHATGPT_AX_WASM (path to browser-accessibility.wasm[.br]),
//      PARITY_PLAYWRIGHT_DIR (directory that contains node_modules/playwright).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { WASI } from "node:wasi";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// WASM renderer
// ---------------------------------------------------------------------------

export function defaultWasmPath() {
  if (process.env.CHATGPT_AX_WASM) return process.env.CHATGPT_AX_WASM;
  return path.join(
    os.homedir(),
    ".codex/plugins/cache/openai-bundled/chrome/latest/scripts/browser-accessibility.wasm.br",
  );
}

const REQUIRED_EXPORTS = [
  "memory",
  "computer_use_browser_wasm_allocate",
  "computer_use_browser_wasm_deallocate",
  "computer_use_browser_wasm_revision_create",
  "computer_use_browser_wasm_revision_release",
  "computer_use_browser_wasm_revision_text_length",
  "computer_use_browser_wasm_revision_copy_text",
  "computer_use_browser_wasm_revision_identity_length",
  "computer_use_browser_wasm_revision_copy_identity",
  "computer_use_browser_wasm_revision_is_value_settable",
];

const CREATE_ERRORS = {
  1: "Invalid accessibility revision arguments",
  2: "Invalid accessibility snapshot",
  5: "Previous accessibility revision belongs to another document",
};

/**
 * Loads the renderer. `env` is passed to the WASI environment; the renderer
 * reads TINYSKY_AX_TREE_DIFF_MIN_SAVED_RATIO / _BYTES from it (defaults
 * 0.3 and 1000).
 */
export async function loadChatGPTAccessibilityCore({ wasmPath = defaultWasmPath(), env = {}, deterministic = true } = {}) {
  // The renderer is Swift; its Dictionary/Set order is seeded from WASI
  // random_get. The URL shortener's truncation choice depends on that order,
  // so production output can vary between runs. Deterministic hashing makes
  // goldens reproducible.
  if (deterministic) env = { SWIFT_DETERMINISTIC_HASHING: "1", ...env };
  const raw = fs.readFileSync(wasmPath);
  const bytes = wasmPath.endsWith(".br") ? zlib.brotliDecompressSync(raw) : raw;
  const wasi = new WASI({ version: "preview1", env, stdout: 2, stderr: 2 });
  const { instance } = await WebAssembly.instantiate(bytes, wasi.getImportObject());
  wasi.initialize(instance);
  const x = instance.exports;
  for (const name of REQUIRED_EXPORTS) if (x[name] == null) throw new Error(`missing export ${name}`);
  const enc = new TextEncoder();
  const dec = new TextDecoder("utf-8", { fatal: true });
  const alloc = (n) => {
    const p = x.computer_use_browser_wasm_allocate(n) >>> 0;
    if (p === 0) throw new Error("wasm allocation failed");
    return p;
  };
  const readString = (len, copy) => {
    if (len < 0) throw new Error("Could not read accessibility text");
    if (len === 0) return "";
    const p = alloc(len);
    try {
      if (copy(p, len) !== len) throw new Error("Could not copy accessibility text");
      return dec.decode(new Uint8Array(x.memory.buffer, p, len));
    } finally {
      x.computer_use_browser_wasm_deallocate(p);
    }
  };
  const registry = new FinalizationRegistry((ptr) => x.computer_use_browser_wasm_revision_release(ptr));

  class Revision {
    constructor(ptr) {
      this.ptr = ptr;
      registry.register(this, ptr);
    }
    get text() {
      const len = x.computer_use_browser_wasm_revision_text_length(this.ptr);
      return readString(len, (p, n) => x.computer_use_browser_wasm_revision_copy_text(this.ptr, p, n));
    }
    /** Identity string (Nw key) of the element shown as `id`, or undefined. */
    identityForElement(id) {
      const len = x.computer_use_browser_wasm_revision_identity_length(this.ptr, id);
      if (len < 0) return undefined;
      return readString(len, (p, n) => x.computer_use_browser_wasm_revision_copy_identity(this.ptr, id, p, n));
    }
    isValueSettableForElement(id) {
      const r = x.computer_use_browser_wasm_revision_is_value_settable(this.ptr, id);
      return r < 0 ? undefined : r === 1;
    }
  }

  return {
    /** mode: "auto" (diff against previous when shorter) or "full". */
    buildRevision(previous, snapshot, { mode = "auto" } = {}) {
      const json = enc.encode(JSON.stringify(snapshot));
      const buf = alloc(json.byteLength);
      const out = alloc(4);
      try {
        new Uint8Array(x.memory.buffer, buf, json.byteLength).set(json);
        new DataView(x.memory.buffer).setUint32(out, 0, true);
        const code = x.computer_use_browser_wasm_revision_create(
          previous?.ptr ?? 0,
          buf,
          json.byteLength,
          mode === "full" ? 1 : 0,
          out,
        );
        const ptr = new DataView(x.memory.buffer).getUint32(out, true);
        if (code !== 0 || ptr === 0) {
          if (ptr !== 0) x.computer_use_browser_wasm_revision_release(ptr);
          throw new Error(CREATE_ERRORS[code] ?? `Could not create accessibility revision: ${code}`);
        }
        return new Revision(ptr);
      } finally {
        x.computer_use_browser_wasm_deallocate(out);
        x.computer_use_browser_wasm_deallocate(buf);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Snapshot construction (clean-room, mirrors the service's observable shape)
// ---------------------------------------------------------------------------

// CDP AX properties that are forwarded to the renderer.
const FORWARDED_PROPERTIES = new Set([
  "atomic", "autocomplete", "busy", "checked", "controls", "describedby", "details", "disabled",
  "editable", "errormessage", "expanded", "flowto", "focusable", "focused", "hasPopup", "invalid",
  "keyshortcuts", "labelledby", "level", "live", "modal", "multiline", "multiselectable",
  "orientation", "placeholder", "pressed", "radiogroup", "relevant", "required", "roledescription",
  "selected", "settable", "url", "valuemax", "valuemin", "valuetext",
]);
// DOM attributes kept in node.dom.
const KEPT_ATTRIBUTES = new Set(["id", "class", "role", "aria-description"]);
// DOM attributes inspected for the credential heuristic.
const CREDENTIAL_HINT_ATTRIBUTES = new Set(["type", "autocomplete", "id", "name", "placeholder", "aria-label", "title"]);
const CREDENTIAL_PATTERN =
  /user[-_ ]?name|e[-_ ]?mail|one[-_ ]?time[-_ ]?code|password|passcode|passwd|\botp\b|\b(?:2fa|mfa)\b|phone|mobile|\btel\b/i;

const str = (strings, i) => (i == null ? undefined : strings[i]) ?? "";
const axValue = (v) => v?.value ?? null;

/** DOMSnapshot -> Map<backendNodeId, {tagName, attributes, credential, closedShadow, bounds}> */
function domMetadata(snapshot, axBackendIds) {
  const out = new Map();
  for (const doc of snapshot.documents) {
    const backendIds = doc.nodes.backendNodeId ?? [];
    const names = doc.nodes.nodeName ?? [];
    const attrs = doc.nodes.attributes ?? [];
    const parents = doc.nodes.parentIndex ?? [];
    const bounds = new Map();
    const closed = new Map();
    const shadowType = new Map();
    const srt = doc.nodes.shadowRootType;
    for (const [k, nodeIndex] of (srt?.index ?? []).entries()) {
      const mode = str(snapshot.strings, srt.value[k]);
      shadowType.set(nodeIndex, mode);
      if (mode === "closed") closed.set(nodeIndex, "inside");
    }
    if (closed.size > 0) {
      // Track the shadow-root scope of every node; slots re-enter the host scope.
      const scope = [];
      for (let i = 0; i < backendIds.length; i++) {
        const parent = parents[i];
        const mode = shadowType.get(i);
        let s = parent == null ? undefined : scope[parent];
        if (mode != null && mode !== s?.mode) {
          const parentName = str(snapshot.strings, parent == null ? undefined : names[parent]);
          s = parentName.split(":").at(-1)?.toLowerCase() === "slot"
            ? s?.parent
            : { mode, parent: s, insideClosedRoot: mode === "closed" || s?.insideClosedRoot === true };
        }
        scope[i] = s;
        if (s?.insideClosedRoot) closed.set(i, "inside");
      }
      for (let i = backendIds.length - 1; i >= 0; i--) {
        const parent = parents[i];
        if (closed.has(i) && parent != null && parent >= 0 && !closed.has(parent)) closed.set(parent, "ancestor");
      }
    }
    for (let k = 0; k < doc.layout.nodeIndex.length; k++) {
      const nodeIndex = doc.layout.nodeIndex[k];
      const backend = backendIds[nodeIndex];
      if (backend == null || !axBackendIds.has(backend)) continue;
      const b = doc.layout.bounds[k];
      if (b == null || b.length < 4) continue;
      bounds.set(nodeIndex, [b[0] - (doc.scrollOffsetX ?? 0), b[1] - (doc.scrollOffsetY ?? 0), b[2], b[3]]);
    }
    for (let i = 0; i < backendIds.length; i++) {
      const backend = backendIds[i];
      if (backend == null || (!axBackendIds.has(backend) && !closed.has(i))) continue;
      const attributes = {};
      const hints = [];
      const a = attrs[i] ?? [];
      for (let j = 0; j < a.length; j += 2) {
        const key = str(snapshot.strings, a[j]);
        const value = str(snapshot.strings, a[j + 1]);
        const lower = key.toLowerCase();
        if (KEPT_ATTRIBUTES.has(lower)) attributes[key] = value;
        if (CREDENTIAL_HINT_ATTRIBUTES.has(lower)) hints.push(value);
      }
      const tagName = str(snapshot.strings, names[i]).toLowerCase();
      out.set(backend, {
        tagName,
        attributes,
        credential: tagName === "input" && CREDENTIAL_PATTERN.test(hints.join(" ")),
        closedShadow: closed.get(i),
        bounds: bounds.get(i),
      });
    }
  }
  return out;
}

function nameSourceOf(name) {
  const sources = name?.sources;
  const src =
    sources?.find((s) => s.superseded !== true && (s.value != null || s.attributeValue != null)) ??
    sources?.find((s) => s.superseded !== true);
  if (src == null) return null;
  switch (src.type) {
    case "contents":
    case "placeholder":
    case "relatedElement":
      return src.type;
    case "attribute":
      return src.attribute === "placeholder" ? "placeholder" : src.attribute === "value" ? "value" : "attribute";
    default:
      return null;
  }
}

function referencesHidden(value, hidden) {
  if (hidden.size === 0) return false;
  return (
    value?.relatedNodes?.some((r) => hidden.has(r.backendDOMNodeId)) === true ||
    value?.sources?.some(
      (s) => s.superseded !== true && [s.value, s.attributeValue, s.nativeSourceValue].some((v) => referencesHidden(v, hidden)),
    ) === true
  );
}

function forwardedProperties(node, indexByBackend, hidden) {
  const out = {};
  for (const p of node.properties ?? []) {
    if (!FORWARDED_PROPERTIES.has(p.name) || referencesHidden(p.value, hidden)) continue;
    const value = axValue(p.value);
    const relatedNodes = [];
    for (const r of p.value.relatedNodes ?? []) {
      const targetIndex = indexByBackend.get(r.backendDOMNodeId) ?? -1;
      if (targetIndex < 0 && r.text == null && r.idref == null) continue;
      relatedNodes.push({ targetIndex, text: r.text ?? null, idref: r.idref ?? null });
    }
    if (value != null || relatedNodes.length > 0) out[p.name] = { value, relatedNodes };
  }
  return out;
}

function domSummary(meta, redacted) {
  if (meta == null) return null;
  return {
    bounds: meta.bounds ?? null,
    identifier: (redacted ? undefined : meta.attributes.id) ?? null,
    className: (redacted ? undefined : meta.attributes.class) ?? null,
    declaredRole: (redacted ? undefined : meta.attributes.role) ?? null,
    hasAriaDescription: !redacted && Object.hasOwn(meta.attributes, "aria-description") ? true : null,
    tagName: !redacted && ["input", "select", "textarea"].includes(meta.tagName) ? meta.tagName : null,
  };
}

/** One frame's CDP AX nodes -> flat snapshot nodes (parentIndex local to the frame). */
function frameNodes(frame) {
  const byId = new Map(frame.nodes.map((n) => [n.nodeId, n]));
  const parentOf = new Map();
  const closedInside = new Set();
  const closedAncestors = new Set();
  const hidden = new Set([...frame.metadata].filter(([, m]) => m.closedShadow != null).map(([id]) => id));
  if (hidden.size > 0) {
    const cdpParent = new Map(frame.nodes.flatMap((n) => (n.childIds ?? []).map((c) => [c, n])));
    const stack = frame.nodes.filter((n) => n.backendDOMNodeId != null && frame.metadata.get(n.backendDOMNodeId)?.closedShadow === "inside");
    while (stack.length > 0) {
      const n = stack.pop();
      if (n == null || closedInside.has(n.nodeId)) continue;
      const m = n.backendDOMNodeId == null ? undefined : frame.metadata.get(n.backendDOMNodeId);
      if (m != null && m.closedShadow !== "inside") continue;
      closedInside.add(n.nodeId);
      if (n.backendDOMNodeId != null) hidden.add(n.backendDOMNodeId);
      for (const c of n.childIds ?? []) if (byId.has(c)) stack.push(byId.get(c));
    }
    for (const id of closedInside) {
      let p = cdpParent.get(id);
      while (p != null && !closedAncestors.has(p.nodeId)) {
        closedAncestors.add(p.nodeId);
        if (p.backendDOMNodeId != null) hidden.add(p.backendDOMNodeId);
        p = cdpParent.get(p.nodeId);
      }
    }
  }
  const text = hidden.size === 0 ? axValue : (v) => (referencesHidden(v, hidden) ? null : axValue(v));
  // Ignored nodes are dropped; their non-ignored descendants reattach to the
  // nearest non-ignored ancestor.
  const kept = frame.nodes.filter((n) => !n.ignored && !closedInside.has(n.nodeId));
  for (const n of kept) {
    const stack = [...(n.childIds ?? [])];
    const seen = new Set();
    while (stack.length > 0) {
      const id = stack.pop();
      if (id == null || seen.has(id)) continue;
      seen.add(id);
      const c = byId.get(id);
      if (c == null) continue;
      if (!c.ignored && !closedInside.has(id)) parentOf.set(id, n.nodeId);
      else for (const g of c.childIds ?? []) stack.push(g);
    }
  }
  const indexOf = new Map(kept.map((n, i) => [n.nodeId, i]));
  const indexByBackend = new Map(kept.filter((n) => n.backendDOMNodeId != null).map((n) => [n.backendDOMNodeId, indexOf.get(n.nodeId)]));
  // Nodes whose descendants are redacted.
  const sensitive = new Set(
    kept
      .filter((n) => {
        if (n.backendDOMNodeId == null) return false;
        const m = frame.metadata.get(n.backendDOMNodeId);
        if (m != null) return m.credential;
        if (axValue(n.role) !== "MenuListPopup") return true;
        const pid = parentOf.get(n.nodeId);
        const parent = pid == null ? undefined : byId.get(pid);
        const pm = parent?.backendDOMNodeId == null ? undefined : frame.metadata.get(parent.backendDOMNodeId);
        return pm?.tagName !== "select" || pm.credential !== false;
      })
      .map((n) => n.nodeId),
  );
  return kept.map((n) => {
    const parent = parentOf.get(n.nodeId);
    const meta = n.backendDOMNodeId == null ? undefined : frame.metadata.get(n.backendDOMNodeId);
    const credential = n.backendDOMNodeId != null && (meta?.credential ?? true);
    let insideSensitive = false;
    for (let p = parent; p != null; p = parentOf.get(p)) {
      if (sensitive.has(p)) {
        insideSensitive = true;
        break;
      }
    }
    const value = axValue(n.value);
    const nameSource = nameSourceOf(n.name);
    const dropName =
      ((meta?.closedShadow === "ancestor" || closedAncestors.has(n.nodeId)) && nameSource === "contents") ||
      insideSensitive ||
      (credential && (nameSource === "value" || axValue(n.name) === value));
    const properties = forwardedProperties(n, indexByBackend, hidden);
    const redacted = credential || insideSensitive;
    if (redacted) delete properties.valuetext;
    return {
      parentIndex: (parent == null ? undefined : indexOf.get(parent)) ?? -1,
      nodeID: `${frame.targetId}:${frame.frameId}:${n.nodeId}`,
      role: axValue(n.role),
      chromeRole: axValue(n.chromeRole),
      name: dropName ? null : text(n.name),
      nameSource,
      description: redacted ? null : text(n.description),
      value: redacted ? null : text(n.value),
      properties,
      dom: domSummary(meta, redacted),
      backendDOMNodeID: n.backendDOMNodeId ?? null,
      targetID: frame.actionTargetId,
    };
  });
}

/** Concatenate frames (parents first); a child frame's root hangs under its owner element. */
function stitchFrames(frames, warnings) {
  const out = [];
  const indexByOwner = new Map();
  for (const f of frames) {
    let rootParent = -1;
    if (f.parentFrameId != null) {
      const parent = frames.find((p) => p.frameId === f.parentFrameId);
      rootParent = parent == null || f.ownerBackendNodeId == null ? -1 : indexByOwner.get(`${parent.targetId}:${f.ownerBackendNodeId}`) ?? -1;
      if (rootParent < 0) {
        warnings.push(`Iframe ${f.frameId} owner was not present in the accessibility tree`);
        continue;
      }
    }
    const base = out.length;
    for (const n of frameNodes(f)) {
      const properties = Object.fromEntries(
        Object.entries(n.properties).map(([k, v]) => [
          k,
          { ...v, relatedNodes: v.relatedNodes.map((r) => ({ ...r, targetIndex: r.targetIndex < 0 ? r.targetIndex : r.targetIndex + base })) },
        ]),
      );
      out.push({ ...n, parentIndex: n.parentIndex >= 0 ? n.parentIndex + base : rootParent, properties });
      if (n.backendDOMNodeID != null) indexByOwner.set(`${f.targetId}:${n.backendDOMNodeID}`, out.length - 1);
    }
  }
  return out;
}

/** Nodes for an open JavaScript dialog (the page's AX tree is replaced). */
export function javaScriptDialogNodes({ id, type, message, url, defaultPrompt = "", pageTitle }) {
  const prop = (value) => ({ value, relatedNodes: [] });
  const node = (parentIndex, key, role, name, extra = {}) => ({
    parentIndex,
    nodeID: `javascript-dialog:${id}:${key}`,
    role,
    chromeRole: null,
    name,
    nameSource: "attribute",
    description: null,
    value: null,
    properties: {},
    dom: { bounds: null, identifier: null, className: null, declaredRole: role, hasAriaDescription: null, tagName: null },
    backendDOMNodeID: null,
    targetID: null,
    ...extra,
  });
  const host = URL.canParse(url) ? new URL(url).host : "";
  const nodes = [
    node(-1, "root", "RootWebArea", pageTitle ?? "Web page"),
    node(0, "dialog", "alertdialog", host ? `${host} says` : "This page says", { properties: { modal: prop(true) } }),
    node(1, "message", "StaticText", message),
  ];
  if (type === "prompt")
    nodes.push(
      node(1, "prompt", "textbox", "Response", {
        value: defaultPrompt,
        properties: { editable: prop("plaintext"), focusable: prop(true), focused: prop(true), settable: prop(true) },
        dialogTarget: { dialogID: id, control: "prompt" },
      }),
    );
  if (type !== "alert")
    nodes.push(
      node(1, "dismiss", "button", type === "beforeunload" ? "Stay" : "Cancel", {
        properties: { focusable: prop(true) },
        dialogTarget: { dialogID: id, control: "dismiss" },
      }),
    );
  nodes.push(
    node(1, "accept", "button", type === "beforeunload" ? "Leave" : "OK", {
      properties: { focusable: prop(true), focused: prop(type !== "prompt") },
      dialogTarget: { dialogID: id, control: "accept" },
    }),
  );
  return nodes;
}

const SNAPSHOT_PARAMS = { computedStyles: [], includePaintOrder: false, includeDOMRects: false };

export class ChatGPTAxReference {
  constructor(page, core, { tabId = 1 } = {}) {
    this.page = page;
    this.core = core;
    // The renderer requires a numeric tab id (a Chrome extension tab id).
    this.tabId = Number(tabId);
    this.revision = undefined;
  }

  async #mainSession() {
    if (this.main == null) {
      this.main = await this.page.context().newCDPSession(this.page);
      await this.main.send("Accessibility.enable");
    }
    return this.main;
  }

  /** Discover every debugger session (main + out-of-process iframes). */
  async #sessions(warnings) {
    const main = await this.#mainSession();
    const { frameTree } = await main.send("Page.getFrameTree");
    const sessions = [{ session: main, targetId: `tab:${this.tabId}`, actionTargetId: null, frameTree, dom: await main.send("DOMSnapshot.captureSnapshot", SNAPSHOT_PARAMS) }];
    // Out-of-process frames get their own CDP session in Playwright.
    const oopif = new Map();
    for (const frame of this.page.frames()) {
      if (frame === this.page.mainFrame()) continue;
      try {
        const s = await this.page.context().newCDPSession(frame);
        const { frameTree: ft } = await s.send("Page.getFrameTree");
        oopif.set(ft.frame.id, { session: s, frameTree: ft });
      } catch {
        // In-process frame: covered by its parent's session.
      }
    }
    const seen = new Set([frameTree.frame.id]);
    for (const entry of sessions) {
      for (const doc of entry.dom.documents) {
        const docFrame = str(entry.dom.strings, doc.frameId) || entry.frameTree.frame.id;
        const withContent = new Set(doc.nodes.contentDocumentIndex?.index ?? []);
        const names = doc.nodes.nodeName ?? [];
        for (let i = 0; i < names.length; i++) {
          const name = str(entry.dom.strings, names[i]);
          if ((name !== "IFRAME" && name !== "FRAME") || withContent.has(i)) continue;
          const backendNodeId = doc.nodes.backendNodeId?.[i];
          if (backendNodeId == null) continue;
          let frameId;
          try {
            ({ node: { frameId } } = await entry.session.send("DOM.describeNode", { backendNodeId }));
            if (frameId == null || seen.has(frameId)) continue;
            const child = oopif.get(frameId);
            if (child == null) throw new Error("Debugger target is unavailable");
            await child.session.send("Accessibility.enable");
            const dom = await child.session.send("DOMSnapshot.captureSnapshot", SNAPSHOT_PARAMS);
            seen.add(frameId);
            sessions.push({ session: child.session, targetId: `oopif:${frameId}`, actionTargetId: `oopif:${frameId}`, parentFrameId: docFrame, frameTree: child.frameTree, dom });
          } catch (e) {
            warnings.push(`Iframe ${frameId ?? docFrame} accessibility unavailable: ${e instanceof Error ? e.message : String(e)}`);
          }
        }
      }
    }
    return sessions;
  }

  async snapshot() {
    const warnings = [];
    const sessions = await this.#sessions(warnings);
    const rootFrames = new Set(sessions.map((s) => s.frameTree.frame.id));
    const frames = new Map();
    const owner = new Map();
    for (const s of sessions) {
      const walk = (node, parentId) => {
        const id = node.frame.id;
        const parentFrameId = node.frame.parentId ?? frames.get(id)?.parentFrameId ?? (id === s.frameTree.frame.id ? s.parentFrameId : parentId);
        frames.set(id, { frameId: id, session: s.session, parentFrameId });
        if (id !== s.frameTree.frame.id && rootFrames.has(id)) return;
        owner.set(id, s);
        for (const c of node.childFrames ?? []) walk(c, id);
      };
      walk(s.frameTree);
    }
    const depth = (f) => {
      let d = 0;
      const seen = new Set();
      for (let cur = f; cur?.parentFrameId != null && !seen.has(cur.frameId); cur = frames.get(cur.parentFrameId)) {
        seen.add(cur.frameId);
        d++;
      }
      return d;
    };
    const ordered = [...frames.values()].sort((a, b) => depth(a) - depth(b));
    const captured = [];
    for (const f of ordered) {
      const s = owner.get(f.frameId);
      if (s == null) continue;
      try {
        const { nodes } = await s.session.send("Accessibility.getFullAXTree", { frameId: f.frameId });
        const ids = new Set(nodes.map((n) => n.backendDOMNodeId).filter((x) => x != null));
        const metadata = domMetadata(s.dom, ids);
        let ownerBackendNodeId;
        if (f.parentFrameId != null) {
          const parent = frames.get(f.parentFrameId);
          if (parent == null) throw new Error(`Parent frame ${f.parentFrameId} has no debugger session`);
          ({ backendNodeId: ownerBackendNodeId } = await parent.session.send("DOM.getFrameOwner", { frameId: f.frameId }));
        }
        captured.push({ frameId: f.frameId, parentFrameId: f.parentFrameId, ownerBackendNodeId, targetId: s.targetId, actionTargetId: s.actionTargetId, nodes, metadata });
      } catch (e) {
        if (f.parentFrameId == null) throw e;
        warnings.push(`Iframe ${f.frameId} accessibility unavailable: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    const nodes = stitchFrames(captured, warnings);
    return {
      capturedAt: new Date().toISOString(),
      tab: { id: this.tabId, title: await this.#tabTitle(), url: this.page.url() ?? null, active: true },
      nodes,
      warnings,
    };
  }

  // Like the service, always diff against the previous revision of this tab,
  // across navigations too. The renderer only refuses a revision from another
  // tab id.
  #render(snapshot, disableDiffing) {
    const rev = this.core.buildRevision(this.revision, snapshot, { mode: disableDiffing ? "full" : "auto" });
    this.revision = rev;
    return `Browser tab: ${snapshot.tab.id}, Title: ${JSON.stringify(snapshot.tab.title ?? "Unknown")}, URL: ${JSON.stringify(snapshot.tab.url ?? "Unknown")}.\n${rev.text}`;
  }

  // Tab title as the browser reports it; works while a JavaScript dialog blocks the page.
  async #tabTitle() {
    const { targetInfo } = await (await this.#mainSession()).send("Target.getTargetInfo");
    return targetInfo.title ?? null;
  }

  /** Equivalent of `await tab.ax.get("state", { disableDiffing })`. */
  async state({ disableDiffing = false } = {}) {
    const snapshot = await this.snapshot();
    return this.#render(snapshot, disableDiffing);
  }

  /** State while a JavaScript dialog is open. `dialog` is a Playwright Dialog. */
  async dialogState(dialog, { id = "1", disableDiffing = false } = {}) {
    const title = await this.#tabTitle();
    const snapshot = {
      capturedAt: new Date().toISOString(),
      tab: { id: this.tabId, title, url: this.page.url() ?? null, active: true },
      nodes: javaScriptDialogNodes({
        id,
        type: dialog.type(),
        message: dialog.message(),
        defaultPrompt: dialog.defaultValue(),
        url: this.page.url(),
        pageTitle: title ?? undefined,
      }),
      warnings: [],
    };
    return this.#render(snapshot, disableDiffing);
  }
}

export function loadPlaywright() {
  for (const d of [process.env.PARITY_PLAYWRIGHT_DIR, "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules"].filter(Boolean)) {
    try {
      return require(path.join(d, "playwright"));
    } catch {}
  }
  return require("playwright");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

async function main(argv) {
  const opts = { full: false, json: false, tabId: 1, steps: [], target: undefined, width: 1280, height: 720 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--full") opts.full = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--tab-id") opts.tabId = argv[++i];
    else if (a === "--then") opts.steps.push({ kind: "eval", arg: argv[++i] });
    else if (a === "--click") opts.steps.push({ kind: "click", arg: argv[++i] });
    else if (a === "--viewport") [opts.width, opts.height] = argv[++i].split("x").map(Number);
    else opts.target = a;
  }
  if (!opts.target) {
    console.error("usage: chatgpt-ax-reference.mjs <url|/fixture.html> [--full] [--json] [--then js] [--click css]");
    process.exit(2);
  }
  let servers;
  let url = opts.target;
  if (url.startsWith("/")) {
    const { startFixtureServers } = await import(path.join(here, "fixture-server.mjs"));
    servers = await startFixtureServers();
    const u = new URL(url, servers.origins.primary);
    if (!u.searchParams.has("peer")) u.searchParams.set("peer", servers.origins.peer);
    url = u.href;
  }
  const core = await loadChatGPTAccessibilityCore();
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: process.env.PARITY_CHANNEL ?? "chrome", headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: opts.width, height: opts.height } });
    const page = await context.newPage();
    const ref = new ChatGPTAxReference(page, core, { tabId: opts.tabId });
    let pendingDialog;
    page.on("dialog", (d) => {
      pendingDialog = d;
    });
    await page.goto(url, { waitUntil: "load" });
    await page.waitForTimeout(150);
    const emit = async () => {
      if (pendingDialog) {
        console.log(await ref.dialogState(pendingDialog, { disableDiffing: opts.full }));
        await pendingDialog.dismiss().catch(() => {});
        pendingDialog = undefined;
        return;
      }
      if (opts.json) console.log(JSON.stringify(await ref.snapshot(), null, 2));
      else console.log(await ref.state({ disableDiffing: opts.full }));
    };
    await emit();
    for (const step of opts.steps) {
      console.log("\n----- after", step.kind, step.arg, "-----");
      if (step.kind === "eval") await page.evaluate(step.arg).catch((e) => console.log(`(eval error: ${e.message})`));
      else await page.click(step.arg, { noWaitAfter: true, timeout: 2000 }).catch((e) => console.log(`(click error: ${e.message.split("\n")[0]})`));
      await page.waitForTimeout(250);
      await emit();
    }
  } finally {
    await browser.close();
    await servers?.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2));
}
