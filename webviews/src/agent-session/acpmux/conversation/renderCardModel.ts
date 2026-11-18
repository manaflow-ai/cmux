export const RENDER_FRAME_URL = "cmux-agent://render/frame";
/// Whether this page can frame renders: only the bundled pane has the render origin.
export const canRender = () => typeof location !== "undefined" && location.protocol === "cmux-agent:";
export { ranRenders, useRenderFrame } from "./renderFrame";
