// The one place a transcript becomes read only (conversation/readOnly.ts): every context that carries
// an action on the owner's machine or daemon, or a reader of the owner's host, is provided empty
// here, whatever the page around it provides. VirtualTranscript `readOnly` draws inside it; the guest
// page does too. Hooks that ask the host by themselves (link and path answers, pull requests, image
// and media loads, bookmarks, frame pacing) read `useTranscriptReadOnly` and ask nothing.
//
// A new context that carries an owner action belongs in this list; guest-no-host-calls.test.tsx
// installs a spy for each and fails when one is reached from a read-only transcript.
import type { ReactNode } from "react";
import { BackgroundTaskOutputContext } from "./backgroundTaskOutput";
import { ArtifactContext } from "./artifactPreview";
import { ImageViewerContext } from "./imageViewerContext";
import { FailedSendsContext } from "./PromptDelivery";
import { TranscriptReadOnly } from "./readOnly";
import { RenderPages } from "./renderCall";
import { RunInBackgroundContext } from "./runInBackground";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { ChatAccountsContext } from "../chatAccounts";
import { SpeedToggleHost } from "../FastToggle";
import { UpdateOfferContext } from "../HarnessHealthNotice";
import { PromptFocus } from "../promptFocus";
import { ShellActionsContext } from "../shell/ShellRow";
import { SignInContext } from "../signIn";
import { SessionHoverContext } from "../started/SessionHoverCard";
import { NO_MENTIONS, StartedMentionsContext } from "../started/StartedSessionCard";
import { SubagentNavContext, SubagentPaneContext, SubagentStopContext } from "../subagents/SubagentGroup";
import { SubsessionContext } from "../subagents/subsessions";
import { AvatarContext } from "../../../pages/home-channels/avatars";

const NO_TURN_ACTIONS: TurnActions = {};

export function GuestActionsBoundary({ children }: { children: ReactNode }) {
  // Nested providers, outermost first; each value is "none".
  const providers: [React.Provider<any>, unknown][] = [
    [TranscriptReadOnly.Provider, true],
    [TurnActionsContext.Provider, NO_TURN_ACTIONS],
    [ShellActionsContext.Provider, undefined],
    [SubagentNavContext.Provider, undefined],
    [SubagentPaneContext.Provider, undefined],
    [SubagentStopContext.Provider, undefined],
    [SubsessionContext.Provider, null],
    [SessionHoverContext.Provider, null],
    [StartedMentionsContext.Provider, NO_MENTIONS],
    [ArtifactContext.Provider, undefined],
    [ImageViewerContext.Provider, undefined],
    [RenderPages.Provider, undefined],
    [RunInBackgroundContext.Provider, undefined],
    [BackgroundTaskOutputContext.Provider, undefined],
    [FailedSendsContext.Provider, undefined],
    [SignInContext.Provider, undefined],
    [ChatAccountsContext.Provider, undefined],
    [UpdateOfferContext.Provider, undefined],
    [SpeedToggleHost.Provider, null],
    [PromptFocus.Provider, null],
    [AvatarContext.Provider, undefined],
  ];
  return providers.reduceRight<ReactNode>(
    (inner, [Provider, value]) => <Provider value={value}>{inner}</Provider>,
    children,
  );
}
