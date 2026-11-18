// English / Français. Texts are written in English in the code; [tr] returns the French version when the app is in
// French (fr.dart), with {placeholders} replaced by [args]. A missing translation falls back to English.
import 'package:flutter/foundation.dart';

import 'fr.dart';

final language = ValueNotifier<String>('en');

String tr(String en, [Map<String, Object?> args = const {}]) {
  var s = language.value == 'fr' ? (frenchTexts[en] ?? en) : en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// Thousands separated by a space: 12 345.
String fmtInt(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// A count with its noun, in both languages: pl(3, '{n} file', '{n} files', '{n} fichier', '{n} fichiers').
/// French takes the singular for 0 and 1.
String pl(int n, String en1, String enN, String fr1, String frN) {
  final s = language.value == 'fr' ? (n <= 1 ? fr1 : frN) : (n == 1 ? en1 : enN);
  return s.replaceAll('{n}', fmtInt(n));
}
