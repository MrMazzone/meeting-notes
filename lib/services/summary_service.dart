import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config_service.dart';

class SummaryService {
  // Using Anthropic Claude API for summarization
  // API key is stored in app configuration (accessible via Settings)
  static const String _baseUrl = 'https://api.anthropic.com/v1/messages';
  
  // Token estimation: roughly 1 token = 4 characters
  static const int _charsPerToken = 4;
  static const int _chunkThresholdTokens = 150000; // ~600k characters
  static const int _chunkSizeTokens = 140000; // Leave some margin for prompt overhead
  
  /// Get the maximum output tokens for a specific model
  int _getMaxTokensForModel(String modelName) {
    // Claude 3.5 Sonnet supports up to 8192 tokens
    if (modelName.contains('claude-3-5-sonnet')) {
      return 8192;
    }
    // All other Claude 3 models (Opus, Sonnet, Haiku) support up to 4096 tokens
    return 4096;
  }
  
  /// Estimate token count from character count
  int _estimateTokens(String text) {
    return ((text.length / _charsPerToken).ceil());
  }
  
  /// Split transcript into chunks if it exceeds the threshold
  List<String> _chunkTranscript(String transcript) {
    final tokenCount = _estimateTokens(transcript);
    
    // If transcript is small enough, return as single chunk
    if (tokenCount <= _chunkThresholdTokens) {
      return [transcript];
    }
    
    // Calculate chunk size in characters
    final chunkSizeChars = _chunkSizeTokens * _charsPerToken;
    
    // Split into chunks
    final chunks = <String>[];
    int start = 0;
    
    while (start < transcript.length) {
      int end = (start + chunkSizeChars).clamp(0, transcript.length);
      
      // Try to break at a sentence boundary if possible
      if (end < transcript.length) {
        // Look for sentence endings within the last 20% of the chunk
        final searchStart = (end - chunkSizeChars * 0.2).round();
        final searchEnd = end;
        final searchText = transcript.substring(searchStart, searchEnd);
        
        // Find last sentence boundary (period, exclamation, question mark followed by space)
        final lastPeriod = searchText.lastIndexOf(RegExp(r'[.!?]\s+'));
        if (lastPeriod > 0) {
          end = searchStart + lastPeriod + 1;
        }
      }
      
      chunks.add(transcript.substring(start, end).trim());
      start = end;
    }
    
    return chunks;
  }
  
  Future<String> summarizeMeeting(String transcript) async {
    try {
      // Get API key from configuration
      final String? apiKey = await ConfigService.getApiKey();
      
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception(
          'Anthropic API key not configured. '
          'Please set your API key in Settings.'
        );
      }

      // Check if we need to chunk the transcript
      final chunks = _chunkTranscript(transcript);
      final isChunked = chunks.length > 1;
      
      // If chunked, summarize each chunk and then combine
      if (isChunked) {
        final chunkSummaries = <String>[];
        
        for (int i = 0; i < chunks.length; i++) {
          final chunkSummary = await _summarizeChunk(
            chunks[i],
            chunkNumber: i + 1,
            totalChunks: chunks.length,
          );
          chunkSummaries.add(chunkSummary);
        }
        
        // Combine chunk summaries into final summary
        return await _combineSummaries(chunkSummaries);
      }
      
      // Single chunk - summarize directly
      return await _summarizeChunk(transcript);
    } catch (e) {
      if (e.toString().contains('ANTHROPIC_API_KEY')) {
        rethrow;
      }
      throw Exception('Error generating summary: $e');
    }
  }
  
  /// Summarize a single chunk of transcript
  Future<String> _summarizeChunk(
    String chunk, {
    int? chunkNumber,
    int? totalChunks,
  }) async {
    try {
      // Get API key from configuration
      final String? apiKey = await ConfigService.getApiKey();
      
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception(
          'Anthropic API key not configured. '
          'Please set your API key in Settings.'
        );
      }
      
      final isPartOfLarger = chunkNumber != null && totalChunks != null;
      
      final prompt = isPartOfLarger
          ? '''Please provide a comprehensive summary of this section of a meeting transcript (Part $chunkNumber of $totalChunks). Include:
1. Key topics discussed
2. Decisions made
3. Action items with owners (if mentioned)
4. Important points and outcomes
5. Next steps

Meeting Transcript Section:
$chunk'''
          : '''Please provide a comprehensive summary of this meeting transcript. Include:
1. Key topics discussed
2. Decisions made
3. Action items with owners (if mentioned)
4. Important points and outcomes
5. Next steps

Meeting Transcript:
$chunk''';

      // Try multiple model names in order of preference
      final modelNames = [
        'claude-3-5-sonnet-20240620', // Claude 3.5 Sonnet (preferred)
        'claude-3-opus-20240229',     // Claude 3 Opus (fallback)
        'claude-3-sonnet-20240229',   // Claude 3 Sonnet (fallback)
        'claude-3-haiku-20240307',    // Claude 3 Haiku (fallback - fastest/cheapest)
      ];

      Exception? lastError;
      
      for (final modelName in modelNames) {
        try {
          final maxTokens = _getMaxTokensForModel(modelName);
          final requestBody = jsonEncode({
            'model': modelName,
            'max_tokens': maxTokens,
            'messages': [
              {
                'role': 'user',
                'content': prompt,
              }
            ],
          });

          final response = await http.post(
            Uri.parse(_baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: requestBody,
          );

          if (response.statusCode == 200) {
            final responseData = jsonDecode(response.body);
            final content = responseData['content'] as List;
            if (content.isNotEmpty && content[0]['type'] == 'text') {
              return content[0]['text'] as String;
            }
            throw Exception('Unexpected response format');
          } else if (response.statusCode == 404) {
            // Model not found, try next one
            lastError = Exception('Model $modelName not found');
            continue;
          } else if (response.statusCode == 400) {
            // Check if it's actually a context window error
            final errorBody = response.body.toLowerCase();
            final isContextError = errorBody.contains('context_length_exceeded') || 
                                   errorBody.contains('context_window_exceeded') ||
                                   errorBody.contains('maximum context length') ||
                                   errorBody.contains('context is too long');
            
            if (isContextError) {
              final tokenCount = _estimateTokens(chunk);
              // Only show context error if transcript is actually large
              if (tokenCount > 100000) {
                throw Exception(
                  'Transcript too long: Context window exceeded. '
                  'The transcript is approximately $tokenCount tokens, '
                  'which exceeds the model\'s context limit. '
                  'Try using a model with a larger context window or splitting the transcript manually.'
                );
              }
            }
            // Other 400 error, throw with original message
            throw Exception('Summary failed: ${response.statusCode} - ${response.body}');
          } else if (response.statusCode == 413) {
            // Request entity too large
            final tokenCount = _estimateTokens(chunk);
            throw Exception(
              'Request too large: The transcript is approximately $tokenCount tokens. '
              'Please try splitting the transcript manually or use a model with a larger context window.'
            );
          } else {
            // Other error, throw immediately
            throw Exception('Summary failed: ${response.statusCode} - ${response.body}');
          }
        } catch (e) {
          if (e.toString().contains('404') || e.toString().contains('not found')) {
            // Model not available, try next
            lastError = Exception('Model $modelName not found: $e');
            continue;
          } else {
            // Re-throw other errors immediately
            rethrow;
          }
        }
      }
      
      // If all models failed, throw the last error
      throw lastError ?? Exception('All Claude models unavailable. Please check your API key and account status.');
    } catch (e) {
      if (e.toString().contains('API key') || 
          e.toString().contains('Context window exceeded')) {
        rethrow;
      }
      throw Exception('Error generating summary: $e');
    }
  }
  
  /// Combine multiple chunk summaries into a final comprehensive summary
  Future<String> _combineSummaries(List<String> chunkSummaries) async {
    try {
      // Get API key from configuration
      final String? apiKey = await ConfigService.getApiKey();
      
      if (apiKey == null || apiKey.isEmpty) {
        // If no API key, just return concatenated summaries
        return chunkSummaries.join('\n\n---\n\n');
      }
      
      final combinedText = chunkSummaries.join('\n\n---\n\n');
      
      final prompt = '''The following are summaries from different sections of a long meeting transcript. 
Please provide a comprehensive, unified summary that combines all sections. Include:
1. Key topics discussed (across all sections)
2. Decisions made (consolidate duplicates)
3. Action items with owners (if mentioned, consolidate duplicates)
4. Important points and outcomes
5. Next steps

Section Summaries:
$combinedText''';

      // Try multiple model names in order of preference
      final modelNames = [
        'claude-3-5-sonnet-20240620', // Claude 3.5 Sonnet (preferred)
        'claude-3-opus-20240229',     // Claude 3 Opus (fallback)
        'claude-3-sonnet-20240229',   // Claude 3 Sonnet (fallback)
        'claude-3-haiku-20240307',    // Claude 3 Haiku (fallback - fastest/cheapest)
      ];
      
      for (final modelName in modelNames) {
        try {
          final maxTokens = _getMaxTokensForModel(modelName);
          final requestBody = jsonEncode({
            'model': modelName,
            'max_tokens': maxTokens,
            'messages': [
              {
                'role': 'user',
                'content': prompt,
              }
            ],
          });

          final response = await http.post(
            Uri.parse(_baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: requestBody,
          );

          if (response.statusCode == 200) {
            final responseData = jsonDecode(response.body);
            final content = responseData['content'] as List;
            if (content.isNotEmpty && content[0]['type'] == 'text') {
              return content[0]['text'] as String;
            }
            throw Exception('Unexpected response format');
          } else if (response.statusCode == 404) {
            // Model not found, try next one
            continue;
          } else if (response.statusCode == 400 || response.statusCode == 413) {
            // Context window exceeded - fallback to simple concatenation
            return chunkSummaries.join('\n\n---\n\n');
          } else {
            // Other error, try next model
            continue;
          }
        } catch (e) {
          if (e.toString().contains('404') || e.toString().contains('not found')) {
            // Model not available, try next
            continue;
          } else if (e.toString().contains('400') || e.toString().contains('413')) {
            // Context window exceeded - fallback to simple concatenation
            return chunkSummaries.join('\n\n---\n\n');
          } else {
            // Other error, try next model
            continue;
          }
        }
      }
      
      // If all models failed, fallback to simple concatenation
      return chunkSummaries.join('\n\n---\n\n');
    } catch (e) {
      // If combination fails, return concatenated summaries as fallback
      return chunkSummaries.join('\n\n---\n\n');
    }
  }
}
