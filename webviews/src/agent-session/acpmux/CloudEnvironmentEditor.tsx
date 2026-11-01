import { lazy, Suspense, useSyncExternalStore } from "react";
import { cloudEnvironmentRequest, subscribeCloudEnvironment } from "./cloudEnvironment";

const Editor = lazy(() => import("./CloudEnvironmentEditorContent"));

/** Keep the editor and its catalog off the chat’s startup path until an entry point opens it. */
export function CloudEnvironmentEditor() {
  const request = useSyncExternalStore(subscribeCloudEnvironment, cloudEnvironmentRequest);
  return request ? (
    <Suspense fallback={null}>
      <Editor />
    </Suspense>
  ) : null;
}
