//! cmux NEXT's workspace creation rules, moved out of the macOS app's Swift (cmuxterm-hq
//! `docs/rfd/drafts/why-swift.md`: Swift keeps the windows, views and the daemon socket; Rust
//! holds the rules). Step A of a two-step port: the Swift copy stays until the app FFI's repin
//! lets step B call these ops and delete it.
//!
//! Pure: the app reports the facts and applies the result. It reaches the rules through the app
//! FFI's JSON channel (cmux-layout-reducer-ffi `cmux_layout_reducer_json`, ops in [`ops`]).
//!
//! - [`spawn`]: what a new workspace starts with (`WorkspaceSpawn`): its arguments from `newTab`'s
//!   invocation, its folder, row name, first terminal's start and whether it shows before the
//!   daemon answers.
//! - [`naming`]: the daemon's next default name (`SidebarMapping.defaultWorkspaceName`).
//! - [`env`]: the placement keys hooks read and the old app's id form
//!   (`DaemonConnection.placementEnvironment`, `uuidForm`).
//! - [`placement`]: the `workspaces.newPlacement` rule a create's row and move use
//!   (`NewWorkspaceDefaultSlot.anchored`, `WorkspaceSpawn.placement`).
//! - [`request`]: the create's requests (`NewTerminalWorkspace.applied`, one request or two) and
//!   what each creating request made (`createdObjects`).
//! - [`session_tab`]: a first chat tab's refusals and key (`WorkspaceCreation.sessionTab`).
//! - [`half_created`]: what a failed step does to the workspace (`EmptyWorkspaceRepair.withTerminal`,
//!   `WorkspaceCreation.closeHalfCreated`).
//! - [`new_workspace`]: `newTab`'s decisions (`AppActions.newWorkspace`, `NewWorkspaceFocus`).
//! - [`spawner`]: one create's plan from the press (`WorkspaceSpawner.start`, `create`, `shown`).

pub mod env;
pub mod half_created;
pub mod naming;
pub mod new_workspace;
pub mod ops;
pub mod path;
pub mod placement;
pub mod request;
pub mod session_tab;
pub mod spawn;
pub mod spawner;
