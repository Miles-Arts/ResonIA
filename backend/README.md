# ResonIA Backend - Cabina Inteligente de Radio

Backend de audio interactivo impulsado por FastAPI, faster-whisper, Ollama (LLaMA 3.2), Piper TTS y LiveKit WebRTC.

## Requisitos Previos

1. **Python 3.10+** (recomendado Python 3.11 o 3.12).
2. **Ollama**: Corriendo localmente con el modelo `llama3.2:3b`.
   ```bash
   ollama run llama3.2:3b
   ```
3. **LiveKit Server**: Corriendo en modo desarrollo (puerto 7880).
   ```bash
   livekit-server --dev
   # o vía Docker / OrbStack
   ```

## Instalación

1. Crear y activar el entorno virtual:
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

2. Instalar dependencias:
   ```bash
   pip install -r requirements.txt
   ```

3. Descargar el modelo de voz en español para Piper:
   ```bash
   curl -L -o es_ES-davefx-medium.onnx "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx"
   curl -L -o es_ES-davefx-medium.onnx.json "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json"
   ```

## Ejecución

Iniciar el servidor FastAPI:
```bash
uvicorn server:app --host 0.0.0.0 --port 8000 --reload
```

## Endpoints Principales

- `GET /token?identity=oyente`: Devuelve el token JWT para que los oyentes se conecten a la sala WebRTC `cabina-resonia`.
- `POST /procesar-audio`: Recibe notas de voz (`.m4a` / `.wav`), transcribe con Whisper, modera y resume con Ollama, genera voz con Piper y emite automáticamente a la sala LiveKit en tiempo real.
