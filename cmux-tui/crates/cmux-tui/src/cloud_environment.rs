//! The app bundle's persisted NEXT Cloud selection, shared by CLI and daemon.

use cmux_cloud_environment::{Resolver, Selection};

pub(crate) fn current() -> Result<Option<Selection>, String> {
    let exe = std::env::current_exe().ok();
    let Some(identity) =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
    else {
        return Ok(None);
    };
    let build = identity.build();
    let Some(bundle) = build.bundle_id() else { return Ok(None) };
    // Classic callers retain their existing deployment and override behavior.
    // NEXT sets this marker on its own daemon, even for locked Release/RC.
    if bundle != "com.cmuxterm.app.nightly.cmux-next"
        && std::env::var("CMUX_NEXT_CLOUD_RUNTIME").as_deref() != Ok("1")
    {
        return Ok(None);
    }
    let home = std::env::var_os("HOME").ok_or("HOME is unavailable.")?;
    let resolver = Resolver::new(bundle, std::path::Path::new(&home))?;
    resolver.resolve(std::env::var("CMUX_NEXT_CLOUD_ENV").ok().as_deref()).map(Some)
}
