import { defaultRegistry } from "./rows/registry";
import type { NativeRegistry } from "./rows/rowProps";

export const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});
