// Boots the remote Chief memory inspector (`cmux-page://cmux.chief-inspector/`): the same app as
// the local inspector (src/optchat-inspector), with its API calls carried by the `cmuxPage`
// bridge to the app, which relays them to the paired server's brain daemon (`chief-inspect`).
import { createRoot } from "react-dom/client";
import { App } from "../../optchat-inspector/App";
import { ApiStore, fetcherFor } from "../../optchat-inspector/store";
import { StoreContext } from "../../optchat-inspector/useApi";
import { createPageClient } from "../shared/pageClient";
import "../../optchat-inspector/styles.css";

const client = createPageClient();
const call = client ? (op: string, params: unknown) => client.call<unknown>(op, params) : null;
const store = new ApiStore(fetcherFor(location.protocol, call));
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "chief-inspector") {
  createRoot(root).render(
    <StoreContext.Provider value={store}>
      <App />
    </StoreContext.Provider>,
  );
}
