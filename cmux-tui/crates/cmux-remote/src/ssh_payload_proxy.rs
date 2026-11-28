//! Proxy routes for SSH payload downloads.
//!
//! curl reads proxies only from environment variables, which a Mac app does not
//! inherit. A Mac that reaches the internet only through the proxy or PAC script
//! set in System Settings would then fail to download a payload. On macOS this
//! asks CFNetwork for the routes URLSession would use for the URL, in order,
//! including a PAC file's `PROXY a; DIRECT` fallbacks.

/// One way to reach a payload URL.
// Only the macOS resolver builds routes.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProxyRoute {
    Direct,
    /// A curl proxy URL: `http://host:port` or `socks5h://host:port`.
    Via(String),
}

impl ProxyRoute {
    pub(crate) fn curl_args(&self) -> [&str; 2] {
        match self {
            Self::Direct => ["--noproxy", "*"],
            Self::Via(proxy) => ["--proxy", proxy],
        }
    }
}

/// The variables curl reads for each scheme; it ignores `HTTP_PROXY`.
const HTTPS_PROXY_ENVIRONMENT: [&str; 4] = ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"];
const HTTP_PROXY_ENVIRONMENT: [&str; 3] = ["http_proxy", "all_proxy", "ALL_PROXY"];

/// The routes to try for `url`, in order. Empty leaves the choice to curl: a
/// proxy set in the environment still wins, and platforms without a system
/// proxy API connect as curl decides. `pac_script` replaces the system settings
/// in tests. This blocks while a PAC file is fetched and evaluated.
pub(crate) fn routes(url: &str, pac_script: Option<&str>) -> Vec<ProxyRoute> {
    let environment: &[&str] = if url.starts_with("https://") {
        &HTTPS_PROXY_ENVIRONMENT
    } else {
        &HTTP_PROXY_ENVIRONMENT
    };
    if pac_script.is_none()
        && environment
            .iter()
            .any(|name| std::env::var_os(name).is_some_and(|value| !value.is_empty()))
    {
        return Vec::new();
    }
    let mut routes = Vec::new();
    for route in system_routes(url, pac_script) {
        if !routes.contains(&route) {
            routes.push(route);
        }
    }
    routes
}

#[cfg(not(target_os = "macos"))]
fn system_routes(_url: &str, _pac_script: Option<&str>) -> Vec<ProxyRoute> {
    Vec::new()
}

#[cfg(target_os = "macos")]
fn system_routes(url: &str, pac_script: Option<&str>) -> Vec<ProxyRoute> {
    macos::routes(url, pac_script)
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{c_char, c_void};
    use std::ptr;

    use super::ProxyRoute;

    type CfTypeRef = *const c_void;
    type CfIndex = isize;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const K_CF_NUMBER_SINT32_TYPE: CfIndex = 3;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            alloc: CfTypeRef,
            bytes: *const u8,
            length: CfIndex,
            encoding: u32,
            is_external_representation: u8,
        ) -> CfTypeRef;
        fn CFStringGetLength(string: CfTypeRef) -> CfIndex;
        fn CFStringGetMaximumSizeForEncoding(length: CfIndex, encoding: u32) -> CfIndex;
        fn CFStringGetCString(
            string: CfTypeRef,
            buffer: *mut c_char,
            size: CfIndex,
            encoding: u32,
        ) -> u8;
        fn CFStringGetTypeID() -> usize;
        fn CFURLCreateWithString(alloc: CfTypeRef, string: CfTypeRef, base: CfTypeRef)
        -> CfTypeRef;
        fn CFURLGetString(url: CfTypeRef) -> CfTypeRef;
        fn CFURLGetTypeID() -> usize;
        fn CFArrayGetCount(array: CfTypeRef) -> CfIndex;
        fn CFArrayGetValueAtIndex(array: CfTypeRef, index: CfIndex) -> CfTypeRef;
        fn CFDictionaryGetValue(dictionary: CfTypeRef, key: CfTypeRef) -> CfTypeRef;
        fn CFNumberGetValue(number: CfTypeRef, kind: CfIndex, value: *mut c_void) -> u8;
        fn CFNumberGetTypeID() -> usize;
        fn CFGetTypeID(value: CfTypeRef) -> usize;
        fn CFEqual(first: CfTypeRef, second: CfTypeRef) -> u8;
        fn CFRelease(value: CfTypeRef);
    }

    #[link(name = "CFNetwork", kind = "framework")]
    unsafe extern "C" {
        static kCFProxyTypeKey: CfTypeRef;
        static kCFProxyHostNameKey: CfTypeRef;
        static kCFProxyPortNumberKey: CfTypeRef;
        static kCFProxyAutoConfigurationURLKey: CfTypeRef;
        static kCFProxyAutoConfigurationJavaScriptKey: CfTypeRef;
        static kCFProxyTypeNone: CfTypeRef;
        static kCFProxyTypeHTTP: CfTypeRef;
        static kCFProxyTypeHTTPS: CfTypeRef;
        static kCFProxyTypeSOCKS: CfTypeRef;
        static kCFProxyTypeAutoConfigurationURL: CfTypeRef;
        static kCFProxyTypeAutoConfigurationJavaScript: CfTypeRef;
        fn CFNetworkCopySystemProxySettings() -> CfTypeRef;
        fn CFNetworkCopyProxiesForURL(url: CfTypeRef, settings: CfTypeRef) -> CfTypeRef;
        fn CFNetworkCopyProxiesForAutoConfigurationScript(
            script: CfTypeRef,
            url: CfTypeRef,
            error: *mut CfTypeRef,
        ) -> CfTypeRef;
    }

    /// A Core Foundation object this code created or copied, released on drop.
    struct Owned(CfTypeRef);

    impl Owned {
        fn new(value: CfTypeRef) -> Option<Self> {
            (!value.is_null()).then_some(Self(value))
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: `Owned` holds a +1 reference from a Create or Copy call.
            unsafe { CFRelease(self.0) };
        }
    }

    pub(super) fn routes(url: &str, pac_script: Option<&str>) -> Vec<ProxyRoute> {
        let Some(target) = cf_string(url).and_then(|text| {
            // SAFETY: `text` is a valid CFString for the duration of the call.
            Owned::new(unsafe { CFURLCreateWithString(ptr::null(), text.0, ptr::null()) })
        }) else {
            return Vec::new();
        };
        let proxies = match pac_script {
            Some(script) => evaluate(script, &target),
            None => {
                // SAFETY: plain Copy calls; both results are owned and checked.
                let settings = Owned::new(unsafe { CFNetworkCopySystemProxySettings() });
                settings.and_then(|settings| {
                    Owned::new(unsafe { CFNetworkCopyProxiesForURL(target.0, settings.0) })
                })
            }
        };
        let mut routes = Vec::new();
        if let Some(proxies) = proxies {
            collect(&proxies, &target, true, &mut routes);
        }
        routes
    }

    /// Runs a PAC script for `target` and returns its proxy list.
    fn evaluate(script: &str, target: &Owned) -> Option<Owned> {
        let script = cf_string(script)?;
        // SAFETY: both arguments are valid; a null error pointer is allowed.
        Owned::new(unsafe {
            CFNetworkCopyProxiesForAutoConfigurationScript(script.0, target.0, ptr::null_mut())
        })
    }

    /// Appends the routes of a CFNetwork proxy list. PAC entries are run once:
    /// a PAC script's own results are never PAC entries.
    fn collect(proxies: &Owned, target: &Owned, expand_pac: bool, routes: &mut Vec<ProxyRoute>) {
        // SAFETY: CFNetwork returns a CFArray of CFDictionaries. Values read
        // from them are borrowed and used only while `proxies` is alive.
        let count = unsafe { CFArrayGetCount(proxies.0) };
        for index in 0..count {
            let proxy = unsafe { CFArrayGetValueAtIndex(proxies.0, index) };
            if proxy.is_null() {
                continue;
            }
            let value = |key: CfTypeRef| unsafe { CFDictionaryGetValue(proxy, key) };
            let kind = value(unsafe { kCFProxyTypeKey });
            if kind.is_null() {
                continue;
            }
            let is = |other: CfTypeRef| unsafe { CFEqual(kind, other) } != 0;
            if is(unsafe { kCFProxyTypeNone }) {
                routes.push(ProxyRoute::Direct);
            } else if is(unsafe { kCFProxyTypeHTTP }) || is(unsafe { kCFProxyTypeHTTPS }) {
                routes.extend(endpoint(proxy, "http").map(ProxyRoute::Via));
            } else if is(unsafe { kCFProxyTypeSOCKS }) {
                routes.extend(endpoint(proxy, "socks5h").map(ProxyRoute::Via));
            } else if expand_pac && is(unsafe { kCFProxyTypeAutoConfigurationURL }) {
                let location = value(unsafe { kCFProxyAutoConfigurationURLKey });
                let script = has_type(location, unsafe { CFURLGetTypeID() })
                    .then(|| rust_string(unsafe { CFURLGetString(location) }))
                    .flatten()
                    .and_then(|location| fetch_pac(&location));
                if let Some(proxies) = script.and_then(|script| evaluate(&script, target)) {
                    collect(&proxies, target, false, routes);
                }
            } else if expand_pac && is(unsafe { kCFProxyTypeAutoConfigurationJavaScript }) {
                let script = rust_string(value(unsafe { kCFProxyAutoConfigurationJavaScriptKey }));
                if let Some(proxies) = script.and_then(|script| evaluate(&script, target)) {
                    collect(&proxies, target, false, routes);
                }
            }
        }
    }

    /// `scheme://host:port` for a proxy dictionary entry.
    fn endpoint(proxy: CfTypeRef, scheme: &str) -> Option<String> {
        // SAFETY: `proxy` is a live CFDictionary; values are type-checked first.
        let host = rust_string(unsafe { CFDictionaryGetValue(proxy, kCFProxyHostNameKey) })?;
        if host.is_empty() {
            return None;
        }
        let host = if host.contains(':') { format!("[{host}]") } else { host };
        let port = unsafe { CFDictionaryGetValue(proxy, kCFProxyPortNumberKey) };
        let mut number: i32 = 0;
        let has_port = has_type(port, unsafe { CFNumberGetTypeID() })
            && unsafe { CFNumberGetValue(port, K_CF_NUMBER_SINT32_TYPE, (&raw mut number).cast()) }
                != 0
            && number > 0;
        Some(if has_port {
            format!("{scheme}://{host}:{number}")
        } else {
            format!("{scheme}://{host}")
        })
    }

    /// The PAC file at `location`, fetched directly: PAC servers are local, and
    /// the proxies they describe are not known yet.
    fn fetch_pac(location: &str) -> Option<String> {
        if location.starts_with("file:") {
            let path = url::Url::parse(location).ok()?.to_file_path().ok()?;
            return std::fs::read_to_string(path).ok();
        }
        let output = std::process::Command::new("curl")
            .args(["--fail", "--silent", "--location", "--max-time", "10", "--noproxy", "*"])
            .args(["--proto", "=http,https", "--proto-redir", "=http,https"])
            .arg(location)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        output.status.success().then(|| String::from_utf8(output.stdout).ok()).flatten()
    }

    fn has_type(value: CfTypeRef, type_id: usize) -> bool {
        // SAFETY: `value` is null or a live Core Foundation object.
        !value.is_null() && unsafe { CFGetTypeID(value) } == type_id
    }

    fn cf_string(text: &str) -> Option<Owned> {
        let length = CfIndex::try_from(text.len()).ok()?;
        // SAFETY: the bytes are valid UTF-8 of `length` bytes.
        Owned::new(unsafe {
            CFStringCreateWithBytes(
                ptr::null(),
                text.as_ptr(),
                length,
                K_CF_STRING_ENCODING_UTF8,
                0,
            )
        })
    }

    /// Copies a borrowed CFString; anything else is `None`.
    fn rust_string(string: CfTypeRef) -> Option<String> {
        // SAFETY: `string` is type-checked, and the buffer is as large as the
        // encoding can need plus the terminator.
        if !has_type(string, unsafe { CFStringGetTypeID() }) {
            return None;
        }
        let size = unsafe {
            CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), K_CF_STRING_ENCODING_UTF8)
        }
        .checked_add(1)?;
        let mut buffer = vec![0_u8; usize::try_from(size).ok()?];
        let copied = unsafe {
            CFStringGetCString(string, buffer.as_mut_ptr().cast(), size, K_CF_STRING_ENCODING_UTF8)
        };
        if copied == 0 {
            return None;
        }
        buffer.truncate(buffer.iter().position(|byte| *byte == 0)?);
        String::from_utf8(buffer).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::ProxyRoute;

    #[test]
    fn routes_become_curl_arguments() {
        assert_eq!(ProxyRoute::Direct.curl_args(), ["--noproxy", "*"]);
        assert_eq!(
            ProxyRoute::Via("socks5h://127.0.0.1:1080".into()).curl_args(),
            ["--proxy", "socks5h://127.0.0.1:1080"]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_pac_script_yields_its_routes_in_order() {
        let routes = super::routes(
            "https://files.example/cmux-tui/build",
            Some(
                "function FindProxyForURL(url, host) { \
                 return \"PROXY proxy.example:3128; SOCKS 10.0.0.1:1080; DIRECT; DIRECT\"; }",
            ),
        );
        assert_eq!(
            routes,
            [
                ProxyRoute::Via("http://proxy.example:3128".into()),
                ProxyRoute::Via("socks5h://10.0.0.1:1080".into()),
                ProxyRoute::Direct,
            ]
        );
    }
}
