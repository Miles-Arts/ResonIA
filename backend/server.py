"""
Servidor Orquestador de Cabina ResonIA (FastAPI).

Integra los componentes de IA local:
- Transcripción de audio (faster-whisper)
- Moderación y síntesis de locución (Ollama / LLaMA 3.2:3b)
- Síntesis de voz neural (Piper TTS)
- Streaming en vivo por WebRTC (LiveKit)
"""

import os
import re
import sys
import shutil
import tempfile
import logging
import subprocess
import asyncio
from typing import Optional

import httpx
from fastapi import FastAPI, File, UploadFile, HTTPException, Query, status
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware

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
from locutor_bot import generar_token_acceso, emitir_audio_en_sala, LIVEKIT_URL, ROOM_NAME

# Configuración de logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("resonia-backend")

# Inicialización de la aplicación FastAPI
app = FastAPI(
    title="ResonIA Cabina Backend",
    description="API de procesamiento y orquestación de audio para cabina radial inteligente",
    version="1.0.0"
)

# Configuración de CORS segura para desarrollo y clientes autorizados
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PIPER_MODEL = os.path.join(BASE_DIR, "es_ES-davefx-medium.onnx")
AUDIO_OUTPUT = os.path.join(BASE_DIR, "respuesta.wav")
OLLAMA_API_URL = os.getenv("OLLAMA_API_URL", "http://localhost:11434/api/generate")

# Restricciones de seguridad para subida de audio
MAX_AUDIO_SIZE_BYTES = 15 * 1024 * 1024  # 15 MB máximo (suficiente para notas de voz de hasta 5 minutos)
ALLOWED_AUDIO_EXTENSIONS = {".m4a", ".wav", ".aac", ".mp3", ".ogg", ".flac"}

logger.info("⏳ Inicializando modelo faster-whisper (base, CPU, int8)...")
whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
logger.info("✅ faster-whisper cargado correctamente en memoria.")


def normalizar_locucion(texto: str) -> str:
    """
    Normaliza el texto generado por la IA para asegurar que comience
    exactamente una vez con la fórmula de cabina y sin frases duplicadas.

    Args:
        texto: Texto sin procesar devuelto por Ollama.

    Returns:
        Frase limpia lista para ser vocalizada.
    """
    frase_intro = "Un oyente nos envía un mensaje que dice:"
    t = texto.strip().strip('"\'')

    # Detectar y remover duplicados anidados de la introducción
    while True:
        pos1 = t.find(frase_intro)
        if pos1 != -1:
            resto = t[pos1 + len(frase_intro):].strip().strip('":\'')
            pos2 = resto.find(frase_intro)
            if pos2 != -1:
                t = frase_intro + " " + resto[pos2 + len(frase_intro):].strip().strip('":\'')
                continue
        break

    if not t.startswith(frase_intro):
        t = f"{frase_intro} {t}"

    cuerpo = t[len(frase_intro):].strip().strip('"\'')
    return f"{frase_intro} {cuerpo}"


async def resumir_con_ollama(texto_oyente: str) -> str:
    """
    Consulta al modelo local en Ollama para moderar y redactar la locución radial.

    Args:
        texto_oyente: Transcripción del mensaje recibido.

    Returns:
        'RECHAZADO' si no pasa moderación, o la frase de locución terminada.
    """
    prompt = f"""Eres el locutor y productor principal de cabina de una emisora de radio en vivo.
Tu tarea es presentar al aire los mensajes de voz de los oyentes.

Mensaje del oyente: "{texto_oyente}"

Instrucciones:
1. MODERACIÓN: Si el mensaje contiene insultos explícitos, groserías o agresiones directas, responde únicamente: RECHAZADO.
2. LOCUCIÓN RADIAL: Si el mensaje es apto, redáctalo para el aire. Inicia tu respuesta una sola vez con: "Un oyente nos envía un mensaje que dice:" y continúa con el mensaje o resumen de forma fluida y cálida (frase completa de 15 a 25 palabras).
3. IMPORTANTE: No repitas la introducción, no anides comillas, y concluye la idea de forma clara.

Responde únicamente con la frase de radio o con RECHAZADO:"""

    async with httpx.AsyncClient(timeout=25.0) as client:
        res = await client.post(
            OLLAMA_API_URL,
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
        raw_text = res.json().get("response", "").strip()

        if "RECHAZADO" in raw_text:
            return "RECHAZADO"

        return normalizar_locucion(raw_text)


def obtener_ruta_piper() -> str:
    """Encuentra la ruta al ejecutable de Piper TTS dentro del entorno virtual o PATH."""
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
    """
    Ejecuta el binario Piper TTS para sintetizar voz a partir de texto.

    Args:
        texto: Cadena de texto a sintetizar.
        output_path: Ruta destino del archivo WAV.

    Returns:
        True si el archivo se generó exitosamente, False en caso contrario.
    """
    try:
        piper_bin = obtener_ruta_piper()
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
        logger.error("Error ejecutando Piper TTS: %s", e)
        return False


@app.get("/token")
async def obtener_token(
    identity: str = Query("oyente", max_length=64, description="Identificador del oyente"),
    name: str = Query("Oyente", max_length=64, description="Nombre legible del participante")
):
    """
    Genera un token JWT seguro para que los clientes se conecten a la sala WebRTC.
    Sanitiza los parámetros para prevenir inyecciones.
    """
    clean_identity = re.sub(r"[^\w\-\.]", "", identity)[:64] or "oyente"
    clean_name = re.sub(r"[^\w\s\-\.]", "", name)[:64] or "Oyente"

    token = generar_token_acceso(identity=clean_identity, name=clean_name, can_publish=False)
    return {
        "status": "success",
        "room": ROOM_NAME,
        "identity": clean_identity,
        "token": token,
        "server_url": LIVEKIT_URL
    }


@app.post("/procesar-audio")
async def procesar_audio(file: UploadFile = File(...)):
    """
    Endpoint principal de procesamiento de notas de voz:
    1. Valida extensión y tamaño del archivo.
    2. Transcribe con faster-whisper.
    3. Modera y resume con Ollama.
    4. Genera voz con Piper TTS.
    5. Transmite el audio automáticamente a la sala LiveKit en segundo plano.
    """
    # Validación segura del nombre de archivo y extensión
    filename = file.filename or "nota.m4a"
    extension = os.path.splitext(filename)[1].lower()
    if extension not in ALLOWED_AUDIO_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Formato no permitido ({extension}). Formatos válidos: {list(ALLOWED_AUDIO_EXTENSIONS)}"
        )

    temp_path = None
    try:
        logger.info("📥 [1/4] Recibiendo archivo de audio: %s", filename)

        # Control de tamaño máximo para prevenir saturación de memoria o disco
        contenido = await file.read(MAX_AUDIO_SIZE_BYTES + 1)
        if len(contenido) > MAX_AUDIO_SIZE_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"El archivo excede el tamaño máximo permitido ({MAX_AUDIO_SIZE_BYTES // (1024 * 1024)} MB)"
            )

        with tempfile.NamedTemporaryFile(delete=False, suffix=extension) as temp_file:
            temp_file.write(contenido)
            temp_path = temp_file.name

        # Transcripción con Whisper
        logger.info("🎙️ [2/4] Transcribiendo voz con faster-whisper...")
        segments, _ = whisper_model.transcribe(temp_path, language="es")
        texto_transcrito = " ".join([s.text for s in segments]).strip()
        logger.info("   Texto detectado: '%s'", texto_transcrito)

        if not texto_transcrito:
            return {
                "status": "error",
                "mensaje": "No se detectó contenido de voz en el audio enviado"
            }

        # Moderación y redacción radial con Ollama
        logger.info("🧠 [3/4] Moderando y resumiendo con Ollama...")
        resumen = await resumir_con_ollama(texto_transcrito)
        logger.info("   Resultado: '%s'", resumen)

        es_limpio = "RECHAZADO" not in resumen
        audio_generado = False

        if es_limpio:
            # Síntesis con Piper TTS
            logger.info("🔊 [4/4] Sintetizando locución con Piper TTS...")
            audio_generado = generar_audio_piper(resumen, AUDIO_OUTPUT)

            if audio_generado:
                logger.info("📡 [Auto-Broadcast] Transmitiendo audio a LiveKit en segundo plano...")
                asyncio.create_task(emitir_audio_en_sala(AUDIO_OUTPUT))

        return {
            "status": "success",
            "transcripcion_original": texto_transcrito,
            "resumen_locutor": resumen if es_limpio else None,
            "aprobado": es_limpio,
            "audio_generado": audio_generado,
            "archivo_audio": "respuesta.wav" if audio_generado else None
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Error procesando audio: %s", e)
        return {
            "status": "error",
            "mensaje": "Ocurrió un error interno durante el procesamiento del audio."
        }
    finally:
        if temp_path and os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


@app.get("/escuchar-respuesta")
async def escuchar_respuesta():
    """Descarga el último archivo WAV generado por Piper TTS."""
    if os.path.exists(AUDIO_OUTPUT):
        return FileResponse(AUDIO_OUTPUT, media_type="audio/wav")
    return {"status": "error", "mensaje": "Aún no se ha generado ningún audio"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)
