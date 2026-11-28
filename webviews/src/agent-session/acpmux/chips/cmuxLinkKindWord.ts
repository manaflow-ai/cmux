import { useT } from "../i18n";
import type { CmuxLinkKind } from "./cmuxLinkResolve";

const KIND_KEYS = {
  chat: "cmuxLink.kind.chat",
  workspace: "cmuxLink.kind.workspace",
  pane: "cmuxLink.kind.pane",
  tab: "cmuxLink.kind.tab",
} as const;

/// The kind word of `kind`, in the pane's language.
export function useKindWord(): (kind: CmuxLinkKind) => string {
  const t = useT();
  return (kind) => t(KIND_KEYS[kind]);
}
