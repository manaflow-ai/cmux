// A video's poster for its composer chip (Leo 2026-10-22: "the screen reccording preview is just a
// file name"): the frame just after its start and its length, read once in the page when the file
// is pasted or dropped, while the File is still in hand. The chip keeps them on the attachment
// (`poster`, `duration`), so a render never decodes the video again. The pane plays a blob: URL
// (its CSP's `media-src`), and the poster is a data: JPEG (its `img-src`).

/// What a video chip shows: a small JPEG of its first frame and its length in seconds (undefined
/// when the file does not say).
export type VideoPoster = { poster: string; duration?: number };

const VIDEO_NAME = /\.(mov|mp4|m4v|webm)$/i;
/// The longest side the poster keeps: twice the chip's 64 px tile at its widest, for Retina.
const POSTER_SIDE = 256;
/// A file the engine cannot read in this long keeps its file chip.
const POSTER_TIMEOUT_MS = 4000;

/// Whether `file` is a video the composer draws a poster for, by its type or its name.
export function isVideoFile(file: File): boolean {
  return file.type.startsWith("video/") || VIDEO_NAME.test(file.name);
}

/// The poster of `file`, or undefined when the engine cannot decode it (another codec, a broken
/// file, no blob URLs, past the timeout). A detached <video> loads only its metadata, seeks to
/// min(0.1 s, half its length) and draws that frame on a canvas. Cleanup, whatever the outcome:
/// the timer is cleared, the three listeners are removed, the video lets go of its source (`src`
/// removed and `load()`, which stops its fetch and decoder), the object URL is revoked, and the
/// canvas is shrunk to 0×0 so its pixels go at once.
export function videoPoster(file: Blob, timeoutMs = POSTER_TIMEOUT_MS): Promise<VideoPoster | undefined> {
  if (typeof document === "undefined" || typeof URL.createObjectURL !== "function") return Promise.resolve(undefined);
  let url: string;
  try {
    url = URL.createObjectURL(file);
  } catch {
    return Promise.resolve(undefined);
  }
  const video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;
  video.preload = "metadata";
  return new Promise((resolve) => {
    let done = false;
    const timer = setTimeout(fail, timeoutMs);
    function finish(result: VideoPoster | undefined) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      video.removeEventListener("loadedmetadata", seek);
      video.removeEventListener("seeked", draw);
      video.removeEventListener("error", fail);
      video.removeAttribute("src");
      video.load();
      URL.revokeObjectURL(url);
      resolve(result);
    }
    function fail() {
      finish(undefined);
    }
    function seek() {
      const length = video.duration;
      video.currentTime = Number.isFinite(length) && length > 0 ? Math.min(0.1, length / 2) : 0;
    }
    function draw() {
      const { videoWidth: width, videoHeight: height } = video;
      if (!width || !height) return fail();
      const scale = Math.min(1, POSTER_SIDE / Math.max(width, height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      let poster: string | undefined;
      try {
        canvas.getContext("2d")?.drawImage(video, 0, 0, canvas.width, canvas.height);
        poster = canvas.toDataURL("image/jpeg", 0.8);
      } catch {
        poster = undefined;
      }
      canvas.width = 0;
      canvas.height = 0;
      const length = video.duration;
      finish(
        poster?.startsWith("data:image/jpeg")
          ? { poster, ...(Number.isFinite(length) && length > 0 ? { duration: length } : {}) }
          : undefined,
      );
    }
    video.addEventListener("loadedmetadata", seek);
    video.addEventListener("seeked", draw);
    video.addEventListener("error", fail);
    video.src = url;
  });
}
