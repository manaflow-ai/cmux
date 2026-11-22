//! Windows service (system mode) and Scheduled Task (user mode)
//! (server.md 4.3). `cmux host run` answers the service control manager
//! when it runs as a service; that is the I/O crate's job.

use super::{HOST_RUN_ARGS, UnitError};
use crate::layout::{Layout, WINDOWS_SERVICE};
use crate::pg::valid_os_user;
use crate::platform::{InstallMode, Platform};

fn exe(layout: &Layout) -> Result<&str, UnitError> {
    let path = layout.current_cmux.as_str();
    if path.chars().any(|c| c.is_control() || matches!(c, '"' | '%' | '&' | '<' | '>')) {
        return Err(UnitError::UnsafePath("current_cmux"));
    }
    Ok(path)
}

/// `sc.exe create` argv: an auto-start service under the virtual account
/// `NT SERVICE\cmux-server` (no password). `sc.exe` wants each `name=` and
/// its value as separate arguments.
pub fn windows_service_create_argv(layout: &Layout) -> Result<Vec<String>, UnitError> {
    if layout.platform != Platform::Windows || layout.mode != InstallMode::System {
        return Err(UnitError::WrongLayout);
    }
    let bin_path = format!("\"{}\" {} --mode system", exe(layout)?, HOST_RUN_ARGS.join(" "));
    Ok([
        "sc.exe",
        "create",
        WINDOWS_SERVICE,
        "binPath=",
        &bin_path,
        "start=",
        "auto",
        "obj=",
        &format!("NT SERVICE\\{WINDOWS_SERVICE}"),
        "DisplayName=",
        "cmux server",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect())
}

/// `sc.exe failure` argv: restart after 2 s, 2 s, then 60 s; reset the
/// failure count after a day.
pub fn windows_service_failure_argv() -> Vec<String> {
    [
        "sc.exe",
        "failure",
        WINDOWS_SERVICE,
        "reset=",
        "86400",
        "actions=",
        "restart/2000/restart/2000/restart/60000",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect()
}

fn xml_escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Task Scheduler XML for user mode: start at the user's logon, run with
/// least privilege, never stop on battery or after a time limit, restart on
/// failure. `user` is `DOMAIN\name` or `name`. The I/O crate saves it as
/// UTF-16 and registers it with `schtasks /Create /XML`.
pub fn scheduled_task_xml(layout: &Layout, user: &str) -> Result<String, UnitError> {
    if layout.platform != Platform::Windows || layout.mode != InstallMode::User {
        return Err(UnitError::WrongLayout);
    }
    let valid_user = match user.split_once('\\') {
        Some((domain, name)) => {
            !domain.is_empty()
                && domain.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.')
                && valid_os_user(name)
        }
        None => valid_os_user(user),
    };
    if !valid_user {
        return Err(UnitError::BadUser);
    }
    let command = xml_escape(exe(layout)?);
    let user = xml_escape(user);
    let args = format!("{} --mode user", HOST_RUN_ARGS.join(" "));
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?>
<Task version=\"1.4\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">
  <RegistrationInfo>
    <Description>cmux server</Description>
    <URI>\\cmux-server</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id=\"Author\">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context=\"Author\">
    <Exec>
      <Command>{command}</Command>
      <Arguments>{args}</Arguments>
    </Exec>
  </Actions>
</Task>
"
    ))
}
