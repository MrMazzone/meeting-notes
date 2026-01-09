import 'dart:io';
import 'dart:async';

/// Audio recording service using PulseAudio's parecord command
/// This is a native Linux solution that doesn't require external dependencies
class AudioRecorderService {
  Process? _recordingProcess;
  String? _currentRecordingPath;
  bool _isRecording = false;
  
  // Chunked recording support
  StreamController<String>? _chunkStreamController;
  Timer? _chunkTimer;
  int _chunkCounter = 0;
  String? _tempDir;
  int _chunkDurationSeconds = 5;

  /// Check if parecord is available on the system
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('which', ['parecord']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Check if microphone permission is available
  /// On Linux, we check if PulseAudio can list sources
  Future<bool> hasPermission() async {
    try {
      final result = await Process.run('pactl', ['list', 'sources', 'short']);
      return result.exitCode == 0 && result.stdout.toString().isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Get the default audio source
  Future<String?> getDefaultSource() async {
    try {
      final result = await Process.run('pactl', ['get-default-source']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      // Fallback to default
    }
    return null;
  }

  /// Get stream of chunk file paths during recording
  Stream<String> get chunkStream {
    _chunkStreamController ??= StreamController<String>.broadcast();
    return _chunkStreamController!.stream;
  }

  /// Start recording audio in chunks
  /// 
  /// Parameters:
  /// - path: Full path where the final recording should be saved (WAV format) - optional for chunked mode
  /// - sampleRate: Sample rate in Hz (default: 16000)
  /// - channels: Number of audio channels (default: 1 for mono)
  /// - source: PulseAudio source name (null uses default)
  /// - chunkDuration: Duration of each chunk in seconds (default: 5)
  /// - chunked: Whether to record in chunks (default: true)
  Future<void> start({
    String? path,
    int sampleRate = 16000,
    int channels = 1,
    String? source,
    int chunkDuration = 5,
    bool chunked = true,
  }) async {
    if (_isRecording) {
      throw Exception('Recording is already in progress');
    }

    // Check if parecord is available
    if (!await isAvailable()) {
      throw Exception(
        'parecord is not installed. Please install PulseAudio:\n'
        'sudo apt-get install pulseaudio-utils'
      );
    }

    // Check permissions
    if (!await hasPermission()) {
      throw Exception('Microphone permission denied or PulseAudio not running');
    }

    _chunkDurationSeconds = chunkDuration;
    _chunkCounter = 0;
    _chunkStreamController ??= StreamController<String>.broadcast();

    if (chunked) {
      // Chunked recording mode
      final Directory tempDir = Directory.systemTemp;
      _tempDir = tempDir.path;
      
      // Start chunked recording
      _isRecording = true;
      _startChunkedRecording(sampleRate, channels, source);
    } else {
      // Legacy single file mode
      if (path == null) {
        throw Exception('path is required when chunked=false');
      }
      
      final String sourceToUse = source ?? await getDefaultSource() ?? '@DEFAULT_SOURCE@';
      final List<String> command = [
        'parecord',
        '--file-format=wav',
        '--rate=$sampleRate',
        '--channels=$channels',
        '--device=$sourceToUse',
        path,
      ];

      try {
        _recordingProcess = await Process.start(
          command[0],
          command.sublist(1),
          runInShell: false,
        );

        _recordingProcess!.stderr.listen((data) {
          print('parecord stderr: ${String.fromCharCodes(data)}');
        });

        _recordingProcess!.exitCode.then((exitCode) {
          if (exitCode != 0 && _isRecording) {
            print('parecord exited with code: $exitCode');
          }
        });

        _currentRecordingPath = path;
        _isRecording = true;
      } catch (e) {
        _isRecording = false;
        _currentRecordingPath = null;
        throw Exception('Failed to start recording: $e');
      }
    }
  }

  /// Start chunked recording - records in intervals and emits chunk paths
  Future<void> _startChunkedRecording(
    int sampleRate,
    int channels,
    String? source,
  ) async {
    final String sourceToUse = source ?? await getDefaultSource() ?? '@DEFAULT_SOURCE@';
    
    // Record first chunk immediately
    _recordChunk(sampleRate, channels, sourceToUse);
    
    // Set up timer to record subsequent chunks
    _chunkTimer = Timer.periodic(
      Duration(seconds: _chunkDurationSeconds),
      (timer) {
        if (_isRecording) {
          _recordChunk(sampleRate, channels, sourceToUse);
        } else {
          timer.cancel();
        }
      },
    );
  }

  /// Record a single chunk
  Future<void> _recordChunk(
    int sampleRate,
    int channels,
    String source,
  ) async {
    if (!_isRecording) return;
    
    _chunkCounter++;
    final chunkPath = '$_tempDir/meeting_chunk_${_chunkCounter.toString().padLeft(3, '0')}.wav';
    
    try {
      // Start parecord process
      final process = await Process.start(
        'parecord',
        [
          '--file-format=wav',
          '--rate=$sampleRate',
          '--channels=$channels',
          '--device=$source',
          chunkPath,
        ],
        runInShell: false,
      );

      // Set up timer to stop recording after chunk duration
      Timer(Duration(seconds: _chunkDurationSeconds), () {
        try {
          process.kill(ProcessSignal.sigterm);
        } catch (e) {
          // Ignore if process already finished
        }
      });

      // Wait for process to complete (either naturally or killed by timer)
      await process.exitCode;
      
      // Small delay to ensure file is written
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Check if chunk file was created
      final chunkFile = File(chunkPath);
      if (await chunkFile.exists() && await chunkFile.length() > 0) {
        _chunkStreamController?.add(chunkPath);
      }
    } catch (e) {
      print('Error recording chunk $_chunkCounter: $e');
      // Continue recording even if one chunk fails
    }
  }

  /// Stop recording and return the path to the recorded file (or null for chunked mode)
  Future<String?> stop() async {
    if (!_isRecording) {
      return null;
    }

    try {
      _isRecording = false;
      
      // Cancel chunk timer
      _chunkTimer?.cancel();
      _chunkTimer = null;
      
      // Stop any active recording process
      if (_recordingProcess != null) {
        _recordingProcess!.kill(ProcessSignal.sigterm);
        await _recordingProcess!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _recordingProcess!.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        _recordingProcess = null;
      }

      // Close chunk stream
      await _chunkStreamController?.close();
      _chunkStreamController = null;

      final path = _currentRecordingPath;
      _currentRecordingPath = null;

      // For chunked mode, return null (chunks are handled via stream)
      // For single file mode, return the path
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          return path;
        }
      }

      return path;
    } catch (e) {
      _isRecording = false;
      _currentRecordingPath = null;
      _recordingProcess = null;
      _chunkTimer?.cancel();
      _chunkTimer = null;
      throw Exception('Failed to stop recording: $e');
    }
  }

  /// Clean up chunk files
  Future<void> cleanupChunks() async {
    if (_tempDir == null) return;
    
    try {
      final dir = Directory(_tempDir!);
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.contains('meeting_chunk_')) {
          try {
            await entity.delete();
          } catch (e) {
            // Ignore deletion errors
          }
        }
      }
    } catch (e) {
      // Ignore cleanup errors
    }
  }

  /// Check if currently recording
  bool get isRecording => _isRecording;

  /// Dispose resources
  Future<void> dispose() async {
    if (_isRecording) {
      await stop();
    }
    await cleanupChunks();
    await _chunkStreamController?.close();
    _chunkStreamController = null;
  }
}
