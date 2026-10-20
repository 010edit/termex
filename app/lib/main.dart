import 'dart:async' show unawaited;
import 'dart:convert' show utf8;
import 'dart:io' show HttpClient, HttpException, Platform;

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart'
    show
        DeviceOrientation,
        SystemChrome,
        SystemUiMode,
        SystemUiOverlay,
        SystemUiOverlayStyle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:termex_bridge/termex_bridge.dart' as bridge;

import 'package:termex_bridge/api.dart';

import 'package:termex_shared/design/tokens.dart';
import 'desktop/desktop_shell.dart';
import 'mobile/mobile_localizer.dart';
import 'mobile/mobile_shell.dart';
import 'mobile/notification_threshold.dart';
import 'mobile/notification_thresholds_listener.dart';
import 'mobile/task_event_bus.dart';
import 'mobile/task_history_store.dart';
import 'mobile/task_notifier.dart';
import 'package:termex_shared/features/server_list/state/app_state_provider.dart';
import 'package:termex_shared/features/server_list/widgets/master_password_dialog.dart';
import 'package:termex_shared/features/task/task_completion_sink.dart';
import 'package:termex_shared/app_version.dart';
import 'package:termex_shared/l10n/app_localizations.dart';
import 'package:termex_shared/system/auto_updater_linux.dart';
import 'package:termex_shared/system/auto_updater_macos.dart';
import 'package:termex_shared/system/auto_updater_windows.dart';
import 'package:termex_shared/system/splash_gate.dart';
import 'package:termex_shared/system/state/update_provider.dart';
import 'package:termex_shared/system/update_service.dart';
import 'package:termex_shared/widgets/toast.dart';

final appInitStateProvider =
    Provider<bridge.AppInitState>((ref) => throw UnimplementedError());

// Web does not expose dart:io's Platform; this app does not target web today,
// so a direct check is safe.
bool get _isMobilePlatform => Platform.isIOS || Platform.isAndroid;

/// Result of the async bootstrap performed by `SplashGate`. Bundles
/// everything the root ProviderScope needs to override so we don't
/// re-await on rebuilds.
class _BootResult {
  final bridge.AppInitState initState;
  final bool isUnlocked;
  const _BootResult({required this.initState, required this.isUnlocked});
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Mobile chrome: match Termex's dark theme on day one rather than wait
  // for the Flutter splash to fade. Edge-to-edge keeps the status / nav
  // bars transparent so the MobileShell background extends behind them.
  // Done before runApp so the very first frame already paints with the
  // right system bars.
  if (Platform.isIOS || Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color(0x00000000),
        statusBarIconBrightness: Brightness.light, // Android: white icons
        statusBarBrightness: Brightness.dark, // iOS: light text
        systemNavigationBarColor: Color(0xFF161B22),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Color(0xFF161B22),
      ),
    );
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Initialise the local-notification plugin. Idempotent and cheap —
    // failure is non-fatal (notifications just don't fire). v0.79.21
    // wires the primitive; v0.79.22 will hook task lifecycle events.
    unawaited(MobileTaskNotifier.instance.init());

    // v0.79.26: attach disk persistence + hydrate before any source
    // publishes so the rehydrated snapshot is visible to early
    // subscribers (e.g. the history page on first navigation).
    unawaited(() async {
      final store = await TaskHistoryStore.create();
      TaskEventBus.instance.attachPersistence(store);
      await TaskEventBus.instance.hydrate();
    }());

    // v0.79.25: hook the shared TaskCompletionSink so SFTP transfers
    // (and any future cross-package source) surface through the mobile
    // task pipeline. Desktop intentionally skips this — events still
    // emit, but no callback means the sink is a no-op.
    //
    // v0.79.28: callback now consults [MobileLocalizer] to translate
    // structured kind/data into the user's locale; falls back to the
    // English title/summary the source pre-formatted when the localizer
    // hasn't built yet (rare — only during very first frame) or the
    // kind isn't recognised.
    TaskCompletionSink.register((payload) {
      final l10n = MobileLocalizer.current;
      final localized =
          l10n == null ? null : _localizeTaskCompletion(payload, l10n);
      TaskEventBus.instance.publish(TaskEvent(
        taskId: payload.taskId,
        title: localized?.$1 ?? payload.title,
        summary: localized?.$2 ?? payload.summary,
        status: payload.success
            ? TaskEventStatus.succeeded
            : TaskEventStatus.failed,
        notify: shouldNotifyForPayload(payload),
      ));
    });
  }

  // Render the brand splash immediately, then run heavy bootstrap
  // inside the gate. On macOS / Windows / Linux this is the only
  // splash mechanism Flutter offers; on iOS / Android it visually
  // continues from the native splash (same logo + colour).
  runApp(SplashGate<_BootResult>(
    bootstrap: _bootstrap,
    builder: (context, result) => ProviderScope(
      overrides: [
        appInitStateProvider.overrideWithValue(result.initState),
        dbUnlockedProvider.overrideWith((_) => result.isUnlocked),
        // v0.79.0 (release-blocker B-1): wire the auto-update service.
        // Without this override the provider throws UnimplementedError
        // the moment the About tab's "检查更新" button reads it. The
        // per-platform UpdateService subclasses only differ in their
        // installer handoff (open DMG / run installer / open release
        // page); the appcast fetch is a plain HTTPS GET shared by all.
        updateServiceProvider.overrideWith((_) => _buildUpdateService()),
      ],
      child: const TermexApp(),
    ),
  ));
}

/// Selects the platform-appropriate [UpdateService] and injects the
/// HTTP appcast fetcher. Mobile gets the base service with no installer
/// handoff — store-distributed builds update through the store, so the
/// About tab only ever shows "new version available" there.
UpdateService _buildUpdateService() {
  if (Platform.isMacOS) {
    return MacAutoUpdater(
      currentVersion: kAppVersion,
      channel: kAppChannel,
      baseUrl: kAppcastBaseUrl,
      fetchAppcast: _httpAppcastFetcher,
    );
  }
  if (Platform.isWindows) {
    return WindowsAutoUpdater(
      currentVersion: kAppVersion,
      channel: kAppChannel,
      baseUrl: kAppcastBaseUrl,
      fetchAppcast: _httpAppcastFetcher,
    );
  }
  if (Platform.isLinux) {
    return LinuxAutoUpdater(
      currentVersion: kAppVersion,
      channel: kAppChannel,
      baseUrl: kAppcastBaseUrl,
      fetchAppcast: _httpAppcastFetcher,
    );
  }
  return UpdateService(
    currentVersion: kAppVersion,
    channel: kAppChannel,
    baseUrl: kAppcastBaseUrl,
    fetchAppcast: _httpAppcastFetcher,
  );
}

/// Plain HTTPS GET for the Sparkle-style appcast XML. Lives in the app
/// entrypoint (not termex_shared) so the shared package stays free of a
/// dart:io HttpClient dependency and unit tests can stub the fetcher.
Future<String> _httpAppcastFetcher(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException(
        'appcast fetch failed: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }
    return response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

// When launched with `--dart-define=TERMEX_AUDIT_MODE=true` the desktop
// app redirects its SQLCipher DB / recordings / fonts / models / bin /
// config under `~/.termex-flutter-audit/`, so a test build can run
// without sharing or corrupting the production DB.
const bool _kAuditMode =
    bool.fromEnvironment('TERMEX_AUDIT_MODE', defaultValue: false);

Future<_BootResult> _bootstrap() async {
  await TermexBridge.init();
  // Mobile sandboxes don't expose a writable XDG-style data dir to the
  // `dirs` Rust crate; seed the path resolver with Flutter's reported
  // application support directory. Desktop builds skip this — the Rust
  // resolver falls back to `dirs::data_dir()` which works on macOS /
  // Windows / Linux as before.
  if (Platform.isIOS || Platform.isAndroid) {
    final dir = await getApplicationSupportDirectory();
    await bridge.setAppDataDir(path: dir.path);
  } else if (_kAuditMode) {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isNotEmpty) {
      final auditDir = '$home/.termex-flutter-audit';
      await bridge.setAppDataDir(path: auditDir);
    }
  }
  final initState = await bridge.initApp();
  // The Tauri-era database stores the master password as an Argon2id salt
  // + verify-token in the `settings` table, and only when the user has
  // explicitly set one. If no password is configured, init_app already
  // auto-opened the DB on the Rust side — skip the unlock dialog.
  final needsUnlock = await bridge.masterPasswordRequired();
  return _BootResult(initState: initState, isUnlocked: !needsUnlock);
}

class TermexApp extends ConsumerWidget {
  const TermexApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isUnlocked = ref.watch(dbUnlockedProvider);
    // v0.77.0: push live OS brightness into the theme provider so
    // "follow system" actually follows. MediaQuery.platformBrightnessOf
    // already rebuilds on OS theme flip.
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(platformBrightnessProvider.notifier);
      if (notifier.state != platformBrightness) {
        notifier.state = platformBrightness;
      }
    });
    final themeData = ref.watch(themeDataProvider);
    return TermexThemeScope(
      theme: themeData,
      child: WidgetsApp(
        debugShowCheckedModeBanner: false,
        // Exposed to the local-notification deep-link handler so taps can
        // push a route from outside the widget tree (the notification
        // arrives via plugin callback, not a user gesture).
        navigatorKey: MobileTaskNotifier.instance.navigatorKey,
        color: themeData.colors.background,
        // Use the curated delegate list from termex_shared/l10n. It
        // includes AppLocalizations.delegate plus GlobalMaterial /
        // GlobalCupertino / GlobalWidgets — the *Global* variants
        // (from package:flutter_localizations) handle every supported
        // locale, whereas DefaultMaterialLocalizations is English-only
        // and crashes TextField rendering when the system locale is
        // zh (or any non-en).
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (ctx, _, __) => builder(ctx),
        ),
        // Material(type: transparency) supplies the Material ancestor that
        // every Material widget (TabBar, ListTile, InkWell, TextField cursor
        // overlays, etc.) looks up. We use a transparent canvas so the
        // Termex theme's painted backgrounds show through unchanged.
        builder: (context, child) => Material(
          type: MaterialType.transparency,
          child: TermexToastOverlay(child: child ?? const SizedBox()),
        ),
        home: isUnlocked
            ? (_isMobilePlatform
                ? const NotificationThresholdsListener(
                    child: _LocalizerCacheUpdater(child: MobileShell()),
                  )
                : const DesktopShell())
            : const MasterPasswordDialog(),
      ),
    );
  }
}

/// Caches the current [AppLocalizations] into [MobileLocalizer] every
/// frame so emission sites without a [BuildContext] (notifier methods,
/// background pollers, plugin tap callbacks) can still localize.
class _LocalizerCacheUpdater extends StatelessWidget {
  final Widget child;
  const _LocalizerCacheUpdater({required this.child});

  @override
  Widget build(BuildContext context) {
    MobileLocalizer.update(AppLocalizations.of(context));
    return child;
  }
}

/// v0.79.28: format a [TaskCompletionPayload] into the active locale.
/// Returns `(title, summary)` or null when the kind isn't recognised —
/// the caller falls back to the English source-supplied strings.
///
/// v0.79.30: now dispatches by source prefix to source-specific localizers,
/// so adding a future source (`cmd.*`, `cloud.*`, …) only touches this
/// dispatch table.
(String, String)? _localizeTaskCompletion(
  TaskCompletionPayload payload,
  AppLocalizations l10n,
) {
  final kind = payload.kind;
  if (kind == null) return null;
  if (kind.startsWith('sftp.')) return _localizeSftp(payload, l10n);
  if (kind.startsWith('ai.')) return _localizeAi(payload, l10n);
  return null;
}

(String, String)? _localizeSftp(
  TaskCompletionPayload payload,
  AppLocalizations l10n,
) {
  final kind = payload.kind;
  if (kind == null || !kind.startsWith('sftp.')) return null;
  final fileName = payload.data['fileName'] as String? ?? '';
  final totalHuman = payload.data['totalBytesHuman'] as String? ?? '';
  final transferredHuman =
      payload.data['transferredBytesHuman'] as String? ?? '';
  final errorMessage = payload.data['errorMessage'] as String? ?? '';
  final actionLabel = kind.contains('.upload.')
      ? l10n.taskSftpActionUpload
      : l10n.taskSftpActionDownload;
  switch (kind) {
    case 'sftp.upload.succeeded':
      return (
        l10n.taskSftpUploadSucceededTitle(fileName),
        l10n.taskSftpUploadSucceededBody(totalHuman),
      );
    case 'sftp.download.succeeded':
      return (
        l10n.taskSftpDownloadSucceededTitle(fileName),
        l10n.taskSftpDownloadSucceededBody(totalHuman),
      );
    case 'sftp.upload.failed':
      return (
        l10n.taskSftpUploadFailedTitle(fileName),
        l10n.taskSftpFailedBody(actionLabel, errorMessage),
      );
    case 'sftp.download.failed':
      return (
        l10n.taskSftpDownloadFailedTitle(fileName),
        l10n.taskSftpFailedBody(actionLabel, errorMessage),
      );
    case 'sftp.upload.cancelled':
      return (
        l10n.taskSftpUploadCancelledTitle(fileName),
        l10n.taskSftpCancelledBody(actionLabel, transferredHuman, totalHuman),
      );
    case 'sftp.download.cancelled':
      return (
        l10n.taskSftpDownloadCancelledTitle(fileName),
        l10n.taskSftpCancelledBody(actionLabel, transferredHuman, totalHuman),
      );
  }
  return null;
}

/// v0.79.30: AI completion localizer. Branches on conversation title
/// presence (some flows fire before the title is auto-generated) and
/// success / failed / cancelled.
(String, String)? _localizeAi(
  TaskCompletionPayload payload,
  AppLocalizations l10n,
) {
  final kind = payload.kind;
  if (kind == null || !kind.startsWith('ai.')) return null;
  final model = payload.data['model'] as String? ?? '';
  final conversationTitle =
      (payload.data['conversationTitle'] as String? ?? '').trim();
  final responseLength = payload.data['responseLength'];
  // v0.79.49: tokens reported by the provider on the done chunk. Skip
  // when null or 0 (Ollama / local models often report 0).
  final tokensIn = payload.data['tokensIn'];
  final tokensOut = payload.data['tokensOut'];
  final hasTokens = (tokensIn is int && tokensIn > 0) ||
      (tokensOut is int && tokensOut > 0);
  // v0.79.50: USD cost (pre-formatted by ai_pricing.formatCostUsd at
  // emit time so the localizer doesn't need its own NumberFormat).
  final costFormatted = payload.data['costUsdFormatted'];
  final hasCost = costFormatted is String && costFormatted.isNotEmpty;
  final errorMessage = payload.data['errorMessage'] as String? ?? '';
  final hasConversation = conversationTitle.isNotEmpty;
  switch (kind) {
    case 'ai.completion.succeeded':
      final title = hasConversation
          ? l10n.taskAiSucceededTitleWithConversation(
              conversationTitle, model)
          : l10n.taskAiSucceededTitle(model);
      // v0.79.50: four-level fallback — cost > tokens > length > bare.
      final body = responseLength is int
          ? hasCost
              ? l10n.taskAiSucceededBodyWithCost(
                  responseLength,
                  (tokensIn is int ? tokensIn : 0),
                  (tokensOut is int ? tokensOut : 0),
                  costFormatted,
                )
              : hasTokens
                  ? l10n.taskAiSucceededBodyWithTokens(
                      responseLength,
                      (tokensIn is int ? tokensIn : 0),
                      (tokensOut is int ? tokensOut : 0),
                    )
                  : l10n.taskAiSucceededBodyWithLength(responseLength)
          : l10n.taskAiSucceededBody;
      return (title, body);
    case 'ai.completion.failed':
      final title = hasConversation
          ? l10n.taskAiFailedTitleWithConversation(conversationTitle)
          : l10n.taskAiFailedTitle;
      final body = errorMessage.isNotEmpty
          ? l10n.taskAiFailedBodyWithError(errorMessage)
          : l10n.taskAiFailedBody;
      return (title, body);
    case 'ai.completion.cancelled':
      final title = hasConversation
          ? l10n.taskAiCancelledTitleWithConversation(conversationTitle)
          : l10n.taskAiCancelledTitle;
      return (title, l10n.taskAiCancelledBody);
  }
  return null;
}
