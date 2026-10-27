// The app's UI font in the gallery: every cmux web view gets Inter's face at document start
// (BundledFonts.pageScript, a data: URL of this same WOFF2), which `--font-ui` names first.
import interWoff2 from "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/InterVariable.woff2?url";

/** Declares the UI font's face in this document, as the app's document-start script does. */
export function installUiFont(): void {
  if (document.getElementById("cmux-ui-font")) return;
  const style = document.createElement("style");
  style.id = "cmux-ui-font";
  style.textContent =
    `@font-face{font-family:"Inter";src:url(${interWoff2}) format("woff2");` +
    "font-weight:100 900;font-style:normal;font-display:block}";
  document.head.append(style);
}
