import 'dart:io';
import 'dart:async';
import 'faster_whisper_service.dart';

class TranscriptionService {
  // Using local transcription via faster-whisper (preferred) or fallback to whisper/speech_recognition
  // Note: Claude API doesn't support direct audio transcription
  // We use local tools for transcription, then Claude for summarization
  
  final FasterWhisperService _fasterWhisperService = FasterWhisperService();
  
  /// Transcribe audio using available local tools
  /// Falls back to a simple placeholder if no transcription tool is available
  Future<String> transcribeAudio(String audioPath) async {
    try {
      final File audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        throw Exception('Audio file not found: $audioPath');
      }

      // Try faster-whisper first (preferred for speed)
      if (await _fasterWhisperService.isAvailable()) {
        return await _fasterWhisperService.transcribeChunk(audioPath);
      }

      // Fallback to whisper.cpp if available
      if (await _isWhisperCppAvailable()) {
        return await _transcribeWithWhisperCpp(audioPath);
      }

      // Fallback to speech_recognition Python package if available
      if (await _isSpeechRecognitionAvailable()) {
        return await _transcribeWithSpeechRecognition(audioPath);
      }

      // If no local tools available, provide helpful error message
      throw Exception(
        'No local transcription tool found.\n\n'
        'Please install one of the following:\n'
        '1. faster-whisper (recommended for streaming): pip install faster-whisper\n'
        '2. OpenAI Whisper: pip install openai-whisper\n'
        '3. Python speech_recognition: pip3 install SpeechRecognition\n\n'
        'Note: Claude API does not support direct audio transcription.\n'
        'We use local tools for transcription, then Claude for summarization.\n\n'
        'After installing, restart the app and try again.'
      );
    } catch (e) {
      if (e.toString().contains('transcription')) {
        rethrow;
      }
      throw Exception('Error transcribing audio: $e');
    }
  }

  /// Transcribe audio chunks in streaming mode
  /// Processes chunks as they arrive and returns a stream of transcript segments
  Stream<String> transcribeStreaming(Stream<String> chunkPaths) async* {
    try {
      // Check if faster-whisper is available
      if (!await _fasterWhisperService.isAvailable()) {
        throw Exception(
          'faster-whisper is required for streaming transcription.\n'
          'Install with: pip install faster-whisper'
        );
      }

      await for (final chunkPath in chunkPaths) {
        try {
          final transcript = await _fasterWhisperService.transcribeChunk(chunkPath);
          if (transcript.isNotEmpty) {
            yield transcript;
          }
        } catch (e) {
          // Log error but continue processing other chunks
          print('Error transcribing chunk $chunkPath: $e');
          // Yield empty string to maintain stream continuity
          yield '';
        }
      }
    } catch (e) {
      throw Exception('Error in streaming transcription: $e');
    }
  }

  /// Check if whisper.cpp is available
  Future<bool> _isWhisperCppAvailable() async {
    try {
      final result = await Process.run('which', ['whisper']);
      return result.exitCode == 0 || await File('/usr/local/bin/whisper').exists();
    } catch (e) {
      return false;
    }
  }

  /// Transcribe using whisper (OpenAI Whisper local installation)
  Future<String> _transcribeWithWhisperCpp(String audioPath) async {
    try {
      // Get directory of the audio file for output
      final audioFile = File(audioPath);
      final outputDir = audioFile.parent.path;
      final baseName = audioFile.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');

      // Try whisper command (if installed via pip: pip install openai-whisper)
      // Use correct syntax for whisper CLI
      // Note: --fp16 expects True/False (capital), not false
      ProcessResult result = await Process.run('whisper', [
        audioPath,
        '--language', 'en',
        '--output_format', 'txt',
        '--output_dir', outputDir,
        '--model', 'base', // Use base model for faster processing (~140MB)
        '--fp16', 'False', // Boolean as string
        '--verbose', 'False',
      ], runInShell: false);

      // Whisper creates a .txt file with the same base name in the output directory
      final String txtPath = '$outputDir/$baseName.txt';
      
      // Whisper outputs progress bars to stderr which is normal - we ignore them
      // The key is to check if the output file exists, regardless of progress output
      
      // Wait for whisper to finish processing (it outputs progress to stderr)
      // Retry checking for the file multiple times
      File? txtFile;
      for (int attempt = 0; attempt < 20; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final file = File(txtPath);
        if (await file.exists()) {
          // Check if file has content (not empty or still being written)
          final fileSize = await file.length();
          if (fileSize > 10) {  // File must have some content
            txtFile = file;
            break;
          }
        }
      }
      
      // If file was found, read and return transcript
      if (txtFile != null && await txtFile.exists()) {
        final transcript = await txtFile.readAsString();
        
        // Clean up the generated .txt file (ignore errors)
        try {
          await txtFile.delete();
        } catch (e) {
          // Ignore deletion errors
        }
        
        final trimmedTranscript = transcript.trim();
        if (trimmedTranscript.isNotEmpty) {
          return trimmedTranscript;
        }
      }

      // If file doesn't exist, check for actual errors (not progress bars)
      final stderr = result.stderr.toString();
      
      // Check for actual error messages vs progress bars
      // Progress bars: contain "%", "|", "frames/s", "MiB/s", "[", "]", numbers
      // Real errors: contain "error", "failed", "exception", "traceback"
      final hasProgressBars = stderr.contains('%') || 
                              stderr.contains('frames/s') ||
                              stderr.contains('MiB/s') ||
                              (stderr.contains('|') && stderr.contains('['));
      
      final hasErrorMessages = stderr.toLowerCase().contains('error') || 
                               stderr.toLowerCase().contains('failed') ||
                               stderr.toLowerCase().contains('exception') ||
                               stderr.toLowerCase().contains('traceback');

      // If we have progress bars but no error messages, and exit code is 0,
      // whisper might have succeeded but file path is different - search for it
      if (hasProgressBars && !hasErrorMessages && result.exitCode == 0) {
        try {
          final dir = Directory(outputDir);
          await for (final entity in dir.list()) {
            if (entity is File) {
              final name = entity.path.split('/').last;
              if (name.contains(baseName) && name.endsWith('.txt')) {
                final transcript = await entity.readAsString();
                try {
                  await entity.delete();
                } catch (e) {
                  // Ignore
                }
                if (transcript.trim().isNotEmpty) {
                  return transcript.trim();
                }
              }
            }
          }
        } catch (e) {
          // Ignore directory listing errors
        }
      }

      // Only throw error if we have actual error messages OR process failed with non-zero exit
      // Progress bars alone are not errors
      final errorMessage = hasErrorMessages 
          ? stderr.replaceAll(RegExp(r'[\r\n]'), ' ').substring(0, stderr.length > 500 ? 500 : stderr.length)
          : (result.exitCode != 0 
              ? 'Process exited with code ${result.exitCode}'
              : 'Output file not found after waiting');
      
      throw Exception(
        'Whisper transcription failed.\n'
        'Exit code: ${result.exitCode}\n'
        'Expected file: $txtPath\n'
        'Error: $errorMessage'
      );
    } catch (e) {
      if (e.toString().contains('Whisper transcription failed')) {
        rethrow;
      }
      throw Exception('Error using whisper: $e');
    }
  }

  /// Check if Python speech_recognition is available
  Future<bool> _isSpeechRecognitionAvailable() async {
    try {
      final result = await Process.run('python3', ['-c', 'import speech_recognition']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Transcribe using Python speech_recognition
  Future<String> _transcribeWithSpeechRecognition(String audioPath) async {
    try {
      // Create a temporary Python script for transcription
      final script = '''
import speech_recognition as sr
import sys

r = sr.Recognizer()
with sr.AudioFile('$audioPath') as source:
    audio = r.record(source)

try:
    text = r.recognize_google(audio)
    print(text)
except sr.UnknownValueError:
    print("Could not understand audio", file=sys.stderr)
    sys.exit(1)
except sr.RequestError as e:
    print(f"Could not request results: {e}", file=sys.stderr)
    sys.exit(1)
''';

      // Write temporary script
      final tempScript = File('/tmp/transcribe_temp.py');
      await tempScript.writeAsString(script);

      // Execute Python script
      final result = await Process.run('python3', [tempScript.path]);

      // Clean up
      await tempScript.delete();

      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        return result.stdout.toString().trim();
      }

      throw Exception('Speech recognition failed: ${result.stderr}');
    } catch (e) {
      throw Exception('Error using speech_recognition: $e');
    }
  }
}
