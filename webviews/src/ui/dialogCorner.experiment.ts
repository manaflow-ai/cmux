// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/** One dialog corner (RFD 0207 "Dialog corner"): a dialog had three corners. Native: the button corner
 * plus the 16 pt card padding (CmuxDialogMetrics.card, Metrics.dialogPadding at Default), 8 + 16 = 24. Web:
 * the button corner plus --role-dialog-inset 24, so 32 (popupSurface.css THE SHEET ROLE), or a dialog's
 * own padding (the Share dialog 24, so 32; others 16, so 24). The role file's sheet says 14. Under `native`
 * every glass web dialog (`.ui-dialog.ui-glass`) pads 16 on every side, so its corner is the native one,
 * 8 + 16 = 24, still concentric with its buttons (Lawrence 2026-11-15). Dialog.tsx puts the arm on the popup
 * as data-dialog-corner. Off by default: making 24 the default needs Leo's word. Compare in the gallery:
 * `ui.dialog`, variants `glass` and `glass-native-corner`.
 * @status experimental
 */
export const dialogCorner = defineExperiment({
  id: "dialog-corner",
  title: "Dialog corner",
  description:
    "A web dialog's corner and padding: today's (24 padding, a 32 corner), or the native dialog's (16 padding, a 24 corner), so a web and a native dialog round the same. Look for: the buttons still sit concentric in the corner.",
  arms: {
    page: {
      label: "Page",
      description: "Today's web dialog: the button corner plus 24 padding, a 32 corner (a dialog's own padding wins).",
    },
    native: {
      label: "Native",
      description: "The native dialog's: the button corner plus 16 padding on every glass dialog, a 24 corner.",
    },
  },
  defaultArm: "page",
});

export type DialogCorner = keyof typeof dialogCorner.arms;
