//! Op and event declarations. Params, results and event data derive
//! `serde` and `schemars::JsonSchema`; [`pane_op!`](crate::pane_op) and
//! [`pane_event!`](crate::pane_event) declare the name, kind, scope and
//! errors next to the types, and [`crate::ir::Catalog`] collects them.

use schemars::JsonSchema;
use serde::Serialize;
use serde::de::DeserializeOwned;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OpKind {
    Read,
    Mutation,
    /// Opened with `open`; data flows on a credit-limited byte stream.
    Stream,
}

/// Whether agents see an op as an MCP tool (decision 21).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpExpose {
    /// Offered to agents by default.
    Default,
    /// Offered only after the user opts in.
    OptIn,
    /// Never offered (the default for an op that says nothing).
    Never,
}

/// An op's MCP exposure; `group` is a slice of at most one name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct McpSpec {
    pub expose: McpExpose,
    pub group: &'static [&'static str],
}

impl McpSpec {
    pub const NEVER: Self = Self { expose: McpExpose::Never, group: &[] };
}

/// An op's CLI verb: `path` relative to the app (`git status`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CliSpec {
    pub path: &'static str,
    pub visible: bool,
    /// Top-level params taken positionally.
    pub positional: &'static [&'static str],
}

/// One declared op.
pub trait Op: 'static {
    const NAME: &'static str;
    const KIND: OpKind;
    /// The scope a token must carry to call this op.
    const SCOPE: &'static str;
    /// Op-specific error codes (`<ns>.<code>`), beyond the protocol codes in
    /// [`crate::error`].
    const ERRORS: &'static [&'static str];
    /// Old wire names that still reach this op (`workspace.list`).
    const ALIASES: &'static [&'static str] = &[];
    /// Params that name a filesystem path. The provider canonicalizes each
    /// and refuses it unless it is inside one of the token's roots.
    const PATH_PARAMS: &'static [&'static str] = &[];
    /// MCP exposure; fail closed.
    const MCP: McpSpec = McpSpec::NEVER;
    /// The CLI verb, if any (zero or one entry).
    const CLI: &'static [CliSpec] = &[];
    type Params: Serialize + DeserializeOwned + JsonSchema + Send + 'static;
    type Result: Serialize + DeserializeOwned + JsonSchema + Send + 'static;
}

/// One declared event stream.
pub trait Event: 'static {
    const NAME: &'static str;
    const SCOPE: &'static str;
    type Data: Serialize + DeserializeOwned + JsonSchema + Send + 'static;
}

/// Declare an op:
///
/// ```ignore
/// pane_op! {
///     /// Working tree status.
///     pub GitStatusOp {
///         name: "cmux.git.status", kind: Read, scope: "git:read",
///         params: GitStatusParams, result: GitStatus,
///         errors: ["cmux.git.not_a_repo"],
///     }
/// }
/// ```
#[macro_export]
macro_rules! pane_op {
    ($(#[$meta:meta])* $vis:vis $marker:ident {
        name: $name:literal, kind: $kind:ident, scope: $scope:literal,
        params: $params:ty, result: $result:ty,
        errors: [$($error:literal),* $(,)?]
        $(, aliases: [$($alias:literal),* $(,)?])?
        $(, paths: [$($path:literal),* $(,)?])?
        $(, mcp: $expose:ident $(in $group:literal)?)?
        $(, cli: $cli:literal $(positional [$($positional:literal),* $(,)?])? $(visible $visible:literal)?)? $(,)?
    }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy)]
        $vis struct $marker;
        impl $crate::op::Op for $marker {
            const NAME: &'static str = $name;
            const KIND: $crate::op::OpKind = $crate::op::OpKind::$kind;
            const SCOPE: &'static str = $scope;
            const ERRORS: &'static [&'static str] = &[$($error),*];
            const ALIASES: &'static [&'static str] = &[$($($alias),*)?];
            const PATH_PARAMS: &'static [&'static str] = &[$($($path),*)?];
            $(const MCP: $crate::op::McpSpec = $crate::op::McpSpec {
                expose: $crate::op::McpExpose::$expose,
                group: &[$($group)?],
            };)?
            const CLI: &'static [$crate::op::CliSpec] = &[$($crate::op::CliSpec {
                path: $cli,
                // `visible false` hides the verb; the default is visible.
                visible: [$($visible,)? true][0],
                positional: &[$($($positional),*)?],
            })?];
            type Params = $params;
            type Result = $result;
        }
    };
}

/// Declare an event stream: `pane_event! { pub Marker { name: "...", scope: "...", data: Type } }`.
#[macro_export]
macro_rules! pane_event {
    ($(#[$meta:meta])* $vis:vis $marker:ident {
        name: $name:literal, scope: $scope:literal, data: $data:ty $(,)?
    }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy)]
        $vis struct $marker;
        impl $crate::op::Event for $marker {
            const NAME: &'static str = $name;
            const SCOPE: &'static str = $scope;
            type Data = $data;
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    crate::pane_op! {
        HiddenOp {
            name: "cmux.test.hidden.run", kind: Mutation, scope: "test:run",
            params: crate::example::HelloParams, result: crate::example::HelloResult,
            errors: [],
            mcp: OptIn,
            cli: "hidden run" positional ["name"] visible false,
        }
    }

    #[test]
    fn the_macro_sets_cli_visibility_and_defaults_it_to_visible() {
        assert!(!HiddenOp::CLI[0].visible);
        assert_eq!(HiddenOp::CLI[0].positional, ["name"]);
        assert_eq!(HiddenOp::MCP.expose, McpExpose::OptIn);
        assert!(crate::git::GitStatusOp::CLI[0].visible);
        assert_eq!(crate::git::GitStatusOp::PATH_PARAMS, ["cwd"]);
    }
}
