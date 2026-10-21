// The host's editing commands for the composer's right-click menu (POLISH.md right-click contract):
// Cut, Copy, Paste and Paste as Plain Text run in the app as the page view's own responder actions
// (`cmux.app.edit {command}`, only on the person's click or key), as the agent pane's `pane.edit`
// does, so the page never reads the pasteboard and a paste carries files as a real paste does.
// Absent in a browser or the gallery: those items stay off.
import { createContext } from "react";
import type { ComposerEditCommand } from "../../agent-session/acpmux/Composer";
import type { PageClient } from "../shared/pageClient";

export type { ComposerEditCommand };

export const EDIT_OP = "cmux.app.edit";

export const ComposerEdit = createContext<((command: ComposerEditCommand) => void) | undefined>(undefined);

/** The app host's edit: a refusal (no gesture) leaves the field as it was. */
export const hostEdit =
  (host: PageClient) =>
  (command: ComposerEditCommand): void =>
    void host.call(EDIT_OP, { command }).catch(() => {});
