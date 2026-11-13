"""Generate natural-sounding demo narration with an OpenRouter audio model.

    OPENROUTER_API_KEY=… python3 tests/e2e/make_demo_voice.py [voice] [model]

Writes tests/e2e/audio/demo/{basic,vocab,cleanup}.wav (24 kHz mono PCM).
The plain `say` fixtures stay as the deterministic test inputs; these are only
for the recorded product demo.
"""
import base64, json, os, sys, urllib.request, wave

LINES = {
    "basic": "Let's move the design review to Wednesday at three o'clock, and send the agenda to the whole team.",
    "vocab": "Can you ask J. Q. Reyes to look at the Kubernetes dashboard before lunch?",
    "cleanup": "Um, so I think, uh, we should move the meeting to Tuesday. No wait, actually, Wednesday works better.",
}
VOICE = sys.argv[1] if len(sys.argv) > 1 else "marin"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "openai/gpt-audio"
OUT = os.path.join(os.path.dirname(__file__), "audio", "demo")
KEY = os.environ["OPENROUTER_API_KEY"]

SYSTEM = ("You are a voice actor recording lines for a product demo. Speak the user's text aloud exactly as "
          "written, word for word, including any filler words like 'um' and 'uh'. Sound like a relaxed, friendly "
          "person dictating a message at a natural pace. Do not add, omit or comment on anything.")

def speak(text: str) -> bytes:
    body = {
        "model": MODEL, "stream": True, "modalities": ["text", "audio"],
        "audio": {"voice": VOICE, "format": "pcm16"},
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": f"Read this aloud:\n\n{text}"}],
    }
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                                 {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    pcm, transcript = bytearray(), []
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            delta = json.loads(line[6:]).get("choices", [{}])[0].get("delta", {})
            audio = delta.get("audio") or {}
            if audio.get("data"):
                pcm += base64.b64decode(audio["data"])
            if audio.get("transcript"):
                transcript.append(audio["transcript"])
    print(f"  model said: {''.join(transcript).strip()!r}")
    return bytes(pcm)

os.makedirs(OUT, exist_ok=True)
for name, text in LINES.items():
    print(f"{name} ({VOICE}):")
    pcm = speak(text)
    path = os.path.join(OUT, f"{name}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(pcm)
    print(f"  {len(pcm) / 48000:.1f}s → {path}")
