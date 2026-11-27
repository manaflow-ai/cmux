// One prompt editor for the agent chat and the new tab page (R135, the new tab lead reviews it).
// Both surfaces mount it, so the text survives when the new tab becomes the chat in place. It is
// the composer's Milkdown (ProseMirror) field with the hooks a surface needs: typed and pasted
// text before it lands (`onBeforeInput`, the new tab's "!" rule), Enter as `onSubmit`, the first
// input, plain text, and the surface's own keymap (the omnibar word rules).
//
// Features: `keymap` and `multiline` are the editor's. Mentions, slash commands, attachments and
// dictation are still the chat composer's (Composer.tsx); they move behind these flags next, so
// the new tab can turn on the ones it uses (mentions, attachments, dictation).
import React from "react";
import type { Plugin } from "@milkdown/kit/prose/state";
import { MarkdownField, type MarkdownFieldHandle, type MarkdownFieldProps } from "../MarkdownField";

export type PromptFeatures = {
  /// Shift-Enter adds a line (default true).
  multiline?: boolean;
  /// Surface keymaps, which run before the editor's keys.
  keymap?: Plugin[];
  /// The @ file mention, searched in this folder (session host).
  mentions?: { cwd: () => string | undefined };
  /// The `/` command menu (the chat only).
  slashCommands?: boolean;
  /// Pasted or dropped images and text files.
  attachments?: boolean;
  /// The composer's microphone; nothing loads until first use.
  dictation?: boolean;
};

export type PromptEditorProps = Omit<MarkdownFieldProps, "plugins" | "multiline"> & { features: PromptFeatures };
export type PromptEditorHandle = MarkdownFieldHandle;

export const PromptEditor = React.forwardRef<PromptEditorHandle, PromptEditorProps>(function PromptEditor(
  { features, ...props },
  ref,
) {
  return <MarkdownField ref={ref} {...props} plugins={features.keymap} multiline={features.multiline ?? true} />;
});
