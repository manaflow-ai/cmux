use cmux_launch_record::LaunchRecord;
use std::fs;
use std::time::Instant;

fn main() {
    let path =
        std::env::temp_dir().join(format!("cmux-launch-record-bench-{}", std::process::id()));
    let mut bytes = Vec::with_capacity(64 * 1024);
    bytes.extend_from_slice(b"CMUXLR01\x01\x00\x00\x00\x00\x00");
    bytes.extend_from_slice(&65520u16.to_le_bytes());
    bytes.resize(64 * 1024, b'x');
    // The final string is intentionally valid ASCII and fills the cap.
    fs::write(&path, &bytes).expect("write benchmark record");
    let start = Instant::now();
    let mut count = 0usize;
    while start.elapsed().as_secs_f64() < 1.0 {
        if LaunchRecord::read(&path).is_some() {
            count += 1;
        }
    }
    println!("read {} records in {:?}", count, start.elapsed());
    let _ = fs::remove_file(path);
}
