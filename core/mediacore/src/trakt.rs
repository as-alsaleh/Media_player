//! Trakt.tv device-code authentication.
//!
//! Requires a (free) Trakt API app's client id/secret — the standard flow:
//! show the user a short code for trakt.tv/activate, poll until approved.

use serde::Deserialize;

#[derive(Debug, Clone, serde::Serialize)]
pub struct TraktDeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub interval: u64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TraktTokens {
    pub access_token: String,
    pub refresh_token: String,
}

pub async fn device_code(client_id: &str) -> Option<TraktDeviceCode> {
    #[derive(Deserialize)]
    struct Resp {
        device_code: String,
        user_code: String,
        verification_url: String,
        interval: u64,
    }
    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.trakt.tv/oauth/device/code")
        .json(&serde_json::json!({"client_id": client_id}))
        .send()
        .await
        .ok()?;
    let r = resp.json::<Resp>().await.ok()?;
    Some(TraktDeviceCode {
        device_code: r.device_code,
        user_code: r.user_code,
        verification_url: r.verification_url,
        interval: r.interval,
    })
}

/// One poll attempt; None while the user hasn't approved yet.
pub async fn device_token(
    client_id: &str,
    client_secret: &str,
    device_code: &str,
) -> Option<TraktTokens> {
    #[derive(Deserialize)]
    struct Resp {
        access_token: String,
        refresh_token: String,
    }
    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.trakt.tv/oauth/device/token")
        .json(&serde_json::json!({
            "code": device_code,
            "client_id": client_id,
            "client_secret": client_secret,
        }))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None; // 400 = pending approval
    }
    let r = resp.json::<Resp>().await.ok()?;
    Some(TraktTokens { access_token: r.access_token, refresh_token: r.refresh_token })
}

/// Report playback to Trakt. `state` is "start" | "pause" | "stop";
/// stop with progress > 80 marks the item watched.
pub async fn scrobble(
    client_id: &str,
    access_token: &str,
    state: &str,
    mut body: serde_json::Value,
    progress: f64,
) -> bool {
    body["progress"] = serde_json::json!(progress);
    let client = reqwest::Client::new();
    client
        .post(format!("https://api.trakt.tv/scrobble/{state}"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("trakt-api-version", "2")
        .header("trakt-api-key", client_id)
        .json(&body)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}
