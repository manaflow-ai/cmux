"use client";

import { useSyncExternalStore } from "react";
import type { FeatureVideo } from "./changelog-media";

const reducedMotionQuery = "(prefers-reduced-motion: reduce)";

function subscribeReducedMotion(onChange: () => void) {
  const query = window.matchMedia(reducedMotionQuery);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

function readReducedMotion() {
  return window.matchMedia(reducedMotionQuery).matches;
}

// The server cannot see the reader's motion preference, so it renders the
// still. Clients that allow motion swap in the looping clip after hydration.
function readServerReducedMotion() {
  return true;
}

export function ChangelogVideo({
  video,
  label,
  width,
  height,
}: {
  video: FeatureVideo;
  label: string;
  width?: number;
  height?: number;
}) {
  const reducedMotion = useSyncExternalStore(
    subscribeReducedMotion,
    readReducedMotion,
    readServerReducedMotion,
  );
  return (
    <ChangelogVideoView
      video={video}
      label={label}
      width={width}
      height={height}
      reducedMotion={reducedMotion}
    />
  );
}

/**
 * Muted, looping, controls-free clip. Under reduced motion it shows the
 * poster (or the first frame when no poster exists) and never autoplays.
 */
export function ChangelogVideoView({
  video,
  label,
  width,
  height,
  reducedMotion,
}: {
  video: FeatureVideo;
  label: string;
  width?: number;
  height?: number;
  reducedMotion: boolean;
}) {
  const aspectRatio = width && height ? `${width} / ${height}` : undefined;
  return (
    <video
      // Remount when the preference flips so autoplay state follows it.
      key={reducedMotion ? "still" : "motion"}
      aria-label={label}
      poster={video.poster}
      width={width}
      height={height}
      muted
      loop={!reducedMotion}
      autoPlay={!reducedMotion}
      playsInline
      disablePictureInPicture
      preload={reducedMotion ? (video.poster ? "none" : "metadata") : "auto"}
      className="block w-full h-auto bg-code-bg"
      style={{ aspectRatio }}
    >
      {video.webm && <source src={video.webm} type="video/webm" />}
      <source src={video.src} type="video/mp4" />
    </video>
  );
}
