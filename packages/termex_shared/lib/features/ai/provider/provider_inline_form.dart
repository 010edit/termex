/// Single-layer inline form for editing one provider's configuration.
/// Replaces the previous dialog-based flow so the entire AI settings page
/// works without nested popups.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/tokens.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/clickable.dart';
import '../local_ai/local_model_picker.dart';
import '../local_ai/server_status.dart';
import '../state/conversation_provider.dart';
import '../state/local_ai_provider.dart';
import '../state/provider_config_provider.dart';
import '../../settings/state/settings_provider.dart';
import 'provider_registry.dart';

class ProviderInlineForm extends ConsumerStatefulWidget {
  final AiProvider provider;
  final VoidCallback onClose;

  const ProviderInlineForm({
    super.key,
    required this.provider,
    required this.onClose,
  });

  @override
  ConsumerState<ProviderInlineForm> createState() => _ProviderInlineFormState();
}

class _ProviderInlineFormState extends ConsumerState<ProviderInlineForm> {
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _baseUrlCtrl;
  late TextEditingController _modelCtrl;
  late String _model;
  late int _contextLines;
  bool _obscureKey = true;
  String? _statusMessage;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    final meta = metaFor(widget.provider);
    final cfg = ref.read(providerConfigProvider).configs[widget.provider];
    _apiKeyCtrl = TextEditingController(text: cfg?.apiKey ?? '');
    _baseUrlCtrl = TextEditingController(
      text: cfg?.baseUrl ??
          (widget.provider == AiProvider.ollama
              ? 'http://localhost:11434'
              : ''),
    );
    final fallback =
        meta.models.isNotEmpty ? meta.models.first : '';
    _model = (cfg?.model.isNotEmpty ?? false) ? cfg!.model : fallback;
    _modelCtrl = TextEditingController(text: _model);
    _contextLines = cfg?.contextLines ?? 100;
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  /// Custom providers have no registry roster, so the model comes from the
  /// free-text field instead of the dropdown.
  String get _effectiveModel => metaFor(widget.provider).models.isEmpty
      ? _modelCtrl.text.trim()
      : _model;

  void _save() {
    final l10n = AppLocalizations.of(context);
    final model = _effectiveModel;
    if (model.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMessage = l10n.settingsAiSelectModelError;
      });
      return;
    }
    final config = AiProviderConfig(
      provider: widget.provider,
      model: model,
      apiKey: _apiKeyCtrl.text.trim().isEmpty ? null : _apiKeyCtrl.text.trim(),
      baseUrl:
          _baseUrlCtrl.text.trim().isEmpty ? null : _baseUrlCtrl.text.trim(),
      contextLines: _contextLines,
    );
    ref.read(providerConfigProvider.notifier).updateConfig(config);
    widget.onClose();
  }

  Future<void> _verify() async {
    final l10n = AppLocalizations.of(context);
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMessage = l10n.settingsAiApiKeyRequired;
      });
      return;
    }
    final model = _effectiveModel;
    if (model.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMessage = l10n.settingsAiSelectModelError;
      });
      return;
    }
    final ok = await ref.read(providerConfigProvider.notifier).verifyApiKey(
          widget.provider,
          key,
          baseUrl: _baseUrlCtrl.text.trim(),
          model: model,
        );
    if (!mounted) return;
    final err = ref.read(providerConfigProvider).verifyError;
    setState(() {
      _statusOk = ok;
      _statusMessage =
          ok ? l10n.settingsAiVerifySuccess : (err ?? l10n.settingsAiVerifyFailed);
    });
  }

  @override
  Widget build(BuildContext context) {
    final meta = metaFor(widget.provider);
    final cfgState = ref.watch(providerConfigProvider);
    final isLocal = widget.provider == AiProvider.localLlama;
    final l10n = AppLocalizations.of(context);

    return Container(
      decoration: BoxDecoration(
        color: context.colors.backgroundSecondary,
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(meta.description,
              style: TextStyle(
                  fontSize: 11, color: context.colors.textSecondary)),
          const SizedBox(height: 12),

          if (meta.requiresApiKey) ...[
            const _Label('API Key'),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    controller: _apiKeyCtrl,
                    hint: '${meta.label} API key',
                    obscure: _obscureKey,
                    suffix: Clickable(
                      onTap: () =>
                          setState(() => _obscureKey = !_obscureKey),
                      child: Icon(
                        _obscureKey
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 14,
                        color: context.colors.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SmallBtn(
                  label: cfgState.isVerifying ? '…' : l10n.settingsAiVerify,
                  onTap: cfgState.isVerifying ? null : _verify,
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],

          if (meta.requiresBaseUrl) ...[
            const _Label('Base URL'),
            _textField(
              controller: _baseUrlCtrl,
              hint: 'http://localhost:11434',
            ),
            const SizedBox(height: 10),
          ],

          // Model selector — local provider gets the embedded picker;
          // providers without a registry roster (Custom) get free text.
          _Label(l10n.aiConfigModel),
          if (isLocal)
            LocalModelPicker(
              selectedModelId: _model,
              onSelected: (id) => setState(() => _model = id),
            )
          else if (meta.models.isEmpty)
            _textField(
              controller: _modelCtrl,
              hint: 'gpt-4o-mini / qwen2.5:7b / your-model',
            )
          else
            _modelDropdown(meta.models),
          const SizedBox(height: 10),

          _Label(l10n.settingsAiTerminalContextLines),
          DropdownButtonFormField<int>(
            initialValue: _contextLines,
            isDense: true,
            dropdownColor: context.colors.backgroundSecondary,
            style:
                TextStyle(fontSize: 12, color: context.colors.textPrimary),
            decoration: _decoration(''),
            items: const [50, 100, 200, 500]
                .map((n) => DropdownMenuItem(
                    value: n, child: Text(l10n.settingsAiLinesUnit(n))))
                .toList(),
            onChanged: (v) => setState(() => _contextLines = v!),
          ),

          if (isLocal) ...[
            const SizedBox(height: 16),
            Divider(color: context.colors.border, height: 1),
            const SizedBox(height: 12),
            Text(l10n.settingsAiLlamaEngine,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.colors.textPrimary,
                )),
            const SizedBox(height: 10),
            const _LocalEngineSettings(),
            const SizedBox(height: 12),
            const _LocalEngineStatus(),
          ],

          if (_statusMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _statusMessage!,
              style: TextStyle(
                fontSize: 11,
                color: _statusOk
                    ? context.colors.success
                    : context.colors.danger,
              ),
            ),
          ],

          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _SmallBtn(label: l10n.commonCancel, onTap: widget.onClose),
              const SizedBox(width: 8),
              _SmallBtn(
                label: l10n.commonSave,
                primary: true,
                onTap: _save,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(fontSize: 12, color: context.colors.textPrimary),
      decoration: _decoration(hint, suffix: suffix),
    );
  }

  Widget _modelDropdown(List<String> models) {
    // Dedup the model list (defensive — registry should already be
    // unique, but a stale per-provider override could append a duplicate
    // and the DropdownButton asserts "Either zero or 2 or more
    // DropdownMenuItems were detected with the same value").
    final uniqueModels = models.toSet().toList(growable: false);
    final value = uniqueModels.contains(_model)
        ? _model
        : (uniqueModels.isNotEmpty ? uniqueModels.first : null);
    // If the saved cfg model isn't in the current registry list (e.g.
    // legacy "claude-3-5-sonnet-20241022" against a refreshed roster),
    // adopt the fallback right away so the next save persists a valid
    // identifier; without this `_model` keeps the stale value and the
    // assertion fires on the very next rebuild.
    if (value != null && value != _model) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _model != value) {
          setState(() => _model = value);
        }
      });
    }
    return DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      dropdownColor: context.colors.backgroundSecondary,
      style: TextStyle(fontSize: 12, color: context.colors.textPrimary),
      decoration: _decoration(''),
      items: uniqueModels
          .map((m) => DropdownMenuItem(value: m, child: Text(m)))
          .toList(),
      onChanged: (v) => setState(() => _model = v ?? _model),
    );
  }

  InputDecoration _decoration(String hint, {Widget? suffix}) =>
      InputDecoration(
        hintText: hint,
        hintStyle:
            TextStyle(fontSize: 12, color: context.colors.textSecondary),
        suffixIcon: suffix == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 8),
                child: suffix,
              ),
        suffixIconConstraints:
            const BoxConstraints(minHeight: 0, minWidth: 0),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: context.colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: context.colors.border),
        ),
      );
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

class _SmallBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  const _SmallBtn({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final bg = primary
        ? (disabled
            ? context.colors.primary.withValues(alpha: 0.5)
            : context.colors.primary)
        : context.colors.backgroundTertiary;
    final fg = primary ? Colors.white : context.colors.textPrimary;
    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: primary ? Colors.transparent : context.colors.border,
          ),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: fg)),
      ),
    );
  }
}

/// Engine port / threads / context-size — formerly in the standalone
/// LocalAiTab; lives inside the inline form when Local AI is selected.
class _LocalEngineSettings extends ConsumerWidget {
  const _LocalEngineSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).settings;
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          context,
          l10n.settingsAiServerPort,
          _NumberField(
            value: settings.localAiPort,
            onChanged: (v) =>
                notifier.update(settings.copyWith(localAiPort: v)),
          ),
        ),
        _row(
          context,
          l10n.settingsAiInferenceThreads,
          _NumberField(
            value: settings.localAiThreads,
            onChanged: (v) =>
                notifier.update(settings.copyWith(localAiThreads: v)),
          ),
        ),
        _row(
          context,
          l10n.settingsAiContextWindow,
          _NumberField(
            value: settings.localAiContextSize,
            onChanged: (v) =>
                notifier.update(settings.copyWith(localAiContextSize: v)),
          ),
        ),
        _row(
          context,
          l10n.settingsAiAutoStartEngine,
          Switch(
            value: settings.localAiAutoStart,
            onChanged: (v) =>
                notifier.update(settings.copyWith(localAiAutoStart: v)),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 12, color: context.colors.textSecondary)),
          ),
          child,
        ],
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _NumberField({required this.value, required this.onChanged});

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(covariant _NumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && _ctrl.text != '${widget.value}') {
      _ctrl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 12, color: context.colors.textPrimary),
        onSubmitted: (s) {
          final v = int.tryParse(s);
          if (v != null && v > 0) widget.onChanged(v);
        },
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: context.colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: context.colors.border),
          ),
        ),
      ),
    );
  }
}

class _LocalEngineStatus extends ConsumerWidget {
  const _LocalEngineStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localAiProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LocalAiServerStatus(),
        if (state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              state.errorMessage!,
              style:
                  TextStyle(fontSize: 11, color: context.colors.danger),
            ),
          ),
      ],
    );
  }
}
