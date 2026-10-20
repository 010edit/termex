import 'package:flutter_test/flutter_test.dart';
import 'package:termex_shared/features/ai/provider/model_list_service.dart';

void main() {
  group('parseOpenAiModelIds', () {
    test('parses data[].id, dedupes and sorts', () {
      expect(
        parseOpenAiModelIds(
          '{"object":"list","data":[{"id":"b"},{"id":"a"},{"id":"a"}]}',
        ),
        ['a', 'b'],
      );
    });

    test('parses models[].name', () {
      expect(
        parseOpenAiModelIds('{"models":[{"name":"qwen2.5:7b"}]}'),
        ['qwen2.5:7b'],
      );
    });

    test('parses a bare array', () {
      expect(parseOpenAiModelIds('["m2","m1"]'), ['m1', 'm2']);
    });

    test('rejects an empty model list', () {
      expect(
        () => parseOpenAiModelIds('{"data":[]}'),
        throwsFormatException,
      );
    });
  });
}
