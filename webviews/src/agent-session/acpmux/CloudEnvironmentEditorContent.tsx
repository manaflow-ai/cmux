import { useEffect, useState, useSyncExternalStore } from "react";
import { EnvironmentSheet } from "../../pages/cloud/EnvironmentSheet";
import { EnvironmentStore, sharedEnvironmentCache } from "../../pages/cloud/environmentStore";
import { createStrings } from "../../pages/shared/i18n";
import table from "../../pages/cloud/generated/strings.json";
import { postNative } from "./native";
import { cloudEnvironmentRequest, closeCloudEnvironmentRequest, subscribeCloudEnvironment } from "./cloudEnvironment";

export default function CloudEnvironmentEditorContent() {
  const request = useSyncExternalStore(subscribeCloudEnvironment, cloudEnvironmentRequest);
  const [strings] = useState(() => createStrings(table));
  const [store] = useState(
    () =>
      new EnvironmentStore(
        {
          list: () => postNative("cloud.environment.list"),
          get: (id) => postNative("cloud.environment.get", { id }),
          update: (id, patch) => postNative("cloud.environment.update", { id, patch }),
          derive: (options) => postNative("cloud.environment.derive", options),
          create: (environment) => postNative("cloud.environment.create", { environment }),
        },
        sharedEnvironmentCache,
      ),
  );
  useEffect(() => {
    if (!request) return;
    void store.open(request);
    const stop = store.subscribe(() => {
      if (!store.getSnapshot().open) closeCloudEnvironmentRequest(request.request);
    });
    return () => {
      stop();
      store.close();
    };
  }, [request, store]);
  return <EnvironmentSheet store={store} strings={strings} />;
}
