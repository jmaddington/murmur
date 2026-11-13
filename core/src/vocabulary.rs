use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Term {
    /// Canonical spelling, e.g. "Kubernetes".
    pub term: String,
    /// What the recognizer tends to hear instead, e.g. ["cooper netties"].
    #[serde(default)]
    pub sounds_like: Vec<String>,
}

#[derive(Deserialize)]
pub struct ApplyArgs {
    pub text: String,
    #[serde(default)]
    pub vocabulary: Vec<Term>,
}

/// Punctuation-insensitive matcher: "j q reyes" matches "J.Q. Reyes",
/// "nettie's" matches "netties", "c plus plus" spacing is flexible.
fn word_regex(phrase: &str) -> Option<Regex> {
    let tokens: Vec<String> = phrase
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter(|t| !t.is_empty())
        .map(|tok| {
            tok.chars()
                .filter(|c| !matches!(c, '.' | '\'' | '’'))
                .map(|c| {
                    let e = regex::escape(&c.to_string());
                    if c.is_alphanumeric() { format!("{e}[.'’]?") } else { e }
                })
                .collect::<String>()
        })
        .filter(|t| !t.is_empty())
        .collect();
    if tokens.is_empty() {
        return None;
    }
    let body = tokens.join(r"[\s\-,]*");
    let p = phrase.trim();
    let lb = if p.chars().next()?.is_alphanumeric() { r"\b" } else { "" };
    let rb = if p.chars().last()?.is_alphanumeric() { r"(?:\b|\B[.'’])" } else { "" };
    RegexBuilder::new(&format!("{lb}{body}{rb}")).case_insensitive(true).build().ok()
}

fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        prev = cur;
    }
    prev[b.len()]
}

/// Fuzzy pass for explicit "sounds like" phrases: replace a run of words whose
/// letters are within a small edit distance of the phrase (≥ 8 letters only,
/// to avoid clobbering short common words).
fn fuzzy_replace(text: &str, phrase: &str, term: &str) -> String {
    let target = squash(phrase);
    let n_words = phrase.split_whitespace().count().max(1);
    if target.chars().count() < 8 {
        return text.to_string();
    }
    // ~1 edit per 5 letters: "kubernettis" → "Kubernetes", "coopernettis" → "cooper netties".
    let max_dist = ((target.chars().count() + 2) / 5).max(1);
    let word_re = Regex::new(r"[\w'’.\-]+").unwrap();
    let words: Vec<regex::Match> = word_re.find_iter(text).collect();
    let mut out = String::new();
    let mut last = 0;
    let mut i = 0;
    while i < words.len() {
        let mut matched = None;
        for span in [n_words, n_words + 1, n_words.saturating_sub(1)] {
            if span == 0 || i + span > words.len() {
                continue;
            }
            let start = words[i].start();
            let end = words[i + span - 1].end();
            let candidate = squash(&text[start..end]);
            // Already correct (possibly with a neighbouring word): nothing to fix.
            if candidate.contains(&squash(term)) {
                continue;
            }
            if levenshtein(&candidate, &target) <= max_dist {
                matched = Some((start, end, span));
                break;
            }
        }
        if let Some((start, mut end, span)) = matched {
            // Keep trailing sentence punctuation that belonged to the last word.
            while end > start && matches!(text.as_bytes()[end - 1], b'.' | b'-') { end -= 1; }
            out.push_str(&text[last..start]);
            out.push_str(term);
            last = end;
            i += span;
        } else {
            i += 1;
        }
    }
    out.push_str(&text[last..]);
    out
}

/// Deterministic vocabulary pass: rewrite known mishearings to the canonical
/// term, then normalise the casing/punctuation of the term itself.
pub fn apply(text: &str, vocab: &[Term]) -> String {
    let mut out = text.to_string();
    // Longest phrases first so "jay queue reyes" wins over "jay em".
    let mut pairs: Vec<(&str, &str, bool)> = vocab
        .iter()
        .flat_map(|t| {
            t.sounds_like
                .iter()
                .map(move |s| (s.as_str(), t.term.as_str(), true))
                .chain(std::iter::once((t.term.as_str(), t.term.as_str(), false)))
        })
        .filter(|(from, to, _)| !from.trim().is_empty() && !to.trim().is_empty())
        .collect();
    pairs.sort_by_key(|(from, _, _)| std::cmp::Reverse(from.len()));
    for (from, to, _) in &pairs {
        if let Some(re) = word_regex(from) {
            out = re.replace_all(&out, regex::NoExpand(to)).into_owned();
        }
    }
    // Fuzzy pass covers explicit variants and the (long enough) term itself.
    for (from, to, _) in &pairs {
        out = fuzzy_replace(&out, from, to);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(term: &str, s: &[&str]) -> Term {
        Term { term: term.into(), sounds_like: s.iter().map(|x| x.to_string()).collect() }
    }

    #[test]
    fn replaces_mishearings_and_case() {
        let v = vec![t("Kubernetes", &["cooper netties"]), t("JM", &["jay em"])];
        assert_eq!(
            apply("deploy to Cooper Netties and kubernetes, ask jay em", &v),
            "deploy to Kubernetes and Kubernetes, ask JM"
        );
    }

    #[test]
    fn respects_word_boundaries() {
        let v = vec![t("Rust", &[])];
        assert_eq!(apply("trust rust", &v), "trust Rust");
    }

    #[test]
    fn punctuation_insensitive() {
        let v = vec![t("JQ Reyes", &["j q reyes"]), t("Kubernetes", &["cooper nettie's"])];
        assert_eq!(
            apply("Ask J.Q. Reyes about the Cooper Netties dashboard.", &v),
            "Ask JQ Reyes about the Kubernetes dashboard."
        );
    }

    #[test]
    fn commas_between_words() {
        let v = vec![t("JQ Reyes", &["jake you raised"])];
        assert_eq!(apply("Can you ask Jake, you raised to look?", &v), "Can you ask JQ Reyes to look?");
    }

    #[test]
    fn fuzzy_sounds_like() {
        let v = vec![t("Kubernetes", &["cooper netties"])];
        assert_eq!(apply("look at the Cooper Netti's dashboard", &v), "look at the Kubernetes dashboard");
        // Short / unrelated words are left alone.
        assert_eq!(apply("cooper said hello", &v), "cooper said hello");
    }

    #[test]
    fn fuzzy_term_itself() {
        let v = vec![t("Kubernetes", &[])];
        assert_eq!(apply("look at the Kubernetti's dashboard", &v), "look at the Kubernetes dashboard");
        // Unrelated words of similar length are left alone.
        assert_eq!(apply("the government dashboard", &v), "the government dashboard");
        assert_eq!(apply("the governess arrived", &v), "the governess arrived");
    }

    #[test]
    fn short_terms_are_exact_only() {
        let v = vec![t("Rust", &[]), t("JQ Reyes", &[])];
        assert_eq!(apply("I trust Rest and rust", &v), "I trust Rest and Rust");
    }

    #[test]
    fn symbols_ok() {
        let v = vec![t("C++", &["see plus plus"])];
        assert_eq!(apply("I like see plus plus", &v), "I like C++");
    }
}
