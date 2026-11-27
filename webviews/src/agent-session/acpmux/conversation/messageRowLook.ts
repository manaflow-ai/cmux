import { createContext, useContext } from "react";

/// How the one message row (AgentMessageRow.tsx) draws a sent message, a received one and a
/// subagent's report (Leo, 2026-11-07, on a "Sent to" row, a received one and a "Subagent
/// finished" one: "why is it formatted differently from everything else? ... They should look
/// basically the same as the other ones"). Every kind takes the same header and the same body.
/// `card`, the default: the opened message in the rounded glass card a received message always had
/// (the look Leo pointed at as the good one), and an unverified sender's marker right after its name.
/// The others are gallery versions kept beside it (AgentMessageRowKinds.gallery.tsx): `corner`, the
/// marker as a dot on the icon's corner, the card the same; `flat`, the marker after the name and the
/// message flush at the text column with no card (the sent row's look before).
export type MessageRowLook = "card" | "corner" | "flat";

export const MessageRowLookContext = createContext<MessageRowLook>("card");

/// The look the row draws in.
export const useMessageRowLook = (): MessageRowLook => useContext(MessageRowLookContext);
