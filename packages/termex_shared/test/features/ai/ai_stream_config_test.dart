import 'package:flutter_test/flutter_test.dart';
import 'package:termex_bridge/models.dart' as bridge_models;
import 'package:termex_shared/features/ai/state/ai_stream_provider.dart';
import 'package:termex_shared/features/ai/state/conversation_provider.dart';
import 'package:termex_shared/features/ai/state/provider_config_provider.dart';

void main() {
  group('AiStreamNotifier.bridgeConfigFor', () {
    test('custom provider carries apiKey and baseUrl into the bridge DTO', () {
      const config = AiProviderConfig(
        provider: AiProvider.custom,
        model: 'deepseek/deepseek-v4.1-flash-fast',
        apiKey: 'cpa-test-key',
        baseUrl: 'http://gateway.local/v1',
      );

      final bridgeConfig = AiStreamNotifier.bridgeConfigFor(config);

      expect(bridgeConfig.provider, bridge_models.AiProvider.custom);
      expect(bridgeConfig.model, 'deepseek/deepseek-v4.1-flash-fast');
      expect(bridgeConfig.apiKey, 'cpa-test-key');
      expect(bridgeConfig.baseUrl, 'http://gateway.local/v1');
      expect(bridgeConfig.contextLines, 100);
    });

    test('non-custom provider keeps its model and context lines', () {
      const config = AiProviderConfig(
        provider: AiProvider.deepSeek,
        model: 'deepseek-chat',
        apiKey: 'sk-test',
        contextLines: 200,
      );

      final bridgeConfig = AiStreamNotifier.bridgeConfigFor(config);

      expect(bridgeConfig.provider, bridge_models.AiProvider.deepSeek);
      expect(bridgeConfig.model, 'deepseek-chat');
      expect(bridgeConfig.apiKey, 'sk-test');
      expect(bridgeConfig.baseUrl, isNull);
      expect(bridgeConfig.contextLines, 200);
    });
  });
}
