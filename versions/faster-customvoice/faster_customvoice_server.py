#!/usr/bin/env python3
import io
import os
import time
from typing import Callable, Iterator, Optional, Tuple

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
    # Streaming output format. Keep wav_chunks as backward-compatible debug mode.
    # For Jarvis live playback, use stream=true and stream_format=pcm_s16le.
    stream_format: Optional[str] = "wav_chunks"
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
    audio = np.asarray(audio)
    if audio.ndim > 1:
        audio = np.squeeze(audio)
    return audio.astype(np.float32, copy=False)


def wav_bytes(audio, sr: int) -> bytes:
    audio = normalize_audio(audio)
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV")
    return buf.getvalue()


def pcm_s16le_bytes(audio, sr: int) -> bytes:
    del sr
    audio = normalize_audio(audio)
    audio = np.nan_to_num(audio, nan=0.0, posinf=1.0, neginf=-1.0)
    audio = np.clip(audio, -1.0, 1.0)
    return (audio * 32767.0).astype("<i2", copy=False).tobytes()


def pcm_f32le_bytes(audio, sr: int) -> bytes:
    del sr
    audio = normalize_audio(audio)
    audio = np.nan_to_num(audio, nan=0.0, posinf=1.0, neginf=-1.0)
    return audio.astype("<f4", copy=False).tobytes()


def normalize_stream_format(value: Optional[str]) -> str:
    fmt = (value or "wav_chunks").strip().lower().replace("-", "_")
    aliases = {
        "wav": "wav_chunks",
        "wav_chunk": "wav_chunks",
        "wav_chunks": "wav_chunks",
        "pcm": "pcm_s16le",
        "s16le": "pcm_s16le",
        "pcm_s16": "pcm_s16le",
        "pcm_s16le": "pcm_s16le",
        "raw_pcm_s16le": "pcm_s16le",
        "f32le": "pcm_f32le",
        "float32": "pcm_f32le",
        "pcm_f32le": "pcm_f32le",
        "raw_pcm_f32le": "pcm_f32le",
    }
    if fmt not in aliases:
        raise HTTPException(
            status_code=400,
            detail="Unsupported stream_format. Use wav_chunks, pcm_s16le, or pcm_f32le.",
        )
    return aliases[fmt]


def stream_encoder(fmt: str) -> Tuple[Callable[[object, int], bytes], str, str]:
    if fmt == "wav_chunks":
        return wav_bytes, "audio/wav", "wav_chunks"
    if fmt == "pcm_s16le":
        return pcm_s16le_bytes, "application/octet-stream", "pcm_s16le"
    if fmt == "pcm_f32le":
        return pcm_f32le_bytes, "application/octet-stream", "pcm_f32le"
    raise HTTPException(status_code=400, detail="Unsupported stream_format")


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
        "stream_formats": ["wav_chunks", "pcm_s16le", "pcm_f32le"],
        "recommended_stream_format": "pcm_s16le",
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
        fmt = normalize_stream_format(req.stream_format)
        encode, media_type, audio_format = stream_encoder(fmt)
        chunk_iter: Iterator = model.generate_custom_voice_streaming(
            **kwargs,
            chunk_size=req.chunk_size or 8,
        )
        try:
            first_audio, first_sr, _first_timing = next(chunk_iter)
        except StopIteration:
            return Response(content=b"", media_type=media_type)

        def gen():
            yield encode(first_audio, first_sr)
            for audio_chunk, sr, _timing in chunk_iter:
                yield encode(audio_chunk, sr)

        headers = {
            "X-Audio-Format": audio_format,
            "X-Sample-Rate": str(first_sr),
            "X-Audio-Channels": "1",
        }
        if fmt == "pcm_s16le":
            headers["X-Sample-Width"] = "2"
        elif fmt == "pcm_f32le":
            headers["X-Sample-Width"] = "4"
        return StreamingResponse(gen(), media_type=media_type, headers=headers)

    audio, sr = model.generate_custom_voice(**kwargs)
    return Response(content=wav_bytes(audio, sr), media_type="audio/wav")
