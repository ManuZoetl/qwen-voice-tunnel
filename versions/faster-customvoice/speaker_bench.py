#!/usr/bin/env python3
import json
import os
import statistics
import time
import urllib.request

API = os.environ.get("SPEAKER_API", "http://127.0.0.1:8000/v1/chat/completions")
KEY = os.environ.get("VLLM_API_KEY", "")
MODEL = os.environ.get("SPEAKER_SERVED_MODEL_NAME", "jarvis-speaker")

if not KEY:
    raise SystemExit("VLLM_API_KEY is missing")

SYSTEM_SHORT = (
    "Du bist Jarvis. Antworte mit genau einem kurzen deutschen Satz, "
    "maximal 8 Wörter. Nur gesprochener Text. Keine Nachfrage. "
    "Wiederhole nicht die Anfrage. Keine Analyse. Kein Thinking."
)

SYSTEM_REAL = (
    "Du bist die Voice-Schicht von Jarvis. Sprich kurz, warm, direkt "
    "und natürlich auf Deutsch. Nutze Kontext nur zur passenden Formulierung. "
    "Gib ausschließlich gesprochenen Text zurück. Keine Analyse. Kein Thinking. "
    "Keine Listen."
)

BASE_MEMORY = (
    "Manuel baut Jarvis als Voice-Agent. Architektur: schneller Speaker spricht "
    "mit dem User, Thinker führt im Hintergrund Aufgaben aus, Memory wird als "
    "Kontext geliefert. Tools sind GitHub, RunPod, VPS, TTS, ASR und später "
    "MCP/Galaxy. Der User bevorzugt kurze direkte deutsche Antworten ohne "
    "Meta-Erklärung im Voice-Kanal. Aktueller Task: Backend-Test hängt. "
    "Thinker prüft Logs, GitHub Branch, Docker Image, RunPod Pod und vLLM. "
)

CASES = [
    {
        "name": "short_ack",
        "system": SYSTEM_SHORT,
        "user": (
            "Memory: Manuel arbeitet am Jarvis Voice Stack. "
            "Status: Backend-Test hängt. Sag kurz, dass du Logs prüfst."
        ),
        "max_tokens": 12,
    },
    {
        "name": "real_state",
        "system": SYSTEM_REAL,
        "user": (
            "USER_MEMORY: Manuel baut Jarvis als Voice-Agent mit TTS, Speaker-LLM "
            "und Thinker. Er arbeitet technisch schnell und will klare Diagnose. "
            "CURRENT_STATE: Backend-Test hängt, Extension bleibt im Loading-State. "
            "THINKER_STATUS: Prüft GitHub Action, Logs und Container-Status. "
            "TOOL_STATE: GitHub verfügbar, RunPod Pod läuft, TTS aktiv. "
            "USER_SAID: mein backend test hängt schon wieder. "
            "SPEAKER_TASK: Sage beruhigend, dass du die Logs prüfst."
        ),
        "max_tokens": 24,
    },
]

for repeat in [1, 5, 10, 20, 40]:
    CASES.append(
        {
            "name": f"memory_x{repeat}",
            "system": SYSTEM_SHORT,
            "user": (
                "MEMORY:\n" + BASE_MEMORY * repeat +
                "\nSTATUS: Backend-Test hängt. TASK: Sage kurz, dass du Logs prüfst."
            ),
            "max_tokens": 18,
        }
    )


def call(case):
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": case["system"]},
            {"role": "user", "content": case["user"]},
        ],
        "max_tokens": case.get("max_tokens", 18),
        "temperature": 0.1,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        API,
        data=data,
        headers={
            "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json",
        },
    )
    started = time.time()
    with urllib.request.urlopen(req, timeout=120) as response:
        body = json.loads(response.read().decode("utf-8"))
    elapsed = time.time() - started
    text = body["choices"][0]["message"]["content"].replace("\n", " ")
    usage = body.get("usage", {})
    return elapsed, text, usage


for case in CASES:
    times = []
    print(f"\n=== {case['name']} ===", flush=True)
    for i in range(3):
        elapsed, text, usage = call(case)
        times.append(elapsed)
        prompt_tokens = usage.get("prompt_tokens")
        completion_tokens = usage.get("completion_tokens")
        print(
            f"run={i+1} time={elapsed:.3f}s "
            f"prompt={prompt_tokens} completion={completion_tokens} | {text}",
            flush=True,
        )
    print(
        f"avg={statistics.mean(times):.3f}s "
        f"min={min(times):.3f}s max={max(times):.3f}s",
        flush=True,
    )
