import { mountGuiModeSurface } from "./guiModeSurface";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux GUI mode root");
}

mountGuiModeSurface(rootElement);
