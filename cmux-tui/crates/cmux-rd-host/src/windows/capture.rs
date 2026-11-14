//! Capture selection and a one-way fallback for unavailable/lost duplication.
use super::dxgi::DxgiCapture;
use super::*;

enum Backend {
    Gdi(GdiCapture),
    Dxgi(DxgiCapture),
}

pub(super) struct DesktopCapture {
    backend: Backend,
    automatic: bool,
    fingerprint: Option<u64>,
    pub damage: Option<Rect>,
    pub fallback_reason: Option<String>,
}

impl DesktopCapture {
    pub fn new(requested: Option<(u32, u32)>, mode: &str) -> Res<Self> {
        if !matches!(mode, "auto" | "gdi" | "dxgi") {
            return Err("--capture must be auto, gdi or dxgi".into());
        }
        let mut fallback_reason = None;
        let backend = if mode == "gdi" {
            Backend::Gdi(GdiCapture::new(requested)?)
        } else {
            let candidate = DxgiCapture::new().and_then(|capture| {
                if requested.is_some_and(|size| size != capture.size()) {
                    return Err("DXGI capture requires the native display dimensions".into());
                }
                Ok(capture)
            });
            match candidate {
                Ok(capture) => Backend::Dxgi(capture),
                Err(error) if mode == "auto" => {
                    fallback_reason = Some(error.to_string());
                    eprintln!("Windows capture: DXGI unavailable ({error}); using GDI");
                    Backend::Gdi(GdiCapture::new(requested)?)
                }
                Err(error) => return Err(error),
            }
        };
        Ok(Self {
            backend,
            automatic: mode == "auto",
            fingerprint: None,
            damage: None,
            fallback_reason,
        })
    }

    pub fn size(&self) -> (u32, u32) {
        match &self.backend {
            Backend::Gdi(c) => c.size(),
            Backend::Dxgi(c) => c.size(),
        }
    }
    pub fn name(&self) -> &'static str {
        match &self.backend {
            Backend::Gdi(_) => "gdi-readback",
            Backend::Dxgi(_) => "dxgi-duplication",
        }
    }
    pub fn pixels(&self) -> &[u8] {
        match &self.backend {
            Backend::Gdi(c) => &c.pixels,
            Backend::Dxgi(c) => c.pixels(),
        }
    }
    pub fn statistics(&self) -> serde_json::Value {
        match &self.backend {
            Backend::Gdi(_) => {
                serde_json::json!({"backend": self.name(), "fallback_reason": self.fallback_reason})
            }
            Backend::Dxgi(c) => serde_json::json!({"backend": self.name(),
                "acquired_frames": c.acquired_frames, "copied_bytes": c.copied_bytes}),
        }
    }

    pub fn capture(&mut self) -> Res<&[u8]> {
        let result = self.update();
        if let Err(error) = result {
            if !self.automatic || !matches!(&self.backend, Backend::Dxgi(_)) {
                return Err(error);
            }
            let size = self.size();
            let fallback = GdiCapture::new(Some(size))?;
            if fallback.size() != size {
                return Err("desktop dimensions changed; reconnect the viewer".into());
            }
            // Release every duplication/device resource before entering the GDI
            // path. No timer retries a permanently unsupported driver.
            self.backend = Backend::Gdi(fallback);
            self.fingerprint = None;
            self.fallback_reason = Some(error.to_string());
            eprintln!("Windows capture: DXGI lost ({error}); using GDI");
            self.update()?;
        }
        Ok(self.pixels())
    }

    fn update(&mut self) -> Res<()> {
        self.damage = None;
        match &mut self.backend {
            Backend::Dxgi(capture) => {
                capture.capture()?;
                self.damage = capture.damage;
            }
            Backend::Gdi(capture) => {
                let pixels = capture.capture()?;
                let mut hash = DefaultHasher::new();
                hash.write(pixels);
                let fingerprint = hash.finish();
                if self.fingerprint != Some(fingerprint) {
                    let (width, height) = capture.size();
                    self.damage = Some(Rect { x: 0, y: 0, width, height });
                }
                self.fingerprint = Some(fingerprint);
            }
        }
        Ok(())
    }
}
