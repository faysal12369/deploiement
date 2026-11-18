// The simulation as a web page to keep or to send to a colleague: what a deployment would send, the lines that
// change in each file, the database and the synced rows. One self-contained .html file, light or dark, printable.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'diff.dart';
import 'i18n.dart';
import 'models.dart';
import 'operations.dart';
import 'results.dart';

/// "To send: 14 files, 2 rows." — the first line of a simulation.
String reportHeadline(Report r) {
  final files = r.newFiles.length + r.changedFiles.length + r.removedFiles.length;
  final rows = r.rowsAdded + r.rowsUpdated;
  if (r.upToDate) return tr('Up to date: nothing to send.');
  return tr('To send: {list}.', {
    'list': [
      if (files > 0) pl(files, '{n} file', '{n} files', '{n} fichier', '{n} fichiers'),
      if (r.migrations.isNotEmpty) pl(r.migrations.length, '{n} migration', '{n} migrations', '{n} migration', '{n} migrations'),
      if (r.tableChanges > 0) pl(r.tableChanges, '{n} table change', '{n} table changes', '{n} changement de table', '{n} changements de tables'),
      if (rows > 0) pl(rows, '{n} row', '{n} rows', '{n} ligne', '{n} lignes'),
    ].join(', ')
  });
}

String reportHtml(Report r, Project pr, Target t, Map<String, FileDiff> diffs, {String? note}) {
  const h = HtmlEscape();
  String two(int n) => n.toString().padLeft(2, '0');
  final d = r.time;
  final when = '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  final b = StringBuffer();
  void section(String title, String meta) => b.write('<h2>${h.convert(title)}<span>${h.convert(meta)}</span></h2>');

  b.write('''<!doctype html>
<html lang="${language.value}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${h.convert('${tr('Simulation')} — ${t.name} — $when')}</title>
<style>
$_css</style></head><body><main>
<div class="kicker"><span class="mark"></span>Déploiement · ${h.convert(pr.name)}</div>
<h1>${h.convert(t.name)}</h1>
<div class="sub"><span class="mono">${h.convert(t.baseUrl)}</span> · ${h.convert(t.transport.label)}</div>
<div class="kicker" style="margin-top:28px">${h.convert(tr('Simulation at {time} — nothing was changed on the target', {'time': when}))}</div>
<div class="headline">${h.convert(reportHeadline(r))}</div>
''');

  // FILES
  final files = [for (final f in r.newFiles) ('A', f), for (final f in r.changedFiles) ('M', f), for (final f in r.removedFiles) ('D', f)]
    ..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
  section(tr('Files'), [
    pl(r.newFiles.length, '{n} new', '{n} new', '{n} nouveau', '{n} nouveaux'),
    pl(r.changedFiles.length, '{n} changed', '{n} changed', '{n} modifié', '{n} modifiés'),
    pl(r.removedFiles.length, '{n} removed', '{n} removed', '{n} retiré', '{n} retirés'),
    tr('{n} in the project', {'n': fmtInt(r.total)}),
  ].join('  ·  '));
  if (files.isEmpty) b.write('<p class="note">${h.convert(tr('No file to send.'))}</p>');
  String? folder;
  for (final (k, path) in files) {
    final dir = p.posix.dirname(path);
    if (dir != folder) {
      folder = dir;
      b.write('<div class="folder mono">${h.convert(dir == '.' ? tr('(project folder)') : '$dir/')}</div>');
    }
    final diff = diffs[path];
    final name = '<span class="k $k">$k</span>${h.convert(p.posix.basename(path))}';
    if (diff == null) {
      b.write('<div class="file mono">$name</div>');
      continue;
    }
    b.write('<details><summary class="mono">$name<span class="n">');
    if (diff.binary) {
      b.write(h.convert(tr('binary file')));
    } else if (diff.onlyLineEndings) {
      b.write(h.convert(tr('only the line endings differ')));
    } else {
      b.write('<span class="A">+${diff.added}</span> <span class="D">−${diff.removed}</span>');
    }
    b.write('</span></summary>');
    if (!diff.binary && !diff.onlyLineEndings) {
      b.write('<pre>');
      for (final hk in diff.hunks()) {
        if (hk.skipped > 0) {
          b.write('<div class="skip">… ${h.convert(pl(hk.skipped, '{n} unchanged line', '{n} unchanged lines', '{n} ligne inchangée', '{n} lignes inchangées'))}</div>');
          continue;
        }
        for (final l in hk.lines) {
          final cls = switch (l.op) { Op.removed => ' class="del"', Op.added => ' class="add"', _ => '' };
          final sign = switch (l.op) { Op.removed => '−', Op.added => '+', _ => ' ' };
          b.write('<div$cls><span class="ln">${l.oldNo ?? ''}</span><span class="ln">${l.newNo ?? ''}</span>$sign ${h.convert(l.text)}</div>');
        }
      }
      b.write('</pre>');
    }
    b.write('</details>');
  }
  if (note != null) b.write('<p class="note">${h.convert(note)}</p>');

  // DATABASE
  final tables = r.missing.where((m) => m.$2 == null).length;
  section(tr('Database'), !r.dbOk ? tr('No database on the target (or no settings): migrations and synced tables are skipped.') : '');
  if (r.dbOk) {
    if (r.migrations.isEmpty && r.missing.isEmpty) b.write('<p class="note">${h.convert(tr('No structure change.'))}</p>');
    for (final (path, reason) in r.migrations) {
      b.write('<div class="row"><span class="mono">${h.convert(p.posix.basename(path))}</span><span class="sub">${h.convert(reason == 'changed' ? tr('file changed') : tr('not run yet'))}</span></div>');
    }
    if (r.missing.isNotEmpty) {
      b.write('<p class="note">${h.convert(tr('Added by the migrations:'))} ');
      b.write(r.missing.map((m) => '<span class="mono A">+ ${h.convert(m.$2 == null ? m.$1 : '${m.$1}.${m.$2}')}</span>').join(' &nbsp; '));
      b.write(' (${h.convert(pl(tables, '{n} table', '{n} tables', '{n} table', '{n} tables'))})</p>');
    }
    if (r.baseline.isNotEmpty) {
      b.write('<p class="note">${h.convert(tr('{n} migration(s) already in the project folder of the target: recorded as applied, not run.', {'n': r.baseline.length}))}</p>');
    }
  }

  // STRUCTURE OF THE CHOSEN TABLES
  if (r.dbOk && r.tables.isNotEmpty) {
    section(tr('Structure of the chosen tables'), r.tableChanges == 0 ? tr('the same as on this PC') : tr('nothing removed'));
    for (final t in r.tables) {
      b.write('<div class="row"><span class="mono">${h.convert(t.table)}</span><span class="sub">${h.convert(t.create ? tr('created') : (t.changes.isEmpty ? tr('the same as on this PC') : ''))}</span></div>');
      if (!t.create) {
        for (final c in t.changes) {
          final cls = c.what == 'change_column' ? 'M' : 'A';
          final txt = c.what == 'change_column' ? '~ ${c.before}  →  ${c.after}' : '+ ${c.sql.replaceFirst(RegExp(r'^ALTER TABLE `[^`]+` (ADD COLUMN |ADD )?'), '').replaceFirst(RegExp(r' (AFTER `[^`]+`|FIRST)$'), '')}';
          b.write('<div class="detail mono $cls">${h.convert(txt)}</div>');
        }
      }
    }
  }

  // SYNCED DATA
  if (r.dbOk && r.sync.isNotEmpty) {
    section(tr('Synced data'), [
      pl(r.rowsAdded, '+{n} added', '+{n} added', '+{n} ajoutée', '+{n} ajoutées'),
      pl(r.rowsUpdated, '{n} updated', '{n} updated', '{n} mise à jour', '{n} mises à jour'),
      pl(r.rowsSkipped, '{n} skipped', '{n} skipped', '{n} écartée', '{n} écartées'),
      tr('nothing deleted'),
    ].join('  ·  '));
    b.write('<table><tr><th>${h.convert(tr('Table'))}</th><th>${h.convert(tr('added'))}</th><th>${h.convert(tr('updated'))}</th><th>${h.convert(tr('same'))}</th><th>${h.convert(tr('skipped'))}</th></tr>');
    String n(int v, String cls, String sign) => v == 0 ? '<span class="sub">—</span>' : '<span class="num $cls">$sign${fmtInt(v)}</span>';
    for (final s in r.sync) {
      b.write('<tr><td class="mono">${h.convert(s.table)}');
      for (final (k, txt) in s.details) {
        final cls = switch (k) { 'add' => 'A', 'update' => 'M', 'unlink' => 'M', _ => 'D' };
        b.write('<div class="detail $cls">${switch (k) { 'add' => '+', 'update' => '~', 'unlink' => '○', _ => '×' }} ${h.convert(txt)}</div>');
      }
      b.write('</td><td>${n(s.added + s.pending, 'A', '+')}</td><td>${n(s.updated, 'M', '')}</td><td>${n(s.same, '', '')}</td><td>${n(s.skipped, 'D', '')}</td></tr>');
    }
    b.write('</table>');
  }

  // TARGET DATA
  if (r.summary != null) {
    section(tr('Target data'), [
      pl(r.summary!.tables, '{n} table', '{n} tables', '{n} table', '{n} tables'),
      pl(r.summary!.rows, 'about {n} row', 'about {n} rows', 'environ {n} ligne', 'environ {n} lignes'),
      tr('kept as they are'),
    ].join('  ·  '));
    for (final (name, rows) in r.summary!.top.take(12)) {
      b.write('<div class="row"><span class="mono">${h.convert(name)}</span><span class="num">${fmtInt(rows)}</span></div>');
    }
  }
  b.write('<p class="note">${h.convert(tr('Before deploying, the target database and files are backed up on the target. "Restore a backup…" puts them back.'))}</p>');
  b.write('<footer>${h.convert(tr('Made by Déploiement on {pc}, {date}.', {'pc': Platform.localHostname, 'date': when}))}</footer></main></body></html>');
  return b.toString();
}

/// The look of the pages written by the app (simulation, comparison of databases), light or dark, printable.
const _css = ''':root{--bg:#F1F5F9;--ink:#0F172A;--muted:#475569;--faint:#94A3B8;--rule:#E2E8F0;--strong:#CBD5E1;--sunken:#F8FAFC;--add:#15803D;--chg:#B45309;--del:#DC2626;--accent:#1D63ED}
@media (prefers-color-scheme:dark){:root{--bg:#0B1220;--ink:#E2E8F0;--muted:#94A3B8;--faint:#64748B;--rule:#1E2A44;--strong:#334155;--sunken:#0E1628;--add:#4ADE80;--chg:#FBBF24;--del:#F87171;--accent:#4C8DF6}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
main{max-width:1080px;margin:0 auto;padding:40px 24px 64px}
.kicker,h2,th{font-family:Bahnschrift,"DIN Alternate","Segoe UI",sans-serif;text-transform:uppercase;letter-spacing:.08em;font-size:11.5px;font-weight:600;color:var(--muted)}
h1{font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:600;font-size:30px;margin:4px 0 6px}
.sub{color:var(--muted)}.mark{display:inline-block;width:10px;height:10px;background:var(--accent);margin-right:8px}
.headline{font-family:Bahnschrift,"Segoe UI",sans-serif;font-size:20px;font-weight:600;margin:28px 0 0}
h2{color:var(--ink);margin:34px 0 0;padding-bottom:8px;border-bottom:1px solid var(--strong);display:flex;gap:14px;align-items:baseline}
h2 span{font-family:"Segoe UI",sans-serif;text-transform:none;letter-spacing:0;font-weight:400;color:var(--muted);font-size:12.5px}
code,pre,.mono{font-family:"Cascadia Mono",Consolas,monospace;font-size:12.5px}
.folder{margin:12px 0 2px;color:var(--muted);font-weight:700}.file{padding:2px 0 2px 14px}
.A{color:var(--add)}.M{color:var(--chg)}.D{color:var(--del)}.k{display:inline-block;width:20px;font-weight:700}
details{margin:2px 0 2px 14px}summary{cursor:pointer;padding:2px 0}summary .n{color:var(--muted);font-family:"Segoe UI",sans-serif;font-size:12px;margin-left:10px}
pre{margin:6px 0 12px;background:var(--sunken);border:1px solid var(--rule);padding:6px 0;overflow-x:auto;white-space:pre}
pre div{padding:0 12px}pre .del{background:color-mix(in srgb,var(--del) 12%,transparent)}pre .add{background:color-mix(in srgb,var(--add) 12%,transparent)}
pre .ln{color:var(--faint);display:inline-block;width:4.5em;text-align:right;margin-right:1em;user-select:none}pre .skip{color:var(--faint);font-family:"Segoe UI",sans-serif}
table{width:100%;border-collapse:collapse}th{text-align:right;padding:8px 0 8px 12px;border-bottom:1px solid var(--rule)}th:first-child,td:first-child{text-align:left;padding-left:0}
td{padding:7px 0 7px 12px;border-bottom:1px solid var(--rule);text-align:right;vertical-align:top}.num{font-family:Bahnschrift,"Segoe UI",sans-serif}
.detail{font-family:"Cascadia Mono",Consolas,monospace;font-size:12px;padding-left:16px}.note{color:var(--muted);font-size:12.5px;margin-top:14px}
.row{padding:7px 0;border-bottom:1px solid var(--rule);display:flex;justify-content:space-between;gap:16px}
footer{margin-top:40px;color:var(--faint);font-size:12px}
@media print{body{background:#fff}details{display:block}details>pre{display:block}}
''';

/// The comparison of the data of this PC and of a target as a web page, grouped by kind of difference.
String dataCompareHtml(DbCompare c, Project pr, Target t) {
  const h = HtmlEscape(HtmlEscapeMode.element); // only in element content: "viewer / read" stays readable in the source
  String two(int n) => n.toString().padLeft(2, '0');
  final d = c.time;
  final when = '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  final b = StringBuffer();
  b.write('''<!doctype html>
<html lang="${language.value}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${h.convert('${tr('Compare databases')} — ${t.name} — $when')}</title>
<style>
$_css
.bad{color:var(--del);font-weight:600}.warn{color:var(--chg)}details ul{margin:6px 0 4px;padding-left:18px;max-height:340px;overflow:auto}
details ul li{font-family:"Cascadia Mono",Consolas,monospace;font-size:12px;padding:1px 0}
</style></head><body><main>
<div class="kicker"><span class="mark"></span>Déploiement · ${h.convert(pr.name)}</div>
<h1>${h.convert(tr('This PC and "{name}"', {'name': t.name}))}</h1>
<div class="sub">${h.convert(tr('This PC: {db} ({server}), {rows} rows', {'db': c.pc.database, 'server': c.pc.server, 'rows': fmtInt(c.pc.rows)}))} · ${h.convert(tr('target: {db} ({server}), {rows} rows', {'db': c.target.database, 'server': c.target.server, 'rows': fmtInt(c.target.rows)}))}</div>
<div class="kicker" style="margin-top:28px">${h.convert(tr('Compared at {time} — nothing was changed on either side', {'time': when}))}</div>
<div class="headline">${h.convert(dataHeadline(c))}</div>
<p class="note">${h.convert(tr('Rows are recognised by their key (a reference, a code, a unique index), never by their id, which differs between copies.'))}</p>
''');
  for (final g in DataRank.values) {
    final list = c.tables.where((x) => x.rank == g).toList();
    if (list.isEmpty) continue;
    b.write('<h2>${h.convert(dataGroupTitle(g))}<span>${h.convert(pl(list.length, '{n} table', '{n} tables', '{n} table', '{n} tables'))}</span></h2>');
    b.write('<table><tr><th>${h.convert(tr('Table'))}</th><th>${h.convert(tr('This PC'))}</th><th>${h.convert(tr('Target'))}</th><th style="text-align:left">${h.convert(tr('Difference'))}</th></tr>');
    for (final x in list) {
      b.write('<tr><td class="mono">${h.convert(x.table)}');
      if (x.byKey) b.write('<div class="note" style="margin:2px 0 0">${h.convert(tr('key: {key}', {'key': x.keyText}))}</div>');
      b.write('</td><td class="num">${x.pc == null ? '—' : fmtInt(x.pc!.rows)}</td><td class="num">${x.target == null ? '—' : fmtInt(x.target!.rows)}</td><td style="text-align:left">');
      b.write(h.convert(dataGap(x)));
      void rows(List<String> l, String title, String cls) {
        if (l.isEmpty) return;
        const most = 300;
        b.write('<details><summary class="$cls">${h.convert(title)}</summary><ul>');
        for (final v in l.take(most)) {
          b.write('<li>${h.convert(v)}</li>');
        }
        if (l.length > most) b.write('<li>${h.convert(tr('… and {n} more', {'n': fmtInt(l.length - most)}))}</li>');
        b.write('</ul></details>');
      }

      rows(x.onlyPc, pl(x.onlyPc.length, '{n} row of this PC missing on the target', '{n} rows of this PC missing on the target', '{n} ligne de ce PC absente de la cible', '{n} lignes de ce PC absentes de la cible'), 'bad');
      rows(x.onlyTarget, pl(x.onlyTarget.length, '{n} row only on the target', '{n} rows only on the target', '{n} ligne seulement sur la cible', '{n} lignes seulement sur la cible'), '');
      if (x.byKey && (x.pc!.noKey > 0 || x.target!.noKey > 0)) {
        b.write('<div class="note" style="margin:4px 0 0">${h.convert(tr('Without a key (counted only): this PC {a}, target {b}', {'a': x.pc!.noKey, 'b': x.target!.noKey}))}</div>');
      }
      b.write('</td></tr>');
    }
    b.write('</table>');
  }
  b.write('<footer>${h.convert(tr('Made by Déploiement on {pc}, {date}.', {'pc': Platform.localHostname, 'date': when}))}</footer></main></body></html>');
  return b.toString();
}

/// "3 tables have rows of this PC missing on the target." — the first line of a comparison.
String dataHeadline(DbCompare c) => c.withMissing == 0
    ? tr('Everything of this PC is on the target.')
    : pl(c.withMissing, '{n} table has rows of this PC missing on the target.', '{n} tables have rows of this PC missing on the target.',
        '{n} table a des lignes de ce PC absentes de la cible.', '{n} tables ont des lignes de ce PC absentes de la cible.');

String dataGroupTitle(DataRank r) => switch (r) {
      DataRank.oneSide => tr('Tables on one side only'),
      DataRank.missingOnTarget => tr('Rows of this PC missing on the target'),
      DataRank.fewerOnTarget => tr('Fewer rows on the target (compared by count only)'),
      DataRank.extraOnTarget => tr('The target has rows this PC does not have'),
      DataRank.same => tr('Identical'),
      DataRank.countOnly => tr('Counted only (logs, sessions…: they always differ)'),
    };

/// "only on this PC", "12 fewer on the target", "3 more on the target"…
String dataGap(DataCompare x) {
  if (x.target == null) return tr('only on this PC');
  if (x.pc == null) return tr('only on the target');
  if (x.byKey && x.onlyPc.isEmpty && x.onlyTarget.isEmpty && x.pc!.rows == x.target!.rows) return tr('same rows');
  final dlt = x.pc!.rows - x.target!.rows;
  if (x.byKey) return '';
  if (dlt == 0) return x.countOnly ? tr('same number') : tr('same number (no key to compare the rows)');
  return dlt > 0
      ? pl(dlt, '{n} fewer on the target', '{n} fewer on the target', '{n} de moins sur la cible', '{n} de moins sur la cible')
      : pl(-dlt, '{n} more on the target', '{n} more on the target', '{n} de plus sur la cible', '{n} de plus sur la cible');
}

/// The option of the Delta Schéma tool for the server of the target ("10.4.32-MariaDB" → maria104), '' when unknown.
/// Chosen here: the tool's own detection compares versions as decimals and takes 10.4 for 10.11 or later.
String deltaTargetKey(String version) {
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return '';
  final major = int.parse(m[1]!), minor = int.parse(m[2]!);
  if (!version.toLowerCase().contains('mariadb')) return major >= 8 ? 'mysql80' : (major == 5 && minor >= 7 ? 'mysql57' : 'mysql56');
  if (major > 10 || minor >= 11) return 'maria1011';
  if (minor >= 6) return 'maria106';
  return switch (minor) { 5 => 'maria105', 4 => 'maria104', 3 => 'maria103', 2 => 'maria102', _ => 'maria101' };
}

/// The Delta Schéma tool (assets/tools/delta-schema.html, unchanged) with both structures filled in — the target as
/// the old one, this PC as the new one — compared when the page opens: it writes the script that brings the target's
/// structure to this PC's, in the syntax of the target's server ([server]: its version).
String deltaSchemaPage(String tool, {required String oldSql, required String newSql, required String title, String server = ''}) {
  String js(String s) => jsonEncode(s).replaceAll('</', r'<\/').replaceAll('<!--', r'<\u0021--');
  final script = '''
<script>
/* Déploiement: the structure of the target (old) and of this PC (new), filled in and compared when the page opens. */
(function () {
  var oldSql = ${js(oldSql)}, newSql = ${js(newSql)}, server = ${js(deltaTargetKey(server))};
  function go() {
    var o = document.getElementById('sql-old'), n = document.getElementById('sql-new'), b = document.getElementById('btn-run'), t = document.getElementById('target');
    if (!o || !n) return;
    o.value = oldSql;
    n.value = newSql;
    if (t && server && t.querySelector('option[value="' + server + '"]')) t.value = server;
    if (b) b.click();
  }
  document.title = ${js(title)};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go); else go();
})();
</script>
''';
  final i = tool.lastIndexOf('</body>');
  return i < 0 ? '$tool$script' : '${tool.substring(0, i)}$script${tool.substring(i)}';
}
