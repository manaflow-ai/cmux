// l10n-allow-file: interactive gallery fixtures, not shipped UI.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MobilePairingPage } from "./MobilePairingPage";
import { localPhoneFixtures, MockMobilePairingProvider } from "./mockProvider";
import { MobilePairingStore } from "./store";

function PairingGallery({ state }: { state: "off" | "approved" | "empty" | "access-off" }) {
  const [strings] = useState(() => createStrings(table));
  const [store] = useState(
    () =>
      new MobilePairingStore(
        new MockMobilePairingProvider({
          state: state === "access-off" ? "accessOff" : "ready",
          account: "you@example.com",
          macName: "Mac Studio",
          allowed: state !== "access-off",
          connectedPhones: 1,
          ...(state === "off" ? {} : { localPhones: state === "empty" ? [] : localPhoneFixtures() }),
        }),
      ),
  );
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return <MobilePairingPage store={store} strings={strings} />;
}

export default componentEntry({
  id: "pages.mobile-pairing-revoke",
  title: "Local iPhone Revocation",
  area: "Mobile Pairing",
  height: 640,
  covers: ["pages/mobile-pairing/MobilePairingPage.tsx"],
  load: async () => PairingGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    off: { props: { state: "off" }, note: "Default: no local revocation controls." },
    approved: {
      props: { state: "approved" },
      note: "Opt-in: connected and offline approvals; revoke either independently.",
    },
    empty: { props: { state: "empty" }, note: "After the last approval is revoked." },
    "access-off": {
      props: { state: "access-off" },
      note: "Local approvals remain manageable while phone access is off.",
    },
  },
});
