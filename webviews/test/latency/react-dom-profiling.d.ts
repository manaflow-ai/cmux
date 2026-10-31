// React ships the profiling client, but @types/react-dom only declares the normal client.
declare module "react-dom/profiling" {
  export { createRoot, hydrateRoot } from "react-dom/client";
}
