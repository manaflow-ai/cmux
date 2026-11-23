use super::*;

fn example(region: &str) -> Key {
    Key {
        id: "AKIDEXAMPLE".to_owned(),
        secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".to_owned(),
        region: region.to_owned(),
        session: None,
    }
}

fn header<'a>(headers: &'a [(&'static str, String)], name: &str) -> &'a str {
    headers.iter().find(|(at, _)| *at == name).map_or("", |(_, value)| value.as_str())
}

#[test]
fn dates_are_utc_stamps() {
    assert_eq!(amz_date(0), ("19700101T000000Z".to_owned(), "19700101".to_owned()));
    assert_eq!(amz_date(1_440_938_160).0, "20150830T123600Z");
    assert_eq!(amz_date(1_795_406_706).0, "20261123T040506Z");
    // A leap day and the last second of a year.
    assert_eq!(amz_date(951_782_400).0, "20000229T000000Z");
    assert_eq!(amz_date(1_704_067_199).0, "20231231T235959Z");
}

/// AWS's own SigV4 suite, `get-vanilla`.
#[test]
fn signs_the_aws_get_vanilla_vector() {
    let headers = sign(
        "GET",
        "https://example.amazonaws.com/",
        &example("us-east-1"),
        "service",
        1_440_938_160,
        EMPTY_SHA256,
    )
    .unwrap();
    assert_eq!(header(&headers, "x-amz-date"), "20150830T123600Z");
    assert_eq!(header(&headers, "x-amz-content-sha256"), "");
    assert_eq!(
        header(&headers, "authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
         SignedHeaders=host;x-amz-date, \
         Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    );
}

/// The same requests signed by botocore 1.34.46's `S3SigV4Auth` (payload signing on).
#[test]
fn signs_s3_get_and_put_as_botocore_does() {
    let get = sign(
        "GET",
        "http://127.0.0.1:9000/blobs/fleet/objects/ce013625030ba8dba906f756967f9e9ca394464a",
        &example("auto"),
        SERVICE,
        1_795_406_706,
        EMPTY_SHA256,
    )
    .unwrap();
    assert_eq!(header(&get, "x-amz-content-sha256"), EMPTY_SHA256);
    assert!(header(&get, "authorization").ends_with(
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
         Signature=bcd733d4784bab47b63bc7c087c96c323f98dac7d2ba863fc38876b4756e90ab"
    ));
    let put = sign(
        "PUT",
        "https://acct.r2.cloudflarestorage.com:443/blobs/objects/ce013625030ba8dba906f756967f9e9ca394464a",
        &example("auto"),
        SERVICE,
        1_795_406_706,
        &sha256_hex(b"hello\n"),
    )
    .unwrap();
    assert_eq!(
        header(&put, "x-amz-content-sha256"),
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    );
    assert!(
        header(&put, "authorization").ends_with(
            "Signature=e071a88b764001aed706aefcd23eff178300f0300cab083c15d534e71fa3fcf4"
        )
    );
}

#[test]
fn refuses_urls_it_would_sign_wrong() {
    let key = example("auto");
    for url in [
        "ftp://host/bucket",
        "https://host/bucket?list-type=2",
        "https://host/a bucket",
        "https://user@host/bucket",
        "https:///bucket",
    ] {
        assert!(sign("GET", url, &key, SERVICE, 0, EMPTY_SHA256).is_err(), "{url}");
    }
}

#[test]
fn keys_parse_from_an_env_file_and_hide_the_secret() {
    let key = Key::parse(
        "# R2 read key\nexport AWS_ACCESS_KEY_ID=\"abc\"\nAWS_SECRET_ACCESS_KEY=s3cr3t\n",
        "auto",
    )
    .unwrap();
    assert_eq!(
        (key.id.as_str(), key.secret.as_str(), key.region.as_str()),
        ("abc", "s3cr3t", "auto")
    );
    assert!(!format!("{key:?}").contains("s3cr3t"));
    let key =
        Key::parse("AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\nAWS_REGION=us-east-1", "auto");
    assert_eq!(key.unwrap().region, "us-east-1");
    assert!(Key::parse("AWS_ACCESS_KEY_ID=a\n", "auto").is_none());
    assert!(Key::parse("AWS_ACCESS_KEY_ID=\nAWS_SECRET_ACCESS_KEY=b", "auto").is_none());
}

/// botocore 1.34.46 with a temporary key: the session token is sent and signed.
#[test]
fn signs_a_session_token_as_botocore_does() {
    let key = Key { session: Some("SESSIONTOKEN123".to_owned()), ..example("auto") };
    let get = sign(
        "GET",
        "http://127.0.0.1:9000/blobs/fleet/objects/ce013625030ba8dba906f756967f9e9ca394464a",
        &key,
        SERVICE,
        1_795_406_706,
        EMPTY_SHA256,
    )
    .unwrap();
    assert_eq!(header(&get, "x-amz-security-token"), "SESSIONTOKEN123");
    assert!(header(&get, "authorization").ends_with(
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, \
         Signature=cd0c3031b2d0aaac8ed164ee8da8fd97fac9d201554e52da15cb204f9d71c7dd"
    ));
    assert!(!format!("{key:?}").contains("SESSIONTOKEN123"));
}

#[test]
fn an_uppercase_host_signs_as_the_client_sends_it() {
    let key = example("auto");
    let url = "http://127.0.0.1:9000/blobs/fleet/objects/ce013625030ba8dba906f756967f9e9ca394464a";
    let lower = sign("GET", url, &key, SERVICE, 1_795_406_706, EMPTY_SHA256).unwrap();
    let mixed = sign(
        "GET",
        "https://Acct.R2.cloudflarestorage.com/b/objects/x",
        &key,
        SERVICE,
        1_795_406_706,
        EMPTY_SHA256,
    )
    .unwrap();
    let plain = sign(
        "GET",
        "https://acct.r2.cloudflarestorage.com/b/objects/x",
        &key,
        SERVICE,
        1_795_406_706,
        EMPTY_SHA256,
    )
    .unwrap();
    assert_eq!(mixed, plain);
    assert_eq!(header(&lower, "x-amz-security-token"), "");
}

#[test]
fn dot_segments_are_refused() {
    let key = example("auto");
    for url in ["https://host/b/./objects/x", "https://host/b/../objects/x"] {
        assert!(sign("GET", url, &key, SERVICE, 0, EMPTY_SHA256).is_err(), "{url}");
    }
}
