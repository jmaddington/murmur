//! Remote / local-server model calls: OpenRouter and any OpenAI-compatible
//! endpoint (Ollama, LM Studio, whisper.cpp server, Groq, OpenAI, ...).

use crate::prompts::{self, CleanupContext};
use crate::vocabulary::Term;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

pub const OPENROUTER_BASE: &str = "https://openrouter.ai/api/v1";

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Openrouter,
    OpenaiCompatible,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Provider {
    pub kind: ProviderKind,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub model: String,
}

impl Provider {
    fn base(&self) -> String {
        let b = match (&self.kind, self.base_url.as_deref().map(str::trim)) {
            (_, Some(u)) if !u.is_empty() => u.to_string(),
            // Test hook: point OpenRouter at a mock server.
            (ProviderKind::Openrouter, _) => std::env::var("MURMUR_OPENROUTER_BASE")
                .unwrap_or_else(|_| OPENROUTER_BASE.to_string()),
            (ProviderKind::OpenaiCompatible, _) => "http://localhost:11434/v1".to_string(),
        };
        b.trim_end_matches('/').to_string()
    }

    fn request(&self, method: &str, path: &str, timeout_s: u64) -> ureq::Request {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout(Duration::from_secs(timeout_s))
            .build();
        let mut r = agent.request(method, &format!("{}{}", self.base(), path));
        if let Some(k) = self.api_key.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
            r = r.set("Authorization", &format!("Bearer {k}"));
        }
        if self.kind == ProviderKind::Openrouter {
            r = r.set("X-Title", "Murmur").set("HTTP-Referer", "https://localhost/murmur");
        }
        r
    }
}

#[derive(Deserialize)]
pub struct TranscribeArgs {
    pub provider: Provider,
    pub wav_path: String,
    #[serde(default)]
    pub vocabulary: Vec<Term>,
    /// BCP-47 language hint, e.g. "en-US".
    #[serde(default)]
    pub language: Option<String>,
}

#[derive(Deserialize)]
pub struct CleanupArgs {
    pub provider: Provider,
    pub text: String,
    #[serde(default)]
    pub context: CleanupContext,
    /// Attach the recording for audio-capable models.
    #[serde(default)]
    pub wav_path: Option<String>,
}

#[derive(Serialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub audio_input: bool,
}

fn http_error(e: ureq::Error) -> String {
    match e {
        ureq::Error::Status(code, resp) => {
            let body = resp.into_string().unwrap_or_default();
            let msg = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| {
                    v.pointer("/error/message")
                        .or_else(|| v.get("error"))
                        .or_else(|| v.get("message"))
                        .and_then(|m| m.as_str().map(str::to_string))
                })
                .unwrap_or_else(|| body.chars().take(300).collect());
            match code {
                401 | 403 => format!("Authentication failed ({code}). Check your API key. {msg}"),
                402 => format!("Out of credits ({code}). {msg}"),
                429 => format!("Rate limited ({code}). {msg}"),
                _ => format!("HTTP {code}: {msg}"),
            }
        }
        ureq::Error::Transport(t) => format!("Network error: {t}"),
    }
}

fn audio_part(wav_path: &str) -> Result<Value, String> {
    let bytes = std::fs::read(wav_path).map_err(|e| format!("cannot read audio: {e}"))?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    Ok(json!({ "type": "input_audio", "input_audio": { "data": b64, "format": "wav" } }))
}

fn chat(provider: &Provider, messages: Value, timeout_s: u64) -> Result<String, String> {
    if provider.model.trim().is_empty() {
        return Err("No model selected".into());
    }
    let body = json!({
        "model": provider.model,
        "messages": messages,
        "temperature": 0,
        "stream": false,
    });
    let resp: Value = provider
        .request("POST", "/chat/completions", timeout_s)
        .send_json(body)
        .map_err(http_error)?
        .into_json()
        .map_err(|e| format!("bad response: {e}"))?;
    if let Some(err) = resp.pointer("/error/message").and_then(Value::as_str) {
        return Err(err.to_string());
    }
    let content = resp.pointer("/choices/0/message/content").ok_or("response had no content")?;
    // Content may be a string or an array of parts.
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(""),
        _ => String::new(),
    };
    Ok(text)
}

pub fn transcribe(a: &TranscribeArgs) -> Result<String, String> {
    match a.provider.kind {
        ProviderKind::Openrouter => {
            let messages = json!([
                { "role": "system", "content": prompts::transcription_instructions(&a.vocabulary) },
                { "role": "user", "content": [
                    { "type": "text", "text": "Transcribe this recording." },
                    audio_part(&a.wav_path)?
                ]}
            ]);
            chat(&a.provider, messages, 120).map(|t| prompts::sanitize_output(&t))
        }
        ProviderKind::OpenaiCompatible => transcribe_multipart(a),
    }
}

/// OpenAI `/audio/transcriptions` (Whisper-style) multipart upload.
fn transcribe_multipart(a: &TranscribeArgs) -> Result<String, String> {
    let wav = std::fs::read(&a.wav_path).map_err(|e| format!("cannot read audio: {e}"))?;
    let boundary = format!("murmur-{:x}", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
    let mut body: Vec<u8> = Vec::with_capacity(wav.len() + 1024);
    let mut field = |name: &str, value: &str| {
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes(),
        );
    };
    field("model", if a.provider.model.trim().is_empty() { "whisper-1" } else { &a.provider.model });
    field("response_format", "json");
    let prompt = prompts::whisper_prompt(&a.vocabulary);
    if !prompt.is_empty() {
        field("prompt", &prompt);
    }
    if let Some(lang) = a.language.as_deref().and_then(|l| l.split(['-', '_']).next()) {
        if !lang.is_empty() {
            field("language", lang);
        }
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes(),
    );
    body.extend_from_slice(&wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let resp: Value = a
        .provider
        .request("POST", "/audio/transcriptions", 120)
        .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
        .send_bytes(&body)
        .map_err(http_error)?
        .into_json()
        .map_err(|e| format!("bad response: {e}"))?;
    resp.get("text")
        .and_then(Value::as_str)
        .map(|s| s.trim().to_string())
        .ok_or_else(|| "response had no text".into())
}

pub fn cleanup(a: &CleanupArgs) -> Result<String, String> {
    let with_audio = a.wav_path.is_some() && a.provider.kind == ProviderKind::Openrouter;
    let ctx = CleanupContext {
        vocabulary: a.context.vocabulary.clone(),
        style: a.context.style.clone(),
        app_name: a.context.app_name.clone(),
        with_audio,
    };
    let user_text = prompts::cleanup_user(&a.text);
    let user_content = if with_audio {
        json!([{ "type": "text", "text": user_text }, audio_part(a.wav_path.as_deref().unwrap())?])
    } else {
        json!(user_text)
    };
    let messages = json!([
        { "role": "system", "content": prompts::cleanup_system(&ctx) },
        { "role": "user", "content": user_content }
    ]);
    let out = prompts::sanitize_output(&chat(&a.provider, messages, 60)?);
    // An empty answer would wipe the user's words; fall back to the input.
    Ok(if out.is_empty() { a.text.clone() } else { out })
}

pub fn list_models(p: &Provider) -> Result<Vec<ModelInfo>, String> {
    let resp: Value = p
        .request("GET", "/models", 20)
        .call()
        .map_err(http_error)?
        .into_json()
        .map_err(|e| format!("bad response: {e}"))?;
    let data = resp.get("data").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut models: Vec<ModelInfo> = data
        .iter()
        .filter_map(|m| {
            let id = m.get("id")?.as_str()?.to_string();
            let name = m.get("name").and_then(Value::as_str).unwrap_or(&id).to_string();
            let audio_input = m
                .pointer("/architecture/input_modalities")
                .and_then(Value::as_array)
                .map(|a| a.iter().any(|x| x.as_str() == Some("audio")))
                .unwrap_or(false);
            Some(ModelInfo { id, name, audio_input })
        })
        .collect();
    models.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(models)
}
