// "SQL…" (asked 17/11/2026: "write SQL myself when I only want to change the structure, not the data"): an editor
// for a target (the query runs there; a backup of its database first when it changes something) or for the local
// database of the project; what is typed can also become a migration of the project, which "Deploy" (Structure)
// then runs once on every target.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'dialogs.dart';
import 'i18n.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets.dart';

/// What one statement gave: its rows (a reading query), or how many rows it changed, or its error.
class SqlOutcome {
  SqlOutcome({required this.sql, this.columns = const [], this.rows = const [], this.count = 0, this.affected, this.error, this.ms = 0});
  final String sql;
  final List<String> columns;
  final List<List<String?>> rows;
  final int count; // rows found (only the first 500 are sent)
  final int? affected; // a statement that changes something
  final String? error;
  final int ms;
  bool get reads => affected == null && error == null;

  factory SqlOutcome.from(Map<String, dynamic> j) => SqlOutcome(
        sql: '${j['sql'] ?? ''}',
        columns: [for (final c in (j['columns'] as List? ?? [])) '$c'],
        rows: [for (final r in (j['rows'] as List? ?? [])) [for (final v in (r as List)) v?.toString()]],
        count: (j['count'] as num?)?.toInt() ?? 0,
        affected: (j['affected'] as num?)?.toInt(),
        error: j['error'] as String?,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
      );
}

/// The statements of [sql], comments left out (for the checks below; the agent splits them for real).
List<String> sqlStatements(String sql) {
  final noComments = sql.replaceAll(RegExp(r'/\*(?!!).*?\*/', dotAll: true), ' ').replaceAll(RegExp(r'(^|\n)\s*(--|#)[^\n]*'), '\n');
  return [for (final s in noComments.split(';')) if (s.trim().isNotEmpty) s.trim()];
}

final _reading = RegExp(r'^\(?\s*(SELECT|SHOW|DESCRIBE|DESC|EXPLAIN|WITH)\b', caseSensitive: false);

/// Something in [sql] changes the database (not only SELECT, SHOW…): a backup comes first.
bool sqlChanges(String sql) => sqlStatements(sql).any((s) => !_reading.hasMatch(s));

/// What in [sql] deletes something: asked again before it runs.
List<String> sqlDangers(String sql) => [
      for (final s in sqlStatements(sql))
        if (RegExp(r'^\s*(DROP|TRUNCATE)\b', caseSensitive: false).hasMatch(s) ||
            RegExp(r'^\s*ALTER\s+TABLE\b[\s\S]*\bDROP\b', caseSensitive: false).hasMatch(s) ||
            (RegExp(r'^\s*DELETE\b', caseSensitive: false).hasMatch(s) && !RegExp(r'\bWHERE\b', caseSensitive: false).hasMatch(s)) ||
            (RegExp(r'^\s*UPDATE\b', caseSensitive: false).hasMatch(s) && !RegExp(r'\bWHERE\b', caseSensitive: false).hasMatch(s)))
          s.replaceAll(RegExp(r'\s+'), ' ').substring(0, s.replaceAll(RegExp(r'\s+'), ' ').length.clamp(0, 80)),
    ];

/// The folder of the migrations of [pr] (database/migrations when none is set yet).
String migrationsFolderOf(Project pr) => pr.migrationsFolder.trim().isEmpty ? 'database/migrations' : pr.migrationsFolder.trim();

/// The next migration file: the number after the highest one of the folder (same width, e.g. 173 after 172), then
/// the name in lower case: "Add phone to clients" → 173_add_phone_to_clients.sql.
File nextMigration(Project pr, String name) {
  final dir = Directory(p.join(pr.folder, migrationsFolderOf(pr)));
  var top = 0, width = 3;
  if (dir.existsSync()) {
    for (final f in dir.listSync().whereType<File>()) {
      final m = RegExp(r'^(\d+)').firstMatch(p.basename(f.path));
      if (m != null && int.parse(m[1]!) >= top) {
        top = int.parse(m[1]!);
        width = m[1]!.length > width ? m[1]!.length : width;
      }
    }
  }
  final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return File(p.join(dir.path, '${'${top + 1}'.padLeft(width, '0')}_${slug.isEmpty ? 'change' : slug}.sql'));
}

/// Writes [sql] as the next migration of [pr] and returns the file (the migrations folder is set when it was empty).
File saveMigration(Project pr, String name, String sql) {
  final f = nextMigration(pr, name);
  f.parent.createSync(recursive: true);
  String two(int n) => n.toString().padLeft(2, '0');
  final d = DateTime.now();
  final head = '-- ${name.trim().isEmpty ? 'Change' : name.trim()}\n-- Written with Déploiement on ${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}\n\n';
  f.writeAsStringSync('$head${sql.trim()}${sql.trim().endsWith(';') ? '' : ';'}\n');
  if (pr.migrationsFolder.trim().isEmpty) pr.migrationsFolder = migrationsFolderOf(pr);
  return f;
}

/// The last query typed for each place (kept while the app is open).
final _drafts = <String, String>{};

/// [target]: run there; null: the local database of the project. [migration]: opened to write a migration.
Future<void> showSqlDialog(BuildContext context, AppState app, Project pr, {Target? target, bool migration = false, List<SqlOutcome>? results}) =>
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (_) => SqlDialog(app: app, project: pr, target: target, migration: migration, results: results),
    );

class SqlDialog extends StatefulWidget {
  const SqlDialog({super.key, required this.app, required this.project, this.target, this.migration = false, this.results});
  final AppState app;
  final Project project;
  final Target? target;
  final bool migration;
  final List<SqlOutcome>? results;
  @override
  State<SqlDialog> createState() => _SqlDialogState();
}

class _SqlDialogState extends State<SqlDialog> {
  String get where => widget.target?.id ?? 'local:${widget.project.id}';
  late final sql = TextEditingController(text: _drafts[where] ?? '');
  late List<SqlOutcome>? results = widget.results;
  bool running = false;

  Project get pr => widget.project;
  Target? get t => widget.target;
  bool get canLocal => pr.localDb.isSet;

  @override
  void dispose() {
    _drafts[where] = sql.text;
    sql.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final text = sql.text.trim();
    if (text.isEmpty || running) return;
    final dangers = sqlDangers(text);
    if (dangers.isNotEmpty &&
        !await confirm(
          context,
          t == null ? tr('Run this on the local database?') : tr('Run this on "{name}"?', {'name': t!.name}),
          '${tr('It deletes something:')}\n${dangers.map((d) => '• $d').join('\n')}\n\n${t == null ? tr('There is no backup of the local database.') : tr('The database of the target is backed up first: "Restore a backup…" puts it back.')}',
          button: tr('Run'),
          danger: true,
        )) {
      return;
    }
    setState(() => running = true);
    final r = await widget.app.run(t, (o) => t == null ? o.runSqlLocal(pr, text) : o.runSql(t!, text));
    if (!mounted) return;
    setState(() {
      running = false;
      if (r != null) results = r;
    });
  }

  Future<void> _saveMigration() async {
    final text = sql.text.trim();
    if (text.isEmpty) return;
    if (pr.folder.trim().isEmpty || !Directory(pr.folder).existsSync()) {
      widget.app.notify(tr('Choose the folder of the project first.'), severity: Severity.warning);
      return;
    }
    final name = TextEditingController();
    final ok = await showSheet<bool>(
      context,
      title: tr('Save as a migration'),
      body: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Field(tr('What it does'), name, placeholder: tr('Add the phone to the clients'), onChanged: (_) => set(() {})),
        const SizedBox(height: 10),
        Text(tr('File: {path}', {'path': p.relative(nextMigration(pr, name.text).path, from: pr.folder).replaceAll('\\', '/')}), style: Ty.of(ctx).mono(size: 12.5)),
        const SizedBox(height: 8),
        Text(tr('"Deploy" then runs it once on each target (tick "Structure"), after a backup, and records it.'), style: Ty.of(ctx).small),
      ]),
      actions: (ctx, _) => [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        FilledButton(key: const ValueKey('sql-save-migration'), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'))),
      ],
    );
    if (ok != true) return;
    try {
      final f = saveMigration(pr, name.text, text);
      widget.app.save();
      widget.app.notify(tr('Migration saved: {path}', {'path': p.relative(f.path, from: pr.folder).replaceAll('\\', '/')}),
          text: tr('Deploy with "Structure" ticked to run it on a target.'));
    } catch (e) {
      widget.app.notify(tr('Error'), text: '$e', severity: Severity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final size = MediaQuery.sizeOf(context);
    final full = size.width < 720;
    final title = widget.migration ? tr('New SQL migration') : (t == null ? tr('SQL on the local database') : tr('SQL on "{name}"', {'name': t!.name}));
    final note = widget.migration
        ? tr('Write the change (ALTER TABLE, CREATE TABLE…). It is saved as a migration file of the project; "Deploy" runs it once on each target.')
        : (t == null
            ? tr('Runs now on the database "{db}" of this PC.', {'db': pr.localDb.name})
            : tr('Runs now on the database of "{name}". Reading queries (SELECT, SHOW…) change nothing; anything else is preceded by a backup of the database.', {'name': t!.name}));
    final editor = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _run},
      child: TextField(
        key: const ValueKey('sql-editor'),
        controller: sql,
        autofocus: true,
        minLines: 6,
        maxLines: 12,
        style: ty.mono(size: 13),
        decoration: InputDecoration(hintText: 'ALTER TABLE customers ADD COLUMN phone VARCHAR(30) NULL;\nSELECT * FROM customers LIMIT 20;'),
      ),
    );
    final actions = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (widget.migration) ...[
        FilledButton(key: const ValueKey('sql-to-migration'), onPressed: running ? null : _saveMigration, child: Text(tr('Save as a migration…'))),
        if (canLocal)
          OutlinedButton(key: const ValueKey('sql-run'), onPressed: running || widget.app.busy ? null : _run, child: Text(tr('Try on the local database'))),
      ] else ...[
        FilledButton(key: const ValueKey('sql-run'), onPressed: running || widget.app.busy ? null : _run, child: Text(tr('Run'))),
        OutlinedButton(onPressed: running ? null : _saveMigration, child: Text(tr('Save as a migration…'))),
      ],
      Text(tr('Ctrl+Enter runs'), style: ty.small.copyWith(color: p.faint)),
      if (running) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
    ]);
    return Dialog(
      insetPadding: full ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      shape: full ? const RoundedRectangleBorder() : null,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: full ? size.width : (size.width - 48).clamp(320, 1100).toDouble(),
        height: full ? size.height : size.height * .86,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
            child: Row(children: [
              Icon(Icons.storage_outlined, size: 20, color: p.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: ty.title)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 19), tooltip: tr('Close')),
            ]),
          ),
          Container(height: 1, color: p.rule),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 20), children: [
              Text(note, style: ty.small),
              const SizedBox(height: 10),
              editor,
              const SizedBox(height: 10),
              actions,
              if (results != null) ...[
                const SizedBox(height: 18),
                if (results!.isEmpty) Text(tr('Nothing to run.'), style: ty.small),
                for (final r in results!) _Outcome(r),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome(this.r);
  final SqlOutcome r;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final (icon, color, what) = r.error != null
        ? (Icons.error_outline, p.removed, r.error!)
        : r.reads
            ? (Icons.table_rows_outlined, p.accent,
                r.count > r.rows.length ? tr('{n} rows ({shown} shown)', {'n': fmtInt(r.count), 'shown': fmtInt(r.rows.length)}) : pl(r.count, '{n} row', '{n} rows', '{n} ligne', '{n} lignes'))
            : (Icons.check_circle_outline, p.added, pl(r.affected ?? 0, '{n} row changed', '{n} rows changed', '{n} ligne modifiée', '{n} lignes modifiées'));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: p.surface, border: Border.all(color: r.error != null ? p.removed.withValues(alpha: .5) : p.rule), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(r.sql, style: ty.mono(size: 12), minLines: 1, maxLines: 3),
                const SizedBox(height: 2),
                Text(what, style: ty.small.copyWith(color: r.error != null ? p.removed : p.muted)),
              ]),
            ),
            Text('${r.ms} ms', style: ty.small.copyWith(color: p.faint)),
          ]),
        ),
        if (r.reads && r.columns.isNotEmpty) ...[
          Container(height: 1, color: p.rule),
          DataGrid(columns: r.columns, rows: r.rows, maxHeight: 320),
        ],
      ]),
    );
  }
}
