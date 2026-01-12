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

  // Cache for command paths
  String? _parecordPath;
  String? _pactlPath;

  /// Find the absolute path to a command
  Future<String?> _findCommand(String command) async {
    try {
      // Try common locations first
      final commonPaths = ['/usr/bin', '/bin', '/usr/local/bin'];
      for (final path in commonPaths) {
        final fullPath = '$path/$command';
        final file = File(fullPath);
        if (await file.exists()) {
          return fullPath;
        }
      }
      
      // Fallback to which command
      final result = await Process.run('which', [command]);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      // Ignore errors
    }
    return null;
  }

  /// Get the path to parecord command
  Future<String> _getParecordPath() async {
    if (_parecordPath != null) return _parecordPath!;
    _parecordPath = await _findCommand('parecord') ?? 'parecord';
    return _parecordPath!;
  }

  /// Get the path to pactl command
  Future<String> _getPactlPath() async {
    if (_pactlPath != null) return _pactlPath!;
    _pactlPath = await _findCommand('pactl') ?? 'pactl';
    return _pactlPath!;
  }

  /// Check if parecord is available on the system
  Future<bool> isAvailable() async {
    try {
      final parecordPath = await _getParecordPath();
      final result = await Process.run(parecordPath, ['--version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Check if microphone permission is available
  /// On Linux, we check if PulseAudio can list sources
  Future<bool> hasPermission() async {
    try {
      final pactlPath = await _getPactlPath();
      final result = await Process.run(pactlPath, ['list', 'sources', 'short']);
      return result.exitCode == 0 && result.stdout.toString().isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Get the default audio source (microphone)
  Future<String?> getDefaultSource() async {
    try {
      final pactlPath = await _getPactlPath();
      final result = await Process.run(pactlPath, ['get-default-source']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      // Fallback to default
    }
    return null;
  }

  /// Get the default output sink's monitor source (system audio)
  Future<String?> getDefaultMonitorSource() async {
    try {
      final pactlPath = await _getPactlPath();
      
      // First get the default sink
      final sinkResult = await Process.run(pactlPath, ['get-default-sink']);
      if (sinkResult.exitCode != 0) {
        print('Failed to get default sink');
        return null;
      }
      
      final sinkName = sinkResult.stdout.toString().trim();
      print('Default sink: $sinkName');
      
      // List all sources and find ALL monitor sources
      final sourcesResult = await Process.run(pactlPath, ['list', 'sources', 'short']);
      if (sourcesResult.exitCode != 0) {
        print('Failed to list sources');
        return null;
      }
      
      final sources = sourcesResult.stdout.toString().split('\n');
      String? monitorSource;
      final allMonitors = <String>[];
      
      for (final source in sources) {
        if (source.trim().isEmpty) continue;
        
        // Format: [index] [name] [driver] [spec] [state]
        // Extract source name (second field, index 1)
        final parts = source.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        
        final sourceName = parts[1]; // Second field is the name
        // State is typically the last field
        final state = parts.length > 1 ? parts[parts.length - 1] : '';
        
        // Collect all monitor sources
        if (sourceName.contains('.monitor')) {
          allMonitors.add(sourceName);
          
          // Check if this is a monitor source for our sink
          if (sourceName.contains(sinkName)) {
            monitorSource = sourceName;
            print('Found monitor source for default sink: $monitorSource (state: $state)');
            break;
          }
        }
      }
      
      if (monitorSource != null) {
        return monitorSource;
      }
      
      // If we didn't find a match, try to find any active monitor
      // (in case audio is playing through a different sink)
      print('Monitor for default sink not found. Available monitors: ${allMonitors.join(", ")}');
      
      // Try to find an active monitor (one that's RUNNING or not SUSPENDED/IDLE)
      for (final source in sources) {
        if (source.trim().isEmpty) continue;
        final parts = source.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        
        final sourceName = parts[1]; // Second field is the name
        // State is typically the last field
        final state = parts.length > 1 ? parts[parts.length - 1].toUpperCase() : '';
        
        if (sourceName.contains('.monitor')) {
          // Accept any monitor (IDLE is normal when no audio is playing)
          // The monitor will become active when audio plays
          monitorSource = sourceName;
          print('Found monitor source: $monitorSource (state: $state)');
          break;
        }
      }
      
      if (monitorSource != null) {
        return monitorSource;
      }
      
      // Fallback: try common monitor source pattern
      final fallbackMonitor = '$sinkName.monitor';
      print('Trying fallback monitor: $fallbackMonitor');
      
      // Verify it exists
      if (allMonitors.contains(fallbackMonitor)) {
        return fallbackMonitor;
      }
      
      // Last resort: use the first monitor we found (if any)
      if (allMonitors.isNotEmpty) {
        print('Using first available monitor: ${allMonitors.first}');
        return allMonitors.first;
      }
      
      print('Monitor source not found for sink: $sinkName');
      print('Available monitor sources: ${allMonitors.join(", ")}');
      return null;
    } catch (e) {
      print('Error getting monitor source: $e');
      return null;
    }
  }

  /// Create a combined source that mixes microphone and system audio
  Future<String?> createCombinedSource() async {
    try {
      final pactlPath = await _getPactlPath();
      final micSource = await getDefaultSource() ?? '@DEFAULT_SOURCE@';
      final monitorSource = await getDefaultMonitorSource();
      
      print('Creating combined source:');
      print('  Microphone: $micSource');
      print('  System audio: $monitorSource');
      
      if (monitorSource == null) {
        print('Warning: Monitor source not found, using microphone only');
        // If we can't find monitor, just use microphone
        return micSource;
      }
      
      // Create a null sink that we can use as a combined source
      // Load module-null-sink with a specific name
      final sinkName = 'meeting_notes_combined';
      
      // Clean up any existing combined sink first
      await cleanupCombinedSource();
      
      // Wait a moment
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Create null sink
      final nullSinkResult = await Process.run(pactlPath, [
        'load-module',
        'module-null-sink',
        'sink_name=$sinkName',
        'sink_properties=device.description="MeetingNotesCombined"'
      ]);
      
      if (nullSinkResult.exitCode != 0) {
        print('Failed to create null sink: ${nullSinkResult.stderr}');
        return micSource;
      }
      
      print('Created null sink: $sinkName');
      
      // Wait a moment for it to be created
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Create loopback from microphone to combined sink
      final micLoopbackResult = await Process.run(pactlPath, [
        'load-module',
        'module-loopback',
        'source=$micSource',
        'sink=$sinkName',
        'latency_msec=50',
        'source_dont_move=true',
        'sink_dont_move=true'
      ]);
      
      if (micLoopbackResult.exitCode != 0) {
        print('Failed to create microphone loopback: ${micLoopbackResult.stderr}');
        // Try without the extra flags
        final retryResult = await Process.run(pactlPath, [
          'load-module',
          'module-loopback',
          'source=$micSource',
          'sink=$sinkName',
          'latency_msec=50'
        ]);
        if (retryResult.exitCode != 0) {
          print('Retry also failed: ${retryResult.stderr}');
        } else {
          print('Created microphone loopback (retry)');
        }
      } else {
        print('Created microphone loopback');
      }
      
      // Wait a moment
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Create loopback from system audio monitor to combined sink
      final monitorLoopbackResult = await Process.run(pactlPath, [
        'load-module',
        'module-loopback',
        'source=$monitorSource',
        'sink=$sinkName',
        'latency_msec=50',
        'source_dont_move=true',
        'sink_dont_move=true'
      ]);
      
      if (monitorLoopbackResult.exitCode != 0) {
        print('Failed to create monitor loopback: ${monitorLoopbackResult.stderr}');
        // Try without the extra flags
        final retryResult = await Process.run(pactlPath, [
          'load-module',
          'module-loopback',
          'source=$monitorSource',
          'sink=$sinkName',
          'latency_msec=50'
        ]);
        if (retryResult.exitCode != 0) {
          print('Retry also failed: ${retryResult.stderr}');
        } else {
          print('Created monitor loopback (retry)');
        }
      } else {
        print('Created monitor loopback');
      }
      
      // Wait a moment for loopbacks to be set up
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Verify the monitor source exists and test if it's working
      final combinedMonitor = '$sinkName.monitor';
      final verifyResult = await Process.run(pactlPath, ['list', 'sources', 'short']);
      if (verifyResult.exitCode == 0 && verifyResult.stdout.toString().contains(combinedMonitor)) {
        print('Combined source ready: $combinedMonitor');
        
        // Verify both loopbacks are active
        final modulesResult = await Process.run(pactlPath, ['list', 'short', 'modules']);
        if (modulesResult.exitCode == 0) {
          final modules = modulesResult.stdout.toString();
          final hasMicLoopback = modules.contains('module-loopback') && 
                                 modules.contains(micSource) && 
                                 modules.contains(sinkName);
          final hasMonitorLoopback = modules.contains('module-loopback') && 
                                     modules.contains(monitorSource) && 
                                     modules.contains(sinkName);
          
          print('Microphone loopback active: $hasMicLoopback');
          print('Monitor loopback active: $hasMonitorLoopback');
          
          if (!hasMicLoopback || !hasMonitorLoopback) {
            print('Warning: Some loopbacks may not be active');
          }
        }
        
        return combinedMonitor;
      } else {
        print('Warning: Combined monitor source not found, falling back to microphone');
        return micSource;
      }
    } catch (e) {
      print('Error creating combined source: $e');
      // Fallback to microphone only
      return await getDefaultSource() ?? '@DEFAULT_SOURCE@';
    }
  }

  /// Clean up combined source modules
  Future<void> cleanupCombinedSource() async {
    try {
      final pactlPath = await _getPactlPath();
      
      // List all modules to find ones we created
      final listResult = await Process.run(pactlPath, ['list', 'short', 'modules']);
      if (listResult.exitCode == 0) {
        final modules = listResult.stdout.toString().split('\n');
        final moduleIdsToUnload = <String>[];
        
        for (final module in modules) {
          if (module.trim().isEmpty) continue;
          
          // Check if this module is related to our combined sink
          final moduleLine = module.toLowerCase();
          if (moduleLine.contains('meeting_notes_combined') || 
              moduleLine.contains('meetingnotescombined') ||
              (moduleLine.contains('module-loopback') && moduleLine.contains('meeting_notes_combined')) ||
              (moduleLine.contains('module-null-sink') && moduleLine.contains('meeting_notes_combined'))) {
            final parts = module.trim().split(RegExp(r'\s+'));
            if (parts.isNotEmpty) {
              final moduleId = parts[0];
              if (moduleId.isNotEmpty && moduleId != 'Module') {
                moduleIdsToUnload.add(moduleId);
              }
            }
          }
        }
        
        // Unload modules in reverse order
        for (final moduleId in moduleIdsToUnload.reversed) {
          try {
            final unloadResult = await Process.run(pactlPath, ['unload-module', moduleId]);
            if (unloadResult.exitCode == 0) {
              print('Unloaded module: $moduleId');
            }
          } catch (e) {
            // Ignore individual unload errors
            print('Error unloading module $moduleId: $e');
          }
        }
      }
      
      // Also try to unload by sink name if it still exists
      final sinksResult = await Process.run(pactlPath, ['list', 'sinks', 'short']);
      if (sinksResult.exitCode == 0 && sinksResult.stdout.toString().contains('meeting_notes_combined')) {
        // Try to find and unload the null sink module
        final modulesResult = await Process.run(pactlPath, ['list', 'short', 'modules']);
        if (modulesResult.exitCode == 0) {
          final modules = modulesResult.stdout.toString().split('\n');
          for (final module in modules) {
            if (module.contains('module-null-sink') && module.contains('meeting_notes_combined')) {
              final parts = module.trim().split(RegExp(r'\s+'));
              if (parts.isNotEmpty) {
                final moduleId = parts[0];
                await Process.run(pactlPath, ['unload-module', moduleId]);
              }
            }
          }
        }
      }
    } catch (e) {
      // Ignore cleanup errors
      print('Error cleaning up combined source: $e');
    }
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
      
      // If no source specified, create combined source (mic + system audio)
      String sourceToUse;
      if (source != null) {
        sourceToUse = source;
      } else {
        // Create combined source for microphone + system audio
        final combinedSource = await createCombinedSource();
        sourceToUse = combinedSource ?? '@DEFAULT_SOURCE@';
      }
      
      final parecordPath = await _getParecordPath();
      final List<String> command = [
        parecordPath,
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
    // If no source specified, create combined source (mic + system audio)
    String sourceToUse;
    if (source != null) {
      sourceToUse = source;
    } else {
      // Create combined source for microphone + system audio
      final combinedSource = await createCombinedSource();
      sourceToUse = combinedSource ?? '@DEFAULT_SOURCE@';
      print('Using audio source for recording: $sourceToUse');
    }
    
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
      final parecordPath = await _getParecordPath();
      final process = await Process.start(
        parecordPath,
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

      // Clean up combined source when stopping
      await cleanupCombinedSource();

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
    await cleanupCombinedSource();
    await _chunkStreamController?.close();
    _chunkStreamController = null;
  }
}
