//! Browser panes from a pane split (`pane-browser-kind-v1`).
//!
//! Raw `split` and `new-pane-right` with `kind: "browser"` put the
//! daemon-internal field [`PANE_BROWSER_URL_FIELD`] on the `pane.split`
//! intent. Staging then reserves a browser identity in place of a terminal,
//! the effect spawns a browser surface in the new pane, and restart recovery
//! looks for browser evidence. Public v2 `pane.split` never carries the field:
//! its catalog entry refuses extra fields and its result is a terminal path.

use crate::Actor;
use super::*;

/// Daemon-internal `pane.split` field: the new pane holds a browser at this
/// URL instead of a terminal.
pub(crate) const PANE_BROWSER_URL_FIELD: &str = "pane_browser_url";

/// Fields that only a terminal pane can use.
const TERMINAL_ONLY_FIELDS: [&str; 5] = ["cwd", "env", "argv", "shell", RESERVED_TERMINAL_ID_FIELD];

/// The browser URL of a `pane.split` intent, when it creates a browser.
pub(super) fn pane_browser_url(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<&str>> {
    if operation != ResourceOperation::PaneSplit {
        return Ok(None);
    }
    fields
        .get(PANE_BROWSER_URL_FIELD)
        .map(|url| url.as_str().context("browser pane URL must be a string"))
        .transpose()
}

/// What a created-path operation creates, after its fields are known.
pub(super) fn creation_identity_kind(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> Option<CreatedIdentityKind> {
    if operation == ResourceOperation::PaneSplit && fields.contains_key(PANE_BROWSER_URL_FIELD) {
        return Some(CreatedIdentityKind::Browser);
    }
    created_identity_kind(operation)
}

/// `pane.split` field rules for a browser pane: a non-empty URL and no
/// terminal-only field.
pub(super) fn validate_pane_browser_fields(fields: &Map<String, Value>) -> anyhow::Result<()> {
    let Some(url) = pane_browser_url(ResourceOperation::PaneSplit, fields)? else {
        return Ok(());
    };
    anyhow::ensure!(!url.is_empty(), "browser URL is empty");
    if let Some(field) = TERMINAL_ONLY_FIELDS.iter().find(|field| fields.contains_key(**field)) {
        anyhow::bail!("bad request: {field} applies only to a terminal pane");
    }
    Ok(())
}

/// The surface a pane-adding effect spawned, before it is attached.
pub(super) enum SpawnedPaneSurface<'a> {
    Terminal(Arc<Surface>),
    /// The guard keeps the surface's workspace known until it is attached.
    Browser {
        surface: Arc<Surface>,
        _pending: PendingWorkspaceSurface<'a>,
    },
}

impl SpawnedPaneSurface<'_> {
    pub(super) fn surface(&self) -> &Arc<Surface> {
        match self {
            Self::Terminal(surface) | Self::Browser { surface, .. } => surface,
        }
    }
}

impl Mux {
    /// Raw `split` (and `new-pane-right` with `viewport_width`) whose new
    /// pane holds a browser at `url`. Same commit path as a terminal split.
    pub(crate) fn split_browser_pane_as(self: &Arc<Self>, actor: &Actor, target: PaneId, dir: SplitDir, viewport_width: Option<f32>, url: String, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff =
            self.resource_creation_handoff.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(width) = viewport_width
            && (!width.is_finite()
                || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width))
        {
            return Err(ViewportWidthError::OutOfRange { width }.into());
        }
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let direction = match dir {
            SplitDir::Right => "right",
            SplitDir::Down => "down",
        };
        let mut fields = Map::from_iter([
            ("direction".into(), Value::String(direction.into())),
            (PANE_BROWSER_URL_FIELD.into(), Value::String(url)),
        ]);
        if let Some(width) = viewport_width {
            fields.insert("viewport_width".into(), Value::from(width));
        }
        Self::insert_cell_size(&mut fields, size);
        let commit = self
            .commit_ordinary_topology_operation_by(actor, ResourceOperation::PaneSplit, selectors, fields)
            .map_err(|error| {
                // As `new_pane_right_with_options`: caller input errors stay
                // visible; a viewport column's creation failure is generic.
                let message = error.to_string();
                if viewport_width.is_none() || message.starts_with("bad request") {
                    return error;
                }
                eprintln!("cmux-tui: viewport browser pane creation failed: {error:#}");
                anyhow::anyhow!("pane creation failed")
            })?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Spawn the content of a pane that `effect_add_pane` attaches: a browser
    /// for a browser-pane intent, otherwise a terminal with the intent's
    /// terminal reservation.
    pub(super) fn effect_spawn_pane_surface(
        self: &Arc<Self>,
        intent: &Value,
        target: PaneId,
        workspace_key: &str,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SpawnedPaneSurface<'_>> {
        let fields =
            intent["fields"].as_object().context("stored topology intent omitted fields")?;
        if let Some(url) = pane_browser_url(ResourceOperation::PaneSplit, fields)? {
            let identity = self.effect_browser_reservation(intent)?;
            let workspace = self
                .with_state(|state| {
                    state.screen_of(target).map(|(workspace, _)| state.workspaces[workspace].id)
                })
                .with_context(|| format!("pane {target} has no workspace"))?;
            let surface = self.spawn_browser_surface_with_resource_identity(
                url.to_string(),
                size,
                Some(workspace),
                Some(identity),
            )?;
            let pending = self.pending_workspace_surface(surface.id);
            return Ok(SpawnedPaneSurface::Browser { surface, _pending: pending });
        }
        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let reservation = self.effect_terminal_reservation(
            intent,
            workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            None,
            size,
            None,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(workspace_key, cwd, size, argv, reservation)?;
        Ok(SpawnedPaneSurface::Terminal(surface))
    }

    /// Undo a spawned pane surface whose pane could not be attached.
    pub(super) fn fail_pane_surface_attachment(
        &self,
        spawned: &SpawnedPaneSurface<'_>,
    ) -> anyhow::Result<()> {
        match spawned {
            SpawnedPaneSurface::Terminal(surface) => self.fail_hosted_terminal_attachment(
                surface,
                "resource-terminal-pane-attach-failed",
                "pane-disappeared-before-attach",
            ),
            SpawnedPaneSurface::Browser { surface, .. } => {
                self.state
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .surfaces
                    .remove(&surface.id);
                surface.kill();
                Ok(())
            }
        }
    }
}

/// Cell size for a browser created from pixel fields (`tab.create_browser`).
pub(super) fn effect_browser_cell_size(
    mux: &Mux,
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<(u16, u16)>> {
    let (width, height) = match (
        fields.get("width_px").and_then(Value::as_u64),
        fields.get("height_px").and_then(Value::as_u64),
    ) {
        (None, None) => return Ok(None),
        (Some(width), Some(height)) => (width, height),
        _ => anyhow::bail!("width_px and height_px must be paired"),
    };
    let (cell_width, cell_height) = mux.cell_pixel_size();
    let columns = width
        .checked_add(u64::from(cell_width).saturating_sub(1))
        .context("browser width overflows")?
        / u64::from(cell_width.max(1));
    let rows = height
        .checked_add(u64::from(cell_height).saturating_sub(1))
        .context("browser height overflows")?
        / u64::from(cell_height.max(1));
    Ok(Some((
        u16::try_from(columns).context("browser width exceeds terminal geometry")?,
        u16::try_from(rows).context("browser height exceeds terminal geometry")?,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    /// Restart recovery looks for the right evidence: a browser-pane split
    /// was a browser creation, a plain split a terminal creation.
    #[test]
    fn browser_pane_split_recovers_as_a_browser_creation() {
        let browser = fields(json!({"direction":"right", PANE_BROWSER_URL_FIELD:"https://a.test"}));
        let terminal = fields(json!({"direction":"right"}));
        assert_eq!(
            creation_identity_kind(ResourceOperation::PaneSplit, &browser),
            Some(CreatedIdentityKind::Browser)
        );
        assert_eq!(
            creation_identity_kind(ResourceOperation::PaneSplit, &terminal),
            Some(CreatedIdentityKind::Terminal)
        );
        assert_eq!(
            creation_identity_kind(ResourceOperation::PaneCreate, &browser),
            Some(CreatedIdentityKind::Terminal),
            "only pane.split reads the browser field"
        );
    }

    #[test]
    fn browser_pane_fields_refuse_terminal_fields_and_empty_urls() {
        let url = "https://a.test";
        assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:url}))).is_ok());
        assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:""}))).is_err());
        assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:3}))).is_err());
        for field in TERMINAL_ONLY_FIELDS {
            let mut request = fields(json!({PANE_BROWSER_URL_FIELD:url}));
            request.insert(field.to_string(), json!("x"));
            assert!(validate_pane_browser_fields(&request).is_err(), "{field}");
        }
    }
}
