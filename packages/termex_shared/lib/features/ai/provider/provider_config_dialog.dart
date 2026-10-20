import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/tokens.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/clickable.dart';
import '../state/conversation_provider.dart';
import '../state/provider_config_provider.dart';
import 'model_list_service.dart';
import 'provider_registry.dart';

/// Dialog to configure API key, model, and options for one AI provider.
Future<void> showProviderConfigDialog(
  BuildContext context,
  AiProvider provider,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _ProviderConfigDialog(provider: provider),
  );
}

class _ProviderConfigDialog extends ConsumerStatefulWidget {
  final AiProvider provider;
  const _ProviderConfigDialog({required this.provider});

  @override
  ConsumerState<_ProviderConfigDialog> createState() =>
      _ProviderConfigDialogState();
}

class _ProviderConfigDialogState extends ConsumerState<_ProviderConfigDialog> {
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _modelCtrl;
  late String _selectedModel;
  late int _contextLines;
  bool _obscureKey = true;

  /// Model IDs fetched from a Custom provider's `/models` endpoint.
  List<String> _availableModels = const [];
  String? _modelsBaseUrl;
  bool _isLoadingModels = false;
  String? _modelListError;

  @override
  void initState() {
    super.initState();
    final config = ref.read(providerConfigProvider).configs[widget.provider] ??
        AiProviderConfig(
          provider: widget.provider,
          model: kDefaultModel[widget.provider]!,
        );
    _apiKeyCtrl = TextEditingController(text: config.apiKey ?? '');
    _baseUrlCtrl = TextEditingController(
      text: config.baseUrl ?? (widget.provider == AiProvider.ollama ? 'http://localhost:11434' : ''),
    );
    _selectedModel = config.model;
    _modelCtrl = TextEditingController(text: _selectedModel);
    _contextLines = config.contextLines;
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  String get _effectiveModel => metaFor(widget.provider).models.isEmpty
      ? (_availableModels.isEmpty ? _modelCtrl.text.trim() : _selectedModel)
      : _selectedModel;

  void _save() {
    final model = _effectiveModel;
    if (model.isEmpty) return;
    final config = AiProviderConfig(
      provider: widget.provider,
      model: model,
      apiKey: _apiKeyCtrl.text.trim().isEmpty ? null : _apiKeyCtrl.text.trim(),
      baseUrl: _baseUrlCtrl.text.trim().isEmpty ? null : _baseUrlCtrl.text.trim(),
      contextLines: _contextLines,
    );
    ref.read(providerConfigProvider.notifier).updateConfig(config);
    Navigator.of(context).pop();
  }

  Future<void> _verify() async {
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) return;

    ref.read(providerConfigProvider.notifier).clearVerifyError();
    final meta = metaFor(widget.provider);
    final baseUrl = _baseUrlCtrl.text.trim();

    // Custom / OpenAI-compatible endpoints: load `/models` first so the user
    // gets a dropdown instead of an empty model field.
    if (meta.models.isEmpty) {
      final needsFetch = _availableModels.isEmpty || _modelsBaseUrl != baseUrl;
      if (needsFetch) {
        setState(() {
          _isLoadingModels = true;
          _modelListError = null;
        });
        try {
          final models = await fetchOpenAiModels(
            baseUrl: baseUrl,
            apiKey: key,
          );
          if (!mounted) return;
          setState(() {
            _availableModels = models;
            _modelsBaseUrl = baseUrl;
            if (_selectedModel.isEmpty || !models.contains(_selectedModel)) {
              _selectedModel = models.first;
              _modelCtrl.text = _selectedModel;
            }
          });
        } catch (e) {
          if (!mounted) return;
          setState(() => _modelListError = e.toString());
        } finally {
          if (mounted) setState(() => _isLoadingModels = false);
        }
        return;
      }
    }

    final model = _effectiveModel;
    if (model.isEmpty) return;
    await ref.read(providerConfigProvider.notifier).verifyApiKey(
          widget.provider,
          key,
          baseUrl: baseUrl,
          model: model,
        );
  }

  @override
  Widget build(BuildContext context) {
    final meta = metaFor(widget.provider);
    final configState = ref.watch(providerConfigProvider);
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      backgroundColor: context.colors.backgroundSecondary,
      title: Text(
        l10n.settingsAiConfigureTitle(meta.label),
        style:
            TextStyle(fontSize: 15, color: context.colors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meta.description,
                style: TextStyle(
                    fontSize: 12, color: context.colors.textSecondary),
              ),
              const SizedBox(height: 16),

              // API key
              if (meta.requiresApiKey) ...[
                const _Label('API Key'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _apiKeyCtrl,
                        obscureText: _obscureKey,
                        decoration: _inputDecoration(
                          hint: '${meta.label} API key',
                          suffix: Clickable(
                            onTap: () =>
                                setState(() => _obscureKey = !_obscureKey),
                            child: Icon(
                              _obscureKey
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 16,
                              color: context.colors.textSecondary,
                            ),
                          ),
                        ),
                        style: _inputStyle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _VerifyButton(
                      isVerifying: configState.isVerifying || _isLoadingModels,
                      onTap: _verify,
                    ),
                  ],
                ),
                if (configState.verifyError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      configState.verifyError!,
                      style: TextStyle(
                          fontSize: 11, color: context.colors.danger),
                    ),
                  ),
                const SizedBox(height: 12),
              ],

              // Base URL
              if (meta.requiresBaseUrl) ...[
                const _Label('Base URL'),
                TextField(
                  controller: _baseUrlCtrl,
                  decoration: _inputDecoration(
                    hint: widget.provider == AiProvider.custom
                        ? 'http://host:port/v1'
                        : 'http://localhost:11434',
                  ),
                  style: _inputStyle,
                ),
                const SizedBox(height: 12),
              ],

              // Model selector — Custom starts as free text and becomes a
              // dropdown after `/models` is fetched.
              _Label(l10n.aiConfigModel),
              if (meta.models.isEmpty) ...[
                if (_availableModels.isEmpty)
                  TextField(
                    controller: _modelCtrl,
                    decoration: _inputDecoration(
                      hint: 'gpt-4o-mini / qwen2.5:7b / your-model',
                    ),
                    style: _inputStyle,
                  )
                else
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'dialog-custom-models-${(_modelsBaseUrl ?? '')}-${_availableModels.join('|')}',
                    ),
                    initialValue: _availableModels.contains(_selectedModel)
                        ? _selectedModel
                        : null,
                    dropdownColor: context.colors.backgroundSecondary,
                    style: _inputStyle,
                    decoration: _inputDecoration(hint: ''),
                    hint: Text(
                      l10n.settingsAiSelectModelError,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colors.textSecondary,
                      ),
                    ),
                    items: _availableModels
                        .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (v) => setState(() {
                      _selectedModel = v ?? '';
                      _modelCtrl.text = _selectedModel;
                      _modelListError = null;
                    }),
                  ),
                if (_modelListError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _modelListError!,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.colors.danger,
                    ),
                  ),
                ],
              ] else
                DropdownButtonFormField<String>(
                  initialValue: _selectedModel,
                  dropdownColor: context.colors.backgroundSecondary,
                  style: _inputStyle,
                  decoration: _inputDecoration(hint: ''),
                  items: meta.models
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedModel = v!),
                ),
              const SizedBox(height: 12),

              // Context lines
              _Label(l10n.settingsAiTerminalContextLines),
              DropdownButtonFormField<int>(
                initialValue: _contextLines,
                dropdownColor: context.colors.backgroundSecondary,
                style: _inputStyle,
                decoration: _inputDecoration(hint: ''),
                items: const [50, 100, 200, 500]
                    .map((n) => DropdownMenuItem(
                        value: n, child: Text(l10n.settingsAiLinesUnit(n))))
                    .toList(),
                onChanged: (v) => setState(() => _contextLines = v!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel,
              style: TextStyle(color: context.colors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: context.colors.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({required String hint, Widget? suffix}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: context.colors.textSecondary, fontSize: 12),
        suffixIcon: suffix,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: context.colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: context.colors.border),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        isDense: true,
      );

  TextStyle get _inputStyle =>
      TextStyle(fontSize: 12, color: context.colors.textPrimary);
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.colors.textSecondary,
        ),
      ),
    );
  }
}

class _VerifyButton extends StatelessWidget {
  final bool isVerifying;
  final VoidCallback onTap;
  const _VerifyButton({required this.isVerifying, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Clickable(
      onTap: isVerifying ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: isVerifying
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.colors.primary,
                ),
              )
            : Text(
                l10n.settingsAiVerify,
                style: TextStyle(
                    fontSize: 12, color: context.colors.textSecondary),
              ),
      ),
    );
  }
}
