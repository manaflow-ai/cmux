/// Transcript follow (RFD 0026, machine 3): whether the view follows the latest row, as one value.
///
/// It replaces VirtualTranscript's three refs (`followingRef`, `followDeferred`, `followRequest`) and
/// its `jumpTarget`, and reads no clock: the input hold's end comes in as `intentExpired`, carrying the
/// hold generation its timer was issued under (userScroll.ts). Pure: no React, no DOM; O(1) per event.
///
/// - `following`: the view sits at the latest row and each placement pass settles it there.
///   `request` is the input generation of an ask to follow now through the reader's input hold (a
///   send, Jump to latest, a move toward the latest row); a later input supersedes it.
/// - `held`: following, but the placement pass left the view at `place` because the reader's input
///   was held (`hold`, its hold generation); the hold's expiry settles it.
/// - `reading`: the reader is away from the latest row. `anchorRow` is the row the view last rested
///   on (none before the first scroll handler pass) and `offset` the scroll offset it rested at.
/// - `jumping`: Jump to latest's ride (or a send's) is in flight toward `target`, the latest row's
///   end; each placement pass retargets it, and it lands `following`.

export type FollowState =
  | { readonly kind: "following"; readonly request: number | undefined }
  | { readonly kind: "held"; readonly place: number; readonly hold: number }
  | { readonly kind: "reading"; readonly anchorRow: string | undefined; readonly offset: number }
  | { readonly kind: "jumping"; readonly target: number; readonly request: number | undefined };

/// A placement pass that laid the rows out again: rows above the view grew or arrived, rows below
/// it did (a reply streaming, a send's row), or the viewport resized. `top` is where the view is,
/// `latest` the layout's end offset, `input` the scroller's input generation now and `hold` its hold
/// generation while the reader's input holds automatic motion (undefined when it does not).
export type FollowLayout = {
  readonly top: number;
  readonly latest: number;
  readonly input: number;
  readonly hold: number | undefined;
};

export type FollowEvent =
  | ({ readonly type: "growAbove" } & FollowLayout)
  | ({ readonly type: "growBelow" } & FollowLayout)
  | ({ readonly type: "resize" } & FollowLayout)
  /// A reader input (a wheel, a key, a touch, a press) marked under input generation `generation`.
  | { readonly type: "wheel"; readonly generation: number }
  /// The scroll handler committed an offset: at the latest row, or not (where the reader rests).
  | {
      readonly type: "userScroll";
      readonly atLatest: boolean;
      readonly anchorRow: string | undefined;
      readonly offset: number;
    }
  /// Follow again (End, the reader reaching the end, a chat that opens, the pacer's recovery), with
  /// the input generation of an explicit ask (`request`) when there is one.
  | { readonly type: "follow"; readonly request: number | undefined }
  /// Stop following (a reader's move up, a reveal, Jump up, a ride replaced from outside).
  | { readonly type: "unfollow"; readonly anchorRow: string | undefined; readonly offset: number }
  /// The composer sent: follow through the hold, asked under input generation `generation`.
  | { readonly type: "send"; readonly generation: number }
  /// A ride to the latest row started toward `target`.
  | { readonly type: "jump"; readonly target: number }
  /// The ride landed or was stopped (stopJump): following from here.
  | { readonly type: "jumpEnded" }
  /// The input hold's timer fired, issued under hold generation `generation`.
  | { readonly type: "intentExpired"; readonly generation: number }
  /// The transcript shows another chat: nothing deferred or asked for in the old one carries over.
  | { readonly type: "sessionSwitched" };

export type FollowKind = FollowState["kind"];
export type FollowEventType = FollowEvent["type"];

/// What a step did, for the caller's effects and for the table. A refusal leaves the state as it was.
export type FollowOutcome =
  /// The placement pass settles the view at the latest row.
  | "settle"
  /// The placement pass leaves the view where it is: the reader's input holds it.
  | "hold"
  /// The ride in flight heads for the moved end.
  | "retarget"
  /// The anchor pass keeps the reader's row where it is drawn.
  | "anchor"
  /// The hold ended with follow-bottom deferred: the caller runs the deferred pass now.
  | "resume"
  | "followed"
  | "unfollowed"
  | "requested"
  | "rested"
  | "kept"
  | "jumped"
  | "landed"
  | "forgot";

export type FollowRefusal = "jumping" | "not_jumping" | "not_held" | "stale_generation";

export type FollowStep =
  | { readonly state: FollowState; readonly outcome: FollowOutcome }
  | { readonly state: FollowState; readonly refusal: FollowRefusal };

export const INITIAL_FOLLOW: FollowState = { kind: "following", request: undefined };

const following = (request: number | undefined): FollowState => ({ kind: "following", request });
const go = (state: FollowState, outcome: FollowOutcome): FollowStep => ({ state, outcome });
const refuse = (state: FollowState, refusal: FollowRefusal): FollowStep => ({ state, refusal });

/// Whether the view follows the latest row (every state but `reading`).
export const isFollowing = (state: FollowState) => state.kind !== "reading";

/// The ride's target while one is in flight.
export const jumpTargetOf = (state: FollowState) => (state.kind === "jumping" ? state.target : undefined);

/// Whether an explicit ask to follow is still live at input generation `input`: no input came since.
export const followRequested = (state: FollowState, input: number) =>
  (state.kind === "following" || state.kind === "jumping") && state.request === input;

/// Whether a pass would leave a followed view where it is: a ride owns the offset, or the reader's
/// input holds it (`held`) and nothing asked to follow through the hold.
export const followHeld = (state: FollowState, input: number, held: boolean) =>
  state.kind === "jumping" || (held && !followRequested(state, input));

function layout(state: FollowState, event: FollowLayout): FollowStep {
  switch (state.kind) {
    case "following":
    case "held": {
      const request = state.kind === "following" ? state.request : undefined;
      // An ask made at this input generation follows through the hold; an older one has lapsed.
      if (event.hold !== undefined && request !== event.input)
        return go({ kind: "held", place: event.top, hold: event.hold }, "hold");
      return go(following(request), "settle");
    }
    case "reading":
      return go(state, "anchor");
    case "jumping":
      return go({ kind: "jumping", target: event.latest, request: state.request }, "retarget");
  }
}

type Of<T extends FollowEventType> = Extract<FollowEvent, { type: T }>;

function wheel(state: FollowState, event: Of<"wheel">): FollowStep {
  switch (state.kind) {
    case "following":
      return go(state.request === event.generation ? state : following(undefined), "kept");
    case "jumping":
      return go(
        state.request === event.generation ? state : { kind: "jumping", target: state.target, request: undefined },
        "kept",
      );
    case "held":
    case "reading":
      return go(state, "kept");
  }
}

function userScroll(state: FollowState, event: Of<"userScroll">): FollowStep {
  const rest: FollowState = { kind: "reading", anchorRow: event.anchorRow, offset: event.offset };
  switch (state.kind) {
    case "following":
    case "held":
      return event.atLatest ? go(state, "kept") : go(rest, "unfollowed");
    // A ride's steps are the view following (handleScroll commits them at the latest row); only
    // stopJump or the ride's own end leaves it.
    case "jumping":
      return event.atLatest ? go(state, "kept") : refuse(state, "jumping");
    case "reading":
      return event.atLatest ? go(following(undefined), "followed") : go(rest, "rested");
  }
}

function follow(state: FollowState, event: Of<"follow">): FollowStep {
  const asked = event.request === undefined ? "kept" : "requested";
  switch (state.kind) {
    case "following":
      return go(following(event.request ?? state.request), asked);
    case "held":
      return event.request === undefined ? go(state, "kept") : go(following(event.request), "requested");
    case "reading":
      return go(following(event.request), "followed");
    case "jumping":
      return go({ kind: "jumping", target: state.target, request: event.request ?? state.request }, asked);
  }
}

function unfollow(state: FollowState, event: Of<"unfollow">): FollowStep {
  switch (state.kind) {
    case "following":
    case "held":
    case "reading":
      return go({ kind: "reading", anchorRow: event.anchorRow, offset: event.offset }, "unfollowed");
    // Before this machine a ride went on through an unfollow (its next step followed again); the
    // reader's own input stops the ride first (stopJump), then unfollows.
    case "jumping":
      return refuse(state, "jumping");
  }
}

function send(state: FollowState, event: Of<"send">): FollowStep {
  switch (state.kind) {
    case "following":
    case "held":
      return go(following(event.generation), "requested");
    case "reading":
      return go(following(event.generation), "followed");
    case "jumping":
      return go({ kind: "jumping", target: state.target, request: event.generation }, "requested");
  }
}

function jump(state: FollowState, event: Of<"jump">): FollowStep {
  switch (state.kind) {
    case "following":
    case "jumping":
      return go({ kind: "jumping", target: event.target, request: state.request }, "jumped");
    case "held":
    case "reading":
      return go({ kind: "jumping", target: event.target, request: undefined }, "jumped");
  }
}

function jumpEnded(state: FollowState): FollowStep {
  switch (state.kind) {
    case "jumping":
      return go(following(state.request), "landed");
    case "following":
    case "held":
    case "reading":
      return refuse(state, "not_jumping");
  }
}

function intentExpired(state: FollowState, event: Of<"intentExpired">): FollowStep {
  switch (state.kind) {
    case "held":
      // A timer issued before this hold began cannot end it.
      return event.generation < state.hold ? refuse(state, "stale_generation") : go(following(undefined), "resume");
    case "following":
    case "reading":
    case "jumping":
      return refuse(state, "not_held");
  }
}

function sessionSwitched(state: FollowState): FollowStep {
  switch (state.kind) {
    case "following":
    case "held":
      return go(following(undefined), "forgot");
    case "jumping":
      return go({ kind: "jumping", target: state.target, request: undefined }, "forgot");
    case "reading":
      return go(state, "forgot");
  }
}

/// The transition for every (state, event) pair: no default arm anywhere here, so a new state or
/// event does not compile until each pair is a transition or a named refusal.
export function stepFollow(state: FollowState, event: FollowEvent): FollowStep {
  switch (event.type) {
    case "growAbove":
    case "growBelow":
    case "resize":
      return layout(state, event);
    case "wheel":
      return wheel(state, event);
    case "userScroll":
      return userScroll(state, event);
    case "follow":
      return follow(state, event);
    case "unfollow":
      return unfollow(state, event);
    case "send":
      return send(state, event);
    case "jump":
      return jump(state, event);
    case "jumpEnded":
      return jumpEnded(state);
    case "intentExpired":
      return intentExpired(state, event);
    case "sessionSwitched":
      return sessionSwitched(state);
  }
}

/// One representative of each state, and of each event with every branch its payload can take, for
/// the table and the exhaustive test.
export const FOLLOW_STATE_SAMPLES: Readonly<Record<string, FollowState>> = {
  following: { kind: "following", request: undefined },
  "following(request)": { kind: "following", request: 7 },
  held: { kind: "held", place: 120, hold: 3 },
  reading: { kind: "reading", anchorRow: "row-4", offset: 80 },
  jumping: { kind: "jumping", target: 900, request: undefined },
  "jumping(request)": { kind: "jumping", target: 900, request: 7 },
};

const pass = { top: 400, latest: 1000, input: 7 };
export const FOLLOW_EVENT_SAMPLES: Readonly<Record<string, FollowEvent>> = {
  growAbove: { type: "growAbove", ...pass, hold: undefined },
  "growAbove(held)": { type: "growAbove", ...pass, hold: 3 },
  growBelow: { type: "growBelow", ...pass, hold: undefined },
  "growBelow(held)": { type: "growBelow", ...pass, hold: 3 },
  resize: { type: "resize", ...pass, hold: undefined },
  "resize(held)": { type: "resize", ...pass, hold: 3 },
  "wheel(same)": { type: "wheel", generation: 7 },
  "wheel(newer)": { type: "wheel", generation: 8 },
  "userScroll(latest)": { type: "userScroll", atLatest: true, anchorRow: undefined, offset: 1000 },
  "userScroll(away)": { type: "userScroll", atLatest: false, anchorRow: "row-2", offset: 40 },
  follow: { type: "follow", request: undefined },
  "follow(request)": { type: "follow", request: 8 },
  unfollow: { type: "unfollow", anchorRow: "row-2", offset: 40 },
  send: { type: "send", generation: 8 },
  jump: { type: "jump", target: 1000 },
  jumpEnded: { type: "jumpEnded" },
  "intentExpired(stale)": { type: "intentExpired", generation: 2 },
  intentExpired: { type: "intentExpired", generation: 3 },
  sessionSwitched: { type: "sessionSwitched" },
};

/// The machine as data (RFD 0026 rule 4), committed at schemas/transcript-follow/table.json.
export function followTable() {
  const rows: { state: string; event: string; to: FollowKind; outcome?: FollowOutcome; refusal?: FollowRefusal }[] = [];
  for (const [state, from] of Object.entries(FOLLOW_STATE_SAMPLES))
    for (const [event, input] of Object.entries(FOLLOW_EVENT_SAMPLES)) {
      const step = stepFollow(from, input);
      rows.push({
        state,
        event,
        ...("refusal" in step ? { refusal: step.refusal } : { outcome: step.outcome }),
        to: step.state.kind,
      });
    }
  return {
    source: "webviews/src/agent-session/acpmux/conversation/followState.ts",
    states: ["following", "held", "reading", "jumping"] satisfies FollowKind[],
    events: [
      "growAbove",
      "growBelow",
      "resize",
      "wheel",
      "userScroll",
      "follow",
      "unfollow",
      "send",
      "jump",
      "jumpEnded",
      "intentExpired",
      "sessionSwitched",
    ] satisfies FollowEventType[],
    refusals: ["jumping", "not_jumping", "not_held", "stale_generation"] satisfies FollowRefusal[],
    generations:
      "intentExpired carries the hold generation its timer was issued under; one issued before the held state began is refused stale_generation. A request carries the input generation it was asked under and lapses at the next input.",
    transitions: rows,
  };
}
