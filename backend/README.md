# ResonIA Backend - Cabina Inteligente de Radio

Servicio de orquestación de audio e inteligencia artificial desarrollado con **FastAPI**, **faster-whisper**, **Ollama**, **Piper TTS** y **LiveKit WebRTC**.

---

## 📋 Requisitos Previos

- **Python 3.10+** (recomendado 3.11 o 3.12).
- **Ollama**: En ejecución local con el modelo `llama3.2:3b`.
  ```bash
  ollama run llama3.2:3b
  ```
- **LiveKit Server**: En ejecución (por defecto `ws://127.0.0.1:7880`).
  ```bash
  livekit-server --dev
  ```

---

## 🛠️ Instalación y Preparación

1. **Crear y activar el entorno virtual:**
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

2. **Instalar dependencias de Python:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Descargar los modelos de síntesis de voz (Piper TTS):**
   ```bash
   curl -L -o es_ES-davefx-medium.onnx "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx"
   curl -L -o es_ES-davefx-medium.onnx.json "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json"
   ```

4. **Variables de Entorno:**
   Copia el archivo de ejemplo para configurar tus credenciales de forma segura:
   ```bash
   cp .env.example .env
   ```
   *Nota: Nunca confirmes ni subas el archivo `.env` al repositorio de Git.*

---

## 🚀 Ejecución del Servidor

Inicia el servidor FastAPI con recarga en caliente:
```bash
uvicorn server:app --host 0.0.0.0 --port 8000 --reload
```

Documentación interactiva disponible en:
- Swagger UI: `http://localhost:8000/docs`
- ReDoc: `http://localhost:8000/redoc`

---

## 📡 Endpoints de la API

| Método | Endpoint | Descripción | Parámetros |
| :---: | :--- | :--- | :--- |
| `GET` | `/token` | Emite un JWT para que los clientes se autentiquen en LiveKit. | `identity` (opcional), `name` (opcional) |
| `POST` | `/procesar-audio` | Recibe audio (`.m4a`, `.wav`), transcribe, modera y emite la respuesta. | `file` (Multipart UploadFile, máx 15MB) |
| `GET` | `/escuchar-respuesta` | Descarga directa del último archivo de audio WAV sintetizado. | Ninguno |

---

## 🔒 Consideraciones de Seguridad

- **Límites de Carga:** El servidor rechaza archivos que superen los 15 MB para evitar consumo desmedido de memoria.
- **Tipos MIME Permitidos:** Solo se procesan formatos de audio válidos (`.m4a`, `.wav`, `.aac`, `.mp3`, `.ogg`, `.flac`).
- **Sanitización de Datos:** Los nombres e identidades recibidos son depurados con expresiones regulares antes de emitir tokens.
- **Tratamiento de Excepciones:** No se exponen trazas internas de error ni rutas del sistema al cliente.
