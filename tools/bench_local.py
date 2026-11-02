#!/usr/bin/env python3
"""Compare transcription engines on your own recordings: accuracy (WER/CER) and latency.

Each local model runs in whisper.cpp's whisper-server, loaded once, with one request per
recording, which is how the app uses it (model stays loaded, one dictation at a time).
Groq can be measured the same way over your real network for a side-by-side comparison.

Test set: a folder of audio files, each with a reference transcript next to it
(voice_X.wav + voice_X.txt). The app builds one for you:

    defaults write com.tqt.whispertype KeepRecordings -bool true
    # dictate normally for a while, then look in ~/Library/Caches/com.tqt.whispertype/samples/

The .txt files hold what was typed at the time (usually Groq's output). Fix them by hand
so they say what you actually said; until then, WER only measures agreement with that
engine, and that engine scores ~0 against itself.

Examples:
    tools/build-bench.sh                     # builds build-bench/bin/whisper-server
    tools/bench_local.py large-v3-turbo large-v3-turbo-q8_0 large-v3-turbo-q5_0 --download
    tools/bench_local.py ~/models/ggml-phowhisper-medium.bin groq:whisper-large-v3

Only the Python standard library is used (works with the python3 of Xcode's tools).
"""

import argparse
import json
import os
import re
import signal
import socket
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import wave

HOME = os.path.expanduser("~")
DEFAULT_SAMPLES = os.path.join(HOME, "Library/Caches/com.tqt.whispertype/samples")
DEFAULT_MODELS_DIR = os.path.join(HOME, "Library/Application Support/TQT/Whispertype")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SERVER = os.path.join(REPO, "build-bench/bin/whisper-server")
MODEL_REPO_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
AUDIO_EXTS = (".wav", ".flac", ".mp3", ".m4a", ".ogg")
LANGUAGE = "vi"


# ---------------------------------------------------------------- text metrics

def normalize(text):
    """Lowercase, NFC, punctuation removed, whitespace collapsed (Vietnamese words = syllables)."""
    text = unicodedata.normalize("NFC", text).lower()
    text = "".join(" " if unicodedata.category(c).startswith("P") else c for c in text)
    return " ".join(text.split())


def has_punct(text):
    return any(unicodedata.category(c).startswith("P") for c in text)


def has_upper(text):
    return any(c.isupper() for c in text)


def edit_distance(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


# ---------------------------------------------------------------- helpers

def audio_seconds(path):
    if path.lower().endswith(".wav"):
        try:
            with wave.open(path, "rb") as w:
                return w.getnframes() / float(w.getframerate())
        except (wave.Error, EOFError):
            return None
    return None


def multipart(fields, file_field, file_path):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                      % (boundary, name, value)).encode())
    with open(file_path, "rb") as f:
        data = f.read()
    parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                  "Content-Type: application/octet-stream\r\n\r\n"
                  % (boundary, file_field, os.path.basename(file_path))).encode())
    parts.append(data)
    parts.append(("\r\n--%s--\r\n" % boundary).encode())
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


def post(url, fields, file_path, headers=None, timeout=600):
    body, ctype = multipart(fields, "file", file_path)
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", ctype)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = resp.read()
    return time.perf_counter() - t0, payload


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def rss_mb(pid):
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
        return int(out) / 1024.0 if out else None
    except (subprocess.CalledProcessError, ValueError, OSError):
        return None


def groq_key():
    key = os.environ.get("GROQ_API_KEY", "")
    if key:
        return key
    try:
        return subprocess.check_output(
            ["defaults", "read", "com.tqt.whispertype", "GroqAPIKey"],
            text=True, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, OSError):
        return ""


def resolve_model(spec, models_dir, download):
    """'large-v3-turbo-q5_0' -> <models_dir>/ggml-large-v3-turbo-q5_0.bin (downloaded on request)."""
    path = os.path.expanduser(spec)
    if os.path.isfile(path):
        return path
    name = os.path.basename(spec)
    if not name.endswith(".bin"):
        name = "ggml-%s.bin" % name
    path = os.path.join(models_dir, name)
    if os.path.isfile(path):
        return path
    if not download:
        sys.exit("Model not found: %s (pass --download to fetch %s from Hugging Face)" % (path, name))
    os.makedirs(models_dir, exist_ok=True)
    print("Downloading %s ..." % name, flush=True)
    tmp = path + ".part"
    subprocess.check_call(["curl", "-fL", "--progress-bar", "-o", tmp, MODEL_REPO_URL + name])
    os.rename(tmp, path)
    return path


def load_samples(folder, limit):
    samples = []
    for name in sorted(os.listdir(folder)):
        base, ext = os.path.splitext(name)
        if ext.lower() not in AUDIO_EXTS:
            continue
        audio = os.path.join(folder, name)
        ref_path = os.path.join(folder, base + ".txt")
        ref = None
        if os.path.isfile(ref_path):
            with open(ref_path, encoding="utf-8") as f:
                ref = f.read().strip()
        samples.append({"name": base, "audio": audio, "ref": ref, "secs": audio_seconds(audio)})
    return samples[:limit] if limit else samples


# ---------------------------------------------------------------- engines

class WhisperServer:
    def __init__(self, binary, model, threads, vad_model, log_path):
        self.port = free_port()
        cmd = [binary, "-m", model, "-l", LANGUAGE, "-nt",
               "--host", "127.0.0.1", "--port", str(self.port)]
        if threads:
            cmd += ["-t", str(threads)]
        if vad_model:
            cmd += ["--vad", "-vm", vad_model]
        self.log = open(log_path, "w")
        t0 = time.perf_counter()
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
        self.url = "http://127.0.0.1:%d" % self.port
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError("whisper-server exited (code %s), see %s" % (self.proc.returncode, log_path))
            try:
                with urllib.request.urlopen(self.url + "/health", timeout=2) as r:
                    if r.status == 200:
                        break
            except (urllib.error.URLError, ConnectionError, socket.timeout):
                pass
            if time.perf_counter() - t0 > 600:
                raise RuntimeError("whisper-server did not become ready, see %s" % log_path)
            time.sleep(0.2)
        self.load_secs = time.perf_counter() - t0

    def transcribe(self, audio):
        secs, payload = post(self.url + "/inference",
                             {"response_format": "json", "language": LANGUAGE, "no_timestamps": "true",
                              "temperature": "0.0"}, audio)
        return secs, json.loads(payload.decode("utf-8")).get("text", "")

    def rss(self):
        return rss_mb(self.proc.pid)

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()


class Groq:
    load_secs = 0.0

    def __init__(self, model):
        self.model = model
        self.key = groq_key()
        if not self.key:
            raise RuntimeError("No Groq key: set GROQ_API_KEY or the app's GroqAPIKey default")

    def transcribe(self, audio):
        secs, payload = post(GROQ_URL, {"model": self.model, "language": LANGUAGE,
                                        "response_format": "json", "temperature": "0"},
                             audio, headers={"Authorization": "Bearer " + self.key}, timeout=120)
        return secs, json.loads(payload.decode("utf-8")).get("text", "")

    def rss(self):
        return None

    def close(self):
        pass


# ---------------------------------------------------------------- main

def percentile(values, p):
    if not values:
        return float("nan")
    values = sorted(values)
    k = (len(values) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def run_engine(label, engine, samples, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    # Warm-up request: the first inference allocates buffers / compiles GPU kernels.
    try:
        engine.transcribe(samples[0]["audio"])
    except Exception as e:  # noqa: BLE001 - report and keep going with the measured runs
        print("  warm-up failed: %s" % e)

    lat, audio_total, lat_with_audio = [], 0.0, 0.0
    w_err = w_ref = c_err = c_ref = 0
    failures = 0
    # WER/CER ignore case and punctuation, but text typed into apps needs both. Some
    # fine-tunes (trained on lowercase, unpunctuated corpora) drop them: count it.
    nonempty = punct = upper = 0
    for s in samples:
        try:
            secs, text = engine.transcribe(s["audio"])
        except Exception as e:  # noqa: BLE001
            failures += 1
            print("  %s: FAILED %s" % (s["name"], e))
            continue
        text = text.strip()
        lat.append(secs)
        if text:
            nonempty += 1
            punct += has_punct(text)
            upper += has_upper(text)
        if s["secs"]:
            audio_total += s["secs"]
            lat_with_audio += secs
        with open(os.path.join(out_dir, s["name"] + ".txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
        line = "  %-28s %6.2fs" % (s["name"], secs)
        if s["ref"] is not None:
            ref_n, hyp_n = normalize(s["ref"]), normalize(text)
            we = edit_distance(ref_n.split(), hyp_n.split())
            ce = edit_distance(ref_n.replace(" ", ""), hyp_n.replace(" ", ""))
            w_err += we
            w_ref += max(1, len(ref_n.split()))
            c_err += ce
            c_ref += max(1, len(ref_n.replace(" ", "")))
            line += "  %2d word errors" % we
        print(line + "  | " + text[:90], flush=True)

    return {
        "engine": label,
        "n": len(lat),
        "failed": failures,
        "load_s": engine.load_secs,
        "mean_s": statistics.mean(lat) if lat else float("nan"),
        "p50_s": percentile(lat, 0.5),
        "p90_s": percentile(lat, 0.9),
        "max_s": max(lat) if lat else float("nan"),
        "rtf": (lat_with_audio / audio_total) if audio_total else float("nan"),
        "wer": (100.0 * w_err / w_ref) if w_ref else float("nan"),
        "cer": (100.0 * c_err / c_ref) if c_ref else float("nan"),
        "rss_mb": engine.rss(),
        "punct": (100.0 * punct / nonempty) if nonempty else float("nan"),
        "upper": (100.0 * upper / nonempty) if nonempty else float("nan"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("engines", nargs="+",
                    help="ggml model path or name (large-v3-turbo-q5_0, ggml-medium.bin, ...), "
                         "or groq:<model> (groq:whisper-large-v3)")
    ap.add_argument("--samples", default=DEFAULT_SAMPLES, help="folder of audio + .txt references")
    ap.add_argument("--models-dir", default=DEFAULT_MODELS_DIR)
    ap.add_argument("--server", default=DEFAULT_SERVER, help="whisper-server binary (tools/build-bench.sh)")
    ap.add_argument("--download", action="store_true", help="fetch missing official ggml models")
    ap.add_argument("--threads", type=int, default=0, help="CPU threads for whisper-server (default: its own)")
    ap.add_argument("--vad-model", default="", help="Silero VAD ggml model: skip silence before decoding")
    ap.add_argument("--limit", type=int, default=0, help="only the first N samples")
    ap.add_argument("--out", default=os.path.join(REPO, "build-bench/results"))
    args = ap.parse_args()

    if not os.path.isdir(args.samples):
        sys.exit("No samples folder %s (see --help for how to collect one)" % args.samples)
    samples = load_samples(args.samples, args.limit)
    if not samples:
        sys.exit("No audio files in %s" % args.samples)
    with_ref = sum(1 for s in samples if s["ref"] is not None)
    audio = sum(s["secs"] or 0 for s in samples)
    print("%d samples (%.0f s of audio), %d with a reference transcript\n" % (len(samples), audio, with_ref))

    results = []
    for spec in args.engines:
        label = spec if spec.startswith("groq:") else os.path.basename(spec)
        safe = re.sub(r"[^A-Za-z0-9._-]+", "_", label)
        out_dir = os.path.join(args.out, safe)
        print("== %s" % label, flush=True)
        engine = None
        try:
            if spec.startswith("groq:"):
                engine = Groq(spec.split(":", 1)[1])
            else:
                if not os.access(args.server, os.X_OK):
                    sys.exit("whisper-server not found at %s; run tools/build-bench.sh" % args.server)
                model = resolve_model(spec, args.models_dir, args.download)
                os.makedirs(args.out, exist_ok=True)
                engine = WhisperServer(args.server, model, args.threads, args.vad_model,
                                       os.path.join(args.out, safe + ".server.log"))
                print("  loaded in %.1fs" % engine.load_secs)
            results.append(run_engine(label, engine, samples, out_dir))
        except RuntimeError as e:
            print("  skipped: %s" % e)
        finally:
            if engine:
                engine.close()
        print()

    if not results:
        sys.exit(1)

    def fmt(v, spec):
        return "-" if v is None or v != v else spec % v

    header = ("| engine | n | load s | mean s | p50 s | p90 s | max s | RTF | WER % | CER % "
              "| punct % | caps % | RAM MB |")
    rows = [header, "|" + "---|" * 13]
    for r in results:
        rows.append("| %s | %d%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["engine"], r["n"], (" (+%d failed)" % r["failed"]) if r["failed"] else "",
            fmt(r["load_s"], "%.1f"), fmt(r["mean_s"], "%.2f"), fmt(r["p50_s"], "%.2f"),
            fmt(r["p90_s"], "%.2f"), fmt(r["max_s"], "%.2f"), fmt(r["rtf"], "%.3f"),
            fmt(r["wer"], "%.1f"), fmt(r["cer"], "%.1f"), fmt(r["punct"], "%.0f"),
            fmt(r["upper"], "%.0f"), fmt(r["rss_mb"], "%.0f")))
    table = "\n".join(rows)
    print(table)
    print("\nRTF = processing time / audio time (lower is faster). WER/CER ignore case and punctuation;")
    print("punct % / caps % = share of outputs with any punctuation / capital letter (dictation needs both).")
    print("Hypotheses are in %s/<engine>/" % args.out)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(table + "\n")


if __name__ == "__main__":
    main()
