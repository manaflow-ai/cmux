use agent_client_protocol::{
    Client, CreateTerminalRequest, CreateTerminalResponse, Error, KillTerminalCommandRequest,
    KillTerminalCommandResponse, ReadTextFileRequest, ReadTextFileResponse, ReleaseTerminalRequest,
    ReleaseTerminalResponse, RequestPermissionOutcome, RequestPermissionRequest,
    RequestPermissionResponse, SessionNotification, TerminalOutputRequest, TerminalOutputResponse,
    WaitForTerminalExitRequest, WaitForTerminalExitResponse, WriteTextFileRequest,
    WriteTextFileResponse,
};
use anyhow::Result;
use tokio::sync::mpsc;

use crate::acp_client::events::AppEvent;
use crate::acp_client::logging::log_debug;

pub(crate) struct AppClient {
    pub(crate) tx: mpsc::UnboundedSender<AppEvent>,
}

#[async_trait::async_trait(?Send)]
impl Client for AppClient {
    async fn request_permission(
        &self,
        request: RequestPermissionRequest,
    ) -> Result<RequestPermissionResponse, Error> {
        log_debug(&format!("RequestPermission: {:?}", request));
        let option_id = request
            .options
            .first()
            .map(|o| o.id.clone())
            .unwrap_or(agent_client_protocol::PermissionOptionId("allow".into()));

        Ok(RequestPermissionResponse {
            outcome: RequestPermissionOutcome::Selected { option_id },
            meta: None,
        })
    }

    async fn read_text_file(
        &self,
        request: ReadTextFileRequest,
    ) -> Result<ReadTextFileResponse, Error> {
        log_debug(&format!("ReadTextFile: {:?}", request.path));
        match tokio::fs::read_to_string(&request.path).await {
            Ok(content) => Ok(ReadTextFileResponse {
                content,
                meta: None,
            }),
            Err(e) => {
                log_debug(&format!("ReadTextFile Error: {}", e));
                Err(Error::internal_error().with_data(e.to_string()))
            }
        }
    }

    async fn write_text_file(
        &self,
        request: WriteTextFileRequest,
    ) -> Result<WriteTextFileResponse, Error> {
        log_debug(&format!("WriteTextFile: {:?}", request.path));
        match tokio::fs::write(&request.path, &request.content).await {
            Ok(_) => Ok(WriteTextFileResponse::default()),
            Err(e) => Err(Error::internal_error().with_data(e.to_string())),
        }
    }

    async fn create_terminal(
        &self,
        _request: CreateTerminalRequest,
    ) -> Result<CreateTerminalResponse, Error> {
        Err(Error::internal_error().with_data("Terminal not supported yet"))
    }

    async fn terminal_output(
        &self,
        _request: TerminalOutputRequest,
    ) -> Result<TerminalOutputResponse, Error> {
        Err(Error::internal_error().with_data("Terminal not supported yet"))
    }

    async fn release_terminal(
        &self,
        _request: ReleaseTerminalRequest,
    ) -> Result<ReleaseTerminalResponse, Error> {
        Err(Error::internal_error().with_data("Terminal not supported yet"))
    }

    async fn wait_for_terminal_exit(
        &self,
        _request: WaitForTerminalExitRequest,
    ) -> Result<WaitForTerminalExitResponse, Error> {
        Err(Error::internal_error().with_data("Terminal not supported yet"))
    }

    async fn kill_terminal_command(
        &self,
        _request: KillTerminalCommandRequest,
    ) -> Result<KillTerminalCommandResponse, Error> {
        Err(Error::internal_error().with_data("Terminal not supported yet"))
    }

    async fn session_notification(&self, notification: SessionNotification) -> Result<(), Error> {
        log_debug(&format!("SessionNotification: {:?}", notification));
        let _ = self
            .tx
            .send(AppEvent::SessionUpdate(Box::new(notification)));
        Ok(())
    }
}
