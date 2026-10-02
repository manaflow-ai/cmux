//! launchd property lists (server.md 4.3; 9.3 `restart.notLoggedIn`).

use super::{HOST_RUN_ARGS, UnitError};
use crate::layout::{LAUNCHD_LABEL, Layout, ServiceKind};
use crate::pg::valid_os_user;
use crate::platform::{InstallMode, Platform};

fn xml_escape(value: &str) -> Result<String, UnitError> {
    if value.chars().any(|c| c.is_control()) {
        return Err(UnitError::UnsafePath("control character"));
    }
    Ok(value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;"))
}

fn plist(layout: &Layout, user: Option<&str>) -> Result<String, UnitError> {
    let mut args = vec![layout.current_cmux.to_string()];
    args.extend(HOST_RUN_ARGS.iter().map(|s| (*s).to_owned()));
    let mut body = String::new();
    body.push_str(&format!("  <key>Label</key>\n  <string>{LAUNCHD_LABEL}</string>\n"));
    if let ServiceKind::AppServiceAgent { .. } = layout.service {
        // SMAppService resolves the program inside the app bundle.
        body.push_str("  <key>BundleProgram</key>\n  <string>Contents/Resources/bin/cmux</string>\n");
    }
    body.push_str("  <key>ProgramArguments</key>\n  <array>\n");
    for arg in &args {
        body.push_str(&format!("    <string>{}</string>\n", xml_escape(arg)?));
    }
    body.push_str("  </array>\n");
    if let Some(user) = user {
        body.push_str(&format!("  <key>UserName</key>\n  <string>{}</string>\n", xml_escape(user)?));
    }
    let mode = match layout.mode {
        InstallMode::User => "user",
        InstallMode::System => "system",
    };
    body.push_str(&format!(
        "  <key>EnvironmentVariables</key>\n  <dict>\n    <key>CMUX_SERVER_MODE</key>\n    <string>{mode}</string>\n  </dict>\n"
    ));
    body.push_str("  <key>RunAtLoad</key>\n  <true/>\n");
    body.push_str("  <key>KeepAlive</key>\n  <true/>\n");
    body.push_str("  <key>ProcessType</key>\n  <string>Standard</string>\n");
    body.push_str("  <key>ThrottleInterval</key>\n  <integer>2</integer>\n");
    let log = xml_escape(layout.logs().join("server.log").as_str())?;
    body.push_str(&format!("  <key>StandardOutPath</key>\n  <string>{log}</string>\n"));
    body.push_str(&format!("  <key>StandardErrorPath</key>\n  <string>{log}</string>\n"));
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
{body}</dict>
</plist>
"
    ))
}

/// `~/Library/LaunchAgents/com.cmux.server.plist`, or the plist bundled in
/// the app for `SMAppService.agent`. Runs only while the user is logged in.
pub fn launch_agent_plist(layout: &Layout) -> Result<String, UnitError> {
    if layout.platform != Platform::MacOs || layout.mode != InstallMode::User {
        return Err(UnitError::WrongLayout);
    }
    plist(layout, None)
}

/// `/Library/LaunchDaemons/com.cmux.server.plist`: starts at boot without a
/// login and runs as `user` (the installing user for a user-mode layout, the
/// service user for a system-mode layout). Installed by the
/// `restart.notLoggedIn` fix with admin rights once.
pub fn launch_daemon_plist(layout: &Layout, user: &str) -> Result<String, UnitError> {
    if layout.platform != Platform::MacOs {
        return Err(UnitError::WrongLayout);
    }
    if !valid_os_user(user) {
        return Err(UnitError::BadUser);
    }
    plist(layout, Some(user))
}
