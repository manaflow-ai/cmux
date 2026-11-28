use super::*;

#[test]
#[cfg(any(target_os = "macos", target_os = "netbsd"))]
fn test_aligned_bpf_hdr_len() {
    assert_eq!(18, BPF_HDRLEN);
}

#[test]
#[cfg(target_os = "openbsd")]
fn test_aligned_bpf_hdr_len() {
    assert_eq!(26, BPF_HDRLEN);
}
