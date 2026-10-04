// Base UI decides once, when its module first loads, whether to run layout effects: it checks for
// a global `document` (@base-ui/utils/useIsoLayoutEffect). Test files install jsdom in beforeAll,
// after their imports have loaded Base UI, and bun shares one module cache across files, so the
// first file to import src/ui would turn Base UI's layout effects off for every file after it
// (popovers and dialogs that never open). Load that one module here with a stand-in document.
const scope = globalThis as Record<string, unknown>;
const hadDocument = "document" in scope;
if (!hadDocument) scope.document = {};
await import("@base-ui/utils/useIsoLayoutEffect");
if (!hadDocument) delete scope.document;
export {};
