#!/usr/bin/env python3
"""
Faster-Whisper transcription script for audio chunks.
This script transcribes a single audio file using faster-whisper and outputs the transcript.
"""

import sys
import os

def transcribe_audio(audio_path, model_size='base', language='en'):
    """
    Transcribe audio file using faster-whisper.
    
    Args:
        audio_path: Path to the audio file
        model_size: Model size (tiny, base, small, medium, large-v2)
        language: Language code (en, es, fr, etc.)
    
    Returns:
        Transcript text as string
    """
    try:
        from faster_whisper import WhisperModel
        
        # Initialize model with optimizations for speed
        model = WhisperModel(
            model_size,
            device="cpu",  # Use CPU for compatibility, can be "cuda" if GPU available
            compute_type="int8",  # Faster processing
        )
        
        # Transcribe with VAD (Voice Activity Detection) enabled
        segments, info = model.transcribe(
            audio_path,
            language=language,
            beam_size=1,  # Speed optimization
            best_of=1,    # Speed optimization
            vad_filter=True,  # Enable VAD for better accuracy
            vad_parameters=dict(min_silence_duration_ms=500),
        )
        
        # Collect transcript segments
        transcript_parts = []
        for segment in segments:
            transcript_parts.append(segment.text.strip())
        
        return ' '.join(transcript_parts).strip()
        
    except ImportError:
        print("Error: faster_whisper not installed. Install with: pip install faster-whisper", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error transcribing audio: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 faster_whisper_transcribe.py <audio_file> [model_size] [language]", file=sys.stderr)
        print("  model_size: tiny, base, small, medium, large-v2 (default: base)", file=sys.stderr)
        print("  language: en, es, fr, etc. (default: en)", file=sys.stderr)
        sys.exit(1)
    
    audio_file = sys.argv[1]
    model_size = sys.argv[2] if len(sys.argv) > 2 else 'base'
    language = sys.argv[3] if len(sys.argv) > 3 else 'en'
    
    if not os.path.exists(audio_file):
        print(f"Error: Audio file not found: {audio_file}", file=sys.stderr)
        sys.exit(1)
    
    transcript = transcribe_audio(audio_file, model_size, language)
    print(transcript)
