import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'services/audio_recorder_service.dart';
import 'services/transcription_service.dart';
import 'services/summary_service.dart';
import 'services/config_service.dart';
import 'widgets/settings_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final themeModeString = await ConfigService.getThemeMode();
    setState(() {
      switch (themeModeString) {
        case 'light':
          _themeMode = ThemeMode.light;
          break;
        case 'dark':
          _themeMode = ThemeMode.dark;
          break;
        case 'system':
        default:
          _themeMode = ThemeMode.system;
          break;
      }
    });
  }

  void _updateTheme() {
    _loadTheme();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5A7BA8));
    return MaterialApp(
      title: 'Meeting Notes',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5A7BA8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: MeetingNotesPage(
        onThemeChanged: _updateTheme,
      ),
    );
  }
}

class MeetingNotesPage extends StatefulWidget {
  final VoidCallback? onThemeChanged;
  
  const MeetingNotesPage({super.key, this.onThemeChanged});

  @override
  State<MeetingNotesPage> createState() => _MeetingNotesPageState();
}

class _MeetingNotesPageState extends State<MeetingNotesPage> {
  final AudioRecorderService _audioRecorder = AudioRecorderService();
  bool _isRecording = false;
  String _transcript = '';
  String _summary = '';
  String _status = 'Ready to record';
  String? _transcriptPath;
  String? _summaryPath;
  StreamSubscription<String>? _transcriptionSubscription;
  StreamSubscription<String>? _chunkStreamSubscription;
  List<String> _chunkBuffer = [];
  List<String> _transcriptSegments = [];
  List<Future<String>> _pendingTranscriptions = [];

  final TranscriptionService _transcriptionService = TranscriptionService();
  final SummaryService _summaryService = SummaryService();
  bool _hasApiKey = false;

  @override
  void initState() {
    super.initState();
    _checkApiKey();
  }

  Future<void> _checkApiKey() async {
    final hasKey = await ConfigService.hasApiKey();
    setState(() {
      _hasApiKey = hasKey;
    });
    
    // Show first-run dialog if no API key
    if (!hasKey && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showFirstRunDialog();
      });
    }
  }

  void _showFirstRunDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline),
            SizedBox(width: 8),
            Text('Welcome to Meeting Notes'),
          ],
        ),
        content: const Text(
          'To generate AI-powered meeting summaries, you need to configure your Anthropic Claude API key.\n\n'
          'You can set it now or access Settings later from the app.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _openSettings();
            },
            child: const Text('Set API Key'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => SettingsDialog(
        onThemeChanged: widget.onThemeChanged,
      ),
    );
    
    if (result == true) {
      // API key was saved, refresh status
      await _checkApiKey();
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _transcriptionSubscription?.cancel();
    _chunkStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      // Check if API key is configured
      if (!await ConfigService.hasApiKey()) {
        setState(() {
          _status = 'API key not configured. Please set it in Settings.';
        });
        _openSettings();
        return;
      }

      // Check if parecord is available
      if (!await _audioRecorder.isAvailable()) {
        setState(() {
          _status = 'Error: parecord not found. Please install PulseAudio: sudo apt-get install pulseaudio-utils';
        });
        return;
      }

      // Check and request permissions
      if (await _audioRecorder.hasPermission()) {
        setState(() {
          _isRecording = true;
          _status = 'Recording...';
          _transcript = '';
          _summary = '';
          _chunkBuffer = [];
          _transcriptSegments = [];
        });

        // Start chunked recording (5 second chunks)
        await _audioRecorder.start(
          chunked: true,
          chunkDuration: 5,
          sampleRate: 16000,
          channels: 1, // Mono recording
        );

        // Start processing chunks for streaming transcription
        _startLiveTranscription();
      } else {
        setState(() {
          _status = 'Microphone permission denied';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error starting recording: $e';
      });
    }
  }

  void _startLiveTranscription() {
    // Subscribe to chunk stream and process chunks for streaming transcription
    _chunkStreamSubscription?.cancel();
    _chunkStreamSubscription = _audioRecorder.chunkStream.listen(
      (chunkPath) {
        _processChunk(chunkPath);
      },
      onError: (error) {
        print('Error in chunk stream: $error');
      },
    );
  }

  /// Process a single audio chunk
  Future<void> _processChunk(String chunkPath) async {
    try {
      // Add chunk to buffer
      _chunkBuffer.add(chunkPath);

      // Process when we have 2 chunks (update every 2 chunks = 10 seconds)
      if (_chunkBuffer.length >= 2) {
        await _transcribeChunkBuffer();
      }
    } catch (e) {
      print('Error processing chunk: $e');
    }
  }

  /// Transcribe a single chunk and track it
  Future<String> _transcribeChunkAsync(String chunkPath) async {
    try {
      final transcript = await _transcriptionService.transcribeAudio(chunkPath);
      return transcript;
    } catch (e) {
      print('Error transcribing chunk $chunkPath: $e');
      return ''; // Return empty string on error to maintain flow
    }
  }

  /// Transcribe buffered chunks and update UI
  Future<void> _transcribeChunkBuffer() async {
    if (_chunkBuffer.isEmpty) return;

    try {
      if (mounted) {
        setState(() {
          _status = 'Transcribing chunks...';
        });
      }

      // Transcribe all chunks in buffer
      final List<String> chunksToProcess = List.from(_chunkBuffer);
      _chunkBuffer.clear();

      // Start transcription for all chunks (can run in parallel)
      final List<Future<String>> transcriptionFutures = chunksToProcess
          .map((chunkPath) => _transcribeChunkAsync(chunkPath))
          .toList();
      
      // Track these transcriptions
      _pendingTranscriptions.addAll(transcriptionFutures);

      // Wait for all transcriptions to complete
      final results = await Future.wait(transcriptionFutures);

      // Remove completed futures from tracking
      for (final future in transcriptionFutures) {
        _pendingTranscriptions.remove(future);
      }

      // Add non-empty transcripts to segments
      for (final transcript in results) {
        if (transcript.isNotEmpty) {
          _transcriptSegments.add(transcript);
        }
      }
      
      // Update UI with accumulated transcript
      if (mounted) {
        setState(() {
          _transcript = _transcriptSegments.join(' ');
          _status = _isRecording ? 'Recording... (Transcribing)' : 'Transcribing...';
        });
      }
    } catch (e) {
      print('Error in chunk buffer transcription: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      setState(() {
        _status = 'Stopping recording...';
      });

      // Cancel chunk stream subscription to prevent new chunks
      await _chunkStreamSubscription?.cancel();
      _chunkStreamSubscription = null;

      // Stop recording first to prevent new chunks
      await _audioRecorder.stop();
      
      setState(() {
        _isRecording = false;
        _status = 'Processing remaining chunks...';
      });

      // Process any remaining chunks in buffer
      if (_chunkBuffer.isNotEmpty) {
        await _transcribeChunkBuffer();
      }

      // Wait for all pending transcriptions to complete
      if (_pendingTranscriptions.isNotEmpty) {
        if (mounted) {
          setState(() {
            _status = 'Waiting for transcription to complete...';
          });
        }
        
        try {
          // Wait for all pending transcriptions and collect results
          final results = await Future.wait(_pendingTranscriptions);
          
          // Add any new transcripts from pending operations
          for (final transcript in results) {
            if (transcript.isNotEmpty && !_transcriptSegments.contains(transcript)) {
              _transcriptSegments.add(transcript);
            }
          }
          
          _pendingTranscriptions.clear();
          
          // Update transcript in UI
          if (mounted) {
            setState(() {
              _transcript = _transcriptSegments.join(' ');
            });
          }
        } catch (e) {
          print('Error waiting for pending transcriptions: $e');
          // Continue anyway - we'll use what we have
          _pendingTranscriptions.clear();
        }
      }

      // Give a small delay to ensure all transcript segments are added
      await Future.delayed(const Duration(milliseconds: 300));

      setState(() {
        _status = 'Finalizing transcript...';
      });

      // Finalize transcript and generate summary
      await _finalizeAndSave();
    } catch (e) {
      setState(() {
        _status = 'Error stopping recording: $e';
        _isRecording = false;
      });
    } finally {
      // Clean up chunk files
      await _audioRecorder.cleanupChunks();
    }
  }

  /// Finalize transcript and save files
  Future<void> _finalizeAndSave() async {
    try {
      // Combine all transcript segments
      final finalTranscript = _transcriptSegments.join(' ').trim();
      
      if (finalTranscript.isEmpty) {
        setState(() {
          _status = 'No transcript generated';
        });
        return;
      }

      setState(() {
        _transcript = finalTranscript;
        _status = 'Transcription complete. Generating summary...';
      });

      // Save transcript and summary in organized folder structure
      final Directory documentsDir = await getApplicationDocumentsDirectory();
      final String timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      
      // Create MeetingNotesApp folder if it doesn't exist
      final Directory appDir = Directory('${documentsDir.path}/MeetingNotesApp');
      if (!await appDir.exists()) {
        await appDir.create(recursive: true);
      }
      
      // Create timestamped folder for this meeting
      final Directory meetingDir = Directory('${appDir.path}/$timestamp');
      if (!await meetingDir.exists()) {
        await meetingDir.create(recursive: true);
      }
      
      // Save transcript in the meeting folder
      final String transcriptPath = '${meetingDir.path}/meeting_transcript_$timestamp.txt';
      final File transcriptFile = File(transcriptPath);
      await transcriptFile.writeAsString(finalTranscript);

      // Generate and save summary
      setState(() {
        _status = 'Generating summary with Claude...';
      });

      final summary = await _summaryService.summarizeMeeting(finalTranscript);
      final String summaryPath = '${meetingDir.path}/meeting_summary_$timestamp.txt';
      final File summaryFile = File(summaryPath);
      await summaryFile.writeAsString(summary);

      setState(() {
        _summary = summary;
        _transcriptPath = transcriptPath;
        _summaryPath = summaryPath;
        _status = 'Done! Files saved successfully.';
      });
    } catch (e) {
      String errorMessage = e.toString();
      if (errorMessage.contains('API key') || errorMessage.contains('not configured')) {
        setState(() {
          _status = 'API key not configured. Please set it in Settings.';
        });
        // Show dialog to enter API key
        _openSettings();
      } else {
        setState(() {
          _status = 'Error processing audio: $e';
        });
      }
    }
  }


  /// Build status text with clickable file paths
  Widget _buildStatusText(BuildContext context) {
    if (_transcriptPath != null || _summaryPath != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _status,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (_transcriptPath != null)
            _buildClickablePath(context, 'Transcript:', _transcriptPath!),
          if (_summaryPath != null)
            _buildClickablePath(context, 'Summary:', _summaryPath!),
        ],
      );
    }
    
    return Text(
      _status,
      style: Theme.of(context).textTheme.bodyLarge,
      textAlign: TextAlign.center,
    );
  }

  /// Build a clickable file path widget
  Widget _buildClickablePath(BuildContext context, String label, String filePath) {
    final directory = File(filePath).parent.path;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Text(
            '$label ',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => _openFileLocation(directory),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  filePath,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: Theme.of(context).colorScheme.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Copy text to clipboard and show feedback
  Future<void> _copyToClipboard(BuildContext context, String text, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$label copied to clipboard'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to copy: $e'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Open file location in system file manager
  Future<void> _openFileLocation(String directoryPath) async {
    try {
      // Try different file managers on Linux
      final commands = [
        ['xdg-open', directoryPath],
        ['nautilus', directoryPath],
        ['dolphin', directoryPath],
        ['thunar', directoryPath],
        ['pcmanfm', directoryPath],
      ];

      for (final command in commands) {
        try {
          final result = await Process.run(command[0], [command[1]]);
          if (result.exitCode == 0) {
            return; // Successfully opened
          }
        } catch (e) {
          // Try next command
          continue;
        }
      }
      
      // If all fail, show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file location: $directoryPath'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening file location: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text(
          'Meeting Notes',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        actions: [
          // Show indicator if API key is not set
          if (!_hasApiKey)
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: Icon(Icons.warning_amber, color: Colors.orange),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status and Record Button
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    _buildStatusText(context),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: _isRecording ? _stopRecording : _startRecording,
                      icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                      label: Text(_isRecording ? 'Stop Recording' : 'Start Recording'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        backgroundColor: _isRecording ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    if (_isRecording)
                      const Padding(
                        padding: EdgeInsets.only(top: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
                            SizedBox(width: 8),
                            Text('Recording in progress...'),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Transcript and Summary side by side
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Transcript Column (Left)
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Transcript',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy),
                                  tooltip: 'Copy transcript',
                                  onPressed: _transcript.isNotEmpty
                                      ? () => _copyToClipboard(context, _transcript, 'Transcript')
                                      : null,
                                ),
                              ],
                            ),
                            const Divider(),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Text(
                                  _transcript.isEmpty 
                                      ? 'Transcript will appear here...' 
                                      : _transcript,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Summary Column (Right)
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Summary',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy),
                                  tooltip: 'Copy summary',
                                  onPressed: _summary.isNotEmpty
                                      ? () => _copyToClipboard(context, _summary, 'Summary')
                                      : null,
                                ),
                              ],
                            ),
                            const Divider(),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Text(
                                  _summary.isEmpty 
                                      ? 'Summary will appear here after transcription...' 
                                      : _summary,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
