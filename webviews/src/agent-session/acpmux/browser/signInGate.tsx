// A tab at `/app/` signs in before the pane mounts: the pane's client refuses to open without an
// enrolled device (browserDevice.ts `device.identity_required`), and the enrollment lives only in
// page memory, so every page load starts here. The app's own pane never reaches this file.
import { createRoot } from "react-dom/client";
import { UiProvider } from "../../../ui/UiProvider";
import { setBrowserDeviceEnrollment } from "../browserDevice";
import { BrowserSignIn } from "./BrowserSignIn";
import type { BrowserLaunch } from "./host";
import { devicePublicKey, socketSignIn } from "./signInWire";

export function mountBrowserSignIn(launch: BrowserLaunch, mountPane: () => void): void {
  const element = document.getElementById("root")!;
  const block = !launch.secure ? "insecure" : !launch.token ? "noLink" : undefined;
  const transport = block || !launch.token ? undefined : socketSignIn(launch.endpoint, launch.token, devicePublicKey);
  const root = createRoot(element);
  root.render(
    <UiProvider container={element}>
      <BrowserSignIn
        transport={transport}
        host={launch.host}
        block={block}
        onSignedIn={(enrollment) => {
          setBrowserDeviceEnrollment(enrollment);
          root.unmount();
          mountPane();
        }}
      />
    </UiProvider>,
  );
}
