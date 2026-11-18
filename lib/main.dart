// Déploiement — deploy any PHP + MySQL project (files, migrations, synced tables, full database copies) from this PC
// to any target: shared hosting (Hostinger…), a VPS, a server reached by IP. See operations.dart for what each action does.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'alerts_view.dart';
import 'app_mark.dart';
import 'app_state.dart';
import 'dialogs.dart';
import 'i18n.dart';
import 'models.dart';
import 'pickers.dart';
import 'project_view.dart';
import 'target_view.dart';
import 'theme.dart';
import 'watch.dart';
import 'widgets.dart';

void main(List<String> args) {
  // Debug runs ("flutter run"): Marionette lets an AI agent (MCP server marionette_mcp) see and drive the app —
  // tap, type, screenshots, hot reload. The released .exe is a release build: Marionette is off there.
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  final app = AppState();
  app.watcher.restart(); // email alerts, when they are on (Settings); "--background": opened minimized at login
  Startup.migrate(app.settings.alerts.startWithWindows).catchError((_) {}); // the shortcut of the former name
  runApp(DeploiementApp(app));
}

class DeploiementApp extends StatelessWidget {
  const DeploiementApp(this.app, {super.key, this.themeMode = ThemeMode.system});
  final AppState app;
  final ThemeMode themeMode;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: language,
        builder: (_, _, _) => MaterialApp(
          title: 'Déploiement',
          navigatorKey: app.navigatorKey,
          scaffoldMessengerKey: app.messengerKey,
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: Shell(app),
        ),
      );
}

/// The window: the side panel (a drawer on narrow windows) and the page of the current route.
class Shell extends StatelessWidget {
  const Shell(this.app, {super.key});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => LayoutBuilder(builder: (context, c) {
          final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
          final page = AnimatedSwitcher(
            duration: Duration(milliseconds: still ? 0 : 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(.015, 0), end: Offset.zero).animate(a), child: child),
            ),
            child: KeyedSubtree(key: ValueKey(app.route), child: _page()),
          );
          final p = Palette.of(context);
          if (c.maxWidth >= 920) {
            return Scaffold(
              body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(width: 260, child: SidePanel(app)),
                Expanded(child: page),
              ]),
            );
          }
          return Scaffold(
            drawer: Drawer(child: SidePanel(app)),
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Builder(
                builder: (context) => Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(color: p.panel),
                  child: Row(children: [
                    IconButton(onPressed: () => Scaffold.of(context).openDrawer(), icon: Icon(Icons.menu, size: 20, color: p.sideInk), tooltip: tr('Menu')),
                    const SizedBox(width: 6),
                    const Wordmark(),
                  ]),
                ),
              ),
              Expanded(child: page),
            ]),
          );
        }),
      );

  Widget _page() {
    final r = app.route;
    if (r == 'settings') return SettingsPage(app);
    if (r.startsWith('p:')) {
      final pr = app.project;
      if (pr != null) return ProjectPage(app, pr, key: ValueKey('p-${pr.id}'));
    }
    if (r.startsWith('t:')) {
      final t = app.target, pr = app.project;
      if (t != null && pr != null) return TargetPage(app, pr, t, settings: r.endsWith(':settings'), key: ValueKey(r));
    }
    return HomePage(app);
  }
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key});
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const AppMark(size: 30), // the same drawing as the Windows icon
      const SizedBox(width: 10),
      Text('Déploiement', style: ty.cardTitle.copyWith(fontSize: 16, color: ty.p.sideInk)),
    ]);
  }
}

/// Projects and their targets, then the app's own actions.
class SidePanel extends StatelessWidget {
  const SidePanel(this.app, {super.key});
  final AppState app;

  void _go(BuildContext context, String r) {
    if (app.busy) return;
    final s = Scaffold.maybeOf(context);
    if (s != null && s.isDrawerOpen) s.closeDrawer();
    app.go(r);
  }

  void _newProject(BuildContext context) {
    final s = Scaffold.maybeOf(context);
    if (s != null && s.isDrawerOpen) s.closeDrawer();
    newProject(app);
  }

  void _import(BuildContext context) {
    final s = Scaffold.maybeOf(context);
    if (s != null && s.isDrawerOpen) s.closeDrawer();
    importProject(app);
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final current = app.route.endsWith(':settings') ? app.route.substring(0, app.route.length - 9) : app.route;
    Widget item(String route, Widget child, {double indent = 0, List<Widget> menu = const []}) =>
        _NavItem(route: route, on: current == route, indent: indent, onTap: () => _go(context, route), menu: menu, child: child);

    // the menu of a project or a target: right click on it, or its "⋯" button
    Widget open(String route) => MenuItemButton(
        leadingIcon: const Icon(Icons.open_in_new, size: 17), onPressed: app.busy ? null : () => _go(context, route), child: Text(tr('Open')));
    Widget delete(String label, Future<void> Function(BuildContext) f) => MenuItemButton(
          leadingIcon: Icon(Icons.delete_outline, size: 17, color: app.busy ? null : ty.p.removed),
          style: MenuItemButton.styleFrom(foregroundColor: ty.p.removed),
          onPressed: app.busy
              ? null
              : () {
                  final s = Scaffold.maybeOf(context);
                  if (s != null && s.isDrawerOpen) s.closeDrawer();
                  f(app.navigatorKey.currentContext ?? context); // the drawer and this panel may close meanwhile
                },
          child: Text(label),
        );

    Widget action(String text, IconData icon, VoidCallback f) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            hoverColor: Colors.white.withValues(alpha: .06),
            onTap: app.busy ? null : f,
            child: Container(
              height: 34,
              padding: const EdgeInsets.only(left: 10, right: 8),
              child: Row(children: [
                Icon(icon, size: 17, color: ty.p.sideMuted),
                const SizedBox(width: 10),
                Text(text, style: ty.body.copyWith(fontSize: 13.5, color: ty.p.sideMuted)),
              ]),
            ),
          ),
        );

    return Container(
      color: ty.p.panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(padding: EdgeInsets.fromLTRB(18, 18, 12, 18), child: Wordmark()),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            item('home', Row(children: [
              const Icon(Icons.dashboard_outlined, size: 17),
              const SizedBox(width: 10),
              Text(tr('Overview'), style: const TextStyle(fontSize: 13.5)),
            ])),
            if (app.projects.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 20, 12, 6), child: Text(tr('Projects').toUpperCase(), style: ty.caps(color: ty.p.sideMuted))),
            for (final pr in app.projects) ...[
              item(
                'p:${pr.id}',
                Row(children: [
                  const Icon(Icons.folder_outlined, size: 17),
                  const SizedBox(width: 10),
                  Expanded(child: Text(pr.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
                ]),
                menu: [
                  open('p:${pr.id}'),
                  const Divider(height: 9),
                  delete(tr('Delete this project…'), (c) => askRemoveProject(c, app, pr)),
                ],
              ),
              for (final t in pr.targets)
                item(
                  't:${t.id}',
                  Row(children: [
                    SizedBox(
                      width: 17,
                      child: Center(
                        child: app.busy && app.busyTarget == t.id
                            ? SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 2, color: ty.p.sideInk))
                            : StatusMark(app.health[t.id], size: 8),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(t.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
                    if (t.cloneOf.isNotEmpty) Tooltip(message: tr('Clone of "{name}"', {'name': t.cloneOf}), child: const Icon(Icons.content_copy, size: 13)),
                  ]),
                  indent: 14,
                  menu: [
                    open('t:${t.id}'),
                    MenuItemButton(
                        leadingIcon: const Icon(Icons.tune, size: 17),
                        onPressed: app.busy ? null : () => _go(context, 't:${t.id}:settings'),
                        child: Text(tr('Settings'))),
                    const Divider(height: 9),
                    delete(tr('Delete this target…'), (c) => askRemoveTarget(c, app, pr, t)),
                  ],
                ),
              const SizedBox(height: 4),
            ],
          ]),
        ),
        Container(height: 1, color: Colors.white.withValues(alpha: .10)),
        const SizedBox(height: 8),
        action(tr('New project'), Icons.add, () => _newProject(context)),
        action(tr('Import a project…'), Icons.file_open_outlined, () => _import(context)),
        item('settings', Row(children: [
          const Icon(Icons.tune, size: 17),
          const SizedBox(width: 10),
          Text(tr('Settings'), style: const TextStyle(fontSize: 13.5)),
        ])),
        const SizedBox(height: 12),
      ]),
    );
  }
}

/// A line of the side panel. A project or a target also has its menu (open, delete…): right click on the line, or
/// its "⋯" button, shown while the mouse is over the line.
class _NavItem extends StatefulWidget {
  const _NavItem({required this.route, required this.on, required this.onTap, required this.child, this.indent = 0, this.menu = const []});
  final String route;
  final bool on;
  final VoidCallback onTap;
  final Widget child;
  final double indent;
  final List<Widget> menu;
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  final _menu = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final on = widget.on;
    final hasMenu = widget.menu.isNotEmpty;
    final ink = on ? Colors.white : ty.p.sideInk;
    Widget line = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(color: on ? ty.p.selected : Colors.transparent, borderRadius: BorderRadius.circular(8)),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey('nav-${widget.route}'),
            borderRadius: BorderRadius.circular(8),
            hoverColor: Colors.white.withValues(alpha: .06),
            onTap: widget.onTap,
            child: Container(
              height: 34,
              padding: EdgeInsets.only(left: 10 + widget.indent, right: hasMenu ? 2 : 8),
              alignment: Alignment.centerLeft,
              child: DefaultTextStyle.merge(
                style: TextStyle(color: ink, fontWeight: on ? FontWeight.w600 : null),
                child: IconTheme.merge(
                  data: IconThemeData(color: on ? Colors.white : ty.p.sideMuted),
                  child: !hasMenu
                      ? widget.child
                      : Row(children: [
                          Expanded(child: widget.child),
                          Visibility.maintain(
                            visible: _hover || _menu.isOpen,
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: IconButton(
                                key: ValueKey('nav-menu-${widget.route}'),
                                tooltip: tr('More'),
                                padding: EdgeInsets.zero,
                                iconSize: 17,
                                color: ink,
                                onPressed: () {
                                  if (_menu.isOpen) return _menu.close();
                                  final size = context.size; // under the "⋯" button
                                  _menu.open(position: size == null ? null : Offset(size.width - 46, size.height - 2));
                                },
                                icon: const Icon(Icons.more_horiz),
                              ),
                            ),
                          ),
                        ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!hasMenu) return line;
    line = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onSecondaryTapUp: (d) => _menu.open(position: d.localPosition), child: line),
    );
    return MenuAnchor(
      controller: _menu,
      onOpen: () => setState(() {}),
      onClose: () {
        if (mounted) setState(() {});
      },
      menuChildren: widget.menu,
      child: line,
    );
  }
}

/// Overview: every project and its targets, with their state.
class HomePage extends StatelessWidget {
  const HomePage(this.app, {super.key});
  final AppState app;

  void _newProject() => newProject(app);

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final targets = app.projects.fold(0, (n, p) => n + p.targets.length);
    return PageFrame(
      title: tr('Overview'),
      subtitle: app.projects.isEmpty
          ? null
          : Text('${pl(app.projects.length, '{n} project', '{n} projects', '{n} projet', '{n} projets')}  ·  ${pl(targets, '{n} target', '{n} targets', '{n} cible', '{n} cibles')}',
              style: ty.small),
      actions: [
        if (app.projects.isNotEmpty) ...[
          OutlinedButton(onPressed: app.busy ? null : () => importProject(app), child: Text(tr('Import a project…'))),
          FilledButton(onPressed: app.busy ? null : _newProject, child: Text(tr('New project'))),
        ],
      ],
      children: [
        if (app.projects.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text(
                  tr('Add your project (its folder on this PC), then its targets: Hostinger or any PHP hosting, a VPS, a server by IP. The app sends only what changed, runs your SQL migrations, syncs reference tables, and backs up the target before every change.'),
                  style: ty.body.copyWith(color: ty.p.muted)),
            ),
          ),
          Section(
            tr('How it works'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              StepRow(1, tr('Add your project'),
                  tr('Its folder on this PC, the files never sent, the files kept on the targets, its SQL migrations and its local database. Or import a project exported from Déploiement on another PC.'),
                  button: Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton(onPressed: app.busy ? null : () => importProject(app), child: Text(tr('Import a project…'))),
                    FilledButton(onPressed: app.busy ? null : _newProject, child: Text(tr('New project'))),
                  ])),
              StepRow(2, tr('Add its targets'),
                  tr('Hostinger or any PHP hosting by FTP or SFTP, a server by IP, a network share. The app places a small PHP agent there.')),
              StepRow(3, tr('Simulate, then deploy'),
                  tr('See what would change — files, migrations, synced rows — then send it. The target is backed up first.')),
            ]),
          ),
        ],
        for (final p in app.projects)
          Section(
            p.name,
            meta: p.folder.isEmpty ? tr('No folder yet') : p.folder,
            trailing: SmallButton(tr('Open'), onPressed: () => app.go('p:${p.id}')),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (p.targets.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(tr('No target yet.'), style: ty.small)),
              for (final t in p.targets) TargetRow(app, t),
            ]),
          ),
      ],
    );
  }
}

/// One target in a list: state, name, address, last action.
class TargetRow extends StatelessWidget {
  const TargetRow(this.app, this.t, {super.key, this.showTransport = false});
  final AppState app;
  final Target t;
  final bool showTransport;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return LedgerRow(
      onTap: () => app.go('t:${t.id}'),
      child: LayoutBuilder(builder: (context, c) {
        final name = Row(mainAxisSize: MainAxisSize.min, children: [
          StatusMark(app.health[t.id]),
          const SizedBox(width: 12),
          Flexible(child: Text(t.name, style: ty.strong, overflow: TextOverflow.ellipsis)),
        ]);
        final url = Text(t.baseUrl, style: ty.mono(size: 12.5, color: ty.p.muted), overflow: TextOverflow.ellipsis);
        final last = Text([if (showTransport) t.transport.label, t.lastAction.isEmpty ? tr('Not deployed by this app yet') : t.lastAction].join('  ·  '),
            style: ty.small, overflow: TextOverflow.ellipsis);
        if (isNarrow(c)) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            name,
            Padding(padding: const EdgeInsets.only(left: 20, top: 2), child: url),
            Padding(padding: const EdgeInsets.only(left: 20), child: last),
          ]);
        }
        return Row(children: [
          SizedBox(width: 200, child: name),
          Expanded(flex: 5, child: url),
          const SizedBox(width: 16),
          Expanded(flex: 6, child: last),
          Icon(Icons.chevron_right, size: 18, color: ty.p.faint),
        ]);
      }),
    );
  }
}

/// App settings: language, php.exe.
class SettingsPage extends StatefulWidget {
  const SettingsPage(this.app, {super.key});
  final AppState app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final php = TextEditingController(text: widget.app.settings.phpPath);

  @override
  void dispose() {
    php.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final ty = Ty.of(context);
    return PageFrame(
      kicker: 'Déploiement',
      title: tr('Settings'),
      children: [
        const SizedBox(height: 12),
        FormBlock(
          title: tr('Language'),
          child: SizedBox(
            width: 260,
            child: Choice<String>(null,
                value: app.settings.language, items: const [('en', 'English', true), ('fr', 'Français', true)], onChanged: (v) => app.setLanguage(v)),
          ),
        ),
        FormBlock(
          title: tr('php.exe on this PC'),
          description: tr('Empty: found automatically (PATH, XAMPP, Laragon, WampServer). Used to read the local databases.'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Field(tr('Path'), php,
                monospace: true,
                placeholder: r'C:\xampp\php\php.exe',
                suffix: fieldButton(Icons.folder_open_outlined, tr('Browse'), () async {
                  final f = await pickFile(filter: 'php.exe|php.exe');
                  if (f != null) setState(() => php.text = f);
                })),
            const SizedBox(height: 14),
            Row(children: [
              FilledButton(
                onPressed: () {
                  app.settings.phpPath = php.text.trim();
                  app.save();
                  app.notify(tr('Saved'));
                },
                child: Text(tr('Save')),
              ),
            ]),
          ]),
        ),
        AlertsBlock(app),
        FormBlock(
          title: tr('Settings and keys'),
          description: tr('Projects, targets and their keys are stored in this folder; passwords and keys are encrypted for your Windows account.'),
          child: SelectableText(Store.folder, style: ty.mono(size: 13)),
        ),
      ],
    );
  }
}
