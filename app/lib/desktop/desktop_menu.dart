import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cross_tab/cross_tab_search_dialog.dart';
import 'package:termex_shared/features/server_list/state/connection_provider.dart';
import 'package:termex_shared/features/server_list/widgets/quick_connect_dialog.dart';
import 'package:termex_shared/features/server_list/widgets/server_form_dialog.dart';
import 'package:termex_shared/features/settings/settings_page.dart';
import 'package:termex_shared/features/settings/widgets/privacy_policy_dialog.dart';
import 'package:termex_shared/features/snippet/snippet_palette.dart';
import 'package:termex_shared/features/update/update_dialog.dart';
import 'package:termex_shared/features/tabs/state/tab_controller.dart';
import 'package:termex_shared/terminal/broadcast_registry.dart';
import 'package:termex_shared/widgets/dialog.dart';
import 'state/desktop_shell_state.dart';

/// Native macOS menu bar mirroring the former Tauri/Vue desktop menu.
///
/// On non-macOS platforms PlatformMenuBar renders nothing — the [child] is
/// returned unchanged, so this widget is safe to mount on every desktop OS.
///
/// Menu structure:
///   App (Termex) — About / Settings⌘, / Services / Hide / Quit
///   File         — New Connection ⌘N / Close Tab ⌘W
///   Edit         — Undo Redo Cut Copy Paste Select All
///   View         — Sidebar ⌘\\ / AI Panel ⌘⇧I / SFTP / Settings
///   Window       — Minimize / Zoom / Fullscreen
///   Help         — Check for Updates / Privacy Policy
class TermexDesktopMenu extends ConsumerWidget {
  final Widget child;
  const TermexDesktopMenu({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlatformMenuBar(
      menus: [
        // ── App menu (macOS shows this as the bold app name) ──
        PlatformMenu(
          label: 'Termex',
          menus: [
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.about,
            ),
            PlatformMenuItem(
              label: 'Settings…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: () => _openSettingsDialog(context),
            ),
            const PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ]),
            const PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hide,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ]),
            const PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
            ]),
          ],
        ),

        // ── File menu ──
        PlatformMenu(
          label: 'File',
          menus: [
            PlatformMenuItem(
              label: 'New Connection',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: () => ServerFormDialog.show(context),
            ),
            PlatformMenuItem(
              label: 'Quick Connect…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyK,
                meta: true,
                shift: true,
              ),
              onSelected: () => QuickConnectDialog.show(
                context,
                onConnect: (_) {
                  // The shell's onConnect already runs through the dialog's
                  // notifier path; nothing extra needed here.
                },
              ),
            ),
            PlatformMenuItem(
              label: 'Close Tab',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
              ),
              onSelected: () {
                final activeId = ref.read(activeTabIdProvider);
                if (activeId != null) {
                  ref.read(tabListProvider.notifier).closeTab(activeId);
                }
              },
            ),
          ],
        ),

        // ── Edit menu (system-provided shortcuts also work) ──
        PlatformMenu(
          label: 'Edit',
          menus: [
            PlatformMenuItem(
              label: 'Find in All Tabs…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyF,
                meta: true,
                shift: true,
              ),
              onSelected: () => CrossTabSearchDialog.show(context),
            ),
            PlatformMenuItem(
              label: 'Snippet Palette…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyS,
                meta: true,
                shift: true,
              ),
              onSelected: () => SnippetPalette.show(context),
            ),
          ],
        ),

        // ── View menu ──
        PlatformMenu(
          label: 'View',
          menus: [
            PlatformMenuItem(
              label: 'Toggle Sidebar',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.backslash,
                meta: true,
              ),
              onSelected: () => ref
                  .read(sidebarVisibleProvider.notifier)
                  .update((v) => !v),
            ),
            PlatformMenuItem(
              label: 'Toggle AI Panel',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyI,
                meta: true,
                shift: true,
              ),
              onSelected: () =>
                  toggleDesktopSidePanel(ref, DesktopSidePanel.ai),
            ),
            PlatformMenuItem(
              label: 'Toggle SFTP Panel',
              onSelected: () =>
                  toggleDesktopSidePanel(ref, DesktopSidePanel.sftp),
            ),
            PlatformMenuItem(
              label: 'Toggle Settings Panel',
              onSelected: () =>
                  toggleDesktopSidePanel(ref, DesktopSidePanel.settings),
            ),
            PlatformMenuItem(
              label: 'Toggle Input Broadcast',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyB,
                meta: true,
                shift: true,
              ),
              onSelected: () {
                final activeId = ref.read(activeTabIdProvider);
                if (activeId == null) return;
                final sid = ref.read(connectionProvider(activeId)).sessionId;
                if (sid != null) {
                  ref.read(broadcastRegistryProvider).toggle(sid);
                }
              },
            ),
          ],
        ),

        // ── Window menu ──
        const PlatformMenu(
          label: 'Window',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.toggleFullScreen,
              ),
            ]),
          ],
        ),

        // ── Help menu ──
        PlatformMenu(
          label: 'Help',
          menus: [
            PlatformMenuItem(
              label: 'Check for Updates…',
              onSelected: () => showUpdateDialog(context),
            ),
            PlatformMenuItem(
              label: 'Privacy Policy…',
              onSelected: () => PrivacyPolicyDialog.show(context),
            ),
          ],
        ),
      ],
      child: child,
    );
  }
}

/// Centered Settings dialog (matches the Tauri/Vue SettingsModal — 680px
/// modal, not a side panel).
void _openSettingsDialog(BuildContext context) {
  showTermexDialog<void>(
    context: context,
    title: '设置',
    size: DialogSize.large,
    body: const SizedBox(
      width: 680,
      height: 500,
      child: SettingsPage(embedded: true),
    ),
  );
}
