// Resolves a package that @base-ui/react depends on (and this package does not) from Base UI's own
// location. A bare specifier finds it only when the install happens to hoist it to
// webviews/node_modules. One CI shard's install did not, and every file in that shard failed with
// "Cannot find module '@base-ui/utils/useIsoLayoutEffect' from 'test/preload.ts'". Resolving from
// Base UI also gives the copy Base UI itself loads, which is the one the preload must set up.
export function resolveBaseUiDependency(specifier: string, from: string): string {
  return Bun.resolveSync(specifier, Bun.resolveSync("@base-ui/react/tooltip", from));
}
