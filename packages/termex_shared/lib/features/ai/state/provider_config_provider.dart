import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termex_bridge/api.dart' as bridge;
import 'package:termex_bridge/models.dart' as bridge_models;

import 'conversation_provider.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class AiProviderConfig {
  final AiProvider provider;
  final String model;
  final String? apiKey;
  final String? baseUrl;
  /// Max terminal scrollback lines to include as context (50/100/200/500).
  final int contextLines;

  const AiProviderConfig({
    required this.provider,
    required this.model,
    this.apiKey,
    this.baseUrl,
    this.contextLines = 100,
  });

  AiProviderConfig copyWith({
    AiProvider? provider,
    String? model,
    String? apiKey,
    String? baseUrl,
    int? contextLines,
  }) =>
      AiProviderConfig(
        provider: provider ?? this.provider,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        contextLines: contextLines ?? this.contextLines,
      );
}

/// Default model for each provider. **Each entry MUST also exist in
/// `kProviderRegistry`** — when this map diverges from the registry, the
/// model dropdown asserts ("There should be exactly one item with
/// DropdownButton's value: …") because Flutter sees a `value` not in the
/// `items` list. Update both together when introducing a new model.
const Map<AiProvider, String> kDefaultModel = {
  AiProvider.claude: 'claude-opus-4-7',
  AiProvider.openAi: 'gpt-4o',
  AiProvider.gemini: 'gemini-1.5-flash',
  AiProvider.ollama: 'llama3',
  AiProvider.localLlama: 'llama3-8b-q4',
  AiProvider.deepSeek: 'deepseek-chat',
  AiProvider.grok: 'grok-beta',
  AiProvider.mistral: 'mistral-large-latest',
  AiProvider.glm: 'glm-4',
  AiProvider.minimax: 'abab6.5-chat',
  AiProvider.doubao: 'doubao-pro-32k',
  // v0.79.63:
  AiProvider.bailian: 'qwen-plus',
  // Custom has no default — user supplies model name in the inline form.
  // Empty string keeps the DropdownButton happy when first seeded.
  AiProvider.custom: '',
};

// ─── State ────────────────────────────────────────────────────────────────────

class ProviderConfigState {
  final AiProvider activeProvider;
  final Map<AiProvider, AiProviderConfig> configs;
  /// True while an API key verification call is in progress.
  final bool isVerifying;
  final String? verifyError;

  const ProviderConfigState({
    this.activeProvider = AiProvider.claude,
    this.configs = const {},
    this.isVerifying = false,
    this.verifyError,
  });

  AiProviderConfig get activeConfig =>
      configs[activeProvider] ??
      AiProviderConfig(
        provider: activeProvider,
        model: kDefaultModel[activeProvider]!,
      );

  /// v0.79.56: true when at least one provider has a usable config
  /// (cloud providers need a non-empty `apiKey`; local providers count
  /// as soon as a config row exists). Used by [AiPanel] to gate the
  /// chat surface — without this check, the default `activeProvider =
  /// claude` made the panel look operational even with no API key set,
  /// so users hit cryptic "API key missing" errors on first message
  /// instead of an upfront onboarding card.
  bool get hasAnyConfigured {
    for (final entry in configs.entries) {
      final isLocal = entry.key == AiProvider.ollama ||
          entry.key == AiProvider.localLlama;
      if (isLocal) return true;
      if ((entry.value.apiKey ?? '').isNotEmpty) return true;
    }
    return false;
  }

  ProviderConfigState copyWith({
    AiProvider? activeProvider,
    Map<AiProvider, AiProviderConfig>? configs,
    bool? isVerifying,
    String? verifyError,
    bool clearVerifyError = false,
  }) =>
      ProviderConfigState(
        activeProvider: activeProvider ?? this.activeProvider,
        configs: configs ?? this.configs,
        isVerifying: isVerifying ?? this.isVerifying,
        verifyError: clearVerifyError ? null : (verifyError ?? this.verifyError),
      );
}

// ─── Notifier ────────────────────────────────────────────────────────────────

bridge_models.AiProvider _toBridgeProvider(AiProvider p) => switch (p) {
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
    };

AiProvider _fromBridgeProvider(bridge_models.AiProvider b) => switch (b) {
      bridge_models.AiProvider.claude => AiProvider.claude,
      bridge_models.AiProvider.openAi => AiProvider.openAi,
      bridge_models.AiProvider.gemini => AiProvider.gemini,
      bridge_models.AiProvider.ollama => AiProvider.ollama,
      bridge_models.AiProvider.localLlama => AiProvider.localLlama,
      bridge_models.AiProvider.deepSeek => AiProvider.deepSeek,
      bridge_models.AiProvider.grok => AiProvider.grok,
      bridge_models.AiProvider.mistral => AiProvider.mistral,
      bridge_models.AiProvider.glm => AiProvider.glm,
      bridge_models.AiProvider.minimax => AiProvider.minimax,
      bridge_models.AiProvider.doubao => AiProvider.doubao,
      bridge_models.AiProvider.bailian => AiProvider.bailian,
      bridge_models.AiProvider.custom => AiProvider.custom,
    };

class ProviderConfigNotifier extends Notifier<ProviderConfigState> {
  @override
  ProviderConfigState build() {
    Future.microtask(_loadAll);
    return const ProviderConfigState();
  }

  Future<void> _loadAll() async {
    final loaded = <AiProvider, AiProviderConfig>{};
    for (final p in AiProvider.values) {
      try {
        final remote = await bridge.aiLoadProviderConfig(
          provider: _toBridgeProvider(p),
        );
        if (remote != null) {
          loaded[p] = AiProviderConfig(
            provider: _fromBridgeProvider(remote.provider),
            model: remote.model,
            apiKey: remote.apiKey,
            baseUrl: remote.baseUrl,
            contextLines: remote.contextLines,
          );
        }
      } catch (_) {}
    }
    if (loaded.isNotEmpty) {
      state = state.copyWith(configs: loaded);
    }
  }

  void setActiveProvider(AiProvider provider) {
    state = state.copyWith(activeProvider: provider);
  }

  void updateConfig(AiProviderConfig config) {
    final updated = {...state.configs, config.provider: config};

    // v0.79.57: auto-promote the freshly saved config to `activeProvider`
    // when the current active isn't actually usable. Without this, the
    // default `activeProvider = claude` stayed pinned even after the
    // user configured (say) OpenAI as their first provider — sending
    // a message would then hit the unconfigured Claude path and error.
    final isLocal = config.provider == AiProvider.ollama ||
        config.provider == AiProvider.localLlama;
    final newConfigUsable = isLocal || (config.apiKey ?? '').isNotEmpty;
    final activeCfg = updated[state.activeProvider];
    final activeIsLocal = state.activeProvider == AiProvider.ollama ||
        state.activeProvider == AiProvider.localLlama;
    final activeUsable = activeCfg != null &&
        (activeIsLocal || (activeCfg.apiKey ?? '').isNotEmpty);
    final nextActive =
        (newConfigUsable && !activeUsable) ? config.provider : state.activeProvider;

    state = state.copyWith(
      configs: updated,
      activeProvider: nextActive,
      clearVerifyError: true,
    );
    bridge
        .aiSaveProviderConfig(
          config: bridge_models.AiProviderConfig(
            provider: _toBridgeProvider(config.provider),
            model: config.model,
            apiKey: config.apiKey,
            baseUrl: config.baseUrl,
            contextLines: config.contextLines,
          ),
        )
        .catchError((_) {});
  }

  /// v0.78.0: insert an empty config row for [provider] when the user
  /// picks it from the "+ Add Provider" dropdown but hasn't yet filled
  /// anything in. The row is purely client-side scaffolding so the
  /// inline form has somewhere to mutate; the row is **not** persisted
  /// to the Rust side until the form's save button calls [updateConfig].
  void upsertEmpty(AiProvider provider) {
    if (state.configs.containsKey(provider)) return;
    final updated = {
      ...state.configs,
      provider: AiProviderConfig(
        provider: provider,
        model: kDefaultModel[provider] ?? '',
        contextLines: 100,
      ),
    };
    state = state.copyWith(configs: updated);
  }

  /// v0.78.0: drop the local config row for [provider] when the user
  /// hits the "Remove" button on a configured row. The API key in the
  /// OS keychain is intentionally left in place so re-adding the
  /// provider later does not lose the credential — only the SQLite
  /// row + in-memory `configs[provider]` entry go away.
  ///
  /// v0.79.57: when removing the currently-active provider, re-point
  /// `activeProvider` to the next configured one if any exist. Without
  /// this, deleting the active provider leaves a dangling
  /// `activeProvider = removed` that synthesizes a fake config on
  /// `activeConfig` access (matching the v0.79.56 onboarding-gate bug
  /// pattern at a different layer).
  Future<void> removeConfig(AiProvider provider) async {
    final updated = {...state.configs}..remove(provider);
    AiProvider nextActive = state.activeProvider;
    if (provider == state.activeProvider) {
      // Prefer the first remaining provider with a usable config; fall
      // back to whichever entry is left (or leave the original — the
      // AiPanel gate will catch the no-config case).
      final remaining = updated.entries.where((e) {
        final isLocal = e.key == AiProvider.ollama ||
            e.key == AiProvider.localLlama;
        return isLocal || (e.value.apiKey ?? '').isNotEmpty;
      }).toList(growable: false);
      if (remaining.isNotEmpty) {
        nextActive = remaining.first.key;
      } else if (updated.isNotEmpty) {
        nextActive = updated.keys.first;
      }
    }
    state = state.copyWith(configs: updated, activeProvider: nextActive);
    // Best-effort: delete the persisted row. The bridge surface has no
    // dedicated "delete config" yet; storing an empty marker has the
    // same effect on next load (filter logic ignores empty apiKey).
    try {
      await bridge.aiSaveProviderConfig(
        config: bridge_models.AiProviderConfig(
          provider: _toBridgeProvider(provider),
          model: '',
          apiKey: null,
          baseUrl: null,
          contextLines: 100,
        ),
      );
    } catch (_) {}
  }

  /// Verify the credentials currently typed into the provider form.
  ///
  /// This deliberately routes through [bridge.aiExplainCommand] instead of
  /// [bridge.aiVerifyApiKey]: the latter only takes provider + key and falls
  /// back to the vendor's hard-coded base URL/model. For Custom (and any
  /// self-hosted OpenAI-compatible gateway) that means the key is sent to
  /// api.openai.com, which is exactly the wrong endpoint. `aiExplainCommand`
  /// builds the same [ProviderRequest] as a real chat turn, so the form's
  /// baseUrl, model and key are all honored. It does not persist anything.
  Future<bool> verifyApiKey(
    AiProvider provider,
    String apiKey, {
    String? baseUrl,
    String? model,
  }) async {
    state = state.copyWith(isVerifying: true, clearVerifyError: true);
    try {
      final effectiveModel = (model ?? kDefaultModel[provider] ?? '').trim();
      final config = bridge_models.AiProviderConfig(
        provider: _toBridgeProvider(provider),
        model: effectiveModel,
        apiKey: apiKey,
        baseUrl: (baseUrl == null || baseUrl.trim().isEmpty)
            ? null
            : baseUrl.trim(),
        contextLines: 50,
      );
      await bridge.aiExplainCommand(command: 'true', config: config);
      state = state.copyWith(isVerifying: false);
      return true;
    } catch (e) {
      state = state.copyWith(isVerifying: false, verifyError: e.toString());
      return false;
    }
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

final providerConfigProvider =
    NotifierProvider<ProviderConfigNotifier, ProviderConfigState>(
  ProviderConfigNotifier.new,
);
