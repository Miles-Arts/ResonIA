# ResonIA 🎙️🤖

Aplicación móvil nativa en Swift (iOS / SwiftUI) y cabina de radio interactiva potenciada por Inteligencia Artificial local.

## Arquitectura
- **Frontend:** iOS (SwiftUI, AVFoundation, LiveKit Client SDK)
- **Audio en Vivo (WebRTC):** Servidor LiveKit
- **Backend Orquestador:** FastAPI (Python)
- **Pipeline de IA Local:**
  - STT: `faster-whisper`
  - Moderación y Resumen: `Ollama` (`llama3.2:3b`)
  - TTS: `Piper TTS`
