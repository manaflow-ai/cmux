// Counts a list's row renders with nothing added to the row. Each mounted row's component fiber
// (found from the row's DOM node) holds the props object it last rendered with, and React keeps that
// very object when a memoized row skips a render. So a row whose props object is new since the last
// look rendered again (or mounted). React's commit hook would say the same, but the test preload
// loads react-dom before a test file could install one.

type Fiber = { type: unknown; return: Fiber | null; alternate: Fiber | null; memoizedProps: unknown };

const nameOf = (type: unknown): string | undefined => {
  if (typeof type === "function") return (type as { displayName?: string; name: string }).displayName ?? type.name;
  if (type && typeof type === "object" && "type" in type) return nameOf((type as { type: unknown }).type);
  return undefined;
};

function fiberOf(element: Element): Fiber | undefined {
  const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
  return key ? (element as unknown as Record<string, Fiber>)[key] : undefined;
}

/** Both copies of the row component's props (React double-buffers each fiber). Without a name, the
 *  nearest component above the row's node: a minified build has no names. */
function propsOf(element: Element, component: string | undefined): unknown[] {
  for (let fiber: Fiber | null | undefined = fiberOf(element)?.return; fiber; fiber = fiber.return) {
    if (
      component === undefined ? typeof fiber.type === "string" || fiber.type == null : nameOf(fiber.type) !== component
    )
      continue;
    return [fiber.memoizedProps, fiber.alternate?.memoizedProps].filter((props) => props != null);
  }
  return [];
}

export interface MountedRowRenders {
  /** Rows under `elements` whose component rendered or mounted since the last `mark`. */
  since(): number;
  mark(): void;
}

export function mountedRowRenders(elements: () => Iterable<Element>, component?: string): MountedRowRenders {
  let seen = new Set<unknown>();
  const renders: MountedRowRenders = {
    mark() {
      seen = new Set();
      for (const element of elements()) for (const props of propsOf(element, component)) seen.add(props);
    },
    since() {
      let count = 0;
      for (const element of elements()) if (propsOf(element, component).some((props) => !seen.has(props))) count++;
      return count;
    },
  };
  return renders;
}
