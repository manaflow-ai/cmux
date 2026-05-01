//! Integration-test entry points. This file exists only so the
//! `tests/integration.zig` test module can reach into src/ through a
//! single named module without duplicating file ownership (Zig modules
//! must not share source files, and `../src/...` relative imports from a
//! test module rooted under `tests/` are not allowed).
//!
//! Keep this thin: re-export types/functions the test suite needs and
//! nothing more. This file is NOT used by the production daemon binary.

pub const json_rpc = @import("json_rpc.zig");
pub const connection_attachments = @import("connection_attachments.zig");
pub const outbound_queue = @import("outbound_queue.zig");
pub const pty_pump = @import("pty_pump.zig");
pub const server_core = @import("server_core.zig");
pub const service_command = @import("service_command.zig");
pub const session_registry = @import("session_registry.zig");
pub const session_service = @import("session_service.zig");
