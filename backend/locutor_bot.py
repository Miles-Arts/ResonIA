"""
Módulo Emisor de Audio WebRTC para Cabina ResonIA.

Se encarga de la generación de tokens JWT para LiveKit y de la transmisión
de archivos de audio WAV en bloques de 20 ms hacia la sala WebRTC en tiempo real.
"""

import os
import wave
import asyncio
from livekit import rtc
from livekit.api import AccessToken, VideoGrants

# Configuración por variables de entorno con valores por defecto para desarrollo
LIVEKIT_URL = os.getenv("LIVEKIT_URL", "ws://127.0.0.1:7880")
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "secret")
ROOM_NAME = os.getenv("LIVEKIT_ROOM_NAME", "cabina-resonia")
DEFAULT_AUDIO_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "respuesta.wav")


def generar_token_acceso(
    identity: str,
    name: str,
    can_publish: bool = False,
    room: str = ROOM_NAME
) -> str:
    """
    Genera un token JWT firmado para acceder a la sala de LiveKit.

    Args:
        identity: Identificador único del participante (ej. 'oyente-123', 'productor-ia').
        name: Nombre visible en la sala.
        can_publish: Si el participante tiene permisos para publicar audio/video.
        room: Nombre de la sala a la que se otorgará acceso.

    Returns:
        Token JWT codificado como string.
    """
    token = (
        AccessToken(api_key=LIVEKIT_API_KEY, api_secret=LIVEKIT_API_SECRET)
        .with_identity(identity)
        .with_name(name)
        .with_grants(
            VideoGrants(
                room_join=True,
                room=room,
                can_publish=can_publish,
                can_subscribe=True
            )
        )
        .to_jwt()
    )
    return token


async def emitir_audio_en_sala(
    audio_path: str = DEFAULT_AUDIO_PATH,
    room_name: str = ROOM_NAME,
    livekit_url: str = LIVEKIT_URL
) -> bool:
    """
    Conecta el bot Productor IA a LiveKit e inyecta el audio a la sala.
    Incluye silencio de cola y espera de drenado para evitar cortes finales.

    Args:
        audio_path: Ruta al archivo WAV a emitir.
        room_name: Nombre de la sala LiveKit.
        livekit_url: URL WebSockets del servidor LiveKit.

    Returns:
        True si la emisión se completó correctamente, False si hubo error.
    """
    if not os.path.exists(audio_path):
        print(f"❌ Error: No se encontró el archivo de audio '{audio_path}'.")
        return False

    token = generar_token_acceso(
        identity="productor-ia",
        name="Productor IA (Cabina)",
        can_publish=True,
        room=room_name
    )
    room = rtc.Room()

    try:
        print(f"📡 Conectando Productor IA a '{room_name}' en {livekit_url}...")
        await room.connect(livekit_url, token)
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

            # Enviar audio en bloques estándar de 20 ms
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

            # Inyección de 300 ms de silencio final (15 bloques x 20 ms)
            silencio = b"\x00" * (chunk_samples * num_channels * sample_width)
            silence_frame = rtc.AudioFrame(
                data=silencio,
                sample_rate=sample_rate,
                num_channels=num_channels,
                samples_per_channel=chunk_samples
            )
            for _ in range(15):
                await source.capture_frame(silence_frame)
                await asyncio.sleep(0.02)

            # Margen de seguridad para drenado de jitter buffers en clientes receptores
            print("⏹️ Emisión finalizada. Drenando buffers...")
            await asyncio.sleep(1.8)

            await room.local_participant.unpublish_track(publication.sid)
            await asyncio.sleep(0.3)
            return True

    except Exception as e:
        print(f"❌ Error durante la emisión en LiveKit: {e}")
        return False
    finally:
        print("🔌 Desconectando Productor IA...")
        await room.disconnect()
        print("👋 Productor IA desconectado.")


if __name__ == "__main__":
    asyncio.run(emitir_audio_en_sala())
