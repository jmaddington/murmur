//! On-disk history: `<root>/<id>/entry.json` plus an optional audio file
//! (written by the Swift recorder) in the same folder. Retention is enforced
//! separately for audio and for text.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const AUDIO_EXTENSIONS: [&str; 3] = ["m4a", "caf", "wav"];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// Unix seconds.
    pub created_at: f64,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub raw_text: String,
    #[serde(default)]
    pub cleaned_text: Option<String>,
    #[serde(default)]
    pub final_text: String,
    #[serde(default)]
    pub engine: String,
    #[serde(default)]
    pub cleanup_engine: Option<String>,
    #[serde(default)]
    pub app_name: Option<String>,
    #[serde(default)]
    pub microphone: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    /// Filled in by `list`: absolute path of the audio file if it still exists.
    #[serde(default, skip_deserializing)]
    pub audio_path: Option<String>,
    #[serde(default)]
    pub text_purged: bool,
}

#[derive(Deserialize)]
pub struct RootArgs {
    pub root: String,
}
#[derive(Deserialize)]
pub struct SaveArgs {
    pub root: String,
    pub entry: Entry,
}
#[derive(Deserialize)]
pub struct DeleteArgs {
    pub root: String,
    pub id: String,
}
#[derive(Deserialize)]
pub struct PurgeArgs {
    pub root: String,
    /// Days to keep audio. -1 = forever, 0 = delete immediately.
    pub audio_days: i64,
    /// Days to keep transcripts. -1 = forever, 0 = delete immediately.
    pub transcript_days: i64,
    /// Unix seconds; injectable for tests.
    pub now: f64,
}

#[derive(Serialize, Default, Debug)]
pub struct PurgeReport {
    pub audio_removed: usize,
    pub entries_removed: usize,
}

fn safe_dir(root: &str, id: &str) -> Result<PathBuf, String> {
    if id.is_empty() || id.contains(['/', '\\']) || id.contains("..") {
        return Err("invalid id".into());
    }
    Ok(Path::new(root).join(id))
}

fn audio_file(dir: &Path) -> Option<PathBuf> {
    AUDIO_EXTENSIONS.iter().map(|e| dir.join(format!("audio.{e}"))).find(|p| p.exists())
}

pub fn save(root: &str, entry: &Entry) -> Result<(), String> {
    let dir = safe_dir(root, &entry.id)?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let json = serde_json::to_vec_pretty(entry).map_err(|e| e.to_string())?;
    let tmp = dir.join("entry.json.tmp");
    fs::write(&tmp, json).map_err(|e| e.to_string())?;
    fs::rename(&tmp, dir.join("entry.json")).map_err(|e| e.to_string())
}

pub fn list(root: &str) -> Result<Vec<Entry>, String> {
    let Ok(rd) = fs::read_dir(root) else { return Ok(vec![]) };
    let mut out: Vec<Entry> = rd
        .flatten()
        .filter(|d| d.path().is_dir())
        .filter_map(|d| {
            let dir = d.path();
            let data = fs::read(dir.join("entry.json")).ok()?;
            let mut e: Entry = serde_json::from_slice(&data).ok()?;
            e.audio_path = audio_file(&dir).map(|p| p.to_string_lossy().into_owned());
            Some(e)
        })
        .collect();
    out.sort_by(|a, b| b.created_at.partial_cmp(&a.created_at).unwrap_or(std::cmp::Ordering::Equal));
    Ok(out)
}

pub fn delete(root: &str, id: &str) -> Result<(), String> {
    let dir = safe_dir(root, id)?;
    if dir.exists() {
        fs::remove_dir_all(dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn purge(a: &PurgeArgs) -> Result<PurgeReport, String> {
    let mut report = PurgeReport::default();
    let expired = |days: i64, created: f64| days >= 0 && a.now - created >= days as f64 * 86_400.0;
    for mut e in list(&a.root)? {
        let dir = safe_dir(&a.root, &e.id)?;
        if expired(a.audio_days, e.created_at) {
            if let Some(p) = audio_file(&dir) {
                fs::remove_file(p).map_err(|e| e.to_string())?;
                report.audio_removed += 1;
                e.audio_path = None;
            }
        }
        if expired(a.transcript_days, e.created_at) && !e.text_purged {
            if e.audio_path.is_none() {
                fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
                report.entries_removed += 1;
                continue;
            }
            // Audio is retained longer than text: keep a stub so the
            // recording remains discoverable.
            e.raw_text.clear();
            e.cleaned_text = None;
            e.final_text.clear();
            e.text_purged = true;
            save(&a.root, &e)?;
            report.entries_removed += 1;
        } else if e.audio_path.is_none() && e.text_purged {
            fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, created_at: f64) -> Entry {
        Entry {
            id: id.into(), created_at, duration: 1.0, raw_text: "hi".into(), cleaned_text: None,
            final_text: "Hi.".into(), engine: "apple".into(), cleanup_engine: None, app_name: None,
            microphone: None, error: None, audio_path: None, text_purged: false,
        }
    }

    #[test]
    fn retention() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_str().unwrap().to_string();
        let now = 100.0 * 86_400.0;
        for (id, age_days) in [("new", 0.5), ("mid", 10.0), ("old", 40.0)] {
            save(&root, &entry(id, now - age_days * 86_400.0)).unwrap();
            fs::write(tmp.path().join(id).join("audio.m4a"), b"x").unwrap();
        }
        // Audio 7 days, text 30 days.
        let r = purge(&PurgeArgs { root: root.clone(), audio_days: 7, transcript_days: 30, now }).unwrap();
        assert_eq!(r.audio_removed, 2);
        assert_eq!(r.entries_removed, 1);
        let left = list(&root).unwrap();
        assert_eq!(left.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), vec!["new", "mid"]);
        assert!(left[0].audio_path.is_some());
        assert!(left[1].audio_path.is_none());

        // Text 0 days, audio forever: text stubbed but audio kept.
        let r = purge(&PurgeArgs { root: root.clone(), audio_days: -1, transcript_days: 0, now }).unwrap();
        assert_eq!(r.entries_removed, 2);
        let left = list(&root).unwrap();
        assert_eq!(left.len(), 1);
        assert!(left[0].text_purged && left[0].final_text.is_empty() && left[0].audio_path.is_some());
    }

    #[test]
    fn rejects_traversal() {
        assert!(delete("/tmp", "../etc").is_err());
    }
}
