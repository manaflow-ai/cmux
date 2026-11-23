//! Receipted creation: the idempotency receipt a tab, pane, split, screen or
//! workspace create carries, the ambiguous-timeout error that retries it, and
//! the `Session` methods that send those creates.

use super::*;

#[derive(Clone, Debug)]
pub(crate) struct CreationReceipt {
    origin: String,
    id: String,
}

impl CreationReceipt {
    pub(crate) fn new() -> Self {
        Self { origin: "cmux-tui".to_string(), id: uuid::Uuid::new_v4().to_string() }
    }
}

#[derive(Clone)]
pub(crate) struct AmbiguousCreation {
    remote: Arc<RemoteSession>,
    request: Value,
    created: &'static str,
}

impl std::fmt::Debug for AmbiguousCreation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AmbiguousCreation")
            .field("created", &self.created)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Display for AmbiguousCreation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} creation response timed out", self.created)
    }
}

impl std::error::Error for AmbiguousCreation {}

impl AmbiguousCreation {
    pub(crate) fn retry(&self) -> anyhow::Result<SurfaceId> {
        request_receipted_creation(&self.remote, self.request.clone(), self.created)
    }
}

fn request_receipted_creation(
    remote: &Arc<RemoteSession>,
    request: Value,
    created: &'static str,
) -> anyhow::Result<SurfaceId> {
    match remote.request(request.clone()) {
        Ok(result) => response_surface(&result, created),
        Err(error) if is_remote_timeout(&error) => {
            Err(AmbiguousCreation { remote: remote.clone(), request, created }.into())
        }
        Err(error) => Err(error),
    }
}

fn creation_fields(size: Option<(u16, u16)>) -> Map<String, Value> {
    let mut fields = Map::new();
    if let Some((cols, rows)) = size {
        fields.insert("cols".to_string(), json!(cols));
        fields.insert("rows".to_string(), json!(rows));
    }
    fields
}

fn creation_mutation(receipt: &CreationReceipt) -> anyhow::Result<WorkspaceMutation> {
    WorkspaceMutation::by_local_user(receipt.id.clone(), receipt.origin.clone())
}

fn creation_selector_fallbacks(
    remote: &RemoteSession,
    candidates: Vec<ResourceSelectors>,
) -> Vec<ResourceSelectors> {
    if remote.supports_capability(CREATION_SELECTOR_FALLBACKS_CAPABILITY) {
        candidates
    } else {
        Vec::new()
    }
}

fn response_surface(result: &Value, created: &str) -> anyhow::Result<SurfaceId> {
    result
        .get("surface")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow::anyhow!("remote {created} creation omitted its surface"))
}

impl Session {
    fn pane_creation_selector_candidates(
        &self,
        pane: Option<PaneId>,
        mut candidates: Vec<ResourceSelectors>,
    ) -> anyhow::Result<Vec<ResourceSelectors>> {
        if candidates.is_empty() {
            candidates.push(
                self.tree()
                    .resource_selectors_for_pane(pane)
                    .ok_or_else(|| anyhow::anyhow!("pane has no stable resource identity"))?,
            );
        }
        let mut unique = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            if !unique.contains(&candidate) {
                unique.push(candidate);
            }
        }
        anyhow::ensure!(
            unique.len() <= MAX_CREATION_SELECTOR_FALLBACKS + 1,
            "creation accepts one primary selector and at most \
             {MAX_CREATION_SELECTOR_FALLBACKS} fallbacks"
        );
        Ok(unique)
    }

    pub(crate) fn new_tab_receipted(
        &self,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::TabCreateTerminal,
                    selector_candidates,
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-tab",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "tab",
                    );
                }
                let result =
                    remote.request(with_size(json!({"cmd": "new-tab", "pane": pane}), size))?;
                response_surface(&result, "tab")
            }
        }
    }

    pub(crate) fn run_command_receipted(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("argv".to_string(), json!(argv));
                if let Some(cwd) = cwd {
                    fields.insert("cwd".to_string(), json!(cwd));
                }
                mux.receipted_surface_creation(
                    ResourceOperation::PaneRun,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "run-command",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "argv": argv,
                                "pane": pane,
                                "cwd": cwd,
                            }),
                            size,
                        ),
                        "command",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "run", "argv": argv, "pane": pane, "cwd": cwd}),
                    size,
                ))?;
                response_surface(&result, "command")
            }
        }
    }

    pub(crate) fn new_browser_tab_receipted(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = Map::new();
                fields.insert("url".to_string(), json!(url));
                if let Some((cols, rows)) = size {
                    let (cell_width, cell_height) = mux.cell_pixel_size();
                    fields.insert(
                        "width_px".to_string(),
                        json!(u64::from(cols) * u64::from(cell_width)),
                    );
                    fields.insert(
                        "height_px".to_string(),
                        json!(u64::from(rows) * u64::from(cell_height)),
                    );
                }
                mux.receipted_surface_creation(
                    ResourceOperation::TabCreateBrowser,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if !remote.supports_browser_attach() {
                    anyhow::bail!("browser panes are not supported over attach yet");
                }
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-browser-tab",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "url": url,
                                "pane": pane,
                            }),
                            size,
                        ),
                        "browser",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-browser-tab", "url": url, "pane": pane}),
                    size,
                ))?;
                result
                    .get("surface")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| anyhow::anyhow!("remote browser creation omitted its surface"))
            }
        }
    }

    pub(crate) fn new_workspace_receipted(
        &self,
        size: Option<(u16, u16)>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("initial_content".to_string(), json!("terminal"));
                mux.receipted_surface_creation(
                    ResourceOperation::WorkspaceCreate,
                    vec![TreeView::session_resource_selectors()],
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = TreeView::session_resource_selectors();
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-workspace",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                            }),
                            size,
                        ),
                        "workspace",
                    );
                }
                let result = remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                response_surface(&result, "workspace")
            }
        }
    }

    pub(crate) fn new_screen_receipted(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let selectors = self
            .tree()
            .resource_selectors_for_workspace(workspace)
            .ok_or_else(|| anyhow::anyhow!("workspace has no stable resource identity"))?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::ScreenCreate,
                    vec![selectors],
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-screen",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "workspace": workspace,
                            }),
                            size,
                        ),
                        "screen",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-screen", "workspace": workspace}),
                    size,
                ))?;
                response_surface(&result, "screen")
            }
        }
    }

    pub(crate) fn split_receipted(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
        mut selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        let direction = match dir {
            SplitDir::Right => "right",
            SplitDir::Down => "down",
        };
        match self {
            Session::Local(mux) => {
                let mutation = creation_mutation(receipt)?;
                let mut fields = Map::new();
                fields.insert("direction".to_string(), json!(direction));
                if let Some((cols, rows)) = size {
                    fields.insert("cols".to_string(), json!(cols));
                    fields.insert("rows".to_string(), json!(rows));
                }
                mux.receipted_surface_creation(
                    ResourceOperation::PaneSplit,
                    selector_candidates,
                    fields,
                    &mutation,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": format!("split-{direction}"),
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "split",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "split", "pane": pane, "dir": direction}),
                    size,
                ))?;
                response_surface(&result, "split")
            }
        }
    }

    pub(crate) fn new_pane_receipted(
        &self,
        pane: PaneId,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::PaneCreate,
                    selector_candidates,
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-pane",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "pane",
                    );
                }
                let result =
                    remote.request(with_size(json!({"cmd": "new-pane", "pane": pane}), size))?;
                response_surface(&result, "pane")
            }
        }
    }

    pub(crate) fn new_pane_right_receipted(
        &self,
        pane: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        validate_viewport_width(width)?;
        let mut selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("direction".to_string(), json!("right"));
                fields.insert("viewport_width".to_string(), json!(width));
                mux.receipted_surface_creation(
                    ResourceOperation::PaneSplit,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if !remote.supports_capability(VIEWPORT_SPLITS_CAPABILITY) {
                    anyhow::bail!(
                        crate::localization::catalog().layout.remote_viewport_panes_unsupported
                    );
                }
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-pane-right",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                                "width": width,
                            }),
                            size,
                        ),
                        "pane",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-pane-right", "pane": pane, "width": width}),
                    size,
                ))?;
                response_surface(&result, "pane")
            }
        }
    }
}
