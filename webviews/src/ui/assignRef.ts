import type { Ref } from "react";

/**
 * Hands `node` to a ref a component received as a prop: a callback, or a ref object (its `current`
 * is written). The write is made here, in a function, rather than as `ref.current = node` in the
 * component: the React Compiler treats a prop as immutable.
 */
export function assignRef<T>(ref: Ref<T> | undefined, node: T | null): void {
  if (typeof ref === "function") ref(node);
  else if (ref) ref.current = node;
}
