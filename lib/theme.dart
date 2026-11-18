// The look: a navy side panel, a cool light page, white cards with a soft border, figures you read at a glance. Blue
// is the colour of action and selection (Deploy, Save, the page you are on, links); elsewhere colour carries a
// meaning: green added / online, amber changed / to check, red removed / failed. Segoe UI for text, Bahnschrift
// (Windows' DIN) for figures and small capitals, Cascadia Mono for paths and data. Light or dark like Windows.
import 'package:flutter/material.dart';

const sans = 'Segoe UI';
const din = 'Bahnschrift';
const monoFont = 'Cascadia Mono';
const monoFallback = ['Consolas', 'Courier New'];

@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.panel,
    required this.surface,
    required this.sunken,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.rule,
    required this.field,
    required this.strong,
    required this.accent,
    required this.onAccent,
    required this.added,
    required this.changed,
    required this.removed,
    required this.hover,
    required this.selected,
    required this.sideInk,
    required this.sideMuted,
  });

  final Color bg, panel, surface, sunken; // page, side panel, cards / inputs / dialogs, table heads and log
  final Color ink, muted, faint; // text
  final Color rule, field, strong; // card borders and hairlines, input borders, separators that must show
  final Color accent, onAccent;
  final Color added, changed, removed;
  final Color hover, selected;
  final Color sideInk, sideMuted; // text on the side panel

  static const light = Palette(
    bg: Color(0xFFF1F5F9),
    panel: Color(0xFF0F2342),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFF8FAFC),
    ink: Color(0xFF0F172A),
    muted: Color(0xFF475569),
    faint: Color(0xFF94A3B8),
    rule: Color(0xFFE2E8F0),
    field: Color(0xFFCBD5E1),
    strong: Color(0xFFCBD5E1),
    accent: Color(0xFF1D63ED),
    onAccent: Color(0xFFFFFFFF),
    added: Color(0xFF15803D),
    changed: Color(0xFFB45309),
    removed: Color(0xFFDC2626),
    hover: Color(0x0A0F172A),
    selected: Color(0xFF1D63ED),
    sideInk: Color(0xFFF1F5F9),
    sideMuted: Color(0xFF94A3B8),
  );

  static const dark = Palette(
    bg: Color(0xFF0B1220),
    panel: Color(0xFF0A1830),
    surface: Color(0xFF111A2E),
    sunken: Color(0xFF0E1628),
    ink: Color(0xFFE2E8F0),
    muted: Color(0xFF94A3B8),
    faint: Color(0xFF64748B),
    rule: Color(0xFF1E2A44),
    field: Color(0xFF334155),
    strong: Color(0xFF334155),
    accent: Color(0xFF4C8DF6),
    onAccent: Color(0xFFFFFFFF),
    added: Color(0xFF4ADE80),
    changed: Color(0xFFFBBF24),
    removed: Color(0xFFF87171),
    hover: Color(0x0FE2E8F0),
    selected: Color(0xFF1D63ED),
    sideInk: Color(0xFFE2E8F0),
    sideMuted: Color(0xFF8DA2C0),
  );

  static Palette of(BuildContext context) => Theme.of(context).extension<Palette>()!;

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => other == null || t < .5 ? this : other;
}

/// Text styles of the look.
class Ty {
  Ty(this.p);
  factory Ty.of(BuildContext context) => Ty(Palette.of(context));
  final Palette p;

  static TextStyle _din(double size, FontWeight w, Color c, {double spacing = 0, double height = 1.25}) => TextStyle(
        fontFamily: din,
        fontFamilyFallback: const [sans],
        fontSize: size,
        fontWeight: w,
        fontVariations: [FontVariation.weight(w.value.toDouble())],
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: spacing,
        height: height,
        color: c,
      );

  /// Page titles.
  TextStyle get display => TextStyle(fontFamily: sans, fontSize: 26, fontWeight: FontWeight.w600, height: 1.15, letterSpacing: -.2, color: p.ink);

  /// Dialog titles, the first line of a report.
  TextStyle get title => TextStyle(fontFamily: sans, fontSize: 19, fontWeight: FontWeight.w600, height: 1.25, color: p.ink);

  /// Card titles.
  TextStyle get cardTitle => TextStyle(fontFamily: sans, fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: p.ink);

  /// The big figure of a tile.
  TextStyle bigFigure({Color? color}) => _din(32, FontWeight.w600, color ?? p.ink, height: 1.05);

  /// Small capitals over sections and table columns (the text is upper-cased by the caller).
  TextStyle caps({Color? color}) => _din(11.5, FontWeight.w600, color ?? p.muted, spacing: 1.1);

  /// Buttons.
  TextStyle get button => TextStyle(fontFamily: sans, fontSize: 13.5, fontWeight: FontWeight.w600, height: 1, color: p.ink);

  /// Figures in tables.
  TextStyle figure({Color? color, double size = 14, FontWeight weight = FontWeight.w400}) => _din(size, weight, color ?? p.ink);

  TextStyle get body => TextStyle(fontFamily: sans, fontSize: 14, height: 1.45, color: p.ink);
  TextStyle get strong => body.copyWith(fontWeight: FontWeight.w600);
  TextStyle get small => TextStyle(fontFamily: sans, fontSize: 12.5, height: 1.4, color: p.muted);
  TextStyle get label => TextStyle(fontFamily: sans, fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w600, color: p.muted);

  TextStyle mono({double size = 12.5, Color? color, FontWeight weight = FontWeight.w400}) =>
      TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: size, color: color ?? p.ink, fontWeight: weight, height: 1.55);
}

/// Kept for the pages that still call it with a context.
TextStyle monoStyle(BuildContext context, {double size = 12.5, Color? color, FontWeight weight = FontWeight.w400}) =>
    Ty.of(context).mono(size: size, color: color, weight: weight);

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.light ? Palette.light : Palette.dark;
  final ty = Ty(p);
  final square = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final outline = OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.field));
  final base = ThemeData(brightness: b, useMaterial3: true, fontFamily: sans);
  return base.copyWith(
    colorScheme: ColorScheme(
      brightness: b,
      primary: p.accent,
      onPrimary: p.onAccent,
      secondary: p.ink,
      onSecondary: p.bg,
      error: p.removed,
      onError: p.onAccent,
      surface: p.surface,
      onSurface: p.ink,
      onSurfaceVariant: p.muted,
      outline: p.field,
      outlineVariant: p.rule,
      surfaceContainerHighest: p.sunken,
      surfaceContainerHigh: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerLow: p.surface,
      surfaceTint: Colors.transparent,
    ),
    extensions: [p],
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    hoverColor: p.hover,
    focusColor: p.accent.withValues(alpha: .14),
    dividerColor: p.rule,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    textTheme: base.textTheme.apply(fontFamily: sans, bodyColor: p.ink, displayColor: p.ink),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.ink, selectionColor: p.accent.withValues(alpha: .25), selectionHandleColor: p.accent),
    dividerTheme: DividerThemeData(color: p.rule, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.muted, size: 18),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.rule,
        disabledForegroundColor: p.faint,
        shape: square,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: ty.button,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? p.faint : p.ink),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.disabled) ? p.rule : (s.contains(WidgetState.hovered) ? p.faint : p.field))),
        backgroundColor: WidgetStatePropertyAll(p.surface),
        overlayColor: WidgetStatePropertyAll(p.hover),
        shape: WidgetStatePropertyAll(square),
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
        textStyle: WidgetStatePropertyAll(ty.button),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        disabledForegroundColor: p.faint,
        shape: square,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: ty.button,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: p.muted, shape: square, minimumSize: const Size(32, 32), padding: EdgeInsets.zero)),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(color: p.faint, fontFamily: sans, fontSize: 13.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      border: outline,
      enabledBorder: outline,
      disabledBorder: outline.copyWith(borderSide: BorderSide(color: p.rule)),
      focusedBorder: outline.copyWith(borderSide: BorderSide(color: p.accent, width: 1.5)),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: p.field, width: 1.4),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      overlayColor: WidgetStatePropertyAll(p.hover),
      visualDensity: VisualDensity.compact,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.rule)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: .3)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.rule))),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? p.faint : p.ink),
        overlayColor: WidgetStatePropertyAll(p.hover),
        textStyle: WidgetStatePropertyAll(ty.body.copyWith(fontSize: 13.5)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
        minimumSize: const WidgetStatePropertyAll(Size(220, 36)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: ty.body,
      inputDecorationTheme: InputDecorationTheme(isDense: true, filled: true, fillColor: p.surface, border: outline, enabledBorder: outline),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.rule))),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: TextStyle(color: p.bg, fontFamily: sans, fontSize: 13.5, height: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 6,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: p.bg, fontFamily: sans, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: Colors.transparent, linearMinHeight: 2),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.faint.withValues(alpha: .5)),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: p.panel, surfaceTintColor: Colors.transparent, shape: const RoundedRectangleBorder(), width: 280),
  );
}
