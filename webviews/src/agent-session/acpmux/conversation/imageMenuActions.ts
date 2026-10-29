// The native context menu's image rows (CmuxNextAgentPane AgentPaneContextMenu): Copy Image, Save
// Image As…, Quick Look and Show in Finder act on the image the page reported under the pointer
// (messageMenu.ts). The page sends the host that image as a `data:` URL with its name; the host
// keeps a named copy and acts on it (AgentPaneImageCopies.swift), so the pasteboard, the saved file
// and Finder all get a real file. The user, 2026-10-21: "right click any image/video etc 'copy'".
import { postNative } from "../native";
import { dataUrl } from "./ImageViewer";
import { takeReportedPicture } from "./messageMenu";

export type ReportedImageMethod = "image.copy" | "image.save" | "image.quickLook" | "image.reveal";

/// Sends the reported image to the host's `method`; false when the report named no image.
export async function actOnReportedImage(method: ReportedImageMethod): Promise<boolean> {
  const picture = takeReportedPicture();
  if (!picture) return false;
  const src = await dataUrl(picture.src);
  await postNative(
    method,
    method === "image.reveal" && picture.path
      ? { src, name: picture.name, path: picture.path }
      : { src, name: picture.name },
  );
  return true;
}
