// l10n-allow-file: gallery fixtures, not shipped UI.
// Add Device (design/server-cards.md): the shipped "Any machine" look (card) through every phase, the
// two looks it was picked over (steps, compact), and every other way.
import { componentEntry } from "../../../gallery/format";
import type { JoinLineLayout } from "./AddDeviceCard";
import type { Scene } from "./fixtures";

type Props = { scene: Scene; layout?: JoinLineLayout };

export default componentEntry<Props>({
  id: "pages.server-cards-add-device",
  title: "Add Device card",
  area: "Server cards",
  height: 640,
  widths: { narrow: 540, normal: 540, wide: 540 },
  covers: ["pages/server-cards/addDevice/AddDeviceCard.tsx", "pages/server-cards/addDevice/AddDeviceCardHost.tsx"],
  keywords: ["device", "machine", "pair", "ssh", "join", "line", "tailscale"],
  load: async () => {
    const [{ AddDeviceCard }, { scenes }, { createStrings }, table] = await Promise.all([
      import("./AddDeviceCard"),
      import("./fixtures"),
      import("../../shared/i18n"),
      import("../generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    return function GalleryAddDevice({ scene, layout }: Props) {
      const model = scenes[scene]();
      return (
        <div className="server-card-frame add-device-frame">
          <AddDeviceCard
            model={model}
            state={model.getSnapshot()}
            strings={strings}
            layout={layout}
            onAction={() => {}}
          />
        </div>
      );
    };
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
    await import("./addDevice.css");
  },
  variants: {
    card: {
      props: { scene: "showing" },
      note: 'Shipped: the help, the line in its box, the countdown and "It works once" under it, then the wait.',
    },
    steps: {
      props: { scene: "showing", layout: "steps" },
      note: "Variant: the same parts as numbered steps (copy the line, paste it there), no help paragraph.",
    },
    compact: {
      props: { scene: "showing", layout: "compact" },
      note: "Variant: no help; the line on one row cut in the middle, its countdown inside the box.",
    },
    idle: { props: { scene: "idle" }, note: "The default way, signed out: the optional name, then Make Line." },
    "steps-idle": { props: { scene: "idle", layout: "steps" }, note: "steps: the name as step 1." },
    minting: { props: { scene: "minting" }, note: "Making a line." },
    copied: { props: { scene: "copied" }, note: "Copied (concealed): the button says so until a new line." },
    "last-minute": {
      props: { scene: "lastMinute" },
      note: "Under a minute left: the countdown takes the attention color.",
    },
    joined: { props: { scene: "joined" }, note: "build-box joined: its checks, Show in Machines and Done." },
    expired: { props: { scene: "expired" }, note: "The line expired unused: New Line." },
    "signed-out": { props: { scene: "signedOut" }, note: "Refused signed out: Sign In as the Return button." },
    unavailable: { props: { scene: "unavailable" }, note: "The account has no join: New Line." },
    invite: { props: { scene: "invite" }, note: "Signed in: Pair Another Machine… (a code, no ssh)." },
    advanced: { props: { scene: "advanced" }, note: "Advanced open: the ssh way's list, as when it was the default." },
    network: { props: { scene: "network" }, note: "No join offered: the ssh-first card on your network (440 px)." },
    loading: { props: { scene: "loading" }, note: "Looking for your computers." },
    "no-network": {
      props: { scene: "noNetwork" },
      note: "No Tailscale: the reason, Install Tailscale…, and the ~/.ssh/config computers still listed.",
    },
    code: { props: { scene: "code" }, note: "It shows a code: Enter Code… opens Add Server." },
    "new-mac": { props: { scene: "newMac" }, note: "Set up a new Mac or Linux computer: its line, Other Computer…" },
    "setup-copied": { props: { scene: "setupCopied" }, note: "The setup line copied." },
    phone: { props: { scene: "phone" }, note: "A new iPhone: no line; Done." },
  },
});
