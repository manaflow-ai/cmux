//! Desktop Duplication. The acquired texture is the complete current desktop;
//! dirty and move-destination rectangles limit GPU readback and CPU copies.
use super::*;
use windows::core::Interface;
use windows::Win32::Foundation::{HMODULE, RECT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;

pub(super) struct DxgiCapture {
    duplication: IDXGIOutputDuplication,
    context: ID3D11DeviceContext,
    staging: ID3D11Texture2D,
    width: u32,
    height: u32,
    pixels: Vec<u8>,
    initialized: bool,
    pub damage: Option<Rect>,
    pub acquired_frames: u64,
    pub copied_bytes: u64,
}

impl DxgiCapture {
    pub fn new() -> Res<Self> {
        // SAFETY: COM wrappers own each returned interface. All calls remain on
        // the session's capture thread; no raw interface pointer escapes.
        unsafe {
            let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
            for adapter_index in 0..32 {
                let adapter = match factory.EnumAdapters1(adapter_index) {
                    Ok(adapter) => adapter,
                    Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                    Err(e) => return Err(e.into()),
                };
                for output_index in 0..32 {
                    let output = match adapter.EnumOutputs(output_index) {
                        Ok(output) => output,
                        Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                        Err(e) => return Err(e.into()),
                    };
                    let desc = output.GetDesc()?;
                    let bounds = desc.DesktopCoordinates;
                    if !desc.AttachedToDesktop.as_bool() || bounds.left != 0 || bounds.top != 0 {
                        continue;
                    }
                    if desc.Rotation != DXGI_MODE_ROTATION_IDENTITY {
                        return Err("DXGI primary display is rotated; use GDI".into());
                    }
                    let mut device = None;
                    let mut context = None;
                    D3D11CreateDevice(
                        &adapter,
                        D3D_DRIVER_TYPE_UNKNOWN,
                        HMODULE::default(),
                        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                        None,
                        D3D11_SDK_VERSION,
                        Some(&mut device),
                        None,
                        Some(&mut context),
                    )
                    .map_err(|e| format!("D3D11CreateDevice: {e} ({:#x})", e.code().0))?;
                    let device = device.ok_or("D3D11CreateDevice returned no device")?;
                    let context = context.ok_or("D3D11CreateDevice returned no context")?;
                    let duplication =
                        output.cast::<IDXGIOutput1>()?.DuplicateOutput(&device).map_err(|e| {
                            format!("IDXGIOutput1::DuplicateOutput: {e} ({:#x})", e.code().0)
                        })?;
                    let mode = duplication.GetDesc();
                    let (width, height) = (mode.ModeDesc.Width, mode.ModeDesc.Height);
                    let bytes = width
                        .checked_mul(height)
                        .and_then(|n| n.checked_mul(4))
                        .filter(|&n| n <= 256 * 1024 * 1024)
                        .ok_or("DXGI desktop exceeds 256 MiB")?;
                    if width == 0
                        || height == 0
                        || width % 2 != 0
                        || height % 2 != 0
                        || mode.ModeDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM
                    {
                        return Err("DXGI desktop format/dimensions require GDI".into());
                    }
                    let texture = D3D11_TEXTURE2D_DESC {
                        Width: width,
                        Height: height,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_STAGING,
                        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                        ..Default::default()
                    };
                    let mut staging = None;
                    device.CreateTexture2D(&texture, None, Some(&mut staging))?;
                    return Ok(Self {
                        duplication,
                        context,
                        staging: staging.ok_or("no DXGI staging texture")?,
                        width,
                        height,
                        pixels: vec![0; bytes as usize],
                        initialized: false,
                        damage: None,
                        acquired_frames: 0,
                        copied_bytes: 0,
                    });
                }
            }
        }
        Err("DXGI has no attached primary display".into())
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
    fn full(&self) -> Rect {
        Rect { x: 0, y: 0, width: self.width, height: self.height }
    }

    pub fn capture(&mut self) -> Res<()> {
        self.damage = None;
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource = None;
        // First capture is bounded to one second. Later captures never wait on
        // an unchanged desktop; feedback can encode the retained valid pixels.
        let acquired = unsafe {
            self.duplication.AcquireNextFrame(
                if self.initialized { 0 } else { 1000 },
                &mut info,
                &mut resource,
            )
        };
        match acquired {
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT && self.initialized => return Ok(()),
            Err(e) => return Err(format!("DXGI AcquireNextFrame: {e} ({:#x})", e.code().0).into()),
            Ok(()) => {}
        }
        // Always release after a successful acquisition, including all metadata,
        // texture and map failures. No outstanding frame reaches fallback.
        let result = self.copy_frame(&info, resource);
        let released = unsafe { self.duplication.ReleaseFrame() };
        result?;
        released?;
        self.acquired_frames += 1;
        Ok(())
    }

    fn regions(&self, info: &DXGI_OUTDUPL_FRAME_INFO) -> Vec<Rect> {
        if !self.initialized || info.TotalMetadataBufferSize > 1024 * 1024 {
            return vec![self.full()];
        }
        if info.TotalMetadataBufferSize == 0 {
            // A pointer-only notification changes no desktop pixels. Like the
            // existing BitBlt path, this backend captures the desktop surface;
            // it does not composite a separately supplied hardware cursor.
            return if info.LastPresentTime == 0 { Vec::new() } else { vec![self.full()] };
        }
        let bytes = info.TotalMetadataBufferSize as usize;
        let mut dirty = vec![RECT::default(); bytes.div_ceil(size_of::<RECT>())];
        let mut moves = vec![
            DXGI_OUTDUPL_MOVE_RECT::default();
            bytes.div_ceil(size_of::<DXGI_OUTDUPL_MOVE_RECT>())
        ];
        let (mut dirty_bytes, mut move_bytes) = (0, 0);
        let read_dirty = unsafe {
            self.duplication.GetFrameDirtyRects(
                (dirty.len() * size_of::<RECT>()) as u32,
                dirty.as_mut_ptr(),
                &mut dirty_bytes,
            )
        };
        let read_moves = unsafe {
            self.duplication.GetFrameMoveRects(
                (moves.len() * size_of::<DXGI_OUTDUPL_MOVE_RECT>()) as u32,
                moves.as_mut_ptr(),
                &mut move_bytes,
            )
        };
        if read_dirty.is_err()
            || read_moves.is_err()
            || dirty_bytes as usize > dirty.len() * size_of::<RECT>()
            || move_bytes as usize > moves.len() * size_of::<DXGI_OUTDUPL_MOVE_RECT>()
        {
            return vec![self.full()];
        }
        dirty.truncate(dirty_bytes as usize / size_of::<RECT>());
        moves.truncate(move_bytes as usize / size_of::<DXGI_OUTDUPL_MOVE_RECT>());
        let regions: Vec<_> = dirty
            .into_iter()
            .chain(moves.into_iter().map(|m| m.DestinationRect))
            .filter_map(|r| clip(r, self.width, self.height))
            .collect();
        // Reading move destinations from the current complete texture handles
        // overlapping moves without copying from an already changed CPU frame.
        let area: u64 = regions.iter().map(|r| u64::from(r.width) * u64::from(r.height)).sum();
        if regions.len() > 256 || area > u64::from(self.width) * u64::from(self.height) / 2 {
            vec![self.full()]
        } else {
            regions
        }
    }

    fn copy_frame(
        &mut self,
        info: &DXGI_OUTDUPL_FRAME_INFO,
        resource: Option<IDXGIResource>,
    ) -> Res<()> {
        let texture =
            resource.ok_or("DXGI acquired no desktop resource")?.cast::<ID3D11Texture2D>()?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut desc) };
        if (desc.Width, desc.Height) != self.size() || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
            return Err("DXGI desktop mode changed during capture".into());
        }
        let regions = self.regions(info);
        if regions.is_empty() {
            return Ok(());
        }
        for r in &regions {
            let source = D3D11_BOX {
                left: r.x,
                top: r.y,
                front: 0,
                right: r.x + r.width,
                bottom: r.y + r.height,
                back: 1,
            };
            // SAFETY: source and destination rectangles are clipped to both textures.
            unsafe {
                self.context.CopySubresourceRegion(
                    &self.staging,
                    0,
                    r.x,
                    r.y,
                    0,
                    &texture,
                    0,
                    Some(&source),
                );
            }
        }
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe {
            self.context.Map(&self.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
        }
        let result = self.copy_mapped(&mapped, &regions);
        unsafe {
            self.context.Unmap(&self.staging, 0);
        }
        result?;
        self.initialized = true;
        self.damage = regions.into_iter().reduce(Rect::union);
        Ok(())
    }

    fn copy_mapped(&mut self, mapped: &D3D11_MAPPED_SUBRESOURCE, regions: &[Rect]) -> Res<()> {
        let stride = self.width as usize * 4;
        let pitch = mapped.RowPitch as usize;
        let bytes = pitch
            .checked_mul(self.height as usize)
            .filter(|&n| n <= isize::MAX as usize)
            .ok_or("DXGI mapped pitch overflow")?;
        if mapped.pData.is_null() || pitch < stride {
            return Err("invalid DXGI mapped surface".into());
        }
        // SAFETY: D3D owns this mapping until Unmap; RowPitch covers every row,
        // validated dimensions bound all source/destination slices below.
        let source = unsafe { std::slice::from_raw_parts(mapped.pData.cast::<u8>(), bytes) };
        self.copied_bytes += copy_regions(source, pitch, &mut self.pixels, stride, regions)?;
        Ok(())
    }
}

fn copy_regions(
    source: &[u8],
    pitch: usize,
    pixels: &mut [u8],
    stride: usize,
    regions: &[Rect],
) -> Res<u64> {
    let mut copied_bytes = 0;
    for r in regions {
        let x = r.x as usize * 4;
        let length = r.width as usize * 4;
        for y in r.y as usize..(r.y + r.height) as usize {
            let row = source
                .get(y * pitch + x..y * pitch + x + length)
                .ok_or("DXGI source row exceeds mapping")?;
            pixels
                .get_mut(y * stride + x..y * stride + x + length)
                .ok_or("DXGI destination row exceeds backing buffer")?
                .copy_from_slice(row);
        }
        copied_bytes += u64::from(r.width) * u64::from(r.height) * 4;
    }
    Ok(copied_bytes)
}

fn clip(rect: RECT, width: u32, height: u32) -> Option<Rect> {
    let x = rect.left.clamp(0, width as i32) as u32;
    let y = rect.top.clamp(0, height as i32) as u32;
    let right = rect.right.clamp(0, width as i32) as u32;
    let bottom = rect.bottom.clamp(0, height as i32) as u32;
    (right > x && bottom > y).then(|| Rect { x, y, width: right - x, height: bottom - y })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dxgi_dirty_rectangles_clip_negative_and_offscreen_edges() {
        assert_eq!(
            clip(RECT { left: -10, top: -20, right: 50, bottom: 60 }, 40, 40),
            Some(Rect { x: 0, y: 0, width: 40, height: 40 })
        );
        assert_eq!(clip(RECT { left: 40, top: 0, right: 60, bottom: 5 }, 40, 40), None);
        assert_eq!(clip(RECT { left: 20, top: 10, right: 10, bottom: 5 }, 40, 40), None);
    }
    #[test]
    fn dxgi_dirty_and_move_destinations_keep_unchanged_pixels_and_ignore_row_padding() {
        // The acquired desktop is complete. A dirty rectangle and an overlapping
        // move destination both read these final bytes, never the old CPU image.
        let width = 4usize;
        let pitch = 24usize;
        let mut source = vec![0xee; pitch * 3];
        for y in 0..3 {
            for x in 0..width {
                source[y * pitch + x * 4..y * pitch + x * 4 + 4].fill((y * width + x) as u8);
            }
        }
        let mut backing = vec![0x99; width * 3 * 4];
        let regions =
            [Rect { x: 1, y: 0, width: 2, height: 2 }, Rect { x: 2, y: 1, width: 2, height: 2 }];
        let copied = copy_regions(&source, pitch, &mut backing, width * 4, &regions).expect("copy");
        assert_eq!(copied, 32);
        for y in 0..3 {
            for x in 0..width {
                let touched = regions.iter().any(|r| {
                    x >= r.x as usize
                        && x < (r.x + r.width) as usize
                        && y >= r.y as usize
                        && y < (r.y + r.height) as usize
                });
                let expected = if touched { (y * width + x) as u8 } else { 0x99 };
                assert_eq!(&backing[(y * width + x) * 4..(y * width + x + 1) * 4], &[expected; 4]);
            }
        }
        assert!(copy_regions(&source[..1], pitch, &mut backing, width * 4, &regions).is_err());
    }
}
