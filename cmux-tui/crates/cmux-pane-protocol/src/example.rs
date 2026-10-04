//! `com.example.hello`: the third-party example namespace the SDK lanes
//! build against. Declared here so the IR, the router tests and the example
//! provider binary share one definition.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub const APP_ID: &str = "com.example.hello";
pub const SCOPE: &str = "hello:read";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloParams {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloResult {
    pub message: String,
}

crate::pane_op! {
    /// Greet `name`.
    pub GreetOp {
        name: "com.example.hello.greet.say", kind: Read, scope: "hello:read",
        params: HelloParams, result: HelloResult,
        errors: [],
    }
}

crate::pane_op! {
    /// Wave at `name`; needs a user gesture (decision 29 vectors).
    pub GreetWaveOp {
        name: "com.example.hello.greet.wave", kind: Mutation, scope: "hello:write",
        params: HelloParams, result: HelloResult,
        errors: [],
        risk: MutateOwn,
        gesture: true,
    }
}

crate::pane_op! {
    /// Focus the greeting; a view-state op a `*view` gesture covers.
    pub GreetFocusOp {
        name: "com.example.hello.greet.focus", kind: Mutation, scope: "hello:write",
        params: HelloParams, result: HelloResult,
        errors: [],
        risk: MutateOwn,
        gesture: true,
        view_state: true,
    }
}

crate::pane_op! {
    /// A server-only op: refused for page tokens (decision 30 vectors).
    pub GreetAdminOp {
        name: "com.example.hello.greet.admin", kind: Mutation, scope: "op:com.example.hello.greet.admin",
        params: HelloParams, result: HelloResult,
        errors: [],
        risk: MutateOwn,
    }
}

crate::pane_event! {
    /// Three greetings, one per event (conformance: `seq` starts at 1).
    pub GreetTicks { name: "com.example.hello.greet.ticks", scope: "hello:read", data: HelloResult }
}

/// A provider serving the example op and event.
pub fn provider() -> crate::provider::Provider {
    let mut provider = crate::provider::Provider::new(APP_ID);
    provider.handle::<GreetOp, _, _>(|_claims, params: HelloParams| async move {
        Ok(HelloResult { message: format!("hello, {}", params.name) })
    });
    provider.handle::<GreetWaveOp, _, _>(|_claims, params: HelloParams| async move {
        Ok(HelloResult { message: format!("waved at {}", params.name) })
    });
    provider.handle::<GreetFocusOp, _, _>(|_claims, params: HelloParams| async move {
        Ok(HelloResult { message: format!("focused {}", params.name) })
    });
    provider.handle::<GreetAdminOp, _, _>(|_claims, params: HelloParams| async move {
        Ok(HelloResult { message: format!("admin {}", params.name) })
    });
    provider.source::<GreetTicks, _>(|_claims| {
        let (tx, rx) = tokio::sync::mpsc::channel(4);
        tokio::spawn(async move {
            for n in 1..=3 {
                let _ = tx.send(HelloResult { message: format!("tick {n}") }).await;
            }
        });
        rx
    });
    provider
}
