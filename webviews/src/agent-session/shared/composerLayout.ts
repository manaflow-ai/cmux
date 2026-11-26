const singleLineTextPadding = 32;

export type ComposerLayoutMode = "auto-single-line" | "multiline";

export type ComposerLayoutInput = {
  composerLayoutMode: ComposerLayoutMode;
  hasVisibleAttachments: boolean;
  isEditorMultiline: boolean;
  isVoiceLayoutActive: boolean;
  singleLineInputWidth: number | null;
  singleLineTextWidth: number;
};

export function shouldUseSingleLineComposer(input: ComposerLayoutInput): boolean {
  if (input.composerLayoutMode === "multiline") {
    return false;
  }
  if (input.hasVisibleAttachments || input.isEditorMultiline || input.isVoiceLayoutActive) {
    return false;
  }
  if (input.singleLineInputWidth == null) {
    return true;
  }
  return input.singleLineTextWidth + singleLineTextPadding <= input.singleLineInputWidth;
}
