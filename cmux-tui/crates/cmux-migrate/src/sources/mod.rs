//! One reader per place people come from. Each takes a root it reads (a home folder, a checkout,
//! a file someone exported) and returns a [`crate::Plan`]; none writes, none talks to a network.
//! Commands that reach a network (an SSH host, a competitor's API) gather their facts in the CLI
//! and hand them here as plain data, so every reader is a pure function a test can feed.
