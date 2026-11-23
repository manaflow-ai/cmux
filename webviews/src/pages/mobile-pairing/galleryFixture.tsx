// l10n-allow-file: public-safe gallery fixtures.
// The Mobile Pairing page over its mock host, held at one step: signed out, phone access off, or
// ready (with the pairing code or without it).
import { useEffect, useState } from "react";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockMobilePairingProvider } from "./mockProvider";
import { MobilePairingPage } from "./MobilePairingPage";
import { MobilePairingStore } from "./store";
import type { MobilePairingStatus, PairingHost } from "./types";

export type MobilePairingGalleryProps = {
  state?: "signedOut" | "accessOff" | "ready" | "readyNoCode";
};

const HOST: PairingHost = {
  status: "Online · no phones connected",
  how: "Install cmux on your iPhone and sign in with the same account as this Mac. This Mac then appears under Workspaces.",
  phonesTitle: "Phones",
  phones: [],
  phonesEmpty: "No phones yet.",
  pendingTitle: "Waiting for You",
  pending: [],
  allowTitle: "Allow",
  denyTitle: "Don't Allow",
  blocked: null,
};

// The mock's sample code (made-up token and key hash).
const QR_IMAGE =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADUAAAA1AQAAAADJnZ7dAAABp0lEQVR42mP4DwY/GGD0gYBG66UXJBjuB+gx1ojfYLgYIRx3aEoEw8UyG5XYLUA6zIhV60sEw/2iJ2Ury28wHAgFggAJhv8P35Xujv/BcIPtBkvuWwmGe7tWPAh0qGC4YFz4a8qFGwzfd7tYHY+MYHjr4OrjuhLI7/+4zUPhB8O11Hrf8xYzGL5N63UUYLNguFj8+bQvjwTDzaZnHGaTfjAcCzbwZD8pwfBvzbbnzrN2MHxRyLlTmT6D4eMDF7N0RwuGM+KdbIcbZzC8vfm89FJMBcNJ577QgyFA/j2GYu+YHww/pNrYvzRKMPy6unnRtscRDNfNthy7YhzB8PWhpDTLaQuGNwLKgYJHIxhOnnvn17biB8M/h+T1J5dEMPy90uH3xiWC4Zu3lYl28Q2Gy+uXm/lYSTBcCTi39ur+GwyH13CyclZYMLwzU565Vj2C4fGCN0ZmuysYjqusZ5rCAAyPM6dKU+5UMBwI3ht6Y8oNhvuBJwvMYmcwXAz6xlp4cAfDxWCel6J2wPDMmnj3wtMdDPcL4xzMr0swHIg8rigw+wYDWrwAAHFsz/5q78d0AAAAAElFTkSuQmCC";

function initial(state: NonNullable<MobilePairingGalleryProps["state"]>): Partial<MobilePairingStatus> {
  const account = "you@example.com";
  switch (state) {
    case "signedOut":
      return { state: "signedOut" };
    case "accessOff":
      return { state: "accessOff", account };
    case "readyNoCode":
      return { state: "ready", account, allowed: true, host: HOST };
    case "ready":
      return {
        state: "ready",
        account,
        allowed: true,
        host: HOST,
        qr: { url: "cmux-next://pair?mac=mac-studio", image: QR_IMAGE, expiresAt: Date.now() + 86_400_000 },
      };
  }
}

export function MobilePairingGallery({ state = "signedOut" }: MobilePairingGalleryProps) {
  const [store] = useState(() => new MobilePairingStore(new MockMobilePairingProvider(initial(state))));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return <MobilePairingPage store={store} strings={strings} />;
}
