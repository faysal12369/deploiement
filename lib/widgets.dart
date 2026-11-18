// Building blocks of the cards dashboard: page header card, section cards, stat tiles, badges, ledger rows, facts,
// form cards, fields, grids.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'i18n.dart';
import 'motion.dart';
import 'theme.dart';

/// Width breakpoints of the content area.
bool isNarrow(BoxConstraints c) => c.maxWidth < 640;

/// A white card with a soft border.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.margin = const EdgeInsets.only(top: 16), this.color});
  final Widget child;
  final EdgeInsets padding, margin;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.rule),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.light ? .03 : 0), blurRadius: 3, offset: const Offset(0, 1))],
      ),
      child: child,
    );
  }
}

/// A page: its header in a card (small capitals, title, subtitle, actions on the right — under the title on narrow
/// windows), then the content, scrolled, never wider than a comfortable reading width.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, this.kicker, required this.title, this.subtitle, this.actions = const [], this.top, this.onBack, required this.children});
  final String? kicker;
  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final Widget? top; // a thin progress line over the page
  final VoidCallback? onBack;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 880;
      final pad = c.maxWidth < 640 ? 14.0 : 32.0;
      final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (kicker != null || onBack != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              if (onBack != null)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onBack,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.arrow_back, size: 15, color: ty.p.muted),
                      const SizedBox(width: 4),
                      if (kicker == null) Text(tr('Back').toUpperCase(), style: ty.caps()),
                    ]),
                  ),
                ),
              if (kicker != null) Flexible(child: Text(kicker!.toUpperCase(), style: ty.caps(), overflow: TextOverflow.ellipsis)),
            ]),
          ),
        Text(title, style: ty.display),
        if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 8), child: subtitle),
      ]);
      final bar = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 2, child: top),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, narrow ? 12 : 22, pad, 48),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Appear(
                   child: AppCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
                    child: narrow || actions.isEmpty
                        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            heading,
                            if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 14), child: bar),
                          ])
                        : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                            Expanded(child: heading),
                            const SizedBox(width: 24),
                            bar,
                          ]),
                  )),
                  for (final (i, c) in children.indexed) Appear(index: i + 1, child: c),
                ]),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

/// A card of a page: an icon and a title, some facts next to them, actions on the right, a line, the content.
class Section extends StatelessWidget {
  const Section(this.title, {super.key, this.meta, this.trailing, required this.child, this.gap = 16, this.icon, this.flush = false});
  final String title;
  final String? meta;
  final Widget? trailing;
  final Widget child;
  final double gap;
  final IconData? icon;
  final bool flush; // the content touches the card's sides (grids)

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return AppCard(
      margin: EdgeInsets.only(top: gap),
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (icon != null) ...[
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: ty.p.sunken, borderRadius: BorderRadius.circular(8), border: Border.all(color: ty.p.rule)),
                child: Icon(icon, size: 16, color: ty.p.muted),
              ),
              const SizedBox(width: 10),
            ],
            Text(title, style: ty.cardTitle),
            const SizedBox(width: 12),
            Expanded(child: meta == null ? const SizedBox() : Text(meta!, style: ty.small, maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ]),
        ),
        Container(height: 1, color: ty.p.rule),
        Padding(padding: flush ? const EdgeInsets.only(bottom: 4) : const EdgeInsets.fromLTRB(18, 2, 18, 14), child: child),
      ]),
    );
  }
}

/// A figure of the dashboard: label, big number, what it is made of.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.label, required this.value, this.caption, this.color, this.onTap});
  final IconData icon;
  final String label, value;
  final String? caption;
  final Color? color; // the figure's colour when it means something
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final c = color ?? ty.p.ink;
    return Material(
      color: ty.p.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: ty.p.rule)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 15, color: ty.p.faint),
              const SizedBox(width: 6),
              Expanded(child: Text(label.toUpperCase(), style: ty.caps(), overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 10),
            CountUp(value, style: ty.bigFigure(color: c)),
            if (caption != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(caption!, style: ty.small, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );
  }
}

/// Tiles side by side: 4 on wide windows, 2 on medium ones, 1 under the other on narrow ones.
class TileRow extends StatelessWidget {
  const TileRow(this.tiles, {super.key});
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: LayoutBuilder(builder: (context, c) {
          final per = c.maxWidth >= 860 ? tiles.length : (c.maxWidth >= 360 ? 2 : 1);
          final w = (c.maxWidth - (per - 1) * 12) / per;
          return Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
        }),
      );
}

/// A small coloured label: "● Online", "Agent 4", "PHP 8.2.12".
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.dot = false, this.icon});
  final String text;
  final Color? color;
  final bool dot;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final c = color ?? ty.p.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color == null ? ty.p.sunken : c.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color == null ? ty.p.rule : c.withValues(alpha: .25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)), const SizedBox(width: 6)],
        if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 5)],
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis, maxLines: 1, style: ty.small.copyWith(color: color == null ? ty.p.muted : c, fontWeight: FontWeight.w600, fontSize: 12))),
      ]),
    );
  }
}

/// A row of a list inside a card: a hairline under it, a hover tint when it opens something.
class LedgerRow extends StatelessWidget {
  const LedgerRow({super.key, required this.child, this.onTap, this.vertical = 11});
  final Widget child;
  final VoidCallback? onTap;
  final double vertical;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final box = Container(
      padding: EdgeInsets.symmetric(vertical: vertical, horizontal: onTap == null ? 0 : 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.rule))),
      child: child,
    );
    return onTap == null ? box : InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap, child: box);
  }
}

/// "LABEL      value" — side by side, or one under the other when narrow.
class Fact extends StatelessWidget {
  const Fact(this.label, this.value, {super.key, this.mono = false, this.color, this.note});
  final String label;
  final String value;
  final bool mono;
  final Color? color;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final v = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: mono ? ty.mono(size: 13, color: color) : ty.body.copyWith(color: color)),
      if (note != null) Text(note!, style: ty.small),
    ]);
    return LedgerRow(
      child: LayoutBuilder(builder: (context, c) {
        final l = Text(label.toUpperCase(), style: ty.caps());
        if (isNarrow(c)) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [l, const SizedBox(height: 4), v]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 170, child: Padding(padding: const EdgeInsets.only(top: 3), child: l)),
          Expanded(child: v),
        ]);
      }),
    );
  }
}

/// A card of a settings form: its title and what it is for on the left, the fields on the right.
class FormBlock extends StatelessWidget {
  const FormBlock({super.key, required this.title, this.description, this.trailing, this.child, this.icon});
  final String title;
  final String? description;
  final Widget? trailing;
  final Widget? child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 760;
        final head = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, size: 17, color: ty.p.muted), const SizedBox(width: 8)],
            Flexible(child: Text(title, style: ty.cardTitle)),
          ]),
          if (description != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(description!, style: ty.small)),
          if (trailing != null) Padding(padding: const EdgeInsets.only(top: 12), child: trailing),
        ]);
        if (narrow || child == null) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, if (child != null) ...[const SizedBox(height: 16), child!]]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 280, child: Padding(padding: const EdgeInsets.only(right: 32), child: head)),
          Expanded(child: child!),
        ]);
      }),
    );
  }
}

/// A label, a text box, a hint.
class Field extends StatelessWidget {
  const Field(this.label, this.controller,
      {super.key, this.placeholder, this.obscure = false, this.monospace = false, this.maxLines = 1, this.onChanged, this.help, this.suffix});
  final String label;
  final TextEditingController controller;
  final String? placeholder, help;
  final bool obscure, monospace;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label, style: ty.label),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        minLines: maxLines > 1 ? maxLines : null,
        onChanged: onChanged,
        style: monospace ? ty.mono(size: 13) : ty.body,
        decoration: InputDecoration(hintText: placeholder, suffixIcon: suffix),
      ),
      if (help != null) Padding(padding: const EdgeInsets.only(top: 5), child: Text(help!, style: ty.small.copyWith(color: ty.p.faint))),
    ]);
  }
}

/// Fields side by side when there is room, one under the other on narrow windows.
class FieldRow extends StatelessWidget {
  const FieldRow(this.children, {super.key, this.widths});
  final List<Widget> children;
  final List<double>? widths; // preferred widths; -1 = takes the rest
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (isNarrow(c) || children.length == 1) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, w) in children.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 14), child: w),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, w) in children.indexed) ...[
            if (i > 0) const SizedBox(width: 14),
            if (widths != null && i < widths!.length && widths![i] > 0) SizedBox(width: widths![i], child: w) else Expanded(child: w),
          ],
        ]);
      });
}

/// A labelled select box.
class Choice<T> extends StatelessWidget {
  const Choice(this.label, {super.key, required this.value, required this.items, required this.onChanged});
  final String? label;
  final T value;
  final List<(T, String, bool)> items; // value, text, enabled
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final box = DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      isDense: true,
      icon: Icon(Icons.expand_more, size: 18, color: ty.p.muted),
      dropdownColor: ty.p.surface,
      borderRadius: BorderRadius.circular(4),
      style: ty.body,
      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9)),
      items: [
        for (final (v, text, enabled) in items)
          DropdownMenuItem<T>(value: v, enabled: enabled, child: Text(text, overflow: TextOverflow.ellipsis, style: enabled ? null : TextStyle(color: ty.p.faint))),
      ],
      onChanged: (v) => onChanged(v as T),
    );
    if (label == null) return box;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(label!, style: ty.label), const SizedBox(height: 6), box]);
  }
}

/// Next to the title of a settings page: every change is saved by itself (false: being saved).
class AutoSaveMark extends StatelessWidget {
  const AutoSaveMark(this.state, {super.key});
  final ValueListenable<bool?> state;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return ValueListenableBuilder<bool?>(
      valueListenable: state,
      builder: (context, s, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s == false ? Icons.sync : Icons.check_circle_outline, size: 16, color: s == false ? ty.p.faint : ty.p.added),
        const SizedBox(width: 6),
        Text(s == false ? tr('Saving…') : tr('Saved automatically'), style: ty.small),
      ]),
    );
  }
}

/// A check box with its text (the whole line is clickable) and an optional hint under it.
class CheckLine extends StatelessWidget {
  const CheckLine(this.label, {super.key, required this.value, required this.onChanged, this.help, this.enabled = true});
  final String label;
  final bool value, enabled;
  final ValueChanged<bool> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 22, height: 22, child: Checkbox(value: value, onChanged: enabled ? (v) => onChanged(v ?? false) : null)),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: enabled ? ty.body : ty.body.copyWith(color: ty.p.faint)),
                if (help != null) Text(help!, style: ty.small.copyWith(color: ty.p.faint)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The state of a target as a dot: green (answers), red (failed), hollow (not tested).
class StatusMark extends StatelessWidget {
  const StatusMark(this.health, {super.key, this.size = 8, this.withText = false});
  final bool? health;
  final double size;
  final bool withText;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final c = health == null ? ty.p.faint : (health! ? ty.p.added : ty.p.removed);
    if (withText) {
      return Tag(health == null ? tr('Not tested') : (health! ? tr('Online') : tr('Error')), color: health == null ? null : c, dot: true);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: health == null ? null : c, shape: BoxShape.circle, border: health == null ? Border.all(color: c, width: 1.3) : null),
    );
  }
}

/// A coloured note: work in progress, an error, something to set up.
class Notice extends StatelessWidget {
  const Notice({super.key, required this.color, required this.title, this.text, this.onClose, this.textWidget, this.action, this.icon});
  final Color color;
  final String title;
  final String? text;
  final Widget? textWidget;
  final VoidCallback? onClose;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(color: color.withValues(alpha: .07), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: .30))),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1, right: 12), child: Icon(icon ?? Icons.info_outline, size: 19, color: color)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: ty.strong.copyWith(color: color)),
            if (text != null) Text(text!, style: ty.body.copyWith(fontSize: 13.5)),
            ?textWidget,
            if (action != null) Padding(padding: const EdgeInsets.only(top: 10), child: action),
          ]),
        ),
        if (onClose != null) IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 16), tooltip: tr('Close')),
      ]),
    );
  }
}

/// "More ▾": the less frequent actions of a page.
class MoreMenu extends StatelessWidget {
  const MoreMenu(this.items, {super.key, this.buttonKey});
  final List<(String, VoidCallback?)> items; // ('-', null) = separator
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) => MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          for (final (label, f) in items)
            if (label == '-') const Divider(height: 9) else MenuItemButton(onPressed: f, child: Text(label)),
        ],
        builder: (context, ctl, _) => OutlinedButton(
          key: buttonKey,
          onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Text(tr('More')), const SizedBox(width: 4), const Icon(Icons.expand_more, size: 18)]),
        ),
      );
}

/// A danger button (outlined, red).
class DangerButton extends StatelessWidget {
  const DangerButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return OutlinedButton(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(p.removed),
        side: WidgetStatePropertyAll(BorderSide(color: p.removed.withValues(alpha: .6))),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// A small button in capitals, for the head of a section: COPY, CLEAR, SHOW…
class SmallButton extends StatelessWidget {
  const SmallButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return TextButton(
      style: TextButton.styleFrom(minimumSize: const Size(0, 26), padding: const EdgeInsets.symmetric(horizontal: 8), foregroundColor: ty.p.ink, textStyle: ty.caps()),
      onPressed: onPressed,
      child: Text(label.toUpperCase()),
    );
  }
}

/// The button inside a text box (browse…).
Widget fieldButton(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 34, height: 32),
      padding: EdgeInsets.zero,
    );

/// A numbered step: a round number, its title and what it does, its button on the right (under it when narrow).
class StepRow extends StatelessWidget {
  const StepRow(this.n, this.title, this.text, {super.key, this.button});
  final int n;
  final String title, text;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return LedgerRow(
      vertical: 14,
      child: LayoutBuilder(builder: (context, c) {
        final narrow = isNarrow(c);
        final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: ty.strong),
          const SizedBox(height: 2),
          Text(text, style: ty.small),
          if (narrow && button != null) Padding(padding: const EdgeInsets.only(top: 10), child: button),
        ]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(right: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: ty.p.accent.withValues(alpha: .10), shape: BoxShape.circle),
            child: Text('$n', style: ty.figure(size: 14, color: ty.p.accent, weight: FontWeight.w600)),
          ),
          Expanded(child: body),
          if (!narrow && button != null) ...[const SizedBox(width: 16), button!],
        ]);
      }),
    );
  }
}

/// A grid of values with a head row, both scrolling sideways when wider than the card. [cell] colours a cell.
/// Sideways: the bar under it can be dragged with the mouse (it has its own controller, else Flutter gives it the
/// page's one and it cannot move), Shift + wheel, or a touchpad.
class DataGrid extends StatefulWidget {
  const DataGrid({super.key, required this.columns, required this.rows, this.cell, this.widths, this.rowColor, this.maxHeight});
  final List<String> columns;
  final List<List<String?>> rows;
  final Widget? Function(int row, int col, String? value)? cell; // null: the default text
  final List<double>? widths;
  final Color? Function(int row)? rowColor;
  final double? maxHeight;

  @override
  State<DataGrid> createState() => _DataGridState();
}

class _DataGridState extends State<DataGrid> {
  final side = ScrollController(), down = ScrollController();

  List<String> get columns => widget.columns;
  List<List<String?>> get rows => widget.rows;
  Widget? Function(int row, int col, String? value)? get cell => widget.cell;
  List<double>? get widths => widget.widths;
  Color? Function(int row)? get rowColor => widget.rowColor;
  double? get maxHeight => widget.maxHeight;

  @override
  void dispose() {
    side.dispose();
    down.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    double w(int i) => widths != null && i < widths!.length ? widths![i] : _guess(i);
    Widget box(int i, Widget child, {Color? color}) => Container(
          width: w(i),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: color, border: Border(right: BorderSide(color: p.rule), bottom: BorderSide(color: p.rule))),
          child: child,
        );
    final head = Row(children: [
      for (var i = 0; i < columns.length; i++) box(i, Text(columns[i], style: ty.mono(size: 12, weight: FontWeight.w700, color: p.muted), overflow: TextOverflow.ellipsis), color: p.sunken),
    ]);
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var r = 0; r < rows.length; r++)
        Container(
          color: rowColor?.call(r),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < columns.length; i++)
              box(
                i,
                cell?.call(r, i, i < rows[r].length ? rows[r][i] : null) ??
                    Text(i < rows[r].length ? (rows[r][i] ?? 'NULL') : '',
                        style: ty.mono(size: 12, color: i < rows[r].length && rows[r][i] == null ? p.faint : p.ink), maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
          ]),
        ),
    ]);
    final grid = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      head,
      if (maxHeight == null)
        body
      else
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight!),
          child: Scrollbar(controller: down, child: SingleChildScrollView(controller: down, primary: false, child: body)),
        ),
    ]);
    return Scrollbar(
      controller: side,
      thumbVisibility: true,
      interactive: true,
      notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
      child: SingleChildScrollView(
        controller: side,
        primary: false,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 10), // room for the bar, so it never covers the last row
        child: grid,
      ),
    );
  }

  double _guess(int i) {
    var longest = columns[i].length;
    for (final r in rows.take(60)) {
      if (i < r.length) longest = longest > (r[i]?.length ?? 4) ? longest : (r[i]?.length ?? 4);
    }
    return (longest * 7.6 + 24).clamp(70, 320).toDouble();
  }
}
