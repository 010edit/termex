import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/tokens.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/clickable.dart';
import '../state/ai_stream_provider.dart';
import '../state/provider_config_provider.dart';

/// Multi-line text input for AI messages.
///
/// Send on Enter, Shift+Enter inserts newline. Shows character count and
/// cancel button during generation.
class AiInput extends ConsumerStatefulWidget {
  final String? terminalContext;
  const AiInput({super.key, this.terminalContext});

  @override
  ConsumerState<AiInput> createState() => _AiInputState();
}

class _AiInputState extends ConsumerState<AiInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final has = _ctrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    setState(() => _hasText = false);
    await ref.read(aiStreamProvider.notifier).send(
          userContent: text,
          terminalContext: widget.terminalContext,
        );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final streamState = ref.watch(aiStreamProvider);
    // Watched for the rebuild, not the value — the input's enabled state
    // follows whichever provider is active.
    ref.watch(providerConfigProvider);
    final isGenerating = streamState.isGenerating;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: context.colors.backgroundSecondary,
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rate limit warning
          if (streamState.rateLimitRetryAfterSeconds != null)
            _RateLimitBanner(
              seconds: streamState.rateLimitRetryAfterSeconds!,
              onRetry: () => ref
                  .read(aiStreamProvider.notifier)
                  .retry(terminalContext: widget.terminalContext),
            ),
          // Request failure (auth, endpoint, timeout, ...). Without this
          // the assistant bubble used to sit on the typing animation with
          // no explanation of why no reply arrived.
          if (streamState.errorMessage != null)
            _ErrorBanner(
              message: streamState.errorMessage!,
              onRetry: () => ref
                  .read(aiStreamProvider.notifier)
                  .retry(terminalContext: widget.terminalContext),
            ),
          // Input row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: KeyboardListener(
                  focusNode: FocusNode(skipTraversal: true),
                  onKeyEvent: (event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed &&
                        !isGenerating) {
                      _send();
                    }
                  },
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    enabled: !isGenerating,
                    maxLines: 6,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: '询问 AI… (Enter 发送，Shift+Enter 换行)',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: context.colors.textSecondary,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: context.colors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: context.colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: context.colors.primary),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    style: TextStyle(
                      fontSize: 13,
                      color: context.colors.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (isGenerating)
                _CancelButton(
                  onTap: () => ref.read(aiStreamProvider.notifier).cancel(),
                )
              else
                _SendButton(enabled: _hasText, onTap: _send),
            ],
          ),
          // v0.77.0 PC final parity: removed the redundant
          // "${provider} · ${model} · 上下文 N 行" footer — the same
          // metadata is already shown in the top-right Provider Switcher
          // chip in the AiPanel toolbar.
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _SendButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: enabled
              ? context.colors.primary
              : context.colors.backgroundTertiary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.send_rounded,
          size: 18,
          color: enabled ? Colors.white : context.colors.textSecondary,
        ),
      ),
    );
  }
}

class _CancelButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CancelButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: context.colors.danger.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: context.colors.danger.withValues(alpha: 0.4)),
        ),
        child: Icon(
          Icons.stop_rounded,
          size: 20,
          color: context.colors.danger,
        ),
      ),
    );
  }
}

class _RateLimitBanner extends StatelessWidget {
  final int seconds;
  final VoidCallback onRetry;
  const _RateLimitBanner({required this.seconds, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border:
            Border.all(color: context.colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 14, color: context.colors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '达到速率限制，请 $seconds 秒后重试',
              style:
                  TextStyle(fontSize: 12, color: context.colors.warning),
            ),
          ),
          Clickable(
            onTap: onRetry,
            child: Text(
              '重试',
              style: TextStyle(
                fontSize: 12,
                color: context.colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: context.colors.danger.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 14, color: context.colors.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: context.colors.danger),
            ),
          ),
          const SizedBox(width: 8),
          Clickable(
            onTap: onRetry,
            child: Text(
              l10n.commonRetry,
              style: TextStyle(
                fontSize: 12,
                color: context.colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
