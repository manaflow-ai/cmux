//! The encoder against a stand-in libva: what it asks the driver for (profile, entry point,
//! rate control, frame types, references) and what it hands back. The stand-in "encodes" a
//! frame as the packed headers it was given plus one slice NAL of the right type, as a driver does.

use super::*;
use std::collections::{HashMap, HashSet};
use std::ffi::c_char;
use std::sync::Mutex;

#[derive(Default)]
struct Mock {
    profiles: Vec<i32>,
    entrypoints: Vec<i32>,
    rc: u32,
    packed: u32,
    derive_ok: bool,
    /// Every frame comes back as an IDR slice.
    break_p_frames: bool,
    next_id: VAId,
    size: (u32, u32),
    config_attribs: Vec<VAConfigAttrib>,
    buffers: HashMap<VAId, (c_int, Vec<u8>)>,
    /// Image buffers (NV12) by buffer id, and image id -> buffer id.
    images: HashMap<VAId, VAId>,
    pitch: u32,
    picture: Vec<(c_int, Vec<u8>)>,
    /// Every rendered picture's buffers, in order.
    pictures: Vec<Vec<(c_int, Vec<u8>)>>,
    coded: Vec<u8>,
    segment: Option<Box<VACodedBufferSegment>>,
    live: HashSet<VAId>,
    surfaces: Vec<VAId>,
    terminated: u32,
    put_images: u32,
}

// SAFETY: the coded segment's pointers point into the same Mock; it is used under the lock.
unsafe impl Send for Mock {}

static MOCK: Mutex<Option<Mock>> = Mutex::new(None);
static SERIAL: Mutex<()> = Mutex::new(());

fn with<R>(f: impl FnOnce(&mut Mock) -> R) -> R {
    f(MOCK.lock().unwrap_or_else(|e| e.into_inner()).as_mut().expect("mock set"))
}

fn id(m: &mut Mock) -> VAId {
    m.next_id += 1;
    m.live.insert(m.next_id);
    m.next_id
}

unsafe extern "C" fn get_display_drm(_fd: c_int) -> VADisplay {
    std::ptr::dangling_mut::<c_void>()
}
unsafe extern "C" fn initialize(_: VADisplay, major: *mut c_int, minor: *mut c_int) -> VAStatus {
    // SAFETY: the encoder passes two writable ints.
    unsafe {
        *major = 1;
        *minor = 20;
    }
    0
}
unsafe extern "C" fn terminate(_: VADisplay) -> VAStatus {
    with(|m| m.terminated += 1);
    0
}
unsafe extern "C" fn vendor(_: VADisplay) -> *const c_char {
    c"mock driver".as_ptr()
}
unsafe extern "C" fn error_str(_: VAStatus) -> *const c_char {
    c"mock error".as_ptr()
}
unsafe extern "C" fn max_profiles(_: VADisplay) -> c_int {
    8
}
unsafe extern "C" fn query_profiles(_: VADisplay, out: *mut i32, n: *mut c_int) -> VAStatus {
    with(|m| {
        for (i, p) in m.profiles.iter().enumerate() {
            // SAFETY: room for max_profiles entries.
            unsafe { *out.add(i) = *p };
        }
        // SAFETY: a writable int.
        unsafe { *n = m.profiles.len() as c_int };
    });
    0
}
unsafe extern "C" fn max_entrypoints(_: VADisplay) -> c_int {
    8
}
unsafe extern "C" fn query_entrypoints(
    _: VADisplay,
    _: i32,
    out: *mut i32,
    n: *mut c_int,
) -> VAStatus {
    with(|m| {
        for (i, e) in m.entrypoints.iter().enumerate() {
            // SAFETY: room for max_entrypoints entries.
            unsafe { *out.add(i) = *e };
        }
        // SAFETY: a writable int.
        unsafe { *n = m.entrypoints.len() as c_int };
    });
    0
}
unsafe extern "C" fn get_attribs(
    _: VADisplay,
    _: i32,
    _: i32,
    a: *mut VAConfigAttrib,
    n: c_int,
) -> VAStatus {
    // SAFETY: `n` attributes to fill.
    let attribs = unsafe { std::slice::from_raw_parts_mut(a, n as usize) };
    with(|m| {
        for a in attribs {
            a.value = match a.kind {
                VA_CONFIG_ATTRIB_RT_FORMAT => VA_RT_FORMAT_YUV420,
                VA_CONFIG_ATTRIB_RATE_CONTROL => m.rc,
                VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS => m.packed,
                _ => VA_ATTRIB_NOT_SUPPORTED,
            };
        }
    });
    0
}
unsafe extern "C" fn create_config(
    _: VADisplay,
    _: i32,
    _: i32,
    a: *mut VAConfigAttrib,
    n: c_int,
    out: *mut VAId,
) -> VAStatus {
    // SAFETY: `n` attributes; one id to write.
    unsafe {
        let attribs = std::slice::from_raw_parts(a, n as usize).to_vec();
        *out = with(|m| {
            m.config_attribs = attribs;
            id(m)
        });
    }
    0
}
unsafe extern "C" fn destroy(_: VADisplay, x: VAId) -> VAStatus {
    with(|m| assert!(m.live.remove(&x), "destroyed {x} twice or never made"));
    0
}
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn create_surfaces(
    _: VADisplay,
    _: c_uint,
    w: c_uint,
    h: c_uint,
    out: *mut VAId,
    n: c_uint,
    _: *mut c_void,
    _: c_uint,
) -> VAStatus {
    with(|m| {
        m.size = (w, h);
        m.pitch = w.next_multiple_of(64);
        for i in 0..n as usize {
            let s = id(m);
            m.surfaces.push(s);
            // SAFETY: room for `n` ids.
            unsafe { *out.add(i) = s };
        }
    });
    0
}
unsafe extern "C" fn destroy_surfaces(_: VADisplay, s: *mut VAId, n: c_int) -> VAStatus {
    // SAFETY: `n` ids.
    let ids = unsafe { std::slice::from_raw_parts(s, n as usize) }.to_vec();
    with(|m| {
        for x in ids {
            assert!(m.live.remove(&x));
        }
    });
    0
}
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn create_context(
    _: VADisplay,
    _: VAId,
    _: c_int,
    _: c_int,
    _: c_int,
    _: *mut VAId,
    _: c_int,
    out: *mut VAId,
) -> VAStatus {
    // SAFETY: one id to write.
    unsafe { *out = with(id) };
    0
}
unsafe extern "C" fn create_buffer(
    _: VADisplay,
    _: VAId,
    kind: c_int,
    size: c_uint,
    _: c_uint,
    data: *mut c_void,
    out: *mut VAId,
) -> VAStatus {
    let bytes = if data.is_null() {
        vec![0; size as usize]
    } else {
        // SAFETY: `size` bytes at `data`.
        unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size as usize) }.to_vec()
    };
    // SAFETY: one id to write.
    unsafe {
        *out = with(|m| {
            let b = id(m);
            m.buffers.insert(b, (kind, bytes));
            b
        });
    }
    0
}
unsafe extern "C" fn map_buffer(_: VADisplay, b: VAId, out: *mut *mut c_void) -> VAStatus {
    with(|m| {
        let (kind, bytes) = m.buffers.get_mut(&b).expect("mapped a live buffer");
        let ptr = if *kind == VA_ENC_CODED_BUFFER_TYPE {
            let seg = m.segment.insert(Box::new(VACodedBufferSegment {
                size: m.coded.len() as u32,
                bit_offset: 0,
                status: 0,
                reserved: 0,
                buf: m.coded.as_mut_ptr().cast(),
                next: std::ptr::null_mut(),
                va_reserved: [0; 4],
            }));
            (&mut **seg as *mut VACodedBufferSegment).cast()
        } else {
            bytes.as_mut_ptr().cast()
        };
        // SAFETY: a pointer to fill.
        unsafe { *out = ptr };
    });
    0
}
unsafe extern "C" fn unmap(_: VADisplay, _: VAId) -> VAStatus {
    0
}
unsafe extern "C" fn begin(_: VADisplay, _: VAId, _: VAId) -> VAStatus {
    with(|m| m.picture.clear());
    0
}
unsafe extern "C" fn render(_: VADisplay, _: VAId, bufs: *mut VAId, n: c_int) -> VAStatus {
    // SAFETY: `n` ids.
    let ids = unsafe { std::slice::from_raw_parts(bufs, n as usize) }.to_vec();
    with(|m| {
        for b in ids {
            let buf = m.buffers.get(&b).expect("rendered a live buffer").clone();
            m.picture.push(buf);
        }
    });
    0
}
unsafe extern "C" fn end(_: VADisplay, _: VAId) -> VAStatus {
    with(|m| {
        let picture = std::mem::take(&mut m.picture);
        let pic = picture
            .iter()
            .find(|(k, _)| *k == VA_ENC_PICTURE_PARAMETER_BUFFER_TYPE)
            .map(|(_, b)| read::<VAEncPictureParameterBufferH264>(b))
            .expect("a picture parameter buffer");
        let mut coded = Vec::new();
        for (kind, bytes) in &picture {
            if *kind == VA_ENC_PACKED_HEADER_DATA_BUFFER_TYPE {
                coded.extend_from_slice(bytes);
            }
        }
        let idr = pic.pic_fields & 1 == 1 || m.break_p_frames;
        coded.extend_from_slice(&[0, 0, 0, 1, if idr { 0x65 } else { 0x41 }, 0x88, 0x84]);
        m.coded = coded;
        m.pictures.push(picture);
    });
    0
}
unsafe extern "C" fn sync(_: VADisplay, _: VAId) -> VAStatus {
    0
}
fn make_image(m: &mut Mock, image: &mut VAImage) {
    let (w, h) = m.size;
    let size = m.pitch * h * 3 / 2;
    let buf = id(m);
    m.buffers.insert(buf, (0, vec![0; size as usize]));
    let image_id = id(m);
    m.images.insert(image_id, buf);
    *image = VAImage {
        image_id,
        format: VAImageFormat { fourcc: VA_FOURCC_NV12, ..Default::default() },
        buf,
        width: w as u16,
        height: h as u16,
        data_size: size,
        num_planes: 2,
        pitches: [m.pitch, m.pitch, 0],
        offsets: [0, m.pitch * h, 0],
        ..Default::default()
    };
}
unsafe extern "C" fn derive_image(_: VADisplay, _: VAId, out: *mut VAImage) -> VAStatus {
    with(|m| {
        if !m.derive_ok {
            return 1;
        }
        // SAFETY: an image struct to fill.
        make_image(m, unsafe { &mut *out });
        0
    })
}
unsafe extern "C" fn create_image(
    _: VADisplay,
    _: *mut VAImageFormat,
    _: c_int,
    _: c_int,
    out: *mut VAImage,
) -> VAStatus {
    // SAFETY: an image struct to fill.
    with(|m| make_image(m, unsafe { &mut *out }));
    0
}
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn put_image(
    _: VADisplay,
    _: VAId,
    _: VAId,
    _: c_int,
    _: c_int,
    _: c_uint,
    _: c_uint,
    _: c_int,
    _: c_int,
    _: c_uint,
    _: c_uint,
) -> VAStatus {
    with(|m| m.put_images += 1);
    0
}
unsafe extern "C" fn destroy_image(_: VADisplay, image: VAId) -> VAStatus {
    with(|m| {
        let buf = m.images.remove(&image).expect("destroyed a live image");
        m.buffers.remove(&buf);
        assert!(m.live.remove(&buf) && m.live.remove(&image));
    });
    0
}
unsafe extern "C" fn destroy_buffer(_: VADisplay, b: VAId) -> VAStatus {
    with(|m| {
        m.buffers.remove(&b);
        assert!(m.live.remove(&b), "buffer {b} destroyed twice or never made");
    });
    0
}

static API: LibVa = LibVa {
    get_display_drm,
    initialize,
    terminate,
    set_info_callback: None,
    query_vendor_string: vendor,
    error_str,
    max_num_profiles: max_profiles,
    query_config_profiles: query_profiles,
    max_num_entrypoints: max_entrypoints,
    query_config_entrypoints: query_entrypoints,
    get_config_attributes: get_attribs,
    create_config,
    destroy_config: destroy,
    create_surfaces,
    destroy_surfaces,
    create_context,
    destroy_context: destroy,
    create_buffer,
    destroy_buffer,
    map_buffer,
    unmap_buffer: unmap,
    begin_picture: begin,
    render_picture: render,
    end_picture: end,
    sync_surface: sync,
    derive_image,
    create_image,
    put_image,
    destroy_image,
};

fn read<T: Copy>(bytes: &[u8]) -> T {
    assert_eq!(bytes.len(), size_of::<T>());
    // SAFETY: the bytes of a T the encoder wrote (read unaligned).
    unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast()) }
}

/// A driver like Intel's iHD: High, Main and Constrained Baseline on the low-power entry point,
/// VBR and CBR, packed headers.
fn intel_like() -> Mock {
    Mock {
        profiles: vec![
            VA_PROFILE_H264_MAIN,
            VA_PROFILE_H264_HIGH,
            VA_PROFILE_H264_CONSTRAINED_BASELINE,
        ],
        entrypoints: vec![VA_ENTRYPOINT_ENC_SLICE, VA_ENTRYPOINT_ENC_SLICE_LP],
        rc: VA_RC_CBR | VA_RC_VBR,
        packed: VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | 0x4,
        derive_ok: true,
        ..Default::default()
    }
}

fn cfg(width: u32, height: u32) -> EncCfg {
    EncCfg { width, height, fps: 60, kbps: 8000, threads: 1, screen_content: true }
}

fn open(mock: Mock, cfg: &EncCfg, baseline: bool) -> Res<Vaapi> {
    *MOCK.lock().unwrap_or_else(|e| e.into_inner()) = Some(mock);
    let enc = Vaapi::open_on(&API, &[PathBuf::from("/dev/null")], cfg, baseline)?;
    // The probe's self-test encoded an IDR and a P frame; tests look at frames from here on.
    assert_eq!(with(|m| std::mem::take(&mut m.pictures).len()), 2);
    with(|m| m.put_images = 0);
    Ok(enc)
}

fn nal_types(au: &[u8]) -> Vec<u8> {
    crate::annexb_nals(au).filter_map(|n| n.first().map(|b| b & 0x1f)).collect()
}

fn of_kind(picture: &[(c_int, Vec<u8>)], kind: c_int) -> Vec<&[u8]> {
    picture.iter().filter(|(k, _)| *k == kind).map(|(_, b)| b.as_slice()).collect()
}

fn misc(picture: &[(c_int, Vec<u8>)], kind: u32) -> Option<Vec<u8>> {
    of_kind(picture, VA_ENC_MISC_PARAMETER_BUFFER_TYPE)
        .into_iter()
        .find(|b| b[..4] == kind.to_ne_bytes())
        .map(|b| b[4..].to_vec())
}

#[test]
fn low_latency_stream_ip_only_infinite_gop() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut enc = open(intel_like(), &cfg(1920, 1080), false).unwrap();
    assert_eq!(enc.probe().profile, VA_PROFILE_H264_HIGH);
    assert_eq!(enc.probe().entrypoint, VA_ENTRYPOINT_ENC_SLICE_LP);
    assert_eq!(enc.probe().rate_control, VA_RC_VBR);
    assert!(enc.name().starts_with("vaapi /dev/null high low-power vbr"), "{}", enc.name());
    let attribs = with(|m| m.config_attribs.clone());
    let attrib = |kind| attribs.iter().find(|a| a.kind == kind).map(|a| a.value);
    assert_eq!(attrib(VA_CONFIG_ATTRIB_RATE_CONTROL), Some(VA_RC_VBR));
    assert_eq!(
        attrib(VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS),
        Some(VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE)
    );

    let pic = I420::new(1920, 1080);
    let mut au = Vec::new();
    let mut idrs = Vec::new();
    for i in 0..300 {
        let idr = enc.encode(&pic, i == 120, i as i64 * 16_667, &mut au).unwrap();
        if idr {
            idrs.push(i);
            assert_eq!(nal_types(&au), vec![7, 8, 5], "frame {i}");
        } else {
            assert_eq!(nal_types(&au), vec![1], "frame {i}");
        }
    }
    // Infinite GOP: an IDR for the first frame and the forced one only.
    assert_eq!(idrs, vec![0, 120]);

    let pictures = with(|m| m.pictures.clone());
    let surfaces = with(|m| m.surfaces.clone());
    let mut last_recon = None;
    let mut idr_ids = Vec::new();
    for (i, picture) in pictures.iter().enumerate() {
        let pic: VAEncPictureParameterBufferH264 =
            read(of_kind(picture, VA_ENC_PICTURE_PARAMETER_BUFFER_TYPE)[0]);
        let slice: VAEncSliceParameterBufferH264 =
            read(of_kind(picture, VA_ENC_SLICE_PARAMETER_BUFFER_TYPE)[0]);
        let idr = i == 0 || i == 120;
        let since = if i >= 120 { i - 120 } else { i } as u32;
        assert_eq!(pic.pic_fields & 1 == 1, idr);
        assert_eq!(u32::from(pic.frame_num), since, "frame_num restarts at each IDR");
        assert_eq!(pic.curr_pic.top_field_order_cnt, 2 * since as i32);
        // CABAC and 8x8 transforms in High.
        assert_eq!(pic.pic_fields & (1 << 3 | 1 << 8), 1 << 3 | 1 << 8);
        // Never a B slice, never a list-1 reference.
        assert_eq!(slice.slice_type, if idr { SLICE_I } else { SLICE_P });
        assert!(slice.ref_pic_list1.iter().all(|r| r.flags == VA_PICTURE_H264_INVALID));
        assert!(pic.reference_frames[1..].iter().all(|r| r.picture_id == VA_INVALID_ID));
        if idr {
            idr_ids.push(slice.idr_pic_id);
            assert_eq!(slice.ref_pic_list0[0].flags, VA_PICTURE_H264_INVALID);
            let seq: VAEncSequenceParameterBufferH264 =
                read(of_kind(picture, VA_ENC_SEQUENCE_PARAMETER_BUFFER_TYPE)[0]);
            assert_eq!(seq.ip_period, 1);
            assert_eq!(seq.max_num_ref_frames, 1);
            assert_eq!((seq.picture_width_in_mbs, seq.picture_height_in_mbs), (120, 68));
            assert_eq!((seq.frame_cropping_flag, seq.frame_crop_bottom_offset), (1, 4));
            assert_eq!(seq.seq_fields >> 10 & 3, 2, "pic_order_cnt_type 2");
            assert_eq!(seq.level_idc, 42);
            assert_eq!(of_kind(picture, VA_ENC_PACKED_HEADER_DATA_BUFFER_TYPE).len(), 2);
        } else {
            assert!(of_kind(picture, VA_ENC_SEQUENCE_PARAMETER_BUFFER_TYPE).is_empty());
            assert!(of_kind(picture, VA_ENC_PACKED_HEADER_DATA_BUFFER_TYPE).is_empty());
            // The reference is the picture the frame before reconstructed.
            assert_eq!(Some(slice.ref_pic_list0[0].picture_id), last_recon);
            assert_eq!(slice.ref_pic_list0[0].flags, VA_PICTURE_H264_SHORT_TERM_REFERENCE);
            assert_eq!(pic.reference_frames[0].picture_id, slice.ref_pic_list0[0].picture_id);
        }
        assert_ne!(Some(pic.curr_pic.picture_id), last_recon);
        assert!(
            surfaces[1..].contains(&pic.curr_pic.picture_id),
            "reconstructs into a recon surface"
        );
        last_recon = Some(pic.curr_pic.picture_id);
        // Rate control and frame rate go to the driver once.
        assert_eq!(misc(picture, VA_ENC_MISC_PARAMETER_TYPE_RATE_CONTROL).is_some(), i == 0);
        assert_eq!(misc(picture, VA_ENC_MISC_PARAMETER_TYPE_FRAME_RATE).is_some(), i == 0);
    }
    assert_ne!(idr_ids[0], idr_ids[1], "consecutive IDRs differ in idr_pic_id");
    let first = &pictures[0];
    let rc: VAEncMiscParameterRateControl =
        read(&misc(first, VA_ENC_MISC_PARAMETER_TYPE_RATE_CONTROL).unwrap());
    let hrd: VAEncMiscParameterHRD = read(&misc(first, VA_ENC_MISC_PARAMETER_TYPE_HRD).unwrap());
    let rate: VAEncMiscParameterFrameRate =
        read(&misc(first, VA_ENC_MISC_PARAMETER_TYPE_FRAME_RATE).unwrap());
    assert_eq!((rc.bits_per_second, rc.target_percentage), (8_000_000, 100));
    assert_eq!(hrd.buffer_size, 2_000_000, "a quarter second at the rate");
    assert_eq!(rate.framerate, 60);
}

#[test]
fn bitrate_changes_reach_the_driver_once() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut enc = open(intel_like(), &cfg(1280, 720), false).unwrap();
    let pic = I420::new(1280, 720);
    let mut au = Vec::new();
    enc.encode(&pic, false, 0, &mut au).unwrap();
    enc.set_bitrate(8100); // under 5%: ignored
    assert_eq!(enc.kbps(), 8000);
    enc.encode(&pic, false, 1, &mut au).unwrap();
    enc.set_bitrate(4000);
    assert_eq!(enc.kbps(), 4000);
    enc.encode(&pic, false, 2, &mut au).unwrap();
    enc.encode(&pic, false, 3, &mut au).unwrap();
    let pictures = with(|m| m.pictures.clone());
    let rcs: Vec<Option<(u32, u32)>> = pictures
        .iter()
        .map(|p| {
            misc(p, VA_ENC_MISC_PARAMETER_TYPE_RATE_CONTROL).map(|b| {
                let rc = read::<VAEncMiscParameterRateControl>(&b);
                (rc.bits_per_second, rc.rc_flags & 1)
            })
        })
        .collect();
    // The mid-stream change resets the driver's rate control; the first setting does not.
    assert_eq!(rcs, vec![Some((8_000_000, 0)), None, Some((4_000_000, 1)), None]);
    // A bitrate change is not an IDR.
    assert!(of_kind(&pictures[2], VA_ENC_SEQUENCE_PARAMETER_BUFFER_TYPE).is_empty());
}

#[test]
fn driver_without_packed_headers_gets_ours_in_front() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mock = Mock { packed: VA_ATTRIB_NOT_SUPPORTED, rc: VA_RC_CBR, ..intel_like() };
    let mut enc = open(mock, &cfg(1920, 1080), false).unwrap();
    assert!(!enc.probe().packed_headers);
    assert_eq!(enc.probe().rate_control, VA_RC_CBR);
    assert!(with(|m| m
        .config_attribs
        .iter()
        .all(|a| a.kind != VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS)));
    let pic = I420::new(1920, 1080);
    let mut au = Vec::new();
    assert!(enc.encode(&pic, false, 0, &mut au).unwrap());
    assert_eq!(nal_types(&au), vec![7, 8, 5]);
    assert!(au.starts_with(&enc.sps));
    assert!(!enc.encode(&pic, false, 1, &mut au).unwrap());
    assert_eq!(nal_types(&au), vec![1]);
}

#[test]
fn profile_and_entrypoint_choice() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // Baseline asked for: Constrained Baseline, without CABAC or 8x8 transforms.
    let enc = open(intel_like(), &cfg(1920, 1080), true).unwrap();
    assert_eq!(enc.probe().profile, VA_PROFILE_H264_CONSTRAINED_BASELINE);
    assert!(!enc.cabac() && !enc.high());
    drop(enc);
    // An AMD-like driver: Main only, the full entry point only.
    let amd = Mock {
        profiles: vec![VA_PROFILE_H264_MAIN],
        entrypoints: vec![VA_ENTRYPOINT_ENC_SLICE],
        ..intel_like()
    };
    let enc = open(amd, &cfg(1920, 1080), false).unwrap();
    assert_eq!(
        (enc.probe().profile, enc.probe().entrypoint),
        (VA_PROFILE_H264_MAIN, VA_ENTRYPOINT_ENC_SLICE)
    );
    drop(enc);
    // Baseline asked for and missing: refused with the reason, so the host falls back.
    let amd = Mock { profiles: vec![VA_PROFILE_H264_MAIN], ..intel_like() };
    let err = open(amd, &cfg(1920, 1080), true).err().unwrap().to_string();
    assert!(err.contains("no H.264 constrained-baseline encode entry point"), "{err}");
    // Decode only (no encode entry point), and no usable rate control.
    let decode_only = Mock { entrypoints: vec![1], ..intel_like() };
    assert!(open(decode_only, &cfg(1920, 1080), false).is_err());
    let cqp_only = Mock { rc: 0x10, ..intel_like() };
    assert!(open(cqp_only, &cfg(1920, 1080), false).is_err());
    // Nothing was left open by the refusals.
    assert!(with(|m| m.live.is_empty()));
    assert_eq!(with(|m| m.terminated), 1);
}

#[test]
fn upload_writes_nv12_through_either_path() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    for derive_ok in [true, false] {
        let mut enc = open(Mock { derive_ok, ..intel_like() }, &cfg(64, 32), false).unwrap();
        let mut pic = I420::new(64, 32);
        for (i, y) in pic.y.iter_mut().enumerate() {
            *y = (i % 251) as u8;
        }
        pic.u.fill(10);
        pic.v.fill(20);
        pic.u[33] = 77; // row 1, column 1 of the 32-wide chroma plane
        enc.upload(&pic).unwrap();
        let (pitch, image) = with(|m| {
            let buf = m
                .buffers
                .iter()
                .find(|(_, (k, b))| *k == 0 && !b.is_empty())
                .map(|(_, (_, b))| b.clone());
            (m.pitch as usize, buf)
        });
        if derive_ok {
            // The derived image was destroyed after the copy; nothing to read back.
            assert!(image.is_none());
            assert_eq!(with(|m| m.put_images), 0);
            continue;
        }
        let image = image.expect("the NV12 image");
        assert_eq!(with(|m| m.put_images), 1);
        assert_eq!(&image[pitch..pitch + 64], &pic.y[64..128]);
        let uv = 32 * pitch;
        assert_eq!(&image[uv..uv + 4], &[10, 20, 10, 20]);
        assert_eq!(&image[uv + pitch + 2..uv + pitch + 4], &[77, 20]);
    }
    assert!(with(|m| m.live.is_empty()), "the image is destroyed with the encoder");
}

#[test]
fn driver_failing_the_self_test_is_refused() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // A driver whose P frames come back as IDRs (it ignores the reference): refused at open,
    // with every id released, so the host falls back to software.
    let mock = Mock { break_p_frames: true, ..intel_like() };
    *MOCK.lock().unwrap_or_else(|e| e.into_inner()) = Some(mock);
    let err = Vaapi::open_on(&API, &[PathBuf::from("/dev/null")], &cfg(1280, 720), false)
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("self-test: the second frame"), "{err}");
    assert!(with(|m| m.live.is_empty()));
    assert_eq!(with(|m| m.terminated), 1);
}

#[test]
fn drop_releases_everything() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut enc = open(Mock { derive_ok: false, ..intel_like() }, &cfg(640, 480), false).unwrap();
    let mut au = Vec::new();
    enc.encode(&I420::new(640, 480), false, 0, &mut au).unwrap();
    assert!(
        enc.encode(&I420::new(320, 240), false, 1, &mut au).is_err(),
        "a picture of another size"
    );
    drop(enc);
    assert!(with(|m| m.live.is_empty()), "{:?}", with(|m| m.live.clone()));
    assert_eq!(with(|m| m.terminated), 1);
}

/// Reads an RBSP back (emulation prevention removed).
struct BitReader {
    bytes: Vec<u8>,
    pos: usize,
}

impl BitReader {
    fn new(nal: &[u8]) -> Self {
        let mut bytes = Vec::new();
        let mut zeros = 0;
        for &b in &nal[5..] {
            if zeros >= 2 && b == 3 {
                zeros = 0;
                continue;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            bytes.push(b);
        }
        Self { bytes, pos: 0 }
    }
    fn u(&mut self, n: usize) -> u32 {
        let mut v = 0;
        for _ in 0..n {
            v = v << 1 | u32::from(self.bytes[self.pos / 8] >> (7 - self.pos % 8) & 1);
            self.pos += 1;
        }
        v
    }
    fn ue(&mut self) -> u32 {
        let mut zeros = 0;
        while self.u(1) == 0 {
            zeros += 1;
        }
        (1 << zeros) - 1 + self.u(zeros)
    }
}

#[test]
fn sps_says_no_frame_waits_for_reordering() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let enc = open(intel_like(), &cfg(1920, 1080), false).unwrap();
    let mut r = BitReader::new(&enc.sps);
    assert_eq!(enc.sps[..5], [0, 0, 0, 1, 0x67]);
    assert_eq!((r.u(8), r.u(8), r.u(8)), (100, 0, 42));
    assert_eq!(r.ue(), 0); // sps id
    assert_eq!((r.ue(), r.ue(), r.ue(), r.u(1), r.u(1)), (1, 0, 0, 0, 0));
    assert_eq!(r.ue(), 12); // log2_max_frame_num_minus4
    assert_eq!(r.ue(), 2); // pic_order_cnt_type
    assert_eq!(r.ue(), 1); // max_num_ref_frames
    assert_eq!(r.u(1), 0);
    assert_eq!((r.ue(), r.ue()), (119, 67));
    assert_eq!((r.u(1), r.u(1)), (1, 1));
    assert_eq!(r.u(1), 1); // frame_cropping_flag
    assert_eq!((r.ue(), r.ue(), r.ue(), r.ue()), (0, 0, 0, 4));
    assert_eq!(r.u(1), 1); // vui
    assert_eq!(r.u(8), 0); // no aspect, overscan, signal type, chroma loc, timing, HRD, pic_struct
    assert_eq!(r.u(1), 1); // bitstream_restriction_flag
    assert_eq!(r.u(1), 1);
    assert_eq!((r.ue(), r.ue(), r.ue(), r.ue()), (0, 0, 15, 15));
    assert_eq!(r.ue(), 0, "max_num_reorder_frames");
    assert_eq!(r.ue(), 1, "max_dec_frame_buffering");
    assert_eq!(r.u(1), 1, "rbsp_stop_one_bit");
    drop(enc);
    let enc = open(intel_like(), &cfg(3840, 2160), false).unwrap();
    assert_eq!(enc.level_idc(), 52, "4K at 60 fps");
    assert_eq!(enc.crop(), (0, 0));
    let mut r = BitReader::new(&enc.pps);
    assert_eq!((r.ue(), r.ue(), r.u(1)), (0, 0, 1), "pps and sps ids, CABAC");
}

#[test]
fn nal_inserts_emulation_prevention() {
    assert_eq!(
        nal(0x67, vec![0, 0, 1, 0, 0, 0, 5]),
        vec![0, 0, 0, 1, 0x67, 0, 0, 3, 1, 0, 0, 3, 0, 5]
    );
    let mut b = BitWriter::default();
    b.ue(0);
    b.ue(1);
    b.ue(2);
    b.se(-1);
    // 1 010 011 011 + stop bit: 1010 0110 1110 0000
    assert_eq!(b.finish(), vec![0xa6, 0xe0]);
}

/// On a machine with an Intel or AMD GPU: `cargo test -p cmux-encode vaapi -- --ignored`.
#[test]
#[ignore = "needs a GPU with a VAAPI H.264 encoder"]
fn real_driver_encodes() {
    let mut enc = Vaapi::new(&cfg(1920, 1080), false).unwrap();
    eprintln!("{}", enc.name());
    let pic = I420::new(1920, 1080);
    let mut au = Vec::new();
    assert!(enc.encode(&pic, false, 0, &mut au).unwrap());
    let types = nal_types(&au);
    assert!(types.contains(&7) && types.contains(&8) && types.contains(&5), "{types:?}");
    assert!(!enc.encode(&pic, false, 1, &mut au).unwrap());
    assert!(nal_types(&au).contains(&1));
}
