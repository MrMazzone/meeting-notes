import 'package:flutter/material.dart';
import '../services/config_service.dart';

class SettingsDialog extends StatefulWidget {
  final VoidCallback? onThemeChanged;
  
  const SettingsDialog({super.key, this.onThemeChanged});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyController = TextEditingController();
  bool _isLoading = false;
  bool _obscureText = true;
  String _selectedTheme = 'system';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
    _loadTheme();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    try {
      final apiKey = await ConfigService.getApiKey();
      if (apiKey != null && mounted) {
        _apiKeyController.text = apiKey;
      }
    } catch (e) {
      print('Error loading API key: $e');
    }
  }

  Future<void> _loadTheme() async {
    try {
      final theme = await ConfigService.getThemeMode();
      if (mounted) {
        setState(() {
          _selectedTheme = theme;
        });
      }
    } catch (e) {
      print('Error loading theme: $e');
    }
  }

  Future<void> _saveTheme(String theme) async {
    try {
      await ConfigService.setThemeMode(theme);
      setState(() {
        _selectedTheme = theme;
      });
      // Notify parent widget to update theme
      if (widget.onThemeChanged != null) {
        widget.onThemeChanged!();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save theme: $e'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _saveApiKey() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final apiKey = _apiKeyController.text.trim();
      await ConfigService.setApiKey(apiKey);

      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate success
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API key saved successfully'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save API key: $e'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.settings),
          SizedBox(width: 8),
          Text('Settings'),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Anthropic Claude API Key',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter your Anthropic API key to enable AI-powered meeting summaries.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _apiKeyController,
                obscureText: _obscureText,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-ant-...',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureText ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureText = !_obscureText;
                      });
                    },
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your API key';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _saveApiKey(),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  // Open Anthropic API key page
                  // Note: This would need url_launcher package for actual implementation
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Visit https://console.anthropic.com/ to get your API key'),
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Get API key from Anthropic'),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'Theme',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose your preferred app theme.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(
                    value: 'system',
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto, size: 18),
                  ),
                  ButtonSegment<String>(
                    value: 'light',
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode, size: 18),
                  ),
                  ButtonSegment<String>(
                    value: 'dark',
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode, size: 18),
                  ),
                ],
                selected: {_selectedTheme},
                onSelectionChanged: (Set<String> selection) {
                  if (selection.isNotEmpty) {
                    _saveTheme(selection.first);
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveApiKey,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
