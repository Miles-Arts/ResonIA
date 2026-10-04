import os
import wave
import asyncio
from livekit import rtc
from livekit.api import AccessToken, VideoGrants

# Configuración del servidor local de LiveKit (modo dev por defecto)
LIVEKIT_URL = "ws://127.0.0.1:7880"
LIVEKIT_API_KEY = "devkey"
LIVEKIT_API_SECRET = "secret"
ROOM_NAME = "cabina-resonia"
AUDIO_PATH = "respuesta.wav"

def generar_token_bot() -> str:
    """Genera el JWT de autenticación para que el bot ingrese como Productor IA."""
    token = (
        AccessToken(api_key=LIVEKIT_API_KEY, api_secret=LIVEKIT_API_SECRET)
        .with_identity("productor-ia")
        .with_name("Productor IA (Cabina)")
        .with_grants(
            VideoGrants(
                room_join=True,
                room=ROOM_NAME,
                can_publish=True,
                can_subscribe=True
            )
        )
        .to_jwt()
    )
    return token

async def emitir_audio_en_sala():
    if not os.path.exists(AUDIO_PATH):
        print(f"❌ Error: No se encontró el archivo '{AUDIO_PATH}'. Genera uno primero.")
        return

    print("🔑 Generando token de acceso para LiveKit...")
    token = generar_token_bot()

    room = rtc.Room()

    try:
        print(f"📡 Conectando a la sala '{ROOM_NAME}' en {LIVEKIT_URL}...")
        await room.connect(LIVEKIT_URL, token)
        print("✅ Bot conectado exitosamente a la sala.")

        # Leer parámetros del archivo .wav
        with wave.open(AUDIO_PATH, "rb") as wf:
            sample_rate = wf.getframerate()
            num_channels = wf.getnchannels()
            sample_width = wf.getsampwidth()

            print(f"ℹ️ Audio: {sample_rate}Hz, {num_channels} canal(es), {sample_width * 8} bits")

            # Crear la fuente y la pista de audio WebRTC
            source = rtc.AudioSource(sample_rate, num_channels)
            track = rtc.LocalAudioTrack.create_audio_track("audio-productor", source)
            
            options = rtc.TrackPublishOptions()
            publication = await room.local_participant.publish_track(track, options)
            print(f"🎙️ Pista de audio publicada: {publication.sid}")

            # Enviar el audio en bloques de 20 ms
            chunk_samples = int(sample_rate * 0.02)
            chunk_bytes = chunk_samples * num_channels * sample_width

            print("▶️ Emitiendo locución al aire...")
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

   # ... (código anterior del bucle while donde se emite el audio)

            print("⏹️ Emisión finalizada.")
            await asyncio.sleep(0.2)
            
            # Despublicar la pista antes de desconectar
            await room.local_participant.unpublish_track(publication.sid)
            await asyncio.sleep(0.2)

    except Exception as e:
        print(f"❌ Error durante la emisión en LiveKit: {e}")
    finally:
        print("🔌 Desconectando bot de la sala...")
        await room.disconnect()
        await asyncio.sleep(0.2)
        print("👋 Bot desconectado.")

if __name__ == "__main__":
    asyncio.run(emitir_audio_en_sala())