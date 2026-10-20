import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termex_bridge/api.dart' as bridge;
import 'package:termex_bridge/models.dart' as bridge_models;

import '../../task/task_completion_sink.dart';
import 'ai_pricing.dart';
import 'conversation_provider.dart';
import 'provider_config_provider.dart';

// ─── State ────────────────────────────────────────────────────────────────────

enum GenerationStatus { idle, generating, cancelled, error }

class AiStreamState {
  final GenerationStatus status;
  final String? activeMessageId;
  final String? errorMessage;
  final int? rateLimitRetryAfterSeconds;

  const AiStreamState({
    this.status = GenerationStatus.idle,
    this.activeMessageId,
    this.errorMessage,
    this.rateLimitRetryAfterSeconds,
  });

  bool get isGenerating => status == GenerationStatus.generating;

  AiStreamState copyWith({
    GenerationStatus? status,
    String? activeMessageId,
    String? errorMessage,
    int? rateLimitRetryAfterSeconds,
    bool clearError = false,
    bool clearRateLimit = false,
  }) =>
      AiStreamState(
        status: status ?? this.status,
        activeMessageId: activeMessageId ?? this.activeMessageId,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        rateLimitRetryAfterSeconds: clearRateLimit
            ? null
            : (rateLimitRetryAfterSeconds ?? this.rateLimitRetryAfterSeconds),
      );
}

// ─── Notifier ────────────────────────────────────────────────────────────────

class AiStreamNotifier extends Notifier<AiStreamState> {
  StreamSubscription<dynamic>? _sub;

  /// v0.79.48: chunk polling timer. The Rust `aiSendMessage` returns
  /// immediately with the message_id; the actual response streams via
  /// `pollAiChunks(conversationId)` in a per-conversation queue. Pre-
  /// v0.79.48 the dart side wrongly treated the message_id as the
  /// response text — fixed by spinning up a 50ms Timer.periodic that
  /// drains chunks and appends each delta to the conversation. The
  /// loop self-terminates on `done: true` or `error != null`.
  Timer? _pollTimer;
  int _accumulatedLength = 0;

  @override
  AiStreamState build() {
    ref.onDispose(_cleanup);
    return const AiStreamState();
  }

  /// Redact lines that look like password prompts before sending to AI.
  @visibleForTesting
  static String redactSensitive(String text) => _redactSensitive(text);

  @visibleForTesting
  static String buildContext(String raw, int maxLines) => _buildContext(raw, maxLines);

  /// Map the Dart-side config onto the FRB DTO. Kept as a pure function so a
  /// regression like "Custom loses its apiKey/baseUrl on send" is testable
  /// without a running Rust bridge.
  @visibleForTesting
  static bridge_models.AiProviderConfig bridgeConfigFor(AiProviderConfig config) =>
      bridge_models.AiProviderConfig(
        provider: switch (config.provider) {
          AiProvider.claude => bridge_models.AiProvider.claude,
          AiProvider.openAi => bridge_models.AiProvider.openAi,
          AiProvider.gemini => bridge_models.AiProvider.gemini,
          AiProvider.ollama => bridge_models.AiProvider.ollama,
          AiProvider.localLlama => bridge_models.AiProvider.localLlama,
          AiProvider.deepSeek => bridge_models.AiProvider.deepSeek,
          AiProvider.grok => bridge_models.AiProvider.grok,
          AiProvider.mistral => bridge_models.AiProvider.mistral,
          AiProvider.glm => bridge_models.AiProvider.glm,
          AiProvider.minimax => bridge_models.AiProvider.minimax,
          AiProvider.doubao => bridge_models.AiProvider.doubao,
          AiProvider.bailian => bridge_models.AiProvider.bailian,
          AiProvider.custom => bridge_models.AiProvider.custom,
        },
        model: config.model,
        apiKey: config.apiKey,
        baseUrl: config.baseUrl,
        contextLines: config.contextLines,
      );

  static String _redactSensitive(String text) {
    return text.split('\n')
        .map((line) {
          final lower = line.toLowerCase();
          if (lower.contains('password:') ||
              lower.contains('passphrase:') ||
              lower.contains('password for')) {
            return '[REDACTED]';
          }
          return line;
        })
        .join('\n');
  }

  /// Truncate [raw] to [maxLines] lines, each at most 500 characters.
  static String _buildContext(String raw, int maxLines) {
    final lines = raw.split('\n');
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    return lines.sublist(start).map((l) {
      if (l.length > 500) return '${l.substring(0, 500)}[...截断]';
      return l;
    }).join('\n');
  }

  /// Send a user message and begin streaming the AI reply.
  ///
  /// [terminalContext] is the last N lines from the active terminal pane;
  /// sensitive lines are redacted before being sent to the provider.
  Future<void> send({
    required String userContent,
    String? terminalContext,
  }) async {
    if (state.isGenerating) return;

    final convNotifier = ref.read(conversationProvider.notifier);
    final config = ref.read(providerConfigProvider).activeConfig;

    // Ensure there is an active conversation.
    final convState = ref.read(conversationProvider);
    if (convState.activeConversationId == null) {
      convNotifier.createConversation(
        provider: config.provider,
        model: config.model,
      );
    }

    convNotifier.addUserMessage(userContent);
    final replyId = convNotifier.beginAssistantReply();

    state = state.copyWith(
      status: GenerationStatus.generating,
      activeMessageId: replyId,
      clearError: true,
      clearRateLimit: true,
    );

    // Redact sensitive lines and apply context line limit before sending.
    final safeContext = terminalContext == null
        ? null
        : _redactSensitive(_buildContext(terminalContext, config.contextLines));

    final conversationId = ref.read(conversationProvider).activeConversationId ?? '';
    try {
      // The chat path must carry the same credentials as the form /
      // Verify path. Omitting these made Custom providers fall back to
      // the OpenAI default base URL with an empty key, so every message
      // failed before reaching the user's gateway.
      final bridgeConfig = bridgeConfigFor(config);
      // v0.79.48: aiSendMessage returns the message_id; the actual
      // response streams via STREAM_CHUNKS keyed by conversation_id.
      // The pre-v0.79.48 code treated message_id as the response text
      // (wrong) — fixed by spinning up a poll loop below. The send call
      // itself returns immediately so an error here is a setup failure
      // (bad config, no network, etc), not a streaming failure.
      await bridge.aiSendMessage(
        conversationId: conversationId,
        content: userContent,
        config: bridgeConfig,
        terminalContext: safeContext,
      );
      _accumulatedLength = 0;
      _startPolling(
        convNotifier: convNotifier,
        conversationId: conversationId,
        replyId: replyId,
        config: config,
      );
    } catch (e) {
      _markFailed(convNotifier, replyId, e.toString());
      state = state.copyWith(
        status: GenerationStatus.error,
        activeMessageId: null,
        errorMessage: e.toString(),
      );
      _emitCompletion(
        conversationId: conversationId,
        replyId: replyId,
        kind: 'ai.completion.failed',
        success: false,
        config: config,
        errorMessage: e.toString(),
      );
    }
  }

  /// Stop the typing indicator and surface the failure in the transcript.
  /// Without this the assistant placeholder stays empty, so the bubble keeps
  /// rendering the three-dot animation forever even though the request died.
  void _markFailed(
    ConversationNotifier convNotifier,
    String replyId,
    String error,
  ) {
    if (error.isNotEmpty) {
      convNotifier.appendDelta(replyId, '\n\n$error');
    }
    convNotifier.finalizeReply(replyId);
  }

  /// v0.79.48: drain chunks every 50 ms. Self-terminates on `done` or
  /// `error` chunk. Robust to concurrent dispose / cancel: every tick
  /// checks `mounted-like` state via `_pollTimer != null` before
  /// touching providers.
  void _startPolling({
    required ConversationNotifier convNotifier,
    required String conversationId,
    required String replyId,
    required AiProviderConfig config,
  }) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) async {
      // Cancelled between scheduling and firing — bail.
      if (_pollTimer != timer) {
        timer.cancel();
        return;
      }
      List<bridge_models.AiChunkDto> chunks;
      try {
        chunks = await bridge.pollAiChunks(conversationId: conversationId);
      } catch (e) {
        _stopPolling();
        _markFailed(convNotifier, replyId, e.toString());
        state = state.copyWith(
          status: GenerationStatus.error,
          activeMessageId: null,
          errorMessage: e.toString(),
        );
        _emitCompletion(
          conversationId: conversationId,
          replyId: replyId,
          kind: 'ai.completion.failed',
          success: false,
          config: config,
          errorMessage: e.toString(),
        );
        return;
      }
      if (chunks.isEmpty) return;
      for (final c in chunks) {
        if (c.error != null) {
          _stopPolling();
          _markFailed(convNotifier, replyId, c.error!);
          state = state.copyWith(
            status: GenerationStatus.error,
            activeMessageId: null,
            errorMessage: c.error,
          );
          _emitCompletion(
            conversationId: conversationId,
            replyId: replyId,
            kind: 'ai.completion.failed',
            success: false,
            config: config,
            errorMessage: c.error,
          );
          return;
        }
        if (c.delta.isNotEmpty) {
          convNotifier.appendDelta(replyId, c.delta);
          _accumulatedLength += c.delta.length;
        }
        if (c.done) {
          _stopPolling();
          convNotifier.finalizeReply(
            replyId,
            tokensIn: c.tokensIn?.toInt() ?? 0,
            tokensOut: c.tokensOut?.toInt() ?? 0,
          );
          state = state.copyWith(
            status: GenerationStatus.idle,
            activeMessageId: null,
          );
          _emitCompletion(
            conversationId: conversationId,
            replyId: replyId,
            kind: 'ai.completion.succeeded',
            success: true,
            config: config,
            responseLength: _accumulatedLength,
            // v0.79.49: tokens reported on the done chunk by most
            // providers. Skip when null/zero to let the localizer fall
            // back to the no-tokens variant.
            tokensIn: c.tokensIn?.toInt(),
            tokensOut: c.tokensOut?.toInt(),
          );
          return;
        }
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Cancel the current in-progress generation.
  Future<void> cancel() async {
    if (!state.isGenerating) return;
    final cancelledReplyId = state.activeMessageId;
    // v0.79.48: stop the chunk poll loop before tell Rust to abort —
    // otherwise an in-flight poll could still emit a stale done event.
    _stopPolling();
    await _sub?.cancel();
    _sub = null;
    final conversationId = ref.read(conversationProvider).activeConversationId;
    if (conversationId != null) {
      try {
        bridge.aiCancelGeneration(conversationId: conversationId);
      } catch (_) {}
    }
    state = state.copyWith(
      status: GenerationStatus.cancelled,
      activeMessageId: null,
    );
    if (conversationId != null && cancelledReplyId != null) {
      final config = ref.read(providerConfigProvider).activeConfig;
      _emitCompletion(
        conversationId: conversationId,
        replyId: cancelledReplyId,
        kind: 'ai.completion.cancelled',
        success: false,
        config: config,
      );
    }
  }

  /// v0.79.30: surface a generation's terminal state through the cross-
  /// package [TaskCompletionSink] so the mobile shell can mirror it into
  /// the [TaskEventBus] (and from there → local notification + history).
  /// Desktop builds register no sink — emission is a no-op.
  void _emitCompletion({
    required String conversationId,
    required String replyId,
    required String kind,
    required bool success,
    required AiProviderConfig config,
    int? responseLength,
    int? tokensIn,
    int? tokensOut,
    String? errorMessage,
  }) {
    final conversation = ref
        .read(conversationProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final providerLabel = _providerLabel(config.provider);
    final modelLabel = config.model.isNotEmpty ? config.model : providerLabel;
    final convTitle = conversation?.title?.trim();
    final taskTitle = convTitle == null || convTitle.isEmpty
        ? success
            ? 'AI reply from $modelLabel'
            : kind.endsWith('.cancelled')
                ? 'AI generation cancelled'
                : 'AI generation failed'
        : success
            ? '$convTitle — reply from $modelLabel'
            : kind.endsWith('.cancelled')
                ? '$convTitle — cancelled'
                : '$convTitle — failed';
    // v0.79.49 / v0.79.50: enrich English fallback summary with tokens
    // and (if model is priced) USD cost. Mobile sink falls through to
    // localized ARB variant via main.dart `_localizeAi`; non-mobile /
    // no-localizer paths render this fallback verbatim.
    final hasTokens = (tokensIn ?? 0) > 0 || (tokensOut ?? 0) > 0;
    final isSelfHosted = config.provider == AiProvider.ollama ||
        config.provider == AiProvider.localLlama;
    final costUsd = hasTokens
        ? estimateCostUsd(
            model: config.model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            isSelfHosted: isSelfHosted,
          )
        : null;
    final hasCost = costUsd != null && costUsd > 0;
    final summary = success
        ? responseLength != null
            ? hasCost
                ? 'Response generated ($responseLength chars · ↑${tokensIn ?? 0} ↓${tokensOut ?? 0} tokens · ${formatCostUsd(costUsd)})'
                : hasTokens
                    ? 'Response generated ($responseLength chars · ↑${tokensIn ?? 0} ↓${tokensOut ?? 0} tokens)'
                    : 'Response generated ($responseLength chars)'
            : 'Response generated'
        : kind.endsWith('.cancelled')
            ? 'Generation cancelled'
            : 'Generation failed${errorMessage == null ? '' : ' — $errorMessage'}';
    TaskCompletionSink.emit(TaskCompletionPayload(
      taskId: 'ai-$conversationId-$replyId',
      title: taskTitle,
      summary: summary,
      success: success,
      kind: kind,
      data: {
        'conversationId': conversationId,
        'replyId': replyId,
        'conversationTitle': convTitle ?? '',
        'provider': providerLabel,
        'model': modelLabel,
        if (responseLength != null) 'responseLength': responseLength,
        // v0.79.49: tokens come from the provider's done chunk when
        // available (Claude/OpenAI/Gemini typically; Ollama / local
        // models often report 0). The localizer picks the with-tokens
        // ARB variant when both are non-zero.
        if (tokensIn != null) 'tokensIn': tokensIn,
        if (tokensOut != null) 'tokensOut': tokensOut,
        // v0.79.50: USD cost estimate from ai_pricing static table.
        // Null when the model isn't priced — localizer falls back to
        // tokens-only / length-only variant.
        if (costUsd != null) 'costUsd': costUsd,
        if (costUsd != null) 'costUsdFormatted': formatCostUsd(costUsd),
        if (errorMessage != null) 'errorMessage': errorMessage,
      },
    ));
  }

  static String _providerLabel(AiProvider p) => switch (p) {
        AiProvider.claude => 'Claude',
        AiProvider.openAi => 'OpenAI',
        AiProvider.gemini => 'Gemini',
        AiProvider.ollama => 'Ollama',
        AiProvider.localLlama => 'Local Llama',
        AiProvider.deepSeek => 'DeepSeek',
        AiProvider.grok => 'Grok',
        AiProvider.mistral => 'Mistral',
        AiProvider.glm => 'GLM',
        AiProvider.minimax => 'MiniMax',
        AiProvider.doubao => 'Doubao',
        AiProvider.bailian => '百炼',
        AiProvider.custom => 'Custom',
      };

  /// Retry the last request (used when a rate-limit error occurred).
  Future<void> retry({String? terminalContext}) async {
    final msgs = ref.read(conversationProvider).activeMessages;
    if (msgs.isEmpty) return;
    final lastUser = msgs.lastWhere(
      (m) => m.role == MessageRole.user,
      orElse: () => msgs.last,
    );
    await send(userContent: lastUser.content, terminalContext: terminalContext);
  }

  /// Cancels the in-flight stream. Registered on disposal in [build] —
  /// it existed but nothing called it, so a provider torn down mid-stream
  /// left its subscription running.
  void _cleanup() {
    _sub?.cancel();
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

final aiStreamProvider =
    NotifierProvider<AiStreamNotifier, AiStreamState>(AiStreamNotifier.new);
