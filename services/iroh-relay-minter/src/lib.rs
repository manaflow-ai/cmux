use std::{
    env, fmt,
    str::FromStr,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE_NO_PAD},
};
use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use http_body::Body;
use http_body_util::BodyExt as _;
use hyper::{
    Method, Request, Response, StatusCode,
    body::Bytes,
    header::{ALLOW, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, HeaderMap, HeaderName},
};
use iroh::{EndpointId, SecretKey};
use iroh_services::{
    ApiSecret,
    caps::{Cap, Caps, RelayCap, create_api_token_from_secret_key},
};
use rcan::Expires;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use vercel_runtime::ResponseBody;
use zeroize::Zeroizing;

pub const MINT_PATH: &str = "/api/relay-token";
pub const RELAY_TOKEN_LIFETIME_SECONDS: u64 = 86_400;
pub const MAX_REQUEST_BYTES: usize = 4 * 1_024;

const MAX_RESPONSE_BYTES: usize = 32 * 1_024;
const MAX_TOKEN_BYTES: usize = 16 * 1_024;
const CLOCK_SKEW_SECONDS: u64 = 30;
const SERVICES_SECRET_ENV: &str = "IROH_SERVICES_API_SECRET";
const HMAC_SECRET_ENV: &str = "CMUX_IROH_MINT_HMAC_SECRET_B64";
const HMAC_PREVIOUS_SECRET_ENV: &str = "CMUX_IROH_MINT_HMAC_PREVIOUS_SECRET_B64";
const TIMESTAMP_HEADER: HeaderName = HeaderName::from_static("x-cmux-iroh-timestamp");
const SIGNATURE_HEADER: HeaderName = HeaderName::from_static("x-cmux-iroh-signature");

type HmacSha256 = Hmac<Sha256>;

pub struct MinterConfig {
    issuer: SecretKey,
    hmac_secret: Zeroizing<Vec<u8>>,
    hmac_previous_secret: Option<Zeroizing<Vec<u8>>>,
}

impl MinterConfig {
    pub fn from_env() -> Result<Self, ConfigurationError> {
        let services_secret = Zeroizing::new(bounded_env(SERVICES_SECRET_ENV, 16_384)?);
        let api_secret =
            ApiSecret::from_str(services_secret.as_str()).map_err(|_| ConfigurationError)?;
        let hmac_secret_text = Zeroizing::new(bounded_env(HMAC_SECRET_ENV, 512)?);
        let hmac_secret = Zeroizing::new(decode_hmac_secret(hmac_secret_text.as_str())?);
        let hmac_previous_secret = optional_bounded_env(HMAC_PREVIOUS_SECRET_ENV, 512)?
            .map(Zeroizing::new)
            .map(|value| decode_hmac_secret(value.as_str()))
            .transpose()?
            .map(Zeroizing::new);
        if hmac_previous_secret
            .as_ref()
            .is_some_and(|previous| previous.as_slice() == hmac_secret.as_slice())
        {
            return Err(ConfigurationError);
        }

        Ok(Self {
            issuer: api_secret.secret,
            hmac_secret,
            hmac_previous_secret,
        })
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ConfigurationError;

impl fmt::Display for ConfigurationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("relay minter configuration is unavailable")
    }
}

impl std::error::Error for ConfigurationError {}

pub async fn handle_request<B>(
    request: Request<B>,
    config: &MinterConfig,
    now: SystemTime,
) -> Response<ResponseBody>
where
    B: Body<Data = Bytes> + Unpin,
{
    match process_request(request, config, now).await {
        Ok(response) => json_response(StatusCode::OK, &response),
        Err(error) => error_response(error.status(), error.code()),
    }
}

pub fn configuration_error_response() -> Response<ResponseBody> {
    error_response(StatusCode::SERVICE_UNAVAILABLE, "configuration_unavailable")
}

async fn process_request<B>(
    request: Request<B>,
    config: &MinterConfig,
    now: SystemTime,
) -> Result<MintResponse, RequestFailure>
where
    B: Body<Data = Bytes> + Unpin,
{
    if request.method() != Method::POST {
        return Err(RequestFailure::Method);
    }
    if request.uri().path() != MINT_PATH || request.uri().query().is_some() {
        return Err(RequestFailure::Path);
    }
    require_json_content_type(request.headers())?;
    validate_content_length(request.headers())?;

    let timestamp_text = single_header(request.headers(), &TIMESTAMP_HEADER)
        .ok_or(RequestFailure::Authentication)?
        .to_owned();
    let timestamp = parse_timestamp(&timestamp_text).ok_or(RequestFailure::Authentication)?;
    let now_seconds = unix_seconds(now).ok_or(RequestFailure::Internal)?;
    if now_seconds.abs_diff(timestamp) > CLOCK_SKEW_SECONDS {
        return Err(RequestFailure::Authentication);
    }

    let signature_text = single_header(request.headers(), &SIGNATURE_HEADER)
        .ok_or(RequestFailure::Authentication)?;
    let signature = decode_signature(signature_text).ok_or(RequestFailure::Authentication)?;

    let body = read_bounded_body(request.into_body()).await?;
    verify_configured_hmac(config, &timestamp_text, &body, &signature)?;

    let input: MintRequest =
        serde_json::from_slice(&body).map_err(|_| RequestFailure::InvalidBody)?;
    if input.lifetime_seconds != RELAY_TOKEN_LIFETIME_SECONDS {
        return Err(RequestFailure::InvalidLifetime);
    }
    let endpoint_id = parse_endpoint_id(&input.endpoint_id)?;

    mint_token(config, endpoint_id, now_seconds)
}

async fn read_bounded_body<B>(mut body: B) -> Result<Vec<u8>, RequestFailure>
where
    B: Body<Data = Bytes> + Unpin,
{
    if body
        .size_hint()
        .upper()
        .is_some_and(|upper| upper > MAX_REQUEST_BYTES as u64)
    {
        return Err(RequestFailure::BodyTooLarge);
    }

    let mut bytes = Vec::with_capacity(
        body.size_hint()
            .upper()
            .unwrap_or(0)
            .min(MAX_REQUEST_BYTES as u64) as usize,
    );
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| RequestFailure::InvalidBody)?;
        let Ok(data) = frame.into_data() else {
            continue;
        };
        let Some(next_len) = bytes.len().checked_add(data.len()) else {
            return Err(RequestFailure::BodyTooLarge);
        };
        if next_len > MAX_REQUEST_BYTES {
            return Err(RequestFailure::BodyTooLarge);
        }
        bytes.extend_from_slice(&data);
    }
    Ok(bytes)
}

fn mint_token(
    config: &MinterConfig,
    endpoint_id: EndpointId,
    authenticated_at: u64,
) -> Result<MintResponse, RequestFailure> {
    let capability = Caps::new([Cap::Relay(RelayCap::Use)]);
    let rcan = create_api_token_from_secret_key(
        config.issuer.clone(),
        endpoint_id,
        Duration::from_secs(RELAY_TOKEN_LIFETIME_SECONDS),
        capability,
    )
    .map_err(|_| RequestFailure::Internal)?;

    let Expires::At(expires_at) = rcan.expires() else {
        return Err(RequestFailure::Internal);
    };
    let expected_expiry = authenticated_at
        .checked_add(RELAY_TOKEN_LIFETIME_SECONDS)
        .ok_or(RequestFailure::Internal)?;
    if expected_expiry.abs_diff(*expires_at) > 2 {
        return Err(RequestFailure::Internal);
    }

    let mut token = BASE32_NOPAD.encode(&rcan.encode());
    token.make_ascii_lowercase();
    if token.is_empty()
        || token.len() > MAX_TOKEN_BYTES
        || token.contains('=')
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || (b'2'..=b'7').contains(&byte))
    {
        return Err(RequestFailure::Internal);
    }

    let expires_at_i64 = i64::try_from(*expires_at).map_err(|_| RequestFailure::Internal)?;
    let expires_at = OffsetDateTime::from_unix_timestamp(expires_at_i64)
        .map_err(|_| RequestFailure::Internal)?
        .format(&Rfc3339)
        .map_err(|_| RequestFailure::Internal)?;
    if expires_at.len() > 64 {
        return Err(RequestFailure::Internal);
    }

    Ok(MintResponse { token, expires_at })
}

fn verify_hmac(
    secret: &[u8],
    timestamp: &str,
    body: &[u8],
    signature: &[u8; 32],
) -> Result<(), RequestFailure> {
    let body_hash = hex::encode(Sha256::digest(body));
    let transcript = format!("POST\n{MINT_PATH}\n{timestamp}\n{body_hash}");
    let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| RequestFailure::Internal)?;
    mac.update(transcript.as_bytes());
    mac.verify_slice(signature)
        .map_err(|_| RequestFailure::Authentication)
}

fn verify_configured_hmac(
    config: &MinterConfig,
    timestamp: &str,
    body: &[u8],
    signature: &[u8; 32],
) -> Result<(), RequestFailure> {
    let current_matches =
        verify_hmac(config.hmac_secret.as_slice(), timestamp, body, signature).is_ok();
    let previous_matches = config
        .hmac_previous_secret
        .as_ref()
        .is_some_and(|secret| verify_hmac(secret.as_slice(), timestamp, body, signature).is_ok());
    if current_matches || previous_matches {
        Ok(())
    } else {
        Err(RequestFailure::Authentication)
    }
}

fn parse_endpoint_id(value: &str) -> Result<EndpointId, RequestFailure> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(RequestFailure::InvalidEndpoint);
    }
    let mut bytes = [0_u8; 32];
    hex::decode_to_slice(value, &mut bytes).map_err(|_| RequestFailure::InvalidEndpoint)?;
    EndpointId::from_bytes(&bytes).map_err(|_| RequestFailure::InvalidEndpoint)
}

fn require_json_content_type(headers: &HeaderMap) -> Result<(), RequestFailure> {
    let content_type = single_header(headers, &CONTENT_TYPE).ok_or(RequestFailure::ContentType)?;
    let media_type = content_type
        .split(';')
        .next()
        .map(str::trim)
        .unwrap_or_default();
    if media_type.eq_ignore_ascii_case("application/json") {
        Ok(())
    } else {
        Err(RequestFailure::ContentType)
    }
}

fn validate_content_length(headers: &HeaderMap) -> Result<(), RequestFailure> {
    let values = headers.get_all(&CONTENT_LENGTH);
    let mut values = values.iter();
    let Some(value) = values.next() else {
        return Ok(());
    };
    if values.next().is_some() {
        return Err(RequestFailure::InvalidBody);
    }
    let length = value
        .to_str()
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .ok_or(RequestFailure::InvalidBody)?;
    if length > MAX_REQUEST_BYTES {
        Err(RequestFailure::BodyTooLarge)
    } else {
        Ok(())
    }
}

fn single_header<'a>(headers: &'a HeaderMap, name: &HeaderName) -> Option<&'a str> {
    let values = headers.get_all(name);
    let mut values = values.iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    Some(value)
}

fn parse_timestamp(value: &str) -> Option<u64> {
    if value.is_empty() || value.len() > 20 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let parsed: u64 = value.parse().ok()?;
    (parsed.to_string() == value).then_some(parsed)
}

fn decode_signature(value: &str) -> Option<[u8; 32]> {
    if value.len() != 43 || value.contains('=') {
        return None;
    }
    let decoded = URL_SAFE_NO_PAD.decode(value.as_bytes()).ok()?;
    let signature: [u8; 32] = decoded.try_into().ok()?;
    (URL_SAFE_NO_PAD.encode(signature) == value).then_some(signature)
}

fn decode_hmac_secret(value: &str) -> Result<Vec<u8>, ConfigurationError> {
    let decoded = STANDARD
        .decode(value.as_bytes())
        .or_else(|_| STANDARD_NO_PAD.decode(value.as_bytes()))
        .map_err(|_| ConfigurationError)?;
    if decoded.len() < 32 || decoded.len() > 256 {
        return Err(ConfigurationError);
    }
    let canonical_padded = STANDARD.encode(&decoded);
    let canonical_unpadded = STANDARD_NO_PAD.encode(&decoded);
    if value != canonical_padded && value != canonical_unpadded {
        return Err(ConfigurationError);
    }
    Ok(decoded)
}

fn bounded_env(name: &str, max_bytes: usize) -> Result<String, ConfigurationError> {
    let value = env::var(name).map_err(|_| ConfigurationError)?;
    if value.is_empty() || value.len() > max_bytes {
        return Err(ConfigurationError);
    }
    Ok(value)
}

fn optional_bounded_env(
    name: &str,
    max_bytes: usize,
) -> Result<Option<String>, ConfigurationError> {
    match env::var(name) {
        Ok(value) if !value.is_empty() && value.len() <= max_bytes => Ok(Some(value)),
        Ok(_) => Err(ConfigurationError),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(_)) => Err(ConfigurationError),
    }
}

fn unix_seconds(time: SystemTime) -> Option<u64> {
    time.duration_since(UNIX_EPOCH)
        .ok()
        .map(|value| value.as_secs())
}

fn json_response(status: StatusCode, value: &impl Serialize) -> Response<ResponseBody> {
    let body = serde_json::to_string(value)
        .unwrap_or_else(|_| "{\"error\":\"internal_error\"}".to_owned());
    if body.len() > MAX_RESPONSE_BYTES {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, "internal_error");
    }
    response(status, body)
}

fn error_response(status: StatusCode, code: &'static str) -> Response<ResponseBody> {
    let body = serde_json::to_string(&ErrorResponse { error: code })
        .unwrap_or_else(|_| "{\"error\":\"internal_error\"}".to_owned());
    let mut response = response(status, body);
    if status == StatusCode::METHOD_NOT_ALLOWED {
        response
            .headers_mut()
            .insert(ALLOW, "POST".parse().expect("static header value"));
    }
    response
}

fn response(status: StatusCode, body: String) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json")
        .header(CACHE_CONTROL, "no-store")
        .header("x-content-type-options", "nosniff")
        .body(ResponseBody::from(body))
        .expect("static response metadata is valid")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MintRequest {
    endpoint_id: String,
    lifetime_seconds: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MintResponse {
    token: String,
    expires_at: String,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: &'static str,
}

#[derive(Clone, Copy, Debug)]
enum RequestFailure {
    Method,
    Path,
    ContentType,
    Authentication,
    BodyTooLarge,
    InvalidBody,
    InvalidEndpoint,
    InvalidLifetime,
    Internal,
}

impl RequestFailure {
    const fn status(self) -> StatusCode {
        match self {
            Self::Method => StatusCode::METHOD_NOT_ALLOWED,
            Self::Path => StatusCode::NOT_FOUND,
            Self::ContentType => StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Self::Authentication => StatusCode::UNAUTHORIZED,
            Self::BodyTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::InvalidBody | Self::InvalidEndpoint | Self::InvalidLifetime => {
                StatusCode::BAD_REQUEST
            }
            Self::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    const fn code(self) -> &'static str {
        match self {
            Self::Method => "method_not_allowed",
            Self::Path => "not_found",
            Self::ContentType => "unsupported_media_type",
            Self::Authentication => "unauthorized",
            Self::BodyTooLarge => "body_too_large",
            Self::InvalidBody => "invalid_body",
            Self::InvalidEndpoint => "invalid_endpoint_id",
            Self::InvalidLifetime => "invalid_lifetime",
            Self::Internal => "internal_error",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{convert::Infallible, time::SystemTime};

    use futures_util::stream;
    use http_body::Frame;
    use http_body_util::{BodyExt as _, Full, StreamBody};
    use hyper::{
        Method, Request, StatusCode,
        body::Bytes,
        header::{ALLOW, HeaderValue},
    };
    use iroh::SecretKey;
    use rcan::{CapabilityOrigin, Expires, Rcan};
    use time::OffsetDateTime;

    use super::*;

    const TEST_HMAC_SECRET: [u8; 32] = [0x42; 32];
    const PREVIOUS_HMAC_SECRET: [u8; 32] = [0x41; 32];

    #[tokio::test]
    async fn mints_lowercase_relay_only_rcan_for_the_exact_audience() {
        let config = test_config();
        let endpoint = test_endpoint();
        let now = SystemTime::now();
        let now_seconds = unix_seconds(now).expect("test clock is after the Unix epoch");
        let body = valid_body(&endpoint.to_string());
        let request = signed_request(Method::POST, MINT_PATH, now_seconds, body);

        let response = handle_request(request, &config, now).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        let response: MintResponse = response_json(response).await;

        assert!(!response.token.contains('='));
        assert!(response.token.len() <= MAX_TOKEN_BYTES);
        assert!(
            response
                .token
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || (b'2'..=b'7').contains(&byte))
        );

        let token_bytes = BASE32_NOPAD
            .decode(response.token.to_ascii_uppercase().as_bytes())
            .expect("response is unpadded base32");
        let rcan = Rcan::<Caps>::decode(&token_bytes).expect("response is a signed RCAN");
        assert_eq!(rcan.audience(), &endpoint.as_verifying_key());
        assert_eq!(rcan.issuer(), &config.issuer.public().as_verifying_key());
        assert_eq!(rcan.capability_origin(), &CapabilityOrigin::Issuer);
        assert_eq!(rcan.capability().to_strings(), ["relay:use"]);

        let Expires::At(token_expiry) = rcan.expires() else {
            panic!("relay token must expire");
        };
        assert!(
            now_seconds
                .checked_add(RELAY_TOKEN_LIFETIME_SECONDS)
                .expect("test expiry is representable")
                .abs_diff(*token_expiry)
                <= 2
        );
        let response_expiry = OffsetDateTime::parse(&response.expires_at, &Rfc3339)
            .expect("response expiry is RFC 3339");
        assert_eq!(response_expiry.unix_timestamp(), *token_expiry as i64);
    }

    #[tokio::test]
    async fn rejects_every_method_and_path_except_the_single_post_route() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());

        let response = handle_request(
            signed_request(Method::GET, MINT_PATH, timestamp, body.clone()),
            &config,
            now,
        )
        .await;
        assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
        assert_eq!(response.headers()[ALLOW], "POST");

        for path in ["/", "/api/relay-token/", "/api/relay-token?debug=1"] {
            let response = handle_request(
                signed_request(Method::POST, path, timestamp, body.clone()),
                &config,
                now,
            )
            .await;
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "path {path}");
        }
    }

    #[tokio::test]
    async fn rejects_missing_wrong_or_body_substituted_hmac() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());

        let mut missing = signed_request(Method::POST, MINT_PATH, timestamp, body.clone());
        missing.headers_mut().remove(&SIGNATURE_HEADER);
        assert_eq!(
            handle_request(missing, &config, now).await.status(),
            StatusCode::UNAUTHORIZED
        );

        let mut wrong = signed_request(Method::POST, MINT_PATH, timestamp, body.clone());
        wrong.headers_mut().insert(
            &SIGNATURE_HEADER,
            URL_SAFE_NO_PAD
                .encode([0_u8; 32])
                .parse()
                .expect("test header is valid"),
        );
        assert_eq!(
            handle_request(wrong, &config, now).await.status(),
            StatusCode::UNAUTHORIZED
        );

        let mut substituted = signed_request(Method::POST, MINT_PATH, timestamp, body);
        *substituted.body_mut() = Full::new(Bytes::from(valid_body(
            &SecretKey::from_bytes(&[0x33; 32]).public().to_string(),
        )));
        assert_eq!(
            handle_request(substituted, &config, now).await.status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn accepts_the_previous_hmac_secret_only_during_rotation_overlap() {
        let mut config = test_config();
        config.hmac_previous_secret = Some(Zeroizing::new(PREVIOUS_HMAC_SECRET.to_vec()));
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());
        let request = signed_request_with_secret(
            Method::POST,
            MINT_PATH,
            timestamp,
            body.clone(),
            &PREVIOUS_HMAC_SECRET,
        );

        assert_eq!(
            handle_request(request, &config, now).await.status(),
            StatusCode::OK
        );
        let previous_after_overlap = signed_request_with_secret(
            Method::POST,
            MINT_PATH,
            timestamp,
            body,
            &PREVIOUS_HMAC_SECRET,
        );
        assert_eq!(
            handle_request(previous_after_overlap, &test_config(), now)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn enforces_the_thirty_second_timestamp_window() {
        let config = test_config();
        let now = SystemTime::now();
        let now_seconds = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());

        for timestamp in [now_seconds - 31, now_seconds + 31] {
            let response = handle_request(
                signed_request(Method::POST, MINT_PATH, timestamp, body.clone()),
                &config,
                now,
            )
            .await;
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        }

        for timestamp in [now_seconds - 30, now_seconds + 30] {
            let response = handle_request(
                signed_request(Method::POST, MINT_PATH, timestamp, body.clone()),
                &config,
                now,
            )
            .await;
            assert_eq!(response.status(), StatusCode::OK);
        }

        let mut malformed = signed_request(Method::POST, MINT_PATH, now_seconds, body);
        malformed.headers_mut().insert(
            &TIMESTAMP_HEADER,
            "+123".parse().expect("test header is valid"),
        );
        assert_eq!(
            handle_request(malformed, &config, now).await.status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(parse_timestamp("01"), None);
    }

    #[tokio::test]
    async fn bounds_declared_and_streamed_request_bodies() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());

        let mut declared = signed_request(Method::POST, MINT_PATH, timestamp, body);
        declared.headers_mut().insert(
            CONTENT_LENGTH,
            (MAX_REQUEST_BYTES + 1)
                .to_string()
                .parse()
                .expect("test header is valid"),
        );
        assert_eq!(
            handle_request(declared, &config, now).await.status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );

        let chunk = Bytes::from(vec![b'x'; MAX_REQUEST_BYTES / 2 + 1]);
        let streamed_body = [chunk.clone(), chunk];
        let joined = streamed_body.concat();
        let signature = sign_request(timestamp, &joined);
        let body_stream = StreamBody::new(stream::iter(
            streamed_body
                .into_iter()
                .map(|chunk| Ok::<Frame<Bytes>, Infallible>(Frame::data(chunk))),
        ));
        let streamed = Request::builder()
            .method(Method::POST)
            .uri(MINT_PATH)
            .header(CONTENT_TYPE, "application/json")
            .header(&TIMESTAMP_HEADER, timestamp.to_string())
            .header(&SIGNATURE_HEADER, signature)
            .body(body_stream)
            .expect("test request is valid");
        assert_eq!(
            handle_request(streamed, &config, now).await.status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }

    #[tokio::test]
    async fn rejects_invalid_endpoint_lifetime_and_json_shape() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let endpoint = test_endpoint().to_string();
        let invalid_bodies = [
            format!(
                "{{\"endpointId\":\"{}\",\"lifetimeSeconds\":86400}}",
                endpoint.to_ascii_uppercase()
            ),
            format!("{{\"endpointId\":\"{endpoint}\",\"lifetimeSeconds\":86401}}"),
            format!(
                "{{\"endpointId\":\"{endpoint}\",\"lifetimeSeconds\":86400,\"capability\":\"all\"}}"
            ),
            "{}".to_owned(),
        ];

        for body in invalid_bodies {
            let response = handle_request(
                signed_request(Method::POST, MINT_PATH, timestamp, body),
                &config,
                now,
            )
            .await;
            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        }
    }

    #[tokio::test]
    async fn accepts_json_content_type_parameters() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());
        let mut request = signed_request(Method::POST, MINT_PATH, timestamp, body);
        request.headers_mut().insert(
            CONTENT_TYPE,
            "Application/JSON; charset=utf-8"
                .parse()
                .expect("valid test header"),
        );

        assert_eq!(
            handle_request(request, &config, now).await.status(),
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn rejects_non_json_duplicate_and_malformed_content_type_headers() {
        let config = test_config();
        let now = SystemTime::now();
        let timestamp = unix_seconds(now).expect("test clock is valid");
        let body = valid_body(&test_endpoint().to_string());
        let mut non_json = signed_request(Method::POST, MINT_PATH, timestamp, body.clone());
        non_json.headers_mut().insert(
            CONTENT_TYPE,
            "text/plain".parse().expect("valid test header"),
        );
        let mut duplicate = signed_request(Method::POST, MINT_PATH, timestamp, body.clone());
        duplicate.headers_mut().append(
            CONTENT_TYPE,
            "application/json; charset=utf-8"
                .parse()
                .expect("valid test header"),
        );
        let mut malformed = signed_request(Method::POST, MINT_PATH, timestamp, body);
        malformed.headers_mut().insert(
            CONTENT_TYPE,
            HeaderValue::from_bytes(&[0xff]).expect("opaque header bytes are representable"),
        );

        for request in [non_json, duplicate, malformed] {
            assert_eq!(
                handle_request(request, &config, now).await.status(),
                StatusCode::UNSUPPORTED_MEDIA_TYPE
            );
        }
    }

    #[test]
    fn matches_the_typescript_hmac_wire_fixture() {
        #[derive(Deserialize)]
        struct Fixture {
            path: String,
            timestamp: String,
            body: String,
            signature: String,
        }

        let fixture: Fixture = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/fixtures/iroh/relay-minter-request-v1.json"
        )))
        .expect("shared relay-minter fixture is valid");
        assert_eq!(fixture.path, MINT_PATH);
        let timestamp = parse_timestamp(&fixture.timestamp).expect("fixture timestamp is valid");
        assert_eq!(
            sign_request(timestamp, fixture.body.as_bytes()),
            fixture.signature
        );
        let signature = decode_signature(&fixture.signature).expect("fixture signature is valid");
        verify_hmac(
            &TEST_HMAC_SECRET,
            &fixture.timestamp,
            fixture.body.as_bytes(),
            &signature,
        )
        .expect("fixture authenticates");
        let request: MintRequest =
            serde_json::from_str(&fixture.body).expect("fixture body matches the contract");
        assert_eq!(request.lifetime_seconds, RELAY_TOKEN_LIFETIME_SECONDS);
        parse_endpoint_id(&request.endpoint_id).expect("fixture endpoint is valid");
    }

    #[test]
    fn accepts_only_canonical_hmac_secret_encodings_of_at_least_32_bytes() {
        let padded = STANDARD.encode(TEST_HMAC_SECRET);
        let unpadded = STANDARD_NO_PAD.encode(TEST_HMAC_SECRET);
        assert_eq!(
            decode_hmac_secret(&padded).expect("padded secret"),
            TEST_HMAC_SECRET
        );
        assert_eq!(
            decode_hmac_secret(&unpadded).expect("unpadded secret"),
            TEST_HMAC_SECRET
        );
        assert!(decode_hmac_secret(&STANDARD.encode([1_u8; 31])).is_err());
        assert!(decode_hmac_secret(&format!(" {padded}")).is_err());
        assert!(decode_hmac_secret(&URL_SAFE_NO_PAD.encode([0xff_u8; 32])).is_err());
    }

    fn test_config() -> MinterConfig {
        MinterConfig {
            issuer: SecretKey::from_bytes(&[0x11; 32]),
            hmac_secret: Zeroizing::new(TEST_HMAC_SECRET.to_vec()),
            hmac_previous_secret: None,
        }
    }

    fn test_endpoint() -> EndpointId {
        SecretKey::from_bytes(&[0x22; 32]).public()
    }

    fn valid_body(endpoint_id: &str) -> String {
        format!(
            "{{\"endpointId\":\"{endpoint_id}\",\"lifetimeSeconds\":{RELAY_TOKEN_LIFETIME_SECONDS}}}"
        )
    }

    fn signed_request(
        method: Method,
        path: &str,
        timestamp: u64,
        body: String,
    ) -> Request<Full<Bytes>> {
        signed_request_with_secret(method, path, timestamp, body, &TEST_HMAC_SECRET)
    }

    fn signed_request_with_secret(
        method: Method,
        path: &str,
        timestamp: u64,
        body: String,
        secret: &[u8],
    ) -> Request<Full<Bytes>> {
        Request::builder()
            .method(method)
            .uri(path)
            .header(CONTENT_TYPE, "application/json")
            .header(&TIMESTAMP_HEADER, timestamp.to_string())
            .header(
                &SIGNATURE_HEADER,
                sign_request_with_secret(secret, timestamp, body.as_bytes()),
            )
            .body(Full::new(Bytes::from(body)))
            .expect("test request is valid")
    }

    fn sign_request(timestamp: u64, body: &[u8]) -> String {
        sign_request_with_secret(&TEST_HMAC_SECRET, timestamp, body)
    }

    fn sign_request_with_secret(secret: &[u8], timestamp: u64, body: &[u8]) -> String {
        let body_hash = hex::encode(Sha256::digest(body));
        let transcript = format!("POST\n{MINT_PATH}\n{timestamp}\n{body_hash}");
        let mut mac = HmacSha256::new_from_slice(secret).expect("test HMAC key length is valid");
        mac.update(transcript.as_bytes());
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    }

    async fn response_json<T>(response: Response<ResponseBody>) -> T
    where
        T: for<'de> Deserialize<'de>,
    {
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("test response body is readable")
            .to_bytes();
        serde_json::from_slice(&bytes).expect("test response is JSON")
    }
}
