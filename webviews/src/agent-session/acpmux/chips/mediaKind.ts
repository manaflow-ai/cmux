// File classification shared by tool-result discovery and the reply media player. No rendering
// or loading happens here; every discovered file still goes through the host's media policy.
import { linkPath } from "./paths";

const VIDEO_EXTENSIONS = ["mp4", "m4v", "mov", "webm"];
const AUDIO_EXTENSIONS = ["mp3", "m4a", "aac", "wav", "flac"];
export const MEDIA_EXTENSIONS: readonly string[] = [...VIDEO_EXTENSIONS, ...AUDIO_EXTENSIONS];

const VIDEO = new RegExp(`\\.(${VIDEO_EXTENSIONS.join("|")})$`, "i");
const AUDIO = new RegExp(`\\.(${AUDIO_EXTENSIONS.join("|")})$`, "i");

/// Whether `src` (a path or `file://` URL) names a video or an audio file, by its extension.
export function mediaKind(src: string): "video" | "audio" | undefined {
  const path = (linkPath(src) ?? src).split(/[?#]/)[0] ?? "";
  return VIDEO.test(path) ? "video" : AUDIO.test(path) ? "audio" : undefined;
}
