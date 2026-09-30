// Chat model shared by the web app, the mux worker and native clients.
// Follows Prototypes/MessagesLab/shared/MODEL.md; differences: a participant
// is a human or a mux, and "is me" is derived from the viewer, never stored.

export type ID = string;
/** ISO 8601 with offset. */
export type Instant = string;
/** Asset path or URL. */
export type AssetRef = string;

export interface Conversation {
  id: ID;
  title: string;
  participants: Participant[];
  /** Sorted by sentAt, then id. */
  messages: Message[];
}

export type Participant =
  | { kind: "human"; id: ID; displayName: string; avatar?: Avatar }
  | { kind: "mux"; id: ID; displayName: string; avatar?: Avatar };

export type Avatar = { monogram: string } | { image: AssetRef };

export interface Message {
  id: ID;
  senderId: ID;
  sentAt: Instant;
  /** At least one unless retracted. */
  parts: Part[];
  /** Thread root this replies to. */
  replyTo?: PartRef;
  status?: DeliveryStatus;
  /** Prior versions, oldest first; parts hold the current text. */
  edits?: { text: string; at: Instant }[];
  retractedAt?: Instant;
  reactions: Reaction[];
}

export interface PartRef {
  messageId: ID;
  partIndex: number;
}

export type DeliveryStatus =
  | { state: "sending" }
  | { state: "sent" }
  | { state: "delivered"; at: Instant }
  | { state: "read"; at: Instant }
  | { state: "failed"; reason?: string };

export type Part =
  | { type: "text"; text: string; runs?: TextRun[] }
  | {
      type: "link";
      url: string;
      title?: string;
      siteName?: string;
      image?: AssetRef;
      theme?: "light" | "dark";
    }
  | { type: "attachment"; attachment: Attachment }
  | { type: "location"; latitude: number; longitude: number; title?: string; subtitle?: string };

/** Ranges are UTF-16 code-unit offsets into the part's text. */
export interface TextRun {
  start: number;
  length: number;
  style?: ("bold" | "italic" | "underline" | "strikethrough")[];
  link?: string;
  mention?: ID;
  detected?: "date" | "phone" | "address";
}

export interface Attachment {
  id: ID;
  kind: "image" | "video" | "audio" | "voiceMemo" | "file" | "contact";
  fileName: string;
  mimeType: string;
  byteSize: number;
  asset?: AssetRef;
  poster?: AssetRef;
  width?: number;
  height?: number;
  durationSeconds?: number;
  transfer:
    | { state: "done" }
    | { state: "uploading" | "downloading"; progress: number }
    | { state: "failed" };
}

export type Tapback = "love" | "like" | "dislike" | "laugh" | "emphasize" | "question";

export interface Reaction {
  senderId: ID;
  partIndex: number;
  kind: { tapback: Tapback } | { emoji: string };
  at: Instant;
}

/** The viewer's side of a participant, derived at render time. */
export function isViewer(participant: Participant, viewerId: ID): boolean {
  return participant.kind === "human" && participant.id === viewerId;
}
