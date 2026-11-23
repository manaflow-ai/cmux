use super::*;

use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::peers::{Answer, Chain, Get, blob_id};

fn aws_keys() -> Keys {
    Keys {
        access_key_id: "AKIAIOSFODNN7EXAMPLE".to_owned(),
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".to_owned(),
        session_token: None,
    }
}

#[test]
fn hmac_matches_rfc_4231() {
    assert_eq!(
        hex(&hmac_sha256(b"Jefe", b"what do ya want for nothing?")),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    );
    // A key longer than the block is hashed first (RFC 4231 test case 6).
    assert_eq!(
        hex(&hmac_sha256(&[0xaa; 131], b"Test Using Larger Than Block-Size Key - Hash Key First")),
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
    );
}

#[test]
fn amz_dates_are_utc() {
    let at = |secs| amz_date(UNIX_EPOCH + Duration::from_secs(secs));
    assert_eq!(at(1_369_353_600), "20130524T000000Z");
    assert_eq!(at(1_709_210_096), "20240229T123456Z");
    assert_eq!(at(946_684_799), "19991231T235959Z");
    assert_eq!(at(0), "19700101T000000Z");
}

/// The "GET Object" example of AWS's Signature Version 4 documentation for S3.
#[test]
fn signs_the_aws_get_object_example() {
    let headers: Vec<(String, String)> = [
        ("Host", "examplebucket.s3.amazonaws.com"),
        ("Range", "bytes=0-9"),
        ("x-amz-content-sha256", EMPTY_SHA256),
        ("x-amz-date", "20130524T000000Z"),
    ]
    .iter()
    .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
    .collect();
    let header = authorization(&aws_keys(), "us-east-1", "GET", "/test.txt", "", &headers);
    assert_eq!(
        header,
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
         SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
         Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    );
}

#[test]
fn http_bases_skip_empty_and_other_schemes() {
    assert_eq!(http_base("https://pub.r2.dev/"), Some("https://pub.r2.dev".to_owned()));
    assert_eq!(http_base(" http://10.0.0.1:9000 "), Some("http://10.0.0.1:9000".to_owned()));
    for bad in ["", "   ", "pub.r2.dev", "ftp://x", "https://", "s3://bucket"] {
        assert_eq!(http_base(bad), None, "{bad:?}");
    }
}

fn bucket(endpoint: &str, path_style: Option<bool>) -> Result<Config, String> {
    Config::bucket(
        "s3",
        Bucket {
            endpoint: endpoint.to_owned(),
            bucket: "blobs".to_owned(),
            path_style,
            prefix: "objects".to_owned(),
            keys: Some(aws_keys()),
            ..Bucket::default()
        },
    )
}

#[test]
fn bucket_urls_by_style() {
    let aws = bucket("https://s3.us-west-2.amazonaws.com", None).unwrap();
    assert_eq!(aws.base, "https://blobs.s3.us-west-2.amazonaws.com/objects");
    assert_eq!(
        (aws.host.as_str(), aws.path.as_str()),
        ("blobs.s3.us-west-2.amazonaws.com", "/objects")
    );
    assert_eq!(aws.region, "us-east-1");
    let minio = bucket("http://127.0.0.1:9000/", None).unwrap();
    assert_eq!(minio.base, "http://127.0.0.1:9000/blobs/objects");
    assert_eq!((minio.host.as_str(), minio.path.as_str()), ("127.0.0.1:9000", "/blobs/objects"));
    // The scheme's own port is not part of the signed host (the client leaves it out too).
    let forced = bucket("https://s3.example.com:443", Some(false)).unwrap();
    assert_eq!(forced.host, "blobs.s3.example.com");
    assert!(bucket("", None).is_err());
    assert!(bucket("minio:9000", None).is_err());
}

fn stores(vars: &[(&str, &str)]) -> (Vec<Config>, Vec<String>) {
    let vars: HashMap<String, String> =
        vars.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect();
    Config::all(&|name: &str| vars.get(name).cloned())
}

#[test]
fn r2_is_one_configuration() {
    let (found, skipped) = stores(&[
        ("CMUX_PROJECTION_R2_URL", "https://pub-1.r2.dev/"),
        ("CMUX_PROJECTION_R2_ACCOUNT_ID", "acct"),
        ("CMUX_PROJECTION_R2_BUCKET", "seed"),
        ("CMUX_PROJECTION_R2_ACCESS_KEY_ID", "id"),
        ("CMUX_PROJECTION_R2_SECRET_ACCESS_KEY", "secret"),
    ]);
    assert!(skipped.is_empty(), "{skipped:?}");
    let [public, private] = found.as_slice() else { panic!("{found:?}") };
    assert_eq!((public.tier, public.base.as_str()), ("r2", "https://pub-1.r2.dev/objects"));
    assert_eq!(public.keys, None);
    assert_eq!(private.base, "https://acct.r2.cloudflarestorage.com/seed/objects");
    assert_eq!(private.region, "auto");
    assert!(private.keys.is_some());
}

#[test]
fn unusable_stores_are_left_out_with_a_reason() {
    for url in ["", "ftp://x", "r2.dev"] {
        let (found, skipped) = stores(&[("CMUX_PROJECTION_R2_URL", url)]);
        assert!(found.is_empty(), "{url:?}");
        assert_eq!(skipped.len(), 1, "{url:?}");
    }
    // A private bucket with no keys would only answer 403: it is never asked.
    let (found, skipped) = stores(&[
        ("CMUX_PROJECTION_S3_ENDPOINT", "https://s3.amazonaws.com"),
        ("CMUX_PROJECTION_S3_BUCKET", "b"),
    ]);
    assert!(found.is_empty());
    assert!(skipped.iter().any(|why| why.contains("no access keys")), "{skipped:?}");
    let (found, _) = stores(&[
        ("CMUX_PROJECTION_R2_ACCOUNT_ID", "acct"),
        ("CMUX_PROJECTION_R2_BUCKET", "seed"),
        ("CMUX_PROJECTION_R2_ACCESS_KEY_ID", "id"),
    ]);
    assert!(found.is_empty());
    let (found, skipped) = stores(&[
        ("CMUX_PROJECTION_S3_ENDPOINT", "https://s3.amazonaws.com"),
        ("CMUX_PROJECTION_S3_ACCESS_KEY_ID", "id"),
        ("CMUX_PROJECTION_S3_SECRET_ACCESS_KEY", "secret"),
    ]);
    assert!(found.is_empty());
    assert!(skipped.iter().any(|why| why.contains("bucket")), "{skipped:?}");
}

#[test]
fn s3_settings_and_standard_aws_keys() {
    let (found, skipped) = stores(&[
        ("CMUX_PROJECTION_S3_ENDPOINT", "http://minio:9000"),
        ("CMUX_PROJECTION_S3_BUCKET", "b"),
        ("CMUX_PROJECTION_S3_REGION", "eu-west-1"),
        ("CMUX_PROJECTION_S3_PREFIX", "/git/blobs/"),
        ("AWS_ACCESS_KEY_ID", "id"),
        ("AWS_SECRET_ACCESS_KEY", "secret"),
        ("AWS_SESSION_TOKEN", "token"),
    ]);
    assert!(skipped.is_empty(), "{skipped:?}");
    let [store] = found.as_slice() else { panic!("{found:?}") };
    assert_eq!(store.base, "http://minio:9000/b/git/blobs");
    assert_eq!(store.region, "eu-west-1");
    assert_eq!(store.keys.as_ref().and_then(|keys| keys.session_token.as_deref()), Some("token"));
    let headers = store.headers(HELLO, UNIX_EPOCH + Duration::from_secs(1_369_353_600));
    let names: Vec<&str> = headers.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(
        names,
        ["x-amz-content-sha256", "x-amz-date", "x-amz-security-token", "authorization"]
    );
    let (found, _) = stores(&[
        ("CMUX_PROJECTION_S3_ENDPOINT", "https://storage.googleapis.com"),
        ("CMUX_PROJECTION_S3_BUCKET", "b"),
        ("CMUX_PROJECTION_S3_PUBLIC", "1"),
    ]);
    let [public] = found.as_slice() else { panic!("{found:?}") };
    assert_eq!(public.keys, None);
    assert!(public.headers(HELLO, SystemTime::now()).is_empty());
}

#[test]
fn the_config_file_fills_what_the_environment_leaves_out() {
    let file = serde_json::json!({"endpoint": "http://minio:9000", "bucket": "b", "public": true});
    assert_eq!(
        from_file(&file, "CMUX_PROJECTION_S3_ENDPOINT").as_deref(),
        Some("http://minio:9000")
    );
    assert_eq!(from_file(&file, "CMUX_PROJECTION_S3_PUBLIC").as_deref(), Some("1"));
    assert_eq!(from_file(&file, "AWS_ACCESS_KEY_ID"), None);
}

// `git hash-object` of "hello\n".
const HELLO: &str = "ce013625030ba8dba906f756967f9e9ca394464a";

/// A local S3: path-style `GET`, `HEAD` and `PUT` of `/<bucket>/objects/<id>`, checking each
/// request's SigV4 signature with `keys` (`None`: a public bucket, asked unsigned) and a `PUT`'s
/// declared payload hash against its body. A request whose signature does not match is answered
/// 403, as S3 does.
struct FakeS3 {
    base: String,
    asked: Arc<AtomicUsize>,
    /// The method of every request, in order.
    methods: Arc<Mutex<Vec<String>>>,
    blobs: Arc<Mutex<HashMap<String, Vec<u8>>>>,
}

fn fake_s3(keys: Option<Keys>, blobs: HashMap<String, Vec<u8>>) -> FakeS3 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let asked = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&asked);
    let methods = Arc::new(Mutex::new(Vec::new()));
    let methods_seen = Arc::clone(&methods);
    let blobs = Arc::new(Mutex::new(blobs));
    let held = Arc::clone(&blobs);
    let keys = Arc::new(keys);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let (keys, blobs, counter, methods) = (
                Arc::clone(&keys),
                Arc::clone(&held),
                Arc::clone(&counter),
                Arc::clone(&methods_seen),
            );
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                let mut reader = BufReader::new(stream);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    counter.fetch_add(1, Ordering::SeqCst);
                    let mut headers = HashMap::new();
                    loop {
                        let mut header = String::new();
                        if reader.read_line(&mut header).unwrap_or(0) == 0
                            || header.trim().is_empty()
                        {
                            break;
                        }
                        if let Some((name, value)) = header.split_once(':') {
                            headers
                                .insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
                        }
                    }
                    let method = line.split_whitespace().next().unwrap_or_default().to_owned();
                    let path = line.split_whitespace().nth(1).unwrap_or_default().to_owned();
                    methods.lock().unwrap().push(method.clone());
                    let length: usize = headers
                        .get("content-length")
                        .and_then(|value| value.parse().ok())
                        .unwrap_or(0);
                    let mut body = vec![0u8; length];
                    if reader.read_exact(&mut body).is_err() {
                        return;
                    }
                    let signed_ok = keys.as_ref().as_ref().is_none_or(|keys| {
                        let mut signed: Vec<(String, String)> =
                            ["host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"]
                                .iter()
                                .filter_map(|name| {
                                    headers
                                        .get(*name)
                                        .map(|value| ((*name).to_owned(), value.clone()))
                                })
                                .collect();
                        signed.sort();
                        let want = authorization(keys, "us-east-1", &method, &path, "", &signed);
                        headers.get("authorization") == Some(&want)
                            && (method != "PUT"
                                || headers.get("x-amz-content-sha256") == Some(&sha256_hex(&body)))
                    });
                    let oid = path.strip_prefix("/blobs/objects/").unwrap_or_default().to_owned();
                    let (status, body) = if !signed_ok {
                        (
                            "403 Forbidden",
                            b"<Error><Code>SignatureDoesNotMatch</Code></Error>".to_vec(),
                        )
                    } else if method == "PUT" {
                        blobs.lock().unwrap().insert(oid, body);
                        ("200 OK", Vec::new())
                    } else if let Some(bytes) = blobs.lock().unwrap().get(&oid) {
                        ("200 OK", if method == "HEAD" { Vec::new() } else { bytes.clone() })
                    } else {
                        ("404 Not Found", Vec::new())
                    };
                    let head = format!(
                        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
                        body.len()
                    );
                    if writer
                        .write_all(head.as_bytes())
                        .and_then(|()| writer.write_all(&body))
                        .is_err()
                    {
                        return;
                    }
                }
            });
        }
    });
    FakeS3 { base: format!("http://127.0.0.1:{port}"), asked, methods, blobs }
}

/// No other source holds anything.
struct NoNet;

impl Get for NoNet {
    fn get(&self, _url: &str, _token: Option<&str>, _deadline: Duration) -> Answer {
        Answer::Absent
    }
}

fn store_at(base: &str, keys: Option<Keys>) -> Store {
    let config = Config::bucket(
        "s3",
        Bucket {
            endpoint: base.to_owned(),
            bucket: "blobs".to_owned(),
            prefix: "objects".to_owned(),
            public: keys.is_none(),
            keys,
            ..Bucket::default()
        },
    )
    .unwrap();
    Store::new(config).unwrap()
}

fn fill(chain: &Chain, oids: &[String]) -> (Vec<String>, crate::peers::Filled, Vec<String>) {
    let kept = std::sync::Mutex::new(Vec::new());
    let (rest, filled) = chain.fill(oids, &|oid, _| {
        kept.lock().unwrap().push(oid.to_owned());
        Ok(())
    });
    (rest, filled, kept.into_inner().unwrap())
}

#[test]
fn a_signed_store_serves_blobs_to_the_chain() {
    let mut keys = aws_keys();
    keys.session_token = Some("session".to_owned());
    let s3 = fake_s3(Some(keys.clone()), HashMap::from([(HELLO.to_owned(), b"hello\n".to_vec())]));
    let other = blob_id(b"nobody has this\n", 40);
    let chain =
        Chain::new(Vec::new(), Box::new(NoNet)).with_stores(vec![store_at(&s3.base, Some(keys))]);
    let (rest, filled, kept) = fill(&chain, &[HELLO.to_owned(), other.clone()]);
    assert_eq!(kept, [HELLO]);
    assert_eq!(rest, [other], "a blob the store lacks goes to git");
    assert_eq!((filled.r2, filled.dropped), (1, 0));
}

#[test]
fn a_public_bucket_is_asked_unsigned() {
    let s3 = fake_s3(None, HashMap::from([(HELLO.to_owned(), b"hello\n".to_vec())]));
    let chain = Chain::new(Vec::new(), Box::new(NoNet)).with_stores(vec![store_at(&s3.base, None)]);
    let (rest, filled, _) = fill(&chain, &[HELLO.to_owned()]);
    assert!(rest.is_empty());
    assert_eq!(filled.r2, 1);
}

/// Wrong keys: the first 403 drops the store, so the fill neither waits nor asks once per blob.
#[test]
fn wrong_keys_drop_the_store_on_its_first_answer() {
    let s3 = fake_s3(Some(aws_keys()), HashMap::from([(HELLO.to_owned(), b"hello\n".to_vec())]));
    let mut wrong = aws_keys();
    wrong.secret_access_key = "not-the-secret".to_owned();
    let chain =
        Chain::new(Vec::new(), Box::new(NoNet)).with_stores(vec![store_at(&s3.base, Some(wrong))]);
    let oids: Vec<String> =
        (0..40).map(|at| blob_id(format!("blob {at}\n").as_bytes(), 40)).collect();
    let started = Instant::now();
    let (rest, filled, kept) = fill(&chain, &oids);
    assert!(kept.is_empty());
    assert_eq!(rest.len(), oids.len(), "every blob goes to git");
    assert_eq!(filled.dropped, 1);
    // At most the requests already in flight when the first 403 came back (8 at once).
    let asked = s3.asked.load(Ordering::SeqCst);
    assert!(asked <= 8, "asked {asked} times");
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
}

fn example_keys() -> Keys {
    Keys {
        access_key_id: "AKIDEXAMPLE".to_owned(),
        secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".to_owned(),
        session_token: None,
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> &'a str {
    headers.iter().find(|(at, _)| at == name).map_or("", |(_, value)| value.as_str())
}

/// The same requests signed by botocore 1.34.46's `S3SigV4Auth` (payload signing on).
#[test]
fn signs_get_and_put_as_botocore_does() {
    let at = UNIX_EPOCH + Duration::from_secs(1_795_406_706);
    let store = |endpoint: &str, bucket: &str, prefix: &str| {
        Config::bucket(
            "s3",
            Bucket {
                endpoint: endpoint.to_owned(),
                bucket: bucket.to_owned(),
                region: "auto".to_owned(),
                prefix: prefix.to_owned(),
                keys: Some(example_keys()),
                ..Bucket::default()
            },
        )
        .unwrap()
    };
    let get = store("http://127.0.0.1:9000", "blobs", "fleet/objects").signed(
        "GET",
        HELLO,
        EMPTY_SHA256,
        at,
    );
    assert_eq!(header(&get, "x-amz-content-sha256"), EMPTY_SHA256);
    assert!(header(&get, "authorization").ends_with(
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
         Signature=bcd733d4784bab47b63bc7c087c96c323f98dac7d2ba863fc38876b4756e90ab"
    ));
    let put = store("https://acct.r2.cloudflarestorage.com:443", "blobs", "objects").signed(
        "PUT",
        HELLO,
        &sha256_hex(b"hello\n"),
        at,
    );
    assert_eq!(
        header(&put, "x-amz-content-sha256"),
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    );
    assert!(
        header(&put, "authorization").ends_with(
            "Signature=e071a88b764001aed706aefcd23eff178300f0300cab083c15d534e71fa3fcf4"
        ),
        "{put:?}"
    );
}

/// A push sends only what the bucket lacks (one `HEAD` each), and the chain then reads it back.
#[test]
fn a_push_stores_what_the_bucket_lacks_and_skips_what_it_has() {
    let s3 = fake_s3(Some(aws_keys()), HashMap::from([(HELLO.to_owned(), b"hello\n".to_vec())]));
    let store = store_at(&s3.base, Some(aws_keys()));
    let new = b"a new blob\n";
    let new_id = blob_id(new, 40);
    assert_eq!(store.push(HELLO, b"hello\n").unwrap(), Pushed::Had);
    assert_eq!(store.push(&new_id, new).unwrap(), Pushed::Stored);
    assert_eq!(store.push(&new_id, new).unwrap(), Pushed::Had);
    assert_eq!(*s3.methods.lock().unwrap(), ["HEAD", "HEAD", "PUT", "HEAD"]);
    assert_eq!(s3.blobs.lock().unwrap().get(&new_id).map(Vec::as_slice), Some(&new[..]));
    let chain = Chain::new(Vec::new(), Box::new(NoNet)).with_stores(vec![store]);
    let (rest, filled, kept) = fill(&chain, std::slice::from_ref(&new_id));
    assert!(rest.is_empty());
    assert_eq!((kept, filled.r2), (vec![new_id], 1));
}

/// Bytes that are not the blob they are named as are never sent: the bucket holds no wrong object
/// under a right name.
#[test]
fn a_push_refuses_bytes_that_do_not_hash_to_their_id() {
    let s3 = fake_s3(Some(aws_keys()), HashMap::new());
    let store = store_at(&s3.base, Some(aws_keys()));
    assert!(store.push(HELLO, b"not hello\n").is_err());
    assert!(store.push("../../etc", b"hello\n").is_err());
    assert_eq!(s3.asked.load(Ordering::SeqCst), 0);
}

#[test]
fn a_push_with_wrong_keys_is_denied() {
    let s3 = fake_s3(Some(aws_keys()), HashMap::new());
    let mut wrong = aws_keys();
    wrong.secret_access_key = "not-the-secret".to_owned();
    let store = store_at(&s3.base, Some(wrong));
    assert_eq!(store.push(HELLO, b"hello\n").unwrap(), Pushed::Denied(403));
    assert!(s3.blobs.lock().unwrap().is_empty());
}

fn push_target(to: &str, vars: &[(&str, &str)]) -> Result<Config, String> {
    let vars: HashMap<String, String> =
        vars.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect();
    Config::push_target(to, &|name: &str| vars.get(name).cloned())
}

#[test]
fn a_push_target_is_the_configured_store_or_the_url_with_the_s3_keys() {
    // The store the chain reads, with its own keys and region.
    let configured = push_target(
        "https://acct.r2.cloudflarestorage.com/seed/objects/",
        &[
            ("CMUX_PROJECTION_R2_ACCOUNT_ID", "acct"),
            ("CMUX_PROJECTION_R2_BUCKET", "seed"),
            ("CMUX_PROJECTION_R2_ACCESS_KEY_ID", "r2-id"),
            ("CMUX_PROJECTION_R2_SECRET_ACCESS_KEY", "r2-secret"),
            ("AWS_ACCESS_KEY_ID", "aws-id"),
            ("AWS_SECRET_ACCESS_KEY", "aws-secret"),
        ],
    )
    .unwrap();
    assert_eq!((configured.tier, configured.region.as_str()), ("r2", "auto"));
    assert_eq!(configured.keys.map(|keys| keys.access_key_id).as_deref(), Some("r2-id"));
    // Any other base, with the standard keys.
    let url = push_target(
        "http://127.0.0.1:9000/blobs/fleet",
        &[("AWS_ACCESS_KEY_ID", "id"), ("AWS_SECRET_ACCESS_KEY", "secret")],
    )
    .unwrap();
    assert_eq!(url.base, "http://127.0.0.1:9000/blobs/fleet");
    assert_eq!((url.host.as_str(), url.path.as_str()), ("127.0.0.1:9000", "/blobs/fleet"));
    assert_eq!(url.region, "us-east-1");
    let r2 = push_target(
        "https://other.r2.cloudflarestorage.com/b/objects",
        &[
            ("CMUX_PROJECTION_S3_ACCESS_KEY_ID", "id"),
            ("CMUX_PROJECTION_S3_SECRET_ACCESS_KEY", "s"),
        ],
    )
    .unwrap();
    assert_eq!(r2.region, "auto");
    // A public bucket is read unsigned, but a push always signs.
    let no_keys = push_target(
        "https://pub-1.r2.dev/objects",
        &[("CMUX_PROJECTION_R2_URL", "https://pub-1.r2.dev")],
    );
    assert!(no_keys.is_err_and(|why| why.contains("no access keys")));
    assert!(push_target("s3://bucket", &[]).is_err());
}

/// botocore 1.34.46's `S3SigV4Auth` with a session token: it is sent and signed as
/// `x-amz-security-token`, and never printed.
#[test]
fn signs_a_session_token_as_botocore_does() {
    let mut keys = example_keys();
    keys.session_token = Some("SESSIONTOKEN123".to_owned());
    let config = Config::bucket(
        "s3",
        Bucket {
            endpoint: "http://127.0.0.1:9000".to_owned(),
            bucket: "blobs".to_owned(),
            region: "auto".to_owned(),
            prefix: "fleet/objects".to_owned(),
            keys: Some(keys.clone()),
            ..Bucket::default()
        },
    )
    .unwrap();
    let get =
        config.signed("GET", HELLO, EMPTY_SHA256, UNIX_EPOCH + Duration::from_secs(1_795_406_706));
    assert_eq!(header(&get, "x-amz-security-token"), "SESSIONTOKEN123");
    assert!(header(&get, "authorization").ends_with(
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, \
         Signature=cd0c3031b2d0aaac8ed164ee8da8fd97fac9d201554e52da15cb204f9d71c7dd"
    ));
    assert!(!format!("{keys:?}").contains("SESSIONTOKEN123"));
    assert!(!format!("{config:?}").contains("SESSIONTOKEN123"));
}

/// The client sends the host lowercased, so it is signed lowercased.
#[test]
fn an_uppercase_host_signs_as_the_client_sends_it() {
    let upper = bucket("https://S3.Example.COM", Some(true)).unwrap();
    assert_eq!(upper.host, "s3.example.com");
    let virtual_hosted = bucket("https://S3.Example.COM", Some(false)).unwrap();
    assert_eq!(virtual_hosted.host, "blobs.s3.example.com");
    assert_eq!(Config::public("r2", "https://Pub-1.R2.dev").unwrap().host, "pub-1.r2.dev");
    let at = UNIX_EPOCH + Duration::from_secs(1_369_353_600);
    assert_eq!(
        upper.headers(HELLO, at),
        bucket("https://s3.example.com", Some(true)).unwrap().headers(HELLO, at)
    );
}

/// The client folds `.` and `..` out of the path it sends, so a signature over them never matches.
#[test]
fn dot_segments_are_refused() {
    let with_prefix = |prefix: &str| {
        Config::bucket(
            "s3",
            Bucket {
                endpoint: "http://127.0.0.1:9000".to_owned(),
                bucket: "blobs".to_owned(),
                prefix: prefix.to_owned(),
                keys: Some(aws_keys()),
                ..Bucket::default()
            },
        )
    };
    assert!(with_prefix("../other").is_err());
    assert!(with_prefix("a/./objects").is_err());
    assert!(with_prefix("a..b/objects").is_ok());
    assert!(bucket("http://127.0.0.1:9000/..", None).is_err());
    assert_eq!(Config::public("r2", "https://pub.r2.dev/a/../b"), None);
    let keys = [("AWS_ACCESS_KEY_ID", "id"), ("AWS_SECRET_ACCESS_KEY", "secret")];
    assert!(push_target("http://127.0.0.1:9000/blobs/../objects", &keys).is_err());
}

/// A store that answers every request 403 with `body`, counting them.
fn refusing_s3(body: &'static str) -> FakeS3 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let asked = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&asked);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let counter = Arc::clone(&counter);
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                let mut reader = BufReader::new(stream);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    counter.fetch_add(1, Ordering::SeqCst);
                    while reader.read_line(&mut line).unwrap_or(0) > 0
                        && !line.ends_with("\r\n\r\n")
                    {}
                    let head = format!(
                        "HTTP/1.1 403 Forbidden\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    );
                    if writer.write_all(head.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    FakeS3 {
        base: format!("http://127.0.0.1:{port}"),
        asked,
        methods: Arc::default(),
        blobs: Arc::default(),
    }
}

/// AWS answers 403 `AccessDenied` for an object it lacks when the key may not list the bucket:
/// each blob is a miss and the store stays in the chain.
#[test]
fn access_denied_is_a_miss_not_a_dropped_store() {
    let s3 =
        refusing_s3("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>");
    let chain = Chain::new(Vec::new(), Box::new(NoNet))
        .with_stores(vec![store_at(&s3.base, Some(aws_keys()))]);
    let oids: Vec<String> =
        (0..12).map(|at| blob_id(format!("blob {at}\n").as_bytes(), 40)).collect();
    let (rest, filled, kept) = fill(&chain, &oids);
    assert!(kept.is_empty());
    assert_eq!(rest.len(), oids.len());
    assert_eq!(filled.dropped, 0);
    assert_eq!(s3.asked.load(Ordering::SeqCst), oids.len(), "every blob was asked");
}
