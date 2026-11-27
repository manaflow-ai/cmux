//! The JSON ops of `session.rs` and `tabs.rs` (the `CmuxNextRemoteViewSessions`
//! rules), on the same `cmux_rd_view_call` as the rest of `view/`. Their ops
//! carry the prefixes in `PREFIXES`; `view::call` hands those here first.

use serde::Deserialize;
use serde_json::{Value, json};

use super::session::{
    self, Endpoint, MakeContext, PageEvent, PageSession, PaneButton, RfbError, SourceFence,
    VncEvent, VncSession, WheelScroll,
};
use super::tab::{TabDecision, TabRecord};
use super::tabs::{self, LiveTab};

/// The op prefixes this module answers.
pub const PREFIXES: [&str; 5] = ["vnc.", "vncSource.", "page.", "pageTab.", "tabs."];

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum Request {
    #[serde(rename = "vnc.endpoint")]
    VncEndpoint {
        host: String,
        port: u16,
        #[serde(default = "mock_host")]
        demo_host: String,
    },
    #[serde(rename = "vnc.cloudEndpoint")]
    VncCloudEndpoint { host: String },
    #[serde(rename = "vnc.endFor")]
    VncEndFor {
        #[serde(default)]
        error: Option<RfbError>,
        #[serde(default)]
        had_credentials: bool,
    },
    #[serde(rename = "vnc.retryWait")]
    VncRetryWait { tries: u32 },
    #[serde(rename = "vnc.new")]
    VncNew {
        #[serde(default)]
        cloud: bool,
        #[serde(default)]
        demo: bool,
    },
    #[serde(rename = "vnc.reduce")]
    VncReduce { state: VncSession, event: VncEvent },
    #[serde(rename = "vnc.scroll")]
    VncScroll {
        #[serde(default)]
        state: WheelScroll,
        dx: i32,
        dy: i32,
        #[serde(default)]
        precise: bool,
    },
    #[serde(rename = "vnc.button")]
    VncButton { button: PaneButton },
    #[serde(rename = "vnc.credentialKey")]
    VncCredentialKey { endpoint: Endpoint },
    #[serde(rename = "vnc.debugCredentialsReadable")]
    VncDebugCredentialsReadable { mode: u32 },
    #[serde(rename = "vnc.signInIds")]
    VncSignInIds,
    #[serde(rename = "vncSource.connect")]
    SourceConnect { state: SourceFence },
    #[serde(rename = "vncSource.stop")]
    SourceStop { state: SourceFence },
    #[serde(rename = "vncSource.accepts")]
    SourceAccepts { state: SourceFence, generation: u64 },
    #[serde(rename = "page.make")]
    PageMake {
        record: TabRecord,
        #[serde(default)]
        context: MakeContext,
        #[serde(default)]
        display_name: Option<String>,
    },
    #[serde(rename = "page.startsInControl")]
    PageStartsInControl { record: TabRecord },
    #[serde(rename = "page.reduce")]
    PageReduce { state: PageSession, event: PageEvent },
    #[serde(rename = "page.selectMode")]
    PageSelectMode { state: PageSession, control: bool },
    #[serde(rename = "page.view")]
    PageView { state: PageSession },
    #[serde(rename = "pageTab.content")]
    PageTabContent { decision: TabDecision },
    #[serde(rename = "pageTab.gateTarget")]
    PageTabGateTarget {
        record: TabRecord,
        #[serde(default)]
        display_name: Option<String>,
    },
    #[serde(rename = "tabs.releaseMethods")]
    TabsReleaseMethods,
    #[serde(rename = "tabs.plan")]
    TabsPlan {
        tabs: Vec<LiveTab>,
        #[serde(default)]
        action: Option<String>,
        #[serde(default)]
        tab: Option<String>,
        #[serde(default)]
        mode: Option<String>,
        #[serde(default)]
        cloud_only: bool,
    },
    #[serde(rename = "tabs.rows")]
    TabsRows { tabs: Vec<LiveTab> },
}

fn mock_host() -> String {
    session::MOCK_HOST.to_owned()
}

#[derive(Deserialize)]
struct Op<'a> {
    #[serde(borrow)]
    op: std::borrow::Cow<'a, str>,
}

/// None when the request's op is not one of `PREFIXES` (or has no op).
pub fn call(request: &[u8]) -> Option<Result<Value, serde_json::Error>> {
    let op: Op = serde_json::from_slice(request).ok()?;
    if !PREFIXES.iter().any(|prefix| op.op.starts_with(prefix)) {
        return None;
    }
    Some(serde_json::from_slice(request).map(run))
}

pub fn run(request: Request) -> Value {
    use Request as R;
    match request {
        R::VncEndpoint { host, port, demo_host } => {
            let (endpoint, demo) = session::vnc_endpoint(&host, port, &demo_host);
            json!({"endpoint": endpoint, "demo": demo, "label": endpoint.label()})
        }
        R::VncCloudEndpoint { host } => {
            let endpoint = session::cloud_endpoint(&host);
            json!({"endpoint": endpoint, "label": endpoint.label()})
        }
        R::VncEndFor { error, had_credentials } => {
            json!(session::end_for(error, had_credentials))
        }
        R::VncRetryWait { tries } => json!(session::retry_wait_seconds(tries)),
        R::VncNew { cloud, demo } => json!(VncSession::new(cloud, demo)),
        R::VncReduce { mut state, event } => {
            let effects = state.reduce(event);
            json!({"state": state, "effects": effects})
        }
        R::VncScroll { mut state, dx, dy, precise } => {
            let (x, y) = state.add(dx, dy, precise);
            json!({"state": state, "x": x, "y": y})
        }
        R::VncButton { button } => json!(session::rfb_button(button)),
        R::VncCredentialKey { endpoint } => json!({
            "service": session::CREDENTIAL_SERVICE,
            "account": session::credential_account(&endpoint),
            "debugEnv": session::DEBUG_CREDENTIALS_ENV,
        }),
        R::VncDebugCredentialsReadable { mode } => json!(session::debug_file_readable(mode)),
        R::VncSignInIds => json!({
            "user": session::SIGN_IN_USER_FIELD,
            "password": session::SIGN_IN_PASSWORD_FIELD,
            "connect": session::SIGN_IN_CONNECT_BUTTON,
            "identifier": session::SIGN_IN_IDENTIFIER,
        }),
        R::SourceConnect { mut state } => {
            let generation = state.connect();
            json!({"state": state, "generation": generation})
        }
        R::SourceStop { mut state } => {
            let generation = state.stop();
            json!({"state": state, "generation": generation})
        }
        R::SourceAccepts { state, generation } => json!(state.accepts(generation)),
        R::PageMake { record, context, display_name } => {
            json!(session::make(&record, context, display_name.as_deref()))
        }
        R::PageStartsInControl { record } => json!(session::starts_in_control(&record)),
        R::PageReduce { mut state, event } => {
            let effects = state.reduce(event);
            json!({"state": state, "effects": effects})
        }
        R::PageSelectMode { mut state, control } => {
            let effects = state.select_mode(control);
            json!({"state": state, "changed": effects.is_some(), "effects": effects.unwrap_or_default()})
        }
        R::PageView { state } => json!({
            "source": state.kind.name(),
            "modeControl": state.mode_control(),
            "control": state.rd_control,
        }),
        R::PageTabContent { decision } => json!(tabs::content(decision)),
        R::PageTabGateTarget { record, display_name } => {
            json!(tabs::gate_target_name(&record, display_name.as_deref()))
        }
        R::TabsReleaseMethods => json!(tabs::RELEASE_METHODS),
        R::TabsPlan { tabs: live, action, tab, mode, cloud_only } => {
            json!(tabs::plan(&live, action.as_deref(), tab.as_deref(), mode.as_deref(), cloud_only))
        }
        R::TabsRows { tabs: live } => {
            json!({"tabs": live.iter().map(tabs::row).collect::<Vec<_>>()})
        }
    }
}
