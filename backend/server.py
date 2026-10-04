import os
import tempfile
import subprocess
import traceback
import sys
import shutil
import asyncio
import wave
import httpx
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import FileResponse
from livekit import rtc
from livekit.api import AccessToken, VideoGrants

# --- PARCHE DE COMPATIBILIDAD PyAV 19 + FASTER-WHISPER ---
import av
import av.container

_orig_av_open = av.open

def _patched_av_open(*args, **kwargs):
    kwargs.pop("metadata_errors", None)
    return _orig_av_open(*args, **kwargs)

av.open = _patched_av_open
if hasattr(av.container, "open"):
    av.container.open = _patched_av_open
# ---------------------------------------------------------

from faster_whisper import WhisperModel

app = FastAPI(title="ResonIA Cabina Backend")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PIPER_MODEL = os.path.join(BASE_DIR, "es_ES-davefx-medium.onnx")
AUDIO_OUTPUT = os.path.join(BASE_DIR, "respuesta.wav")

# Configuración de LiveKit
LIVEKIT_URL = os.getenv("LIVEKIT_URL", "ws://127.0.0.1:7880")
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "secret")
ROOM_NAME = "cabina-resonia"

print("⏳ Cargando faster-whisper en memoria...")
whisper = WhisperModel("base", device="cpu", compute_type="int8")

def generar_token(identity: str, name: str, can_publish: bool = False) -> str:
    """Genera el JWT de autenticación para LiveKit."""
    token = (
        AccessToken(api_key=LIVEKIT_API_KEY, api_secret=LIVEKIT_API_SECRET)
        .with_identity(identity)
        .with_name(name)
        .with_grants(
            VideoGrants(
                room_join=True,
                room=ROOM_NAME,
                can_publish=can_publish,
                can_subscribe=True
            )
        )
        .to_jwt()
    )
    return token

async def resumir_con_ollama(texto_oyente: str) -> str:
    prompt = f"""Eres el locutor y productor principal de cabina de una emisora de radio en vivo.
Tu tarea es presentar al aire los mensajes de voz de los oyentes.

Mensaje del oyente: "{texto_oyente}"

Instrucciones:
1. MODERACIÓN: Si el mensaje contiene insultos explícitos, groserías o agresiones directas, responde únicamente: RECHAZADO.
2. LOCUCIÓN RADIAL: Si el mensaje es apto, redáctalo en una frase completa, cálida y natural (entre 15 y 25 palabras). Debe sonar como locutor profesional al aire, por ejemplo:
   - "Un oyente nos saluda con entusiasmo desde Bogotá y nos envía un abrazo a toda la audiencia."
   - "Nos comparten desde la sintonía que les encanta la programación musical de hoy."
3. IMPORTANTE: Concluye la oración de forma completa, sin dejar puntos suspensivos ni frases inconclusas.

Responde únicamente con la frase de radio terminada o con RECHAZADO:"""

    async with httpx.AsyncClient(timeout=25.0) as client:
        res = await client.post(
            "http://localhost:11434/api/generate",
            json={
                "model": "llama3.2:3b",
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.3
                }
            }
        )
        res.raise_for_status()
        texto_limpio = res.json().get("response", "").strip()
        # Asegurar que no quede entre comillas residuales
        return texto_limpio.strip('"\'')

def obtener_ruta_piper() -> str:
    """Encuentra la ruta exacta del binario de Piper dentro del entorno virtual."""
    bin_dir = os.path.dirname(sys.executable)
    ruta_en_venv = os.path.join(bin_dir, "piper")
    if os.path.exists(ruta_en_venv):
        return ruta_en_venv

    for carpeta in [".venv", "venv"]:
        ruta_alt = os.path.join(BASE_DIR, carpeta, "bin", "piper")
        if os.path.exists(ruta_alt):
            return ruta_alt

    ruta_path = shutil.which("piper")
    if ruta_path:
        return ruta_path

    return "piper"

def generar_audio_piper(texto: str, output_path: str) -> bool:
    try:
        piper_bin = obtener_ruta_piper()
        print(f"   Ejecutando Piper desde: {piper_bin}")

        cmd = [
            piper_bin,
            "--model", PIPER_MODEL,
            "--output_file", output_path
        ]
        proceso = subprocess.run(
            cmd,
            input=texto.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True
        )
        return proceso.returncode == 0
    except Exception as e:
        print(f"❌ Error ejecutando Piper: {e}")
        return False

async def emitir_audio_en_sala(audio_path: str):
    """Conecta el bot Productor IA a LiveKit e inyecta el audio garantizando que no se corte al final."""
    if not os.path.exists(audio_path):
        print(f"❌ Error: No se encontró el archivo '{audio_path}'.")
        return

    print("🔑 Generando token para Productor IA...")
    token = generar_token(identity="productor-ia", name="Productor IA (Cabina)", can_publish=True)
    room = rtc.Room()

    try:
        print(f"📡 Conectando Productor IA a '{ROOM_NAME}' en {LIVEKIT_URL}...")
        await room.connect(LIVEKIT_URL, token)
        print("✅ Productor IA conectado a la cabina.")

        with wave.open(audio_path, "rb") as wf:
            sample_rate = wf.getframerate()
            num_channels = wf.getnchannels()
            sample_width = wf.getsampwidth()

            source = rtc.AudioSource(sample_rate, num_channels)
            track = rtc.LocalAudioTrack.create_audio_track("audio-productor", source)

            options = rtc.TrackPublishOptions()
            publication = await room.local_participant.publish_track(track, options)
            print(f"🎙️ Pista de audio publicada en cabina: {publication.sid}")

            # Bloques de 20 ms
            chunk_samples = int(sample_rate * 0.02)
            print("▶️ Emitiendo locución al aire a través de WebRTC...")
            while True:
                data = wf.readframes(chunk_samples)
                if not data:
                    break

                samples_en_bloque = len(data) // (num_channels * sample_width)
                frame = rtc.AudioFrame(
                    data=data,
                    sample_rate=sample_rate,
                    num_channels=num_channels,
                    samples_per_channel=samples_en_bloque
                )
                await source.capture_frame(frame)
                await asyncio.sleep(0.02)

            # Inyectar 300 ms de silencio final para evitar que el códec corte la última palabra
            silencio = b"\x00" * (chunk_samples * num_channels * sample_width)
            silence_frame = rtc.AudioFrame(
                data=silencio,
                sample_rate=sample_rate,
                num_channels=num_channels,
                samples_per_channel=chunk_samples
            )
            for _ in range(15):  # 15 * 20ms = 300ms de cola limpia
                await source.capture_frame(silence_frame)
                await asyncio.sleep(0.02)

            print("⏹️ Emisión de frames completada. Esperando drenado de buffers WebRTC...")
            # IMPORTANTE: Esperar 1.8 segundos para que los buffers de jitter y altavoces en iOS terminen de reproducir todo
            await asyncio.sleep(1.8)

            await room.local_participant.unpublish_track(publication.sid)
            await asyncio.sleep(0.3)

    except Exception as e:
        print(f"❌ Error durante la emisión en LiveKit: {e}")
    finally:
        print("🔌 Desconectando Productor IA...")
        await room.disconnect()
        print("👋 Productor IA desconectado.")

@app.get("/token")
async def obtener_token(identity: str = "oyente", name: str = "Oyente"):
    """Devuelve un token JWT para que los clientes iOS se conecten automáticamente a LiveKit."""
    token = generar_token(identity=identity, name=name, can_publish=False)
    return {
        "status": "success",
        "room": ROOM_NAME,
        "identity": identity,
        "token": token,
        "server_url": LIVEKIT_URL
    }

@app.post("/procesar-audio")
async def procesar_audio(file: UploadFile = File(...)):
    temp_path = None
    try:
        print(f"\n📥 [1/4] Audio recibido: {file.filename}")

        suffix = os.path.splitext(file.filename)[1] if file.filename else ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
            contenido = await file.read()
            temp_file.write(contenido)
            temp_path = temp_file.name

        print("🎙️ [2/4] Transcribiendo con faster-whisper...")
        segments, _ = whisper.transcribe(temp_path, language="es")
        texto_transcrito = " ".join([s.text for s in segments]).strip()
        print(f"   Texto detectado: \"{texto_transcrito}\"")

        if not texto_transcrito:
            return {"status": "error", "mensaje": "No se detectó voz en el audio"}

        print("🧠 [3/4] Consultando a Ollama...")
        resumen = await resumir_con_ollama(texto_transcrito)
        print(f"   Respuesta Ollama: \"{resumen}\"")

        es_limpio = "RECHAZADO" not in resumen

        audio_generado = False
        if es_limpio:
            print("🔊 [4/4] Generando locución con Piper TTS...")
            audio_generado = generar_audio_piper(resumen, AUDIO_OUTPUT)
            print(f"   Audio generado exitosamente: {audio_generado}")

            if audio_generado:
                print("📡 [Auto-Broadcast] Lanzando locución a la sala LiveKit en segundo plano...")
                asyncio.create_task(emitir_audio_en_sala(AUDIO_OUTPUT))

        return {
            "status": "success",
            "transcripcion_original": texto_transcrito,
            "resumen_locutor": resumen if es_limpio else None,
            "aprobado": es_limpio,
            "audio_generado": audio_generado,
            "archivo_audio": "respuesta.wav" if audio_generado else None
        }

    except Exception as e:
        traceback.print_exc()
        return {
            "status": "error",
            "detalle_error": str(e)
        }
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

@app.get("/escuchar-respuesta")
async def escuchar_respuesta():
    if os.path.exists(AUDIO_OUTPUT):
        return FileResponse(AUDIO_OUTPUT, media_type="audio/wav")
    return {"status": "error", "mensaje": "Aún no se ha generado ningún audio"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)
