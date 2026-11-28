use super::Captured;

const SECRET: &str = "seeded-SECRET-7f3a";

fn request(target: &str, headers: &[(&str, &str)], body: &str) -> Captured {
    Captured {
        host: "api.example".to_owned(),
        method: "POST".to_owned(),
        target: target.to_owned(),
        headers: headers.iter().map(|(n, v)| ((*n).to_owned(), (*v).to_owned())).collect(),
        body: body.as_bytes().to_vec(),
    }
}

// Reference encodings from Python's base64 module, not from capture's own encoder.
#[test]
fn a_base64_copy_is_found_at_every_alignment_in_both_alphabets() {
    for body in [
        "c2VlZGVkLVNFQ1JFVC03ZjNhdGFpbA==", // standard, secret at byte 0
        "YXNlZWRlZC1TRUNSRVQtN2YzYXRhaWw=", // standard, after 1 byte
        "YWJzZWVkZWQtU0VDUkVULTdmM2F0YWls", // standard, after 2 bytes
    ] {
        assert_eq!(request("/", &[], body).carries(SECRET), ["body"], "{body}");
    }
    for value in [
        "c2VlZGVkLVNFQ1JFVC03ZjNhPz4=",     // URL-safe, at byte 0
        "YXNlZWRlZC1TRUNSRVQtN2YzYT8-",     // URL-safe, after 1 byte ('-')
        "YWJzZWVkZWQtU0VDUkVULTdmM2E_Pg==", // URL-safe, after 2 bytes ('_')
    ] {
        assert_eq!(request("/", &[("x-blob", value)], "").carries(SECRET), ["header x-blob"]);
    }
    let in_query = request("/upload?data=YWJzZWVkZWQtU0VDUkVULTdmM2F0YWls", &[], "");
    assert_eq!(in_query.carries(SECRET), ["target"]);
}

#[test]
fn a_percent_encoded_header_value_is_found() {
    let sent = request("/", &[("x-auth", "Bearer%20seeded-SECRET-7f3a")], "");
    assert_eq!(sent.carries("Bearer seeded-SECRET-7f3a"), ["header x-auth"]);
}

#[test]
fn plus_means_a_space_only_in_the_query_and_a_form_body() {
    let secret = "seeded SECRET 7f3a";
    let sent = request("/x?k=seeded+SECRET+7f3a", &[("x-auth", "seeded+SECRET+7f3a")], "");
    assert_eq!(sent.carries(secret), ["target"]);
    let form = [("content-type", "application/x-www-form-urlencoded")];
    assert_eq!(request("/", &form, "k=seeded+SECRET+7f3a").carries(secret), ["body"]);
    assert!(request("/", &[], "k=seeded+SECRET+7f3a").carries(secret).is_empty());
    // A secret that holds a `+` is still found where `+` is written as itself.
    let sent = request("/", &[("x-auth", "a+seeded-SECRET")], "");
    assert_eq!(sent.carries("a+seeded-SECRET"), ["header x-auth"]);
}

#[test]
fn a_neighbouring_secret_is_not_a_match() {
    // base64 of "seeded-SECRET-7f3b": shares every character but the last few.
    let sent = request("/", &[("x-blob", "c2VlZGVkLVNFQ1JFVC03ZjNi")], "c2VlZGVkLVNFQ1JFVC03ZjNi");
    assert!(sent.carries(SECRET).is_empty());
}
