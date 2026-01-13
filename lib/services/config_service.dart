import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';

class ConfigService {
  static const String _configFileName = 'config.json';
  static const String _configKey = 'anthropic_api_key';
  static const String _themeKey = 'theme_mode';
  
  /// Get the configuration directory path
  static Future<Directory> _getConfigDirectory() async {
    if (Platform.isLinux) {
      // Use XDG config directory: ~/.config/meeting-notes
      final homeDir = Platform.environment['HOME'] ?? '';
      if (homeDir.isNotEmpty) {
        final configDir = Directory('$homeDir/.config/meeting-notes');
        if (!await configDir.exists()) {
          await configDir.create(recursive: true);
        }
        return configDir;
      }
    }
    
    // Fallback to application support directory
    final appSupportDir = await getApplicationSupportDirectory();
    return appSupportDir;
  }
  
  /// Get the full path to the config file
  static Future<File> _getConfigFile() async {
    final configDir = await _getConfigDirectory();
    return File('${configDir.path}/$_configFileName');
  }
  
  /// Load configuration from file
  static Future<Map<String, dynamic>> _loadConfig() async {
    try {
      final configFile = await _getConfigFile();
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return json;
      }
    } catch (e) {
      print('Error loading config: $e');
    }
    return {};
  }
  
  /// Save configuration to file
  static Future<void> _saveConfig(Map<String, dynamic> config) async {
    try {
      final configFile = await _getConfigFile();
      final content = jsonEncode(config);
      await configFile.writeAsString(content);
      
      // Set file permissions to 600 (read/write for owner only) on Linux
      if (Platform.isLinux) {
        try {
          await Process.run('chmod', ['600', configFile.path]);
        } catch (e) {
          // Ignore chmod errors - file will still be saved
        }
      }
    } catch (e) {
      print('Error saving config: $e');
      rethrow;
    }
  }
  
  /// Get the Anthropic API key
  static Future<String?> getApiKey() async {
    try {
      final config = await _loadConfig();
      return config[_configKey] as String?;
    } catch (e) {
      print('Error getting API key: $e');
      return null;
    }
  }
  
  /// Set the Anthropic API key
  static Future<void> setApiKey(String key) async {
    try {
      final config = await _loadConfig();
      config[_configKey] = key;
      await _saveConfig(config);
    } catch (e) {
      print('Error setting API key: $e');
      rethrow;
    }
  }
  
  /// Check if API key exists
  static Future<bool> hasApiKey() async {
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }
  
  /// Clear the API key
  static Future<void> clearApiKey() async {
    try {
      final config = await _loadConfig();
      config.remove(_configKey);
      await _saveConfig(config);
    } catch (e) {
      print('Error clearing API key: $e');
      rethrow;
    }
  }
  
  /// Get the config file path (for debugging/info)
  static Future<String> getConfigPath() async {
    final configFile = await _getConfigFile();
    return configFile.path;
  }
  
  /// Get the theme mode preference
  /// Returns "system", "light", or "dark". Defaults to "system" if not set.
  static Future<String> getThemeMode() async {
    try {
      final config = await _loadConfig();
      final theme = config[_themeKey] as String?;
      if (theme != null && ['system', 'light', 'dark'].contains(theme)) {
        return theme;
      }
      return 'system'; // Default to system theme
    } catch (e) {
      print('Error getting theme mode: $e');
      return 'system';
    }
  }
  
  /// Set the theme mode preference
  /// Valid values: "system", "light", or "dark"
  static Future<void> setThemeMode(String mode) async {
    if (!['system', 'light', 'dark'].contains(mode)) {
      throw ArgumentError('Theme mode must be "system", "light", or "dark"');
    }
    try {
      final config = await _loadConfig();
      config[_themeKey] = mode;
      await _saveConfig(config);
    } catch (e) {
      print('Error setting theme mode: $e');
      rethrow;
    }
  }
}
