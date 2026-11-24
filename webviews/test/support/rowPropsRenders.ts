// Counts a list's row renders from the props React commits to each row's own element. React stores
// the props of a host element's latest commit on its DOM node (`__reactProps$`): a render that
// reaches the row makes a new props object, and a row React skipped (a memo row, or JSX the React
// Compiler kept) keeps it. It reads the row's element, not a component above it, so a row drawn
// inline by a parent that re-rendered on its own state counts too (mountedRowRenders.ts reads a
// component's props, which stay the same object then).

const propsOf = (element: Element): unknown => {
  const key = Object.keys(element).find((name) => name.startsWith("__reactProps$"));
  return key ? (element as unknown as Record<string, unknown>)[key] : undefined;
};

export interface RowPropsRenders {
  mark(): void;
  /** Rows mounted at `mark` and still mounted that rendered again since; rows mounted since are not counted. */
  since(): number;
}

export function rowPropsRenders(elements: () => Iterable<Element>): RowPropsRenders {
  let seen = new Map<Element, unknown>();
  return {
    mark() {
      seen = new Map(Array.from(elements(), (element) => [element, propsOf(element)]));
    },
    since() {
      return Array.from(elements()).filter((element) => seen.has(element) && seen.get(element) !== propsOf(element))
        .length;
    },
  };
}
