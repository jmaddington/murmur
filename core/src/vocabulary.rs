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

/// Punctuation dropped from a phrase and tolerated (optionally) in the text.
const SOFT_PUNCT: [char; 3] = ['.', '\'', '’'];
const SOFT: &str = "[.'’]";

/// Punctuation-insensitive matcher: "j q reyes" matches "J.Q. Reyes",
/// "nettie's" matches "netties", "c plus plus" spacing is flexible.
fn word_regex(phrase: &str) -> Option<Regex> {
    let tokens: Vec<String> = phrase
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter(|t| !t.is_empty())
        .map(|tok| {
            tok.chars()
                .filter(|c| !SOFT_PUNCT.contains(c))
                .map(|c| {
                    let e = regex::escape(&c.to_string());
                    if c.is_alphanumeric() { format!("{e}{SOFT}?") } else { e }
                })
                .collect::<String>()
        })
        .filter(|t| !t.is_empty())
        .collect();
    if tokens.is_empty() {
        return None;
    }
    let mut body = tokens.join(r"[\s\-,]*");
    // Word boundaries are decided by the first/last character that is actually
    // matched, not by the phrase's first/last character: for "Dr." or ".NET"
    // the soft punctuation is dropped from the pattern, and anchoring on it
    // left the pattern unanchored ("drive" → "Dr.ive", "internet" → "inter.NET").
    let p = phrase.trim();
    let mut kept = phrase.chars().filter(|c| !(c.is_whitespace() || *c == '-' || SOFT_PUNCT.contains(c)));
    let first_kept = kept.next()?;
    let last_kept = kept.last().unwrap_or(first_kept);
    let lb = match (first_kept.is_alphanumeric(), p.starts_with(SOFT_PUNCT)) {
        // Swallow the term's own leading punctuation if it is already there (".net" → ".NET", not "..NET").
        (true, true) => format!(r"{SOFT}?\b"),
        (true, false) => r"\b".to_string(),
        (false, _) => String::new(),
    };
    let rb = if !last_kept.is_alphanumeric() {
        ""
    } else if p.ends_with(SOFT_PUNCT) {
        // Likewise swallow existing trailing punctuation ("dr." → "Dr.", not "Dr.."),
        // otherwise require the word to end here.
        let trimmed = body.len() - format!("{SOFT}?").len();
        body.truncate(trimmed);
        r"(?:[.'’]|\b)"
    } else {
        r"(?:\b|\B[.'’])"
    };
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
/// to avoid clobbering short common words). Runs that are exactly another
/// vocabulary term (`protected`, squashed) are never touched.
fn fuzzy_replace(text: &str, phrase: &str, term: &str, protected: &[String]) -> String {
    let target = squash(phrase);
    let target_len = target.chars().count();
    let n_words = phrase.split_whitespace().count().max(1);
    if target_len < 8 {
        return text.to_string();
    }
    // ~1 edit per 5 letters: "kubernettis" → "Kubernetes", "coopernettis" → "cooper netties".
    let max_dist = ((target_len + 2) / 5).max(1);
    let term_squashed = squash(term);
    let word_re = Regex::new(r"[\w'’.\-]+").unwrap();
    let words: Vec<regex::Match> = word_re.find_iter(text).collect();

    // Every (distance, span preference, first word, word count) within range…
    let mut candidates: Vec<(usize, usize, usize, usize)> = Vec::new();
    for i in 0..words.len() {
        for (pref, span) in [n_words, n_words + 1, n_words.saturating_sub(1)].into_iter().enumerate() {
            if span == 0 || i + span > words.len() {
                continue;
            }
            let candidate = squash(&text[words[i].start()..words[i + span - 1].end()]);
            // Already correct (possibly with a neighbouring word): nothing to fix.
            if candidate.contains(&term_squashed) || protected.contains(&candidate) {
                continue;
            }
            if candidate.chars().count().abs_diff(target_len) > max_dist {
                continue;
            }
            let dist = levenshtein(&candidate, &target);
            if dist <= max_dist {
                candidates.push((dist, pref, i, span));
            }
        }
    }
    // …then the closest matches win. Taking the first match left-to-right
    // instead would let "to cooper nettis" (3 edits) beat "cooper nettis"
    // (1 edit) and swallow the word in front.
    candidates.sort();
    let mut taken = vec![false; words.len()];
    let mut chosen: Vec<(usize, usize)> = Vec::new();
    for (_, _, i, span) in candidates {
        if taken[i..i + span].iter().any(|t| *t) {
            continue;
        }
        taken[i..i + span].iter_mut().for_each(|t| *t = true);
        chosen.push((i, span));
    }
    chosen.sort();

    let edge = ['.', '-', '\'', '’'];
    let mut out = String::new();
    let mut last = 0;
    for (i, span) in chosen {
        // Keep sentence punctuation / quotes hugging the run's first and last word.
        let run = &text[words[i].start()..words[i + span - 1].end()];
        let start = words[i].start() + (run.len() - run.trim_start_matches(edge).len());
        let end = start + run.trim_start_matches(edge).trim_end_matches(edge).len();
        out.push_str(&text[last..start]);
        out.push_str(term);
        last = end;
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
    let protected: Vec<String> = vocab.iter().map(|t| squash(&t.term)).filter(|t| !t.is_empty()).collect();
    for (from, to, _) in &pairs {
        out = fuzzy_replace(&out, from, to, &protected);
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
    fn terms_ending_in_punctuation_keep_word_boundaries() {
        let v = vec![t("Dr.", &[]), t("Inc.", &[])];
        assert_eq!(apply("drive to the drop zone and include it", &v), "drive to the drop zone and include it");
        assert_eq!(apply("ask dr. Smith at Acme inc. today", &v), "ask Dr. Smith at Acme Inc. today");
        assert_eq!(apply("ask dr Smith at Acme inc", &v), "ask Dr. Smith at Acme Inc.");
    }

    #[test]
    fn terms_starting_with_punctuation_keep_word_boundaries() {
        let v = vec![t(".NET", &["dot net"])];
        assert_eq!(apply("the internet runs on dot net", &v), "the internet runs on .NET");
        assert_eq!(apply("we use .net daily", &v), "we use .NET daily");
    }

    #[test]
    fn fuzzy_does_not_swallow_neighbouring_words() {
        let v = vec![t("Kubernetes", &["cooper netties"])];
        assert_eq!(apply("deploy to Cooper Nettis now", &v), "deploy to Kubernetes now");
        assert_eq!(apply("go to kubernetis, then on to the next", &v), "go to Kubernetes, then on to the next");
    }

    #[test]
    fn fuzzy_leaves_other_vocabulary_terms_alone() {
        let v = vec![t("Christensen", &[]), t("Christiansen", &[])];
        assert_eq!(
            apply("christensen met Christiansen", &v),
            "Christensen met Christiansen"
        );
        // …in either order.
        let v = vec![t("Christiansen", &[]), t("Christensen", &[])];
        assert_eq!(apply("Christensen met christiansen", &v), "Christensen met Christiansen");
    }

    #[test]
    fn multibyte_text_is_safe() {
        let v = vec![t("Kubernetes", &["cooper netties"]), t("Zoë", &["zoey"]), t("München", &[])];
        assert_eq!(
            apply("“Zoey” déploie sur coopér nettïes — à münchen… 日本語 🙂 kubernetti’s.", &v),
            "“Zoë” déploie sur Kubernetes — à München… 日本語 🙂 Kubernetes."
        );
    }

    #[test]
    fn symbols_ok() {
        let v = vec![t("C++", &["see plus plus"])];
        assert_eq!(apply("I like see plus plus", &v), "I like C++");
    }
}
