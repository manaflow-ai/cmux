use super::*;
use std::ffi::CString;

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
    unsafe { cmux_layout_cache_string_free(p) };
    Some(s)
}

const CACHE: &str = r#"{"version":1,"build_key":"b","written_at_ms":1,"displays":[{"id":1,"frame":{"x":0,"y":0,"width":1440,"height":900},"backing_scale":2}],
 "windows":[{"id":"w","frame":{"x":10,"y":10,"width":800,"height":600},"display_id":1,"backing_scale":2,
 "panes":{"type":"split","axis":"h","fractions":[0.5,0.5],"children":[
   {"type":"leaf","pane_id":"a","kind":"terminal","frame":{"x":0,"y":0,"width":400,"height":600}},
   {"type":"leaf","pane_id":"b","kind":"chat","frame":{"x":401,"y":0,"width":399,"height":600}}]}}]}"#;

#[test]
fn write_read_round_trip_through_c() {
    let dir = std::env::temp_dir().join(format!("cmux-layout-cache-ffi-{}", std::process::id()));
    let path = take(unsafe { cmux_layout_cache_path(c(dir.to_str().unwrap()).as_ptr()) }).unwrap();
    let p = c(&path);
    assert_eq!(unsafe { cmux_layout_cache_write(p.as_ptr(), c(CACHE).as_ptr()) }, 0);
    let back = take(unsafe { cmux_layout_cache_read(p.as_ptr()) }).unwrap();
    assert_eq!(LayoutCache::from_json(&back), LayoutCache::from_json(CACHE));
    assert_eq!(unsafe { cmux_layout_cache_write(p.as_ptr(), c("garbage").as_ptr()) }, BAD_INPUT);
    assert_eq!(unsafe { cmux_layout_cache_write(std::ptr::null(), c(CACHE).as_ptr()) }, BAD_INPUT);

    let co = cmux_layout_cache_coalescer_new();
    unsafe { cmux_layout_cache_coalescer_note(co, 1_000) };
    assert!(!unsafe { cmux_layout_cache_coalescer_due(co, 1_100) });
    assert_eq!(unsafe { cmux_layout_cache_coalescer_next_due_ms(co) }, 1_250);
    assert!(unsafe { cmux_layout_cache_coalescer_due(co, 1_250) });
    assert!(unsafe { cmux_layout_cache_coalescer_flush_now(co) });
    assert_eq!(unsafe { cmux_layout_cache_coalescer_write(co, p.as_ptr(), c(CACHE).as_ptr()) }, 1);
    assert_eq!(unsafe { cmux_layout_cache_coalescer_next_due_ms(co) }, -1);
    unsafe { cmux_layout_cache_coalescer_note(co, 2_000) };
    assert_eq!(unsafe { cmux_layout_cache_coalescer_write(co, p.as_ptr(), c(CACHE).as_ptr()) }, 0);
    assert!(unsafe { cmux_layout_cache_coalescer_wrote(co, c(CACHE).as_ptr()) });
    assert!(!unsafe { cmux_layout_cache_coalescer_wrote(co, c("{").as_ptr()) });
    unsafe { cmux_layout_cache_coalescer_free(co) };
    unsafe { cmux_layout_cache_coalescer_free(std::ptr::null_mut()) };
    assert!(!unsafe { cmux_layout_cache_coalescer_due(std::ptr::null_mut(), 0) });
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn usable_and_reconcile_answer_json() {
    let now = c(
        r#"{"build_key":"b","displays":[{"id":1,"frame":{"x":0,"y":0,"width":1440,"height":900},"backing_scale":2}]}"#,
    );
    let u = take(unsafe { cmux_layout_cache_usable(c(CACHE).as_ptr(), now.as_ptr()) }).unwrap();
    assert!(u.contains(r#""windows":["w"]"#), "{u}");
    let cache = LayoutCache::from_json(CACHE).unwrap();
    let node = c(&serde_json::to_string(&cache.windows[0].panes).unwrap());
    let a = take(unsafe {
        cmux_layout_cache_reconcile(node.as_ptr(), c(r#"{"panes":["a","b"]}"#).as_ptr())
    })
    .unwrap();
    assert!(a.contains(r#""transitions":[]"#), "{a}");
    let a = take(unsafe {
        cmux_layout_cache_reconcile(node.as_ptr(), c(r#"{"panes":["b"]}"#).as_ptr())
    })
    .unwrap();
    assert!(a.contains(r#""kind":"removed""#), "{a}");
    assert!(
        take(unsafe { cmux_layout_cache_reconcile(c("[").as_ptr(), c("{}").as_ptr()) }).is_none()
    );
    assert!(take(unsafe { cmux_layout_cache_usable(std::ptr::null(), now.as_ptr()) }).is_none());
    let s = take(unsafe {
        cmux_layout_cache_reconcile_strip(
            c(r#"[{"id":"t","x":0,"width":90}]"#).as_ptr(),
            c(r#"["t","u"]"#).as_ptr(),
            100.0,
        )
    })
    .unwrap();
    assert!(s.contains(r#""kind":"added""#), "{s}");
    let r = take(unsafe {
        cmux_layout_cache_reconcile_rows(
            c(r#"[{"id":"r","height":30}]"#).as_ptr(),
            c(r#"["r"]"#).as_ptr(),
            28.0,
        )
    })
    .unwrap();
    assert!(r.contains(r#""height":30.0"#), "{r}");
}

#[test]
fn shift_score_and_swap_wait_through_c() {
    let before = c(r#"[{"id":"a","x":0,"y":0,"width":10,"height":10}]"#);
    let after = c(r#"[{"id":"a","x":5,"y":0,"width":10,"height":10}]"#);
    let vp = c(r#"{"x":0,"y":0,"width":100,"height":100}"#);
    assert_eq!(
        unsafe { cmux_layout_cache_shift_score(before.as_ptr(), before.as_ptr(), vp.as_ptr()) },
        0.0
    );
    assert!(
        unsafe { cmux_layout_cache_shift_score(before.as_ptr(), after.as_ptr(), vp.as_ptr()) }
            > 0.0
    );
    assert_eq!(
        unsafe { cmux_layout_cache_shift_score(c("x").as_ptr(), after.as_ptr(), vp.as_ptr()) },
        -1.0
    );
    assert_eq!(cmux_layout_cache_swap_wait_ms(0, 2, 2, 0), 0);
    assert_eq!(cmux_layout_cache_swap_wait_ms(0, 2, 1, 100), 300);
    assert_eq!(cmux_layout_cache_swap_wait_ms(2, 1, 0, 0), 1_500);
}
