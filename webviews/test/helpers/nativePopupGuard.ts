// Test instrumentation, not a production fallback or a whole-app migration verdict. A caller
// must exercise its consumers and adapt the generated popup protocol into these observations.
// Strict migration checks and observations of the existing escape adapter have separate policies.

export interface PopupIdentity {
  popupId: string;
  revision: number;
  /** Mounted consumer identity, owned by the harness; this is not a wire field. */
  owner: object;
}

export interface NativePresentation extends PopupIdentity {
  host: "WebPopupHost" | "WebContextMenu";
  /** `pending` is the harness's captured in-flight request, not a successful host receipt. */
  state: "pending" | "shown" | "rejected" | "dismissed";
}

export type SurfaceSemantics =
  | { kind: "persistent" }
  | { kind: "modal" }
  | {
      kind: "escape-mirror";
      shell: Element;
      expected: PopupIdentity;
      presentation: NativePresentation | null;
    }
  | { kind: "native-content"; expected: PopupIdentity; presentation: NativePresentation | null };

export interface PopupGuardOptions {
  /** Only gallery/unit harnesses may explicitly select the DOM adapter. Never infer it from
   * a missing bridge, a failed RPC, a hostname, CSS classes or document data attributes. */
  adapter: "native" | { kind: "test-dom"; reason: string };
  /** Legacy useEscapingPopup retains keyboard/accessibility DOM and restores it on rejection.
   * Native-only is the default and remains the oracle for migrated declarative consumers. */
  lifecycle?: "native-only" | "escape-compatible";
  /** Exact roots, supplied by the exercised surface's harness. Descendants are still scanned. */
  semantics?: ReadonlyMap<Element, SurfaceSemantics>;
  /** Custom portals whose roots do not carry accessible popup semantics yet. */
  portalRoots?: ReadonlySet<Element>;
  /** Roots captured by the harness when their owners call attachShadow({mode:"closed"}).
   * Only roots whose hosts are inside the inspected scope are traversed. */
  shadowRoots?: ReadonlySet<ShadowRoot>;
  /** Required presentations after each open. A rejected or missing host is a failure even
   * when the page draws nothing. An empty list alone is never migration evidence. */
  presentations?: readonly { expected: PopupIdentity; actual: NativePresentation | null }[];
  /** Observed modality, not aria-modal alone. The default uses the browser's :modal.
   * A harness for a custom modal must verify its focus/inert ownership before returning true. */
  isModal?: (element: Element) => boolean;
}

export interface PopupViolation {
  kind: "dom-popup" | "invalid-modal" | "native-presentation";
  element?: Element;
  detail: string;
}

/** The dispatcher must compare the current mounted owner as well as the wire identity. A
 * reopened popup must advance revision or use a new popupId. This helper is an oracle; it
 * does not implement production dispatch or authenticate a renderer-supplied event. */
export function currentPopupEvent(
  event: Pick<PopupIdentity, "popupId" | "revision">,
  current: PopupIdentity | null,
  receivingOwner: object,
): boolean {
  return (
    current !== null &&
    current.owner === receivingOwner &&
    event.popupId.length > 0 &&
    Number.isSafeInteger(event.revision) &&
    event.revision >= 0 &&
    event.popupId === current.popupId &&
    event.revision === current.revision
  );
}

export function nativePresentationProblem(expected: PopupIdentity, actual: NativePresentation | null): string | null {
  if (!actual) return "missing native presentation";
  if (actual.host !== "WebPopupHost") return "presentation used a different native host";
  if (actual.state !== "shown") return `native presentation ${actual.state}`;
  if (!currentPopupEvent(actual, expected, actual.owner)) return "stale popup identity, revision or mounted owner";
  return null;
}

function parent(element: Element): Element | null {
  const root = element.getRootNode();
  return element.parentElement ?? ("host" in root ? (root as ShadowRoot).host : null);
}

function elementsIn(root: Document | Element | ShadowRoot, supplied: ReadonlySet<ShadowRoot> = new Set()): Element[] {
  const result: Element[] = [];
  const byHost = new Map([...supplied].map((shadow) => [shadow.host, shadow]));
  const visited = new Set<Document | Element | ShadowRoot>();
  const visitElement = (element: Element) => {
    if (visited.has(element)) return;
    visited.add(element);
    result.push(element);
    const shadow = element.shadowRoot ?? byHost.get(element);
    if (shadow) visitScope(shadow);
  };
  const visitScope = (scope: Document | Element | ShadowRoot) => {
    if (scope.nodeType === 1) visitElement(scope as Element);
    else {
      if (visited.has(scope)) return;
      visited.add(scope);
    }
    for (const element of scope.querySelectorAll("*")) visitElement(element);
  };
  visitScope(root);
  return result;
}

function escapeMirrorProblem(
  element: Element,
  declaration: Extract<SurfaceSemantics, { kind: "escape-mirror" }>,
): string | null {
  const { shell, expected, presentation } = declaration;
  if (!presentation) return "missing escape presentation observation";
  if (presentation.host !== "WebPopupHost" || !currentPopupEvent(presentation, expected, presentation.owner))
    return "stale escape identity, revision, mounted owner or host";
  if (shell !== element && !shell.contains(element)) return "escape shell does not contain its declared mirror";
  const style = shell.ownerDocument.defaultView?.getComputedStyle(shell);
  const escaped = shell.hasAttribute("data-escaped") && style?.opacity === "0" && style.pointerEvents === "none";
  if (presentation.state === "pending" || presentation.state === "shown")
    return escaped ? null : "pending/shown escape mirror is not invisible and pointer-disabled";
  if (presentation.state === "rejected")
    return !shell.hasAttribute("data-escaped") && style?.opacity !== "0" && style?.pointerEvents !== "none"
      ? null
      : "rejected escape presentation did not restore the page surface";
  return "dismissed escape presentation retains popup DOM";
}

function platformModal(element: Element): boolean {
  try {
    return element.matches(":modal");
  } catch {
    return false;
  }
}

/** Reports mounted popup DOM, including invisible row-scraping replicas. Visibility is not
 * an exemption in native-only mode. The explicit escape-compatible policy accepts only the
 * existing adapter's identity-bound invisible mirrors and rejected/restored page surfaces.
 * Unknown custom surfaces are candidates when out of flow and controlled, portaled or raised.
 * This intentionally needs typed classifications for persistent panels and modal dialogs. */
export function inspectNativePopups(
  root: Document | Element | ShadowRoot,
  options: PopupGuardOptions,
): PopupViolation[] {
  if (options.adapter !== "native") {
    if (!options.adapter.reason.trim()) throw new Error("The test DOM adapter requires a reason");
    return [];
  }
  const violations: PopupViolation[] = [];
  for (const { expected, actual } of options.presentations ?? []) {
    const detail = nativePresentationProblem(expected, actual);
    if (detail) violations.push({ kind: "native-presentation", detail: `${expected.popupId}: ${detail}` });
  }
  const elements = elementsIn(root, options.shadowRoots);
  const compatibleShells = new Set<Element>();
  if (options.lifecycle === "escape-compatible") {
    for (const element of elements) {
      const declaration = options.semantics?.get(element);
      if (declaration?.kind === "escape-mirror" && !escapeMirrorProblem(element, declaration))
        compatibleShells.add(declaration.shell);
    }
  }
  const controlled = new Set<Element>();
  for (const trigger of elements) {
    if (trigger.getAttribute("aria-expanded") !== "true") continue;
    for (const id of (trigger.getAttribute("aria-controls") ?? "").split(/\s+/).filter(Boolean)) {
      const scope = trigger.getRootNode() as Document | ShadowRoot;
      const target = "getElementById" in scope ? scope.getElementById(id) : null;
      if (target) controlled.add(target);
    }
  }
  const isModal = options.isModal ?? platformModal;
  const candidates = new Set<Element>();
  for (const element of elements) {
    if (compatibleShells.has(element)) continue;
    const declaration = options.semantics?.get(element);
    if (declaration?.kind === "persistent") continue;
    if (declaration?.kind === "escape-mirror" && options.lifecycle === "escape-compatible") {
      const detail = escapeMirrorProblem(element, declaration);
      if (!detail) continue;
      violations.push({ kind: "native-presentation", element, detail });
    }
    if (declaration?.kind === "native-content") {
      const detail = nativePresentationProblem(declaration.expected, declaration.presentation);
      if (detail) violations.push({ kind: "native-presentation", element, detail });
      continue;
    }
    if (declaration?.kind === "modal") {
      if (isModal(element)) continue;
      violations.push({
        kind: "invalid-modal",
        element,
        detail: "declared modal has no observed modal ownership",
      });
    } else if (isModal(element)) {
      continue;
    }
    const role = element.getAttribute("role");
    const style = element.ownerDocument.defaultView?.getComputedStyle(element);
    const floating = style?.position === "absolute" || style?.position === "fixed";
    const raised = floating && !!style?.zIndex && style.zIndex !== "auto";
    const portaled = options.portalRoots?.has(element) === true;
    const anchored = controlled.has(element);
    const semantic =
      role === "menu" ||
      (role === "listbox" && (floating || portaled || anchored)) ||
      ((role === "dialog" || (element.localName === "dialog" && element.hasAttribute("open"))) &&
        (floating || portaled || anchored));
    const marked = element.hasAttribute("popover") || element.getAttribute("data-placement") === "popover";
    if (!(semantic || marked || portaled || (floating && (anchored || raised)))) continue;
    // One finding per frame; a menu's positioned descendants are not additional frames.
    let ancestor = parent(element);
    while (ancestor && !candidates.has(ancestor)) ancestor = parent(ancestor);
    if (ancestor) continue;
    candidates.add(element);
    violations.push({
      kind: "dom-popup",
      element,
      detail: "mounted floating popup DOM in the native adapter",
    });
  }
  return violations;
}
