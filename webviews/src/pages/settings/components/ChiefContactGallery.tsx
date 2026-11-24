// l10n-allow-file: synthetic gallery controls and fixtures, not shipped UI.
import { useMemo, useState } from "react";
import { ChiefContactSheet, type ContactLayout } from "./ChiefContactSheet";
import { MockChiefContact } from "../mockChiefContact";
import { installCatalog, setLocale } from "../strings";
import catalog from "../generated/strings.json";
import mascot from "../../../agent-session/acpmux/mascots/ChiefMascotOrb.png";
import type { ChiefContactStatus, LinkErrorCode } from "../chiefContact";

export interface ContactGalleryProps {
  state?: ChiefContactStatus["state"];
  layout?: ContactLayout;
  requestError?: LinkErrorCode;
  sending?: boolean;
}

export default function ChiefContactGallery({ state = "idle", layout, requestError, sending }: ContactGalleryProps) {
  const [open, setOpen] = useState(true);
  const client = useMemo(() => {
    installCatalog(catalog);
    setLocale(document.documentElement.lang || "en");
    const mock = new MockChiefContact({ state, handle: state === "idle" ? undefined : "+15555550123" });
    mock.requestError = requestError;
    mock.holdRequest = sending ?? false;
    return mock;
  }, [state, requestError, sending]);
  return open ? (
    <ChiefContactSheet service={client} mascot={mascot} layout={layout} onClose={() => setOpen(false)} />
  ) : (
    <button type="button" onClick={() => setOpen(true)}>
      Contact your Chief anywhere
    </button>
  );
}
