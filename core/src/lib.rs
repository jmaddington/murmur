//! Murmur core: everything that isn't UI or an Apple-only framework.
//!
//! The Swift app talks to this crate through a deliberately tiny C ABI:
//! one JSON-in / JSON-out dispatcher (`murmur_call`) plus a fast path for
//! WAV encoding. Keeping the boundary JSON-shaped means new commands never
//! require touching the header or the Swift bridging layer.

pub mod history;
pub mod llm;
pub mod prompts;
pub mod vocabulary;
pub mod wav;

use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};

fn dispatch(input: &str) -> Result<Value, String> {
    let req: Value = serde_json::from_str(input).map_err(|e| format!("bad request: {e}"))?;
    let cmd = req.get("cmd").and_then(Value::as_str).ok_or("missing cmd")?;
    let args = || -> Result<Value, String> { Ok(req.clone()) };
    match cmd {
        "apply_vocabulary" => {
            let a: vocabulary::ApplyArgs = from(args()?)?;
            Ok(json!({ "text": vocabulary::apply(&a.text, &a.vocabulary) }))
        }
        "cleanup_system_prompt" => {
            let a: prompts::CleanupContext = from(args()?)?;
            Ok(json!({ "prompt": prompts::cleanup_system(&a) }))
        }
        "cleanup_prompt_info" => Ok(json!({
            "default_template": prompts::DEFAULT_TEMPLATE,
            "placeholders": prompts::PLACEHOLDERS.iter()
                .map(|(name, description)| json!({ "name": name, "description": description }))
                .collect::<Vec<_>>(),
        })),
        "cleanup_user_prompt" => {
            let a: prompts::UserPromptArgs = from(args()?)?;
            Ok(json!({ "prompt": prompts::cleanup_user(&a.text) }))
        }
        "sanitize_llm_output" => {
            let a: prompts::UserPromptArgs = from(args()?)?;
            Ok(json!({ "text": prompts::sanitize_output(&a.text) }))
        }
        "transcribe" => {
            let a: llm::TranscribeArgs = from(args()?)?;
            Ok(json!({ "text": llm::transcribe(&a)? }))
        }
        "cleanup" => {
            let a: llm::CleanupArgs = from(args()?)?;
            let (text, usage) = llm::cleanup_with_usage(&a)?;
            Ok(json!({ "text": text, "usage": usage }))
        }
        "judge" => {
            let a: llm::JudgeArgs = from(args()?)?;
            let (v, usage) = llm::judge(&a)?;
            Ok(json!({ "score": v.score, "notes": v.notes, "usage": usage }))
        }
        "list_models" => {
            let a: llm::Provider = from(args()?)?;
            Ok(json!({ "models": llm::list_models(&a)? }))
        }
        "history_save" => {
            let a: history::SaveArgs = from(args()?)?;
            history::save(&a.root, &a.entry)?;
            Ok(json!({}))
        }
        "history_list" => {
            let a: history::RootArgs = from(args()?)?;
            Ok(serde_json::to_value(history::list(&a.root)?).unwrap())
        }
        "history_delete" => {
            let a: history::DeleteArgs = from(args()?)?;
            history::delete(&a.root, &a.id)?;
            Ok(json!({}))
        }
        "history_purge" => {
            let a: history::PurgeArgs = from(args()?)?;
            Ok(serde_json::to_value(history::purge(&a)?).unwrap())
        }
        other => Err(format!("unknown command: {other}")),
    }
}

fn from<T: serde::de::DeserializeOwned>(v: Value) -> Result<T, String> {
    serde_json::from_value(v).map_err(|e| format!("bad arguments: {e}"))
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

/// # Safety
/// `input` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn murmur_call(input: *const c_char) -> *mut c_char {
    let out = std::panic::catch_unwind(|| {
        if input.is_null() {
            return json!({ "error": "null input" });
        }
        let s = match CStr::from_ptr(input).to_str() {
            Ok(s) => s,
            Err(_) => return json!({ "error": "input is not UTF-8" }),
        };
        match dispatch(s) {
            Ok(v) => json!({ "ok": v }),
            Err(e) => json!({ "error": e }),
        }
    })
    .unwrap_or_else(|_| json!({ "error": "internal panic in murmur_core" }));
    into_c(out.to_string())
}

/// # Safety
/// `ptr` must come from `murmur_call` and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn murmur_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// # Safety
/// `samples` must point to `len` floats; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn murmur_write_wav(
    samples: *const f32,
    len: usize,
    sample_rate: u32,
    path: *const c_char,
) -> i32 {
    if samples.is_null() || path.is_null() {
        return -1;
    }
    let slice = std::slice::from_raw_parts(samples, len);
    let Ok(p) = CStr::from_ptr(path).to_str() else { return -2 };
    match wav::write(slice, sample_rate, std::path::Path::new(p)) {
        Ok(()) => 0,
        Err(_) => -3,
    }
}
