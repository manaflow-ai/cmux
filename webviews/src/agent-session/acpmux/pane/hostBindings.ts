import { postNative } from "../native";
import { setSessionInfoTab } from "../session-info/sessionInfoState";
import { setStashTab } from "../composer/draftStash";
import { type CheckpointDiff } from "../changes/turnCheckpointSource";
import {
  registerAttachmentViewHost,
  registerComposerHost,
  registerComposerRingHost,
  registerDictationSourceHost,
} from "../composerSettings";
import { registerChatDisplayHost } from "../chatDisplay";
import { callNative } from "../callNative";

/// The host names the tab a page a tab adopted after its handshake now is (``setSessionInfoTab``).
const PANE_TAB_EVENT = "acpmux-pane-tab";

// The composer's Hide and Show (composerChrome.tsx) persist through the host, which pushes the
// setting back to every page and on the next launch.
registerComposerHost((method, show) => callNative(method, { show }));
/// The tab this page is, for a page a tab adopted after its handshake (a prewarmed spare,
/// AgentPaneView+SessionAdopt.swift `announceTab`): Session Info is kept by it (sessionInfoState.ts).
if (typeof window !== "undefined")
  window.addEventListener(PANE_TAB_EVENT, (event) => {
    const tab = (event as CustomEvent<{ tab?: unknown }>).detail?.tab;
    if (typeof tab === "string" && tab) {
      setSessionInfoTab(tab);
      setStashTab(tab);
    }
  });
registerAttachmentViewHost((view) => callNative("pane.setAttachmentView", { view }));
registerComposerRingHost((ring) => callNative("pane.setComposerRing", { ring }));
registerDictationSourceHost((source) => callNative("pane.setDictationSource", { source }));
registerChatDisplayHost((key, value) => void callNative("pane.setDisplay", { key, value }).catch(() => undefined));
/// A folder's `git.status` from the native host, named by the folder: a new chat has no session to
/// name it by (the header's worktree pill, cx-lyqio.3b).
export const readFolderStatus = (cwd: string) => postNative("git.status", { cwd });
/// A turn's checkpoint pair, diffed on the session host (`git.checkpoint.diff`).
export const checkpointDiff: CheckpointDiff = (from, to) =>
  callNative("git.checkpoint.diff", { from, to, include_patch: true });
