//! Placeholder (red commit): the encoders land in the next commit.

mod picture;

pub use picture::{I420, bgrx_rect_to_i420};

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct EncCfg {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub kbps: u32,
    pub threads: u16,
    pub screen_content: bool,
}

pub trait H264Encoder: Send {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool>;
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn name(&self) -> String;
}

#[cfg(any(feature = "openh264-source", feature = "openh264-runtime"))]
pub mod openh264 {
    use super::{EncCfg, H264Encoder, I420, Res};

    pub struct OpenH264Api;
    impl OpenH264Api {
        #[cfg(feature = "openh264-source")]
        pub fn from_source() -> Self {
            Self
        }
    }
    pub struct OpenH264;
    impl OpenH264 {
        pub fn new(_cfg: &EncCfg, _api: OpenH264Api) -> Res<Self> {
            Ok(Self)
        }
    }
    impl H264Encoder for OpenH264 {
        fn encode(&mut self, _p: &I420, _f: bool, _t: i64, out: &mut Vec<u8>) -> Res<bool> {
            out.clear();
            Ok(false)
        }
        fn set_bitrate(&mut self, _k: u32) {}
        fn kbps(&self) -> u32 {
            0
        }
        fn name(&self) -> String {
            String::new()
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Platform {
        LinuxX64,
    }
    impl Platform {
        pub const ALL: [Platform; 1] = [Platform::LinuxX64];
    }
    pub struct CiscoBinary {
        pub url: &'static str,
        pub sha256: &'static str,
    }
    impl CiscoBinary {
        pub fn for_platform(_p: Platform) -> Self {
            Self { url: "", sha256: "" }
        }
    }
    #[derive(Debug)]
    pub enum LoadError {
        Io(std::io::Error),
        HashMismatch { expected: &'static str, actual: String },
        NotImplemented,
    }
    pub fn load_verified(_p: impl AsRef<std::path::Path>, _platform: Platform) -> Result<OpenH264Api, LoadError> {
        Err(LoadError::NotImplemented)
    }
}
