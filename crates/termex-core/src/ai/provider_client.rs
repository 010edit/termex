//! HTTP client for calling upstream AI providers (Claude, OpenAI-compatible,
//! Ollama, local llama-server, Gemini).
//!
//! Historically mirrored the legacy Tauri `call_ai_provider`, but now depends
//! on nothing platform-specific so it can be reused from the Flutter bridge.
//! Returns either the completed text (synchronous) or streams deltas through a
//! callback (asynchronous SSE).

use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Claude,
    Gemini,
    OpenAi,
    Ollama,
    LocalLlama,
}

impl ProviderKind {
    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Claude => "https://api.anthropic.com/v1",
            Self::Gemini => "https://generativelanguage.googleapis.com",
            Self::OpenAi => "https://api.openai.com/v1",
            Self::Ollama => "http://localhost:11434",
            Self::LocalLlama => "http://127.0.0.1:8080",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProviderRequest {
    pub kind: ProviderKind,
    pub api_key: String,
    pub base_url: Option<String>,
    pub model: String,
    pub system_prompt: String,
    pub user_message: String,
    pub max_tokens: u32,
}

/// Perform a single-shot completion and return the full assistant text.
pub async fn complete(req: ProviderRequest) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let base = req
        .base_url
        .as_deref()
        .unwrap_or_else(|| req.kind.default_base_url());

    match req.kind {
        ProviderKind::Claude => {
            let url = format!("{base}/messages");
            let body = serde_json::json!({
                "model": req.model,
                "max_tokens": req.max_tokens,
                "system": req.system_prompt,
                "messages": [
                    { "role": "user", "content": req.user_message },
                ],
            });
            let resp = client
                .post(&url)
                .header("x-api-key", &req.api_key)
                .header("anthropic-version", "2023-06-01")
                .header("content-type", "application/json")
                .json(&body)
                .send()
                .await
                .map_err(|e| e.to_string())?;
            let json: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            if let Some(err) = json["error"]["message"].as_str() {
                return Err(err.to_string());
            }
            Ok(json["content"][0]["text"].as_str().unwrap_or("").to_string())
        }
        ProviderKind::Gemini => {
            let url = format!(
                "{base}/v1beta/models/{}:generateContent?key={}",
                req.model, req.api_key
            );
            let body = serde_json::json!({
                "system_instruction": { "parts": [{ "text": req.system_prompt }] },
                "contents": [{ "parts": [{ "text": req.user_message }] }],
            });
            let resp = client
                .post(&url)
                .header("content-type", "application/json")
                .json(&body)
                .send()
                .await
                .map_err(|e| e.to_string())?;
            let json: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            if let Some(err) = json["error"]["message"].as_str() {
                return Err(err.to_string());
            }
            Ok(json["candidates"][0]["content"]["parts"][0]["text"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }
        ProviderKind::Ollama => {
            let url = format!("{base}/api/generate");
            let body = serde_json::json!({
                "model": req.model,
                "prompt": format!("{}\n\n{}", req.system_prompt, req.user_message),
                "stream": false,
            });
            let resp = client
                .post(&url)
                .json(&body)
                .send()
                .await
                .map_err(|e| e.to_string())?;
            let json: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            Ok(json["response"].as_str().unwrap_or("").to_string())
        }
        ProviderKind::LocalLlama => {
            let port = crate::local_ai::read_pid_file().map(|(_, p)| p).unwrap_or(8080);
            let url = format!("http://127.0.0.1:{port}/v1/chat/completions");
            let body = serde_json::json!({
                "model": req.model,
                "messages": [
                    { "role": "system", "content": req.system_prompt },
                    { "role": "user", "content": req.user_message },
                ],
                "max_tokens": req.max_tokens,
            });
            let resp = client
                .post(&url)
                .json(&body)
                .send()
                .await
                .map_err(|e| format!("local llama request failed: {e}"))?;
            let json: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            if let Some(err) = json["error"]["message"].as_str() {
                return Err(err.to_string());
            }
            Ok(json["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }
        ProviderKind::OpenAi => {
            let url = format!("{base}/chat/completions");
            let body = serde_json::json!({
                "model": req.model,
                "messages": [
                    { "role": "system", "content": req.system_prompt },
                    { "role": "user", "content": req.user_message },
                ],
                "max_tokens": req.max_tokens,
            });
            let resp = client
                .post(&url)
                .header("Authorization", format!("Bearer {}", req.api_key))
                .json(&body)
                .send()
                .await
                .map_err(|e| e.to_string())?;
            let json: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            if let Some(err) = json["error"]["message"].as_str() {
                return Err(err.to_string());
            }
            Ok(json["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }
    }
}

/// Streaming completion. `on_chunk` is called for each delta; the function
/// returns after the final chunk or when `cancel_rx` fires.
///
/// Supports SSE for Claude / OpenAI / Ollama. Local llama-server reuses the
/// OpenAI-compatible `/v1/chat/completions` SSE shape. Gemini is not yet
/// streamed (falls back to single-shot complete + one chunk emission).
pub async fn stream(
    req: ProviderRequest,
    mut cancel_rx: oneshot::Receiver<()>,
    on_chunk: impl Fn(String, bool) + Send + 'static,
) -> Result<(), String> {
    use futures_util::StreamExt;

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let base = req
        .base_url
        .as_deref()
        .unwrap_or_else(|| req.kind.default_base_url());

    let (url, body, headers) = match req.kind {
        ProviderKind::Claude => (
            format!("{base}/messages"),
            serde_json::json!({
                "model": req.model,
                "max_tokens": req.max_tokens,
                "stream": true,
                "system": req.system_prompt,
                "messages": [{ "role": "user", "content": req.user_message }],
            }),
            vec![
                ("x-api-key".to_string(), req.api_key.clone()),
                ("anthropic-version".to_string(), "2023-06-01".to_string()),
            ],
        ),
        ProviderKind::OpenAi | ProviderKind::LocalLlama => {
            let endpoint = if req.kind == ProviderKind::LocalLlama {
                let port = crate::local_ai::read_pid_file().map(|(_, p)| p).unwrap_or(8080);
                format!("http://127.0.0.1:{port}/v1/chat/completions")
            } else {
                format!("{base}/chat/completions")
            };
            (
                endpoint,
                serde_json::json!({
                    "model": req.model,
                    "stream": true,
                    "max_tokens": req.max_tokens,
                    "messages": [
                        { "role": "system", "content": req.system_prompt },
                        { "role": "user", "content": req.user_message },
                    ],
                }),
                if req.kind == ProviderKind::LocalLlama {
                    vec![]
                } else {
                    vec![("Authorization".to_string(), format!("Bearer {}", req.api_key))]
                },
            )
        }
        ProviderKind::Ollama => (
            format!("{base}/api/generate"),
            serde_json::json!({
                "model": req.model,
                "prompt": format!("{}\n\n{}", req.system_prompt, req.user_message),
                "stream": true,
            }),
            vec![],
        ),
        ProviderKind::Gemini => {
            // Fall back to non-streaming.
            let text = complete(req).await?;
            on_chunk(text, true);
            return Ok(());
        }
    };

    let mut builder = client.post(&url).json(&body);
    for (k, v) in headers {
        builder = builder.header(&k, &v);
    }
    let resp = builder.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("HTTP {status}: {text}"));
    }

    let mut stream = resp.bytes_stream();
    let mut buffer = Vec::<u8>::new();

    loop {
        tokio::select! {
            _ = &mut cancel_rx => {
                on_chunk(String::new(), true);
                return Ok(());
            }
            maybe_chunk = stream.next() => {
                let Some(chunk) = maybe_chunk else { break };
                let chunk = chunk.map_err(|e| e.to_string())?;
                buffer.extend_from_slice(&chunk);

                // SSE framing: lines end with "\n", events end with "\n\n".
                while let Some(pos) = buffer.windows(2).position(|w| w == b"\n\n") {
                    let event = buffer.drain(..pos + 2).collect::<Vec<_>>();
                    parse_sse_event(&req.kind, &event, &on_chunk);
                }

                // Ollama emits newline-delimited JSON (not SSE).
                if matches!(req.kind, ProviderKind::Ollama) {
                    while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                        let line = buffer.drain(..pos + 1).collect::<Vec<_>>();
                        if let Ok(text) = std::str::from_utf8(&line) {
                            if let Ok(val) = serde_json::from_str::<serde_json::Value>(text.trim()) {
                                let done = val["done"].as_bool().unwrap_or(false);
                                let delta = val["response"].as_str().unwrap_or("").to_string();
                                on_chunk(delta, done);
                            }
                        }
                    }
                }
            }
        }
    }

    on_chunk(String::new(), true);
    Ok(())
}

fn parse_sse_event(kind: &ProviderKind, event: &[u8], on_chunk: &(impl Fn(String, bool) + Send + 'static)) {
    let text = match std::str::from_utf8(event) {
        Ok(t) => t,
        Err(_) => return,
    };
    for line in text.lines() {
        let Some(payload) = line.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim();
        if payload == "[DONE]" {
            on_chunk(String::new(), true);
            return;
        }
        let val: serde_json::Value = match serde_json::from_str(payload) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match kind {
            ProviderKind::Claude => {
                // Claude SSE: { "type": "content_block_delta", "delta": { "text": "..." } }
                if val["type"] == "content_block_delta" {
                    let delta = val["delta"]["text"].as_str().unwrap_or("").to_string();
                    on_chunk(delta, false);
                } else if val["type"] == "message_stop" {
                    on_chunk(String::new(), true);
                }
            }
            ProviderKind::OpenAi | ProviderKind::LocalLlama => {
                // OpenAI SSE: { "choices": [{ "delta": { "content": "..." } }] }
                let delta = val["choices"][0]["delta"]["content"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                let finish = val["choices"][0]["finish_reason"].is_string();
                if !delta.is_empty() {
                    on_chunk(delta, false);
                }
                if finish {
                    on_chunk(String::new(), true);
                }
            }
            _ => {}
        }
    }
}

/// Lightweight verification call — sends a 1-token prompt and returns true on
/// a 2xx response.
pub async fn verify(
    kind: ProviderKind,
    api_key: String,
    base_url: Option<String>,
    model: String,
) -> Result<bool, String> {
    let req = ProviderRequest {
        kind,
        api_key,
        base_url,
        model,
        system_prompt: "ok".to_string(),
        user_message: "ok".to_string(),
        max_tokens: 8,
    };
    match complete(req).await {
        Ok(_) => Ok(true),
        Err(e) => Err(e),
    }
}
