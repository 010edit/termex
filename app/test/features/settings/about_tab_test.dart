import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:termex_shared/app_version.dart';
import 'package:termex_shared/features/settings/tabs/about_tab.dart';
import 'package:termex_shared/l10n/app_localizations.dart';
import 'package:termex_shared/system/update_service.dart';
import 'package:termex_shared/system/state/update_provider.dart';

const _xmlWithUpdate = '''
  <rss><channel><item>
    <sparkle:version>0.49.0</sparkle:version>
    <enclosure url="https://termex.app/dl/t-0.49.0.dmg" length="1"/>
  </item></channel></rss>''';

UpdateService _svc(String xml) => UpdateService(
      currentVersion: '0.48.0',
      channel: 'stable',
      baseUrl: 'https://termex.app/updates',
      fetchAppcast: (_) async => xml,
    );

Widget _wrap(UpdateService svc) => ProviderScope(
      overrides: [updateServiceProvider.overrideWithValue(svc)],
      child: const MaterialApp(
        // Force zh locale + register l10n delegates so AppLocalizations.of
        // resolves to the Chinese strings the assertions below check for.
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AboutTab()),
      ),
    );

void main() {
  testWidgets('renders current version header', (tester) async {
    final svc = _svc(_xmlWithUpdate);
    addTearDown(svc.dispose);
    await tester.pumpWidget(_wrap(svc));
    await tester.pump();

    expect(find.text('Termex'), findsOneWidget);
    // Assert against the shared constant instead of a hardcoded string so
    // `node scripts/bump-version.mjs` (which syncs app_version.dart) can't
    // break this test again — the v0.79.0 bump caught it asserting '0.49.0'.
    expect(find.textContaining(kAppVersion), findsWidgets);
  });

  testWidgets('check button triggers fetch and shows new version',
      (tester) async {
    final svc = _svc(_xmlWithUpdate);
    addTearDown(svc.dispose);

    await tester.pumpWidget(_wrap(svc));
    await tester.pump();

    // Default state = idle → updateUpToDate ("已是最新版本！" in zh ARB)
    expect(find.textContaining('已是最新版本'), findsOneWidget);

    // Tap check (TextButton.icon wraps in a subclass on some Flutter versions,
    // so target the label text directly — hit-testing bubbles up to the button)
    await tester.tap(find.text('立即检查'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('有可用更新'), findsOneWidget);
  });

  testWidgets('auto-download toggle flips preference', (tester) async {
    final svc = _svc(_xmlWithUpdate);
    addTearDown(svc.dispose);

    await tester.pumpWidget(_wrap(svc));
    await tester.pump();

    final switchFinder = find.byType(SwitchListTile);
    expect(switchFinder, findsOneWidget);
    final before = tester.widget<SwitchListTile>(switchFinder).value;
    expect(before, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();
    final after = tester.widget<SwitchListTile>(switchFinder).value;
    expect(after, isTrue);
  });
}
