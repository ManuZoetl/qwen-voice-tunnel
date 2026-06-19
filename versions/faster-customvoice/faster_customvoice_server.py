#!/usr/bin/env python3
import io
import os
import time
from typing import Optional

import numpy as np
import soundfile as sf
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

from faster_qwen3_tts import FasterQwen3TTS

MODEL_ID = os.environ.get("JARVIS_TTS_MODEL", "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
SERVED_MODEL_NAME = os.environ.get("JARVIS_TTS_SERVED_MODEL_NAME", "qwen3-tts-faster-customvoice")
DEFAULT_SPEAKER = os.environ.get("JARVIS_TTS_DEFAULT_SPEAKER", "aiden")
DEFAULT_LANGUAGE = os.environ.get("JARVIS_TTS_DEFAULT_LANGUAGE", "German")
API_KEY = os.environ.get("VLLM_API_KEY", "")

app = FastAPI(title="Jarvis Faster Qwen3 CustomVoice")
model: Optional[FasterQwen3TTS] = None
loaded_at = int(time.time())


class SpeechRequest(BaseModel):
    model: Optional[str] = None
    input: str
    voice: Optional[str] = None
    language: Optional[str] = None
    response_format: Optional[str] = "wav"
    instructions: Optional[str] = None
    instruct: Optional[str] = None
    stream: Optional[bool] = False
    chunk_size: Optional[int] = 8


def require_auth(authorization: Optional[str]) -> None:
    if not API_KEY:
        return
    expected = f"Bearer {API_KEY}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")


def normalize_audio(audio) -> np.ndarray:
    if isinstance(audio, list):
        if len(audio) == 1:
            audio = audio[0]
        else:
            audio = np.concatenate([np.asarray(x) for x in audio])
    return np.asarray(audio)


def wav_bytes(audio, sr: int) -> bytes:
    audio = normalize_audio(audio)
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV")
    return buf.getvalue()


@app.on_event("startup")
def load_model() -> None:
    global model
    print(f"Loading FasterQwen3TTS model: {MODEL_ID}", flush=True)
    model = FasterQwen3TTS.from_pretrained(MODEL_ID)
    print("FasterQwen3TTS ready", flush=True)


@app.get("/health")
def health():
    return {"status": "ok", "model": SERVED_MODEL_NAME}


@app.get("/v1/models")
def models(authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    return {
        "object": "list",
        "data": [
            {
                "id": SERVED_MODEL_NAME,
                "object": "model",
                "created": loaded_at,
                "owned_by": "jarvis",
                "root": MODEL_ID,
                "parent": None,
            }
        ],
    }


@app.get("/v1/audio/voices")
def voices(authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    # Qwen3 CustomVoice uses predefined speaker IDs. Keep this list explicit for Jarvis UI/tests.
    return {
        "voices": ["aiden", "dylan", "eric", "ryan", "serena", "sohee", "uncle_fu", "vivian", "ono_anna"],
        "default_voice": DEFAULT_SPEAKER,
        "mode": "faster-customvoice",
    }


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest, authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    if model is None:
        raise HTTPException(status_code=503, detail="Model is not loaded yet")
    if not req.input.strip():
        raise HTTPException(status_code=400, detail="input is required")

    speaker = req.voice or DEFAULT_SPEAKER
    language = req.language or DEFAULT_LANGUAGE
    instruct = req.instructions or req.instruct
    response_format = (req.response_format or "wav").lower()
    if response_format != "wav":
        raise HTTPException(status_code=400, detail="Only response_format=wav is supported in this Jarvis wrapper")

    kwargs = {
        "text": req.input,
        "language": language,
        "speaker": speaker,
    }
    if instruct:
        kwargs["instruct"] = instruct

    if req.stream:
        def gen():
            for audio_chunk, sr, _timing in model.generate_custom_voice_streaming(
                **kwargs,
                chunk_size=req.chunk_size or 8,
            ):
                yield wav_bytes(audio_chunk, sr)

        return StreamingResponse(gen(), media_type="audio/wav")

    audio, sr = model.generate_custom_voice(**kwargs)
    return Response(content=wav_bytes(audio, sr), media_type="audio/wav")
