"""Murmur's MLX speech-to-text worker.

Runs inside a private virtualenv that Murmur manages with uv. Speaks JSON
lines: one request per line on stdin, one response per line on the protocol
stream. Libraries print freely, so the real stdout is reserved for protocol
messages and everything else goes to stderr (Murmur logs it).

Requests:
  {"cmd": "download"}               fetch the model into HF_HOME
  {"cmd": "load"}                   load it into memory (idempotent)
  {"cmd": "transcribe", "wav": p}   transcribe a 16 kHz WAV file
Responses: {"ok": true} | {"text": "..."} | {"error": "..."}
"""
import json
import os
import sys
import time

MODEL = sys.argv[1]

# Keep fd 1 for the protocol; route stray prints (from any library) to stderr.
_proto = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr

_model = None


def reply(obj):
    _proto.write(json.dumps(obj) + "\n")
    _proto.flush()


def load():
    global _model
    if _model is None:
        from mlx_audio.stt.utils import load as load_stt

        t = time.time()
        _model = load_stt(MODEL)
        print(f"murmur-worker: loaded {MODEL} in {time.time() - t:.1f}s", file=sys.stderr, flush=True)
    return _model


def transcribe(path):
    m = load()
    t = time.time()
    out = m.generate(path, temperature=0.0)
    text = getattr(out, "text", out)
    if not isinstance(text, str):
        text = "".join(text)
    print(f"murmur-worker: transcribed in {time.time() - t:.2f}s", file=sys.stderr, flush=True)
    return text.strip()


reply({"ready": True})
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
        cmd = req.get("cmd")
        if cmd == "download":
            from huggingface_hub import snapshot_download

            snapshot_download(MODEL)
            reply({"ok": True})
        elif cmd == "load":
            load()
            reply({"ok": True})
        elif cmd == "transcribe":
            reply({"text": transcribe(req["wav"])})
        else:
            reply({"error": f"unknown command {cmd!r}"})
    except Exception as e:  # report, keep serving
        reply({"error": f"{type(e).__name__}: {e}"})
