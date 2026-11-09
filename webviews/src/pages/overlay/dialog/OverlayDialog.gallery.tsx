// l10n-allow-file: gallery fixtures, not shipped UI.
// The cmux dialog on the overlay page (cmux-page://cmux.overlay/#/dialog). In the app the window's
// glass is drawn under the card by the host; here the sheet veil stands in for it.
import { componentEntry } from "../../../gallery/format";
import { OverlayDialog } from "./OverlayDialog";
import type { DialogState } from "./types";

const base: DialogState = {
  id: 1,
  title: "Close this tab?",
  lines: ["The terminal is still running a command."],
  fields: [],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
    { id: "close", title: "Close", role: "default", hint: "↩", hintLabel: "Return" },
  ],
  keys: { return: "close", escape: "cancel", command: {} },
  layout: "standard",
  values: {},
  focus: null,
};

const quit: DialogState = {
  ...base,
  title: "Quit cmux?",
  lines: ["2 local terminals are running. Keep their sessions for the next launch, or end them."],
  fields: [{ kind: "check", id: "dontAsk", title: "Don't ask again" }],
  buttons: [
    { id: "endLayout", title: "End Sessions, Keep Layout", role: "destructive" },
    { id: "endAll", title: "End Everything", role: "destructive" },
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "keep", title: "Keep Sessions", role: "default" },
  ],
  keys: { return: "keep", escape: "cancel", command: {} },
  layout: "safeDefault",
  values: { dontAsk: false },
};

const prompt: DialogState = {
  ...base,
  title: "Sign in",
  from: "From intranet.example.com",
  lines: ["The site asks for a user name and password."],
  fields: [
    { kind: "text", id: "user", label: "User name", secure: false },
    { kind: "text", id: "password", label: "Password", secure: true },
  ],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
    { id: "ok", title: "Sign In", role: "default", hint: "↩", hintLabel: "Return" },
  ],
  keys: { return: "ok", escape: "cancel", command: {} },
  values: { user: "", password: "" },
};

const save: DialogState = {
  ...base,
  title: "Save changes to notes.md?",
  lines: ["Your changes are lost if you don't save them."],
  fields: [
    {
      kind: "choice",
      id: "encoding",
      label: "Encoding",
      options: [
        { label: "UTF-8", value: "utf8", enabled: true },
        { label: "UTF-16", value: "utf16", enabled: true },
        { label: "Latin-1 (cannot hold this text)", value: "latin1", enabled: false },
      ],
    },
  ],
  buttons: [
    { id: "discard", title: "Don't Save", role: "destructive", hint: "⌘D", hintLabel: "Command-D" },
    { id: "cancel", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
    { id: "save", title: "Save", role: "default", hint: "↩", hintLabel: "Return" },
  ],
  keys: { return: "save", escape: "cancel", command: { d: "discard" } },
  values: { encoding: "utf8" },
};

const paste: DialogState = {
  ...base,
  title: "Paste 3 lines?",
  lines: ["The terminal runs each line as you paste it."],
  fields: [{ kind: "preview", text: "git fetch origin\ngit reset --hard origin/main\nnpm run deploy" }],
  buttons: [
    { id: "deny", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
    { id: "paste", title: "Paste", role: "default", hint: "↩", hintLabel: "Return" },
  ],
  keys: { return: "paste", escape: "deny", command: {} },
};

const stacked: DialogState = {
  ...base,
  title: "Fermer cet onglet ?",
  lines: ["Le terminal exécute encore une commande."],
  buttons: [
    { id: "cancel", title: "Annuler", role: "cancel", hint: "⎋", hintLabel: "Échap" },
    { id: "keep", title: "Garder l'onglet ouvert", role: "normal" },
    { id: "close", title: "Fermer et arrêter la commande", role: "default", hint: "↩", hintLabel: "Retour" },
  ],
  keys: { return: "close", escape: "cancel", command: {} },
};

function DialogGallery({ dialog }: { dialog: DialogState }) {
  return (
    <div className="overlay-dialog-gallery">
      <OverlayDialog dialog={dialog} onEdit={() => {}} onPress={() => {}} onLayout={() => {}} />
    </div>
  );
}

export default componentEntry<{ dialog: DialogState }>({
  id: "pages.overlay.dialog",
  title: "cmux dialog",
  area: "Pages",
  height: 420,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: ["page:cmux.overlay", "pages/overlay/dialog/OverlayDialog.tsx#OverlayDialog"],
  load: async () => DialogGallery,
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("./dialog.css");
    await import("./OverlayDialog.gallery.css");
  },
  variants: {
    confirm: { note: "Two buttons with their keys: Escape cancels, Return closes.", props: { dialog: base } },
    quit: {
      note: "Safe default: Cancel and Keep Sessions on one line, the end choices quiet red under them, Don't ask again last.",
      props: { dialog: quit },
    },
    prompt: { note: "A web page's sign-in: its origin above the lines, two text fields.", props: { dialog: prompt } },
    save: { note: "A choice with a disabled option, and Command-D on Don't Save.", props: { dialog: save } },
    paste: { note: "A paste preview in monospace, up to 8 lines.", props: { dialog: paste } },
    stacked: {
      note: "Buttons that do not fit on one line stack the card's width, the default on top.",
      props: { dialog: stacked },
    },
  },
});
