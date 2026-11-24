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
    /// Seconds from releasing the key to the transcript being ready.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcribe_seconds: Option<f64>,
    /// Seconds spent in the cleanup model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub polish_seconds: Option<f64>,
    /// Seconds from releasing the key to the final text being ready to type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_seconds: Option<f64>,
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
    // Exactly one ordinary path component: no separators, no "..", and not "."
    // (which would resolve to the history root itself and let `delete` wipe it).
    let mut parts = Path::new(id).components();
    let single_normal = matches!(parts.next(), Some(std::path::Component::Normal(_))) && parts.next().is_none();
    if !single_normal || id.contains(['/', '\\', '\0']) || id.contains("..") {
        return Err("invalid id".into());
    }
    Ok(Path::new(root).join(id))
}

fn audio_files(dir: &Path) -> Vec<PathBuf> {
    AUDIO_EXTENSIONS.iter().map(|e| dir.join(format!("audio.{e}"))).filter(|p| p.exists()).collect()
}

fn audio_file(dir: &Path) -> Option<PathBuf> {
    audio_files(dir).into_iter().next()
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
            // The folder name is the identity every other command addresses the
            // entry by; never trust a diverging `id` inside the JSON.
            e.id = d.file_name().to_str()?.to_string();
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

/// Recordings whose entry was never written (crash or quit mid-dictation) are
/// invisible to `list`; give them at least this long before treating them as
/// abandoned, so a dictation that is still in flight is never touched.
const ORPHAN_GRACE_SECS: f64 = 3_600.0;

pub fn purge(a: &PurgeArgs) -> Result<PurgeReport, String> {
    let mut report = PurgeReport::default();
    let expired = |days: i64, created: f64| days >= 0 && a.now - created >= days as f64 * 86_400.0;
    for mut e in list(&a.root)? {
        // One unreadable or undeletable entry must not stop retention for the rest.
        let Ok(dir) = safe_dir(&a.root, &e.id) else { continue };
        if expired(a.audio_days, e.created_at) {
            let files = audio_files(&dir);
            let removed = files.iter().filter(|p| fs::remove_file(p).is_ok()).count();
            if removed > 0 {
                report.audio_removed += 1;
            }
            if removed == files.len() {
                e.audio_path = None;
            }
        }
        if expired(a.transcript_days, e.created_at) && !e.text_purged {
            if e.audio_path.is_none() {
                if fs::remove_dir_all(&dir).is_ok() {
                    report.entries_removed += 1;
                }
                continue;
            }
            // Audio is retained longer than text: keep a stub so the
            // recording remains discoverable.
            e.raw_text.clear();
            e.cleaned_text = None;
            e.final_text.clear();
            e.text_purged = true;
            if save(&a.root, &e).is_ok() {
                report.entries_removed += 1;
            }
        } else if e.audio_path.is_none() && e.text_purged {
            let _ = fs::remove_dir_all(&dir);
        }
    }
    purge_orphans(a, &mut report);
    Ok(report)
}

/// Folders with audio but no `entry.json` never show up in the UI, so nothing
/// else would ever delete them: apply the audio retention to them by folder age.
fn purge_orphans(a: &PurgeArgs, report: &mut PurgeReport) {
    let Ok(rd) = fs::read_dir(&a.root) else { return };
    for d in rd.flatten() {
        let dir = d.path();
        let is_real_dir = d.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if !is_real_dir || dir.join("entry.json").exists() {
            continue;
        }
        let Some(modified) = fs::metadata(&dir)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        else {
            continue;
        };
        let age = a.now - modified.as_secs_f64();
        if age < ORPHAN_GRACE_SECS {
            continue;
        }
        if a.audio_days >= 0 && age >= a.audio_days as f64 * 86_400.0 {
            let removed = audio_files(&dir).iter().filter(|p| fs::remove_file(p).is_ok()).count();
            if removed > 0 {
                report.audio_removed += 1;
            }
        }
        // Only succeeds once the folder is empty; anything unrecognised is left alone.
        let _ = fs::remove_file(dir.join("entry.json.tmp"));
        let _ = fs::remove_dir(&dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, created_at: f64) -> Entry {
        Entry {
            id: id.into(), created_at, duration: 1.0, raw_text: "hi".into(), cleaned_text: None,
            final_text: "Hi.".into(), engine: "apple".into(), cleanup_engine: None, app_name: None,
            microphone: None, error: None, audio_path: None, text_purged: false, transcribe_seconds: None, polish_seconds: None, latency_seconds: None,
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
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_str().unwrap().to_string();
        save(&root, &entry("keep", 1.0)).unwrap();
        // "." used to resolve to the history root and delete everything.
        for bad in [".", "..", "", "a/b", "/abs", "a\\b"] {
            assert!(delete(&root, bad).is_err(), "{bad:?}");
            assert!(save(&root, &entry(bad, 1.0)).is_err(), "{bad:?}");
        }
        assert_eq!(list(&root).unwrap().len(), 1);
    }

    #[test]
    fn folder_name_is_the_identity() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_str().unwrap().to_string();
        let now = 100.0 * 86_400.0;
        save(&root, &entry("victim", now)).unwrap();
        save(&root, &entry("old", now - 40.0 * 86_400.0)).unwrap();
        // A (corrupt / hand-edited) entry.json naming another entry or the root itself.
        for lie in ["victim", "."] {
            let json = serde_json::to_vec(&entry(lie, now - 40.0 * 86_400.0)).unwrap();
            fs::write(tmp.path().join("old").join("entry.json"), json).unwrap();
            assert_eq!(list(&root).unwrap().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), vec!["victim", "old"]);
        }
        let r = purge(&PurgeArgs { root: root.clone(), audio_days: 7, transcript_days: 30, now }).unwrap();
        assert_eq!(r.entries_removed, 1);
        assert_eq!(list(&root).unwrap().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), vec!["victim"]);
    }

    #[test]
    fn one_bad_entry_does_not_block_purge() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_str().unwrap().to_string();
        let now = 100.0 * 86_400.0;
        for id in ["a", "b", "c"] {
            save(&root, &entry(id, now - 40.0 * 86_400.0)).unwrap();
        }
        // "audio.m4a" that cannot be removed with remove_file (it is a non-empty directory).
        for id in ["a", "b", "c"] {
            if id != "b" { continue; }
            fs::create_dir_all(tmp.path().join(id).join("audio.m4a").join("x")).unwrap();
        }
        let r = purge(&PurgeArgs { root: root.clone(), audio_days: 7, transcript_days: -1, now }).unwrap();
        assert_eq!(r.audio_removed, 0);
        let r = purge(&PurgeArgs { root: root.clone(), audio_days: -1, transcript_days: 30, now }).unwrap();
        assert_eq!(r.entries_removed, 3);
        assert_eq!(list(&root).unwrap().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), vec!["b"]);
    }

    #[test]
    fn orphaned_audio_follows_audio_retention() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_str().unwrap().to_string();
        let orphan = tmp.path().join("orphan");
        fs::create_dir_all(&orphan).unwrap();
        fs::write(orphan.join("audio.m4a"), b"x").unwrap();
        fs::create_dir_all(tmp.path().join("empty")).unwrap();
        let real_now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
        let args = |audio_days, now| PurgeArgs { root: root.clone(), audio_days, transcript_days: 30, now };

        // A recording still in flight (no entry yet) is never touched, even with "don't keep".
        purge(&args(0, real_now + 60.0)).unwrap();
        assert!(orphan.join("audio.m4a").exists());
        // Abandoned, but audio is kept forever / not yet past retention: left alone.
        purge(&args(-1, real_now + 30.0 * 86_400.0)).unwrap();
        purge(&args(7, real_now + 2.0 * 86_400.0)).unwrap();
        assert!(orphan.join("audio.m4a").exists());
        // Past retention: removed, along with empty leftover folders.
        let r = purge(&args(7, real_now + 8.0 * 86_400.0)).unwrap();
        assert_eq!(r.audio_removed, 1);
        assert!(!orphan.exists());
        assert!(!tmp.path().join("empty").exists());
    }
}

#[cfg(test)]
mod timing_tests {
    use super::*;

    #[test]
    fn timings_round_trip_and_old_entries_still_load() {
        let old: Entry = serde_json::from_str(r#"{"id":"a","created_at":1.0}"#).unwrap();
        assert_eq!(old.latency_seconds, None);
        let mut e = old.clone();
        e.transcribe_seconds = Some(0.12);
        e.polish_seconds = Some(0.8);
        e.latency_seconds = Some(0.95);
        let back: Entry = serde_json::from_str(&serde_json::to_string(&e).unwrap()).unwrap();
        assert_eq!((back.transcribe_seconds, back.polish_seconds, back.latency_seconds), (Some(0.12), Some(0.8), Some(0.95)));
        assert!(!serde_json::to_string(&old).unwrap().contains("latency"));
    }
}
