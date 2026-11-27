//! Browser config and how it applies to new browser surfaces.

use super::*;

#[derive(Debug, Clone)]
pub struct Browser {
    pub cdp_url: Option<String>,
    pub max_capture_megapixels: f64,
    pub capture_scale: Option<f64>,
}

impl Default for Browser {
    fn default() -> Self {
        Browser {
            cdp_url: None,
            max_capture_megapixels: TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            capture_scale: None,
        }
    }
}

pub fn apply_browser_to_surface_options(config: &Config, options: &mut SurfaceOptions) {
    options.cdp_url = config.browser.cdp_url.clone();
    options.browser_max_capture_megapixels = config.browser.max_capture_megapixels;
    options.browser_capture_scale = config.browser.capture_scale;
}
