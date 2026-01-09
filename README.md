# Meeting Notes - AI Generated Meeting Notes App

A Flutter desktop app for Linux that records audio from your microphone, transcribes it, and generates AI-powered summaries using Anthropic Claude.

## Features

- 🎤 Record audio from your microphone
- 📝 Audio transcription using Anthropic Claude API
- 🤖 AI-generated meeting summaries using Claude
- 💾 Automatically saves transcript and summary to text files

## Prerequisites

1. **Flutter SDK** (3.0.0 or higher)
   ```bash
   flutter --version
   ```

2. **Linux desktop support enabled**
   ```bash
   flutter config --enable-linux-desktop
   flutter doctor
   ```

3. **PulseAudio** (Required for audio recording on Linux)
   
   The app uses PulseAudio's `parecord` command for recording, which is typically pre-installed on most Linux distributions.
   
   Verify PulseAudio is installed:
   ```bash
   parecord --version
   pactl --version
   ```
   
   If not installed (rare), install it:
   ```bash
   sudo apt-get install pulseaudio-utils
   ```

4. **Local Transcription Tool** (Required for audio transcription)
   
   The app needs a local transcription tool since Claude API doesn't support direct audio transcription. Install one of the following:
   
   **Option 1: faster-whisper (Recommended - Fast streaming transcription)**
   ```bash
   pip install faster-whisper
   ```
   
   This is the preferred option for near-real-time transcription. The app records audio in 5-second chunks and transcribes them progressively, updating the UI every 10 seconds (2 chunks).
   
   **Option 2: OpenAI Whisper (Fallback)**
   ```bash
   pip install openai-whisper
   ```
   
   This will be used if faster-whisper is not available, but transcription happens only after recording stops.
   
   **Option 3: Python speech_recognition (Fallback)**
   ```bash
   pip3 install SpeechRecognition
   ```
   
   The app will automatically detect and use the best available option, preferring faster-whisper for streaming transcription.

5. **Anthropic API Key** (configure via `.env` file):
   - Anthropic API key for transcription and summaries: `ANTHROPIC_API_KEY`

   Create a `.env` file in the project root:
   ```bash
   cp .env.example .env
   ```
   
   Then edit `.env` and add your API key:
   ```
   ANTHROPIC_API_KEY=your_anthropic_api_key_here
   ```
   
   **Note:** The `.env` file is already in `.gitignore` and will not be committed to version control. 
   As a fallback, you can also use environment variables:
   ```bash
   export ANTHROPIC_API_KEY=your_anthropic_api_key
   ```

## Installation

1. Clone this repository:
   ```bash
   cd meeting-notes
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run -d linux
   ```

## Usage

1. Start the app
2. Click "Start Recording" to begin recording audio
3. Speak into your microphone (the app will capture audio in 5-second chunks)
4. Watch the transcript update in real-time (updates every 10 seconds when using faster-whisper)
5. Click "Stop Recording" when done
6. The app will:
   - Finalize the transcript from all chunks
   - Generate a summary using Claude
   - Save both files in organized folders:
     - `MeetingMinutesRecordings/[timestamp]/meeting_transcript_[timestamp].txt`
     - `MeetingMinutesRecordings/[timestamp]/meeting_summary_[timestamp].txt`

## File Locations

Transcripts and summaries are saved in organized folders:
```
~/Documents/MeetingMinutesRecordings/
  └── [timestamp]/
      ├── meeting_transcript_[timestamp].txt
      └── meeting_summary_[timestamp].txt
```

Each meeting gets its own timestamped folder for easy organization.

## Configuration

### Audio Settings

The app currently records:
- Format: WAV
- Sample Rate: 16kHz
- Bit Rate: 128kbps

These settings are optimized for transcription and can be modified in `lib/main.dart`.

### API Configuration

The app uses:
- **faster-whisper** (preferred) for streaming chunked transcription - provides near-real-time updates
- **OpenAI Whisper** (fallback) for batch transcription after recording stops
- **Python speech_recognition** (fallback) as alternative transcription method
- **Anthropic Claude API** for summarization (requires API key)

**Note:** Claude API does not support direct audio transcription. The app uses local tools for transcription, then sends the text to Claude for summarization.

### Chunked Recording

When using faster-whisper, the app records audio in 5-second chunks and transcribes them progressively:
- Chunks are transcribed as they're recorded
- UI updates every 2 chunks (approximately every 10 seconds)
- Provides near-real-time transcription feedback
- Final transcript combines all chunks seamlessly

## Troubleshooting

### Microphone Permission Issues

On Linux, the app uses PulseAudio for recording. You may need to grant microphone permissions through your system settings. The app will check permissions automatically, but if issues persist:

```bash
# Check PulseAudio sources
pactl list sources short

# Check default source
pactl get-default-source

# Set default source if needed
pactl set-default-source <source_name>
```

### PulseAudio / parecord Issues

The app uses PulseAudio's `parecord` command for recording. If you encounter recording issues:

1. **Verify parecord is installed:**
   ```bash
   which parecord
   parecord --version
   ```

2. **If parecord is not found, install PulseAudio:**
   ```bash
   sudo apt-get install pulseaudio-utils
   ```

3. **Check if PulseAudio is running:**
   ```bash
   pactl info
   ```

4. **List available audio sources:**
   ```bash
   pactl list sources short
   ```

5. **Set default source if needed:**
   ```bash
   pactl set-default-source <source_name>
   ```

### API Key Errors

Make sure your Anthropic API key is set in your `.env` file or as an environment variable:

**Check .env file:**
```bash
cat .env
```

**Or check environment variable:**
```bash
echo $ANTHROPIC_API_KEY
```

If the `.env` file doesn't exist, create it from the template:
```bash
cp .env.example .env
# Then edit .env with your Anthropic API key
```

### Build Issues

If you encounter build issues, try:
```bash
flutter clean
flutter pub get
flutter run -d linux
```

## Possible Future Enhancements

- [ ] Support for capturing system audio (speakers)
- [ ] Multiple meeting templates
- [ ] Export to different formats (Markdown, PDF)
- [ ] Integration with calendar apps

## License

MIT License
