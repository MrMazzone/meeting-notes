import 'dart:io';

/// Service for transcribing audio chunks using faster-whisper
class FasterWhisperService {
  static const String _scriptPath = 'scripts/faster_whisper_transcribe.py';
  static const String _defaultModel = 'base'; // tiny, base, small, medium, large-v2
  static const String _defaultLanguage = 'en';

  /// Check if faster-whisper is available
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('python3', ['-c', 'import faster_whisper']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Transcribe a single audio chunk
  /// 
  /// Parameters:
  /// - chunkPath: Path to the audio chunk file
  /// - modelSize: Model size (tiny, base, small, medium, large-v2) - default: base
  /// - language: Language code (en, es, fr, etc.) - default: en
  Future<String> transcribeChunk(
    String chunkPath, {
    String modelSize = _defaultModel,
    String language = _defaultLanguage,
  }) async {
    try {
      final File chunkFile = File(chunkPath);
      if (!await chunkFile.exists()) {
        throw Exception('Audio chunk not found: $chunkPath');
      }

      // Get the script path relative to project root
      final scriptFile = File(_scriptPath);
      if (!await scriptFile.exists()) {
        // Try absolute path
        final currentDir = Directory.current;
        final absoluteScriptPath = '${currentDir.path}/$_scriptPath';
        final absoluteScriptFile = File(absoluteScriptPath);
        if (!await absoluteScriptFile.exists()) {
          throw Exception(
            'faster-whisper script not found. Expected at: $_scriptPath or $absoluteScriptPath'
          );
        }
      }

      // Run faster-whisper transcription script
      final scriptPath = await scriptFile.exists() 
          ? scriptFile.path 
          : '${Directory.current.path}/$_scriptPath';
      
      final result = await Process.run(
        'python3',
        [scriptPath, chunkPath, modelSize, language],
        runInShell: false,
      );

      if (result.exitCode == 0) {
        final transcript = result.stdout.toString().trim();
        if (transcript.isNotEmpty) {
          return transcript;
        }
        // Empty transcript is valid (silence or no speech detected)
        return '';
      } else {
        final errorMsg = result.stderr.toString();
        throw Exception('Faster-whisper transcription failed: $errorMsg');
      }
    } catch (e) {
      if (e.toString().contains('faster-whisper')) {
        rethrow;
      }
      throw Exception('Error transcribing chunk with faster-whisper: $e');
    }
  }

  /// Get recommended model size based on hardware
  /// Returns smaller models for better speed
  String getRecommendedModel() {
    // For streaming, prefer faster models
    // Can be enhanced to detect hardware capabilities
    return 'base'; // Good balance of speed and accuracy
  }
}
