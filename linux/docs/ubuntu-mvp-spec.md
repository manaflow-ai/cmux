# Ubuntu MVP Specification

## Status

This document defines the target for the `release/phase-1-mvp` PR stream.
Until this MVP lands, changes should be evaluated against this scope first.

## Product Thesis

The Ubuntu version of `cmux` should not be treated as "a terminal with a sidebar full of tabs."
Its defining value is that it helps users run several AI coding sessions in parallel and immediately understand:

1. which workspace needs attention,
2. why it needs attention,
3. how to jump back to the exact place that needs action.

The MVP succeeds if it preserves that value with the smallest possible feature set.

## North Star

When 4 to 8 Claude Code or Codex sessions are running at the same time, the user can identify the workspace that needs attention within one second and jump to it with a single action.

## Core UX Model

- The left sidebar answers: "Where should I go?"
- The top surface tabs answer: "Where inside this workspace should I look?"
- Notifications must add context, not just noise.
- Attention cues must be visible without stealing focus.

## MVP User Stories

### 1. Attention routing

As a user running multiple agent sessions, I can see which workspace needs me without reading every terminal.

### 2. Context at a glance

As a user, I can tell why a workspace needs attention from the sidebar alone.

### 3. Exact return target

As a user, I can jump to the latest unread workspace and see which pane or surface triggered the alert.

## In Scope

### Workspace model

- Multiple workspaces
- One or more terminal surfaces per workspace
- Vertical and horizontal splits
- Top tabs within a pane when multiple surfaces exist in that pane

### Notification flow

- Accept notifications from an external control path such as `cmux notify`
- Associate a notification with a workspace, and with a surface when available
- Track unread state
- Track the latest notification text for display in the sidebar
- Support a "jump to latest unread" action

### Sidebar information density

Each workspace row should show the minimum context needed to make routing decisions:

- workspace title,
- agent or status label when available,
- git branch or working directory,
- latest notification text,
- unread indicator.

### Attention highlighting

- Clear unread badge or equivalent state in the sidebar
- Strong visual emphasis for the selected workspace
- Visible pane or surface highlight for the source of the latest unread notification

## Non-Functional Requirements

- Low latency: notification-to-UI update should feel immediate
- No focus stealing: alerts must not switch workspaces automatically
- Keyboard-first: core flows must be accessible without the mouse
- Scanability: the sidebar must remain readable with at least 8 workspaces
- Native feel: the app should stay lightweight and terminal-first

## Explicit Non-Goals For MVP

The following are valuable, but not required for the MVP:

- in-app browser,
- pull request metadata,
- listening ports,
- advanced progress visualizations,
- rich notification history UI,
- drag-and-drop workspace management,
- deep customization or theming,
- fully automatic terminal escape-sequence notification capture.

If a feature does not improve the "notice -> identify -> jump" loop, it is probably out of scope for this phase.

## Acceptance Criteria

The MVP is complete when all of the following are true:

1. A user can create and switch between multiple workspaces.
2. A user can split terminals and use surface tabs inside a workspace.
3. An external notification can target a workspace and update unread state.
4. The sidebar shows enough context to distinguish active and waiting workspaces.
5. The user can jump to the latest unread workspace with one command or shortcut.
6. The pane or surface that triggered the alert is visually identifiable after the jump.
7. The interaction works without requiring desktop notifications to be the only signal.

## PR Guidance

For the current PR stream, preferred work is:

1. notification state and plumbing,
2. sidebar information architecture,
3. unread navigation,
4. pane or surface attention highlighting,
5. keyboard shortcuts for the core attention workflow.

Changes that mainly add breadth should wait until the loop above is solid.
