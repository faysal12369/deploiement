// Windows folder / file pickers through PowerShell (System.Windows.Forms): no Flutter plugin, so building the app
// does not need Windows "Developer Mode".
import 'dart:convert';
import 'dart:io';

String _q(String s) => "'${s.replaceAll("'", "''")}'";

/// Tests answer the dialogs instead of a person: each dialog takes the next answer (null or none left = Cancel).
List<String?>? testAnswers;

Future<String?> _run(String body) async {
  final answers = testAnswers;
  if (answers != null) return answers.isEmpty ? null : answers.removeAt(0);
  final script = '[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $body';
  final r = await Process.run('powershell', ['-NoProfile', '-STA', '-Command', script], stdoutEncoding: utf8);
  final out = '${r.stdout}'.trim();
  return out.isEmpty ? null : out;
}

Future<String?> pickFolder({String? initial, String? title}) => _run(
    '\$d = New-Object System.Windows.Forms.FolderBrowserDialog; \$d.ShowNewFolderButton = \$true; '
    '${title != null ? '\$d.Description = ${_q(title)}; ' : ''}'
    '${initial != null && initial.isNotEmpty ? '\$d.SelectedPath = ${_q(initial)}; ' : ''}'
    'if (\$d.ShowDialog() -eq "OK") { \$d.SelectedPath }');

Future<String?> pickFile({String filter = 'All files (*.*)|*.*'}) => _run(
    '\$d = New-Object System.Windows.Forms.OpenFileDialog; \$d.Filter = ${_q(filter)}; '
    'if (\$d.ShowDialog() -eq "OK") { \$d.FileName }');

Future<String?> pickSaveFile({required String name, String filter = 'JSON (*.json)|*.json'}) => _run(
    '\$d = New-Object System.Windows.Forms.SaveFileDialog; \$d.FileName = ${_q(name)}; \$d.Filter = ${_q(filter)}; '
    'if (\$d.ShowDialog() -eq "OK") { \$d.FileName }');
