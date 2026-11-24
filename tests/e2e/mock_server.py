"""Mock OpenRouter / OpenAI-compatible server for Murmur's e2e tests.

Validates the wire format Murmur's Rust core sends and returns canned text
that encodes what it saw, so assertions can check prompts made it through.
"""
import base64, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/models"):
            return self.reply(200, {"data": [
                {"id": "mock/audio-model", "name": "Mock Audio", "architecture": {"input_modalities": ["text", "audio"]}},
                {"id": "mock/text-model", "name": "Mock Text", "architecture": {"input_modalities": ["text"]}}]})
        self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        auth = self.headers.get("Authorization", "")
        if auth != "Bearer test-key":
            return self.reply(401, {"error": {"message": "bad key"}})
        if self.path.endswith("/audio/transcriptions"):
            ctype = self.headers.get("Content-Type", "")
            ok = "multipart/form-data" in ctype and b'name="file"' in raw and b"RIFF" in raw and b"WAVE" in raw
            prompt_ok = b"Kubernetes" in raw
            LOG.append({"path": self.path, "multipart_ok": ok})
            if not ok:
                return self.reply(400, {"error": {"message": "bad multipart"}})
            return self.reply(200, {"text": "deploy it to cooper netties today" + (" (prompt ok)" if prompt_ok else "")})
        if self.path.endswith("/chat/completions"):
            req = json.loads(raw)
            msgs = req["messages"]
            system = msgs[0]["content"]
            user = msgs[1]["content"]
            has_audio = False
            if isinstance(user, list):
                for part in user:
                    if part.get("type") == "input_audio":
                        wav = base64.b64decode(part["input_audio"]["data"])
                        has_audio = wav[:4] == b"RIFF" and part["input_audio"]["format"] == "wav"
                text = " ".join(p.get("text", "") for p in user if p.get("type") == "text")
            else:
                text = user
            LOG.append({"path": self.path, "model": req["model"], "audio": has_audio})
            if "Transcribe" in text or "Transcribe" in system:
                out = "Ship the SwiftUI build tonight" + (" [audio ok]" if has_audio else " [no audio]")
            else:
                body = text.split("<transcript>")[-1].split("</transcript>")[0].strip()
                tags = []
                if "Kubernetes" in system: tags.append("vocab ok")
                if has_audio: tags.append("audio ok")
                if "British" in system: tags.append("style ok")
                if system.startswith("CUSTOM-PROMPT terms=Kubernetes style=British spelling") and "{{" not in system:
                    tags.append("custom prompt ok")
                out = f"<transcript>Polished: {body} [{', '.join(tags)}]</transcript>"
            return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": out}}]})
        self.reply(404, {"error": {"message": "not found"}})

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
