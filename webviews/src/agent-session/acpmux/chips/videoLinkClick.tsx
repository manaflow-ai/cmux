import { useState, type MouseEvent, type ReactNode } from "react";
import { callChipHost } from "./host";
import { useReplyPolicy } from "./linkStore";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { mediaKind } from "./mediaKind";
import { webURL, mediaOpenRequest, loadPlayableMedia, webGranted } from "./replyMediaModel";
import { VideoViewer } from "./ReplyMedia";

/// A click on a web video's link (a chip in a sentence, a Markdown link): the video plays in the
/// large player over the pane instead of leaving for a browser tab, where a file served as bytes
/// (raw.githubusercontent.com sends `application/octet-stream`) only downloads (Leo, 2026-11-22: "is
/// there a way we can just watch the .mp4s in the app? i want that. in-app video player."). The click
/// is the gesture the host's `media.load` asks for under `images.remote = click`. A link that is no
/// web video, a read-only transcript and `images.remote = never` keep the link's own click; a video
/// the host will not fetch opens as the link would.
export function useVideoLinkClick(href: string): {
  onClick?(event: MouseEvent<HTMLElement>): void;
  viewer: ReactNode;
} {
  const readOnly = useTranscriptReadOnly();
  const policy = useReplyPolicy();
  const [open, setOpen] = useState<{ src: string } | undefined>();
  const url = webURL(href);
  const video = Boolean(url) && mediaKind(url!.pathname) === "video";
  if (!video || readOnly || policy.remoteImages === "never") return { viewer: null };
  const name = url!.pathname.split("/").pop() || href;
  return {
    onClick(event) {
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      )
        return;
      event.preventDefault();
      void loadPlayableMedia(href).then((src) => {
        if (src) setOpen({ src });
        else {
          const request = mediaOpenRequest(href);
          if (request) void callChipHost(request.method, request.params);
        }
      });
    },
    viewer: open ? (
      <VideoViewer
        src={open.src}
        name={name}
        autoPlay
        onError={() => {
          webGranted.delete(href);
          setOpen(undefined);
        }}
        onClose={() => setOpen(undefined)}
      />
    ) : null,
  };
}
