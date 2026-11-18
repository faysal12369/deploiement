// A past deployment opened from the History, with a synced rows grid wider than the window (asked 17/11/2026: "the
// left-right scrollbar cannot be moved"): the bar under the grid is dragged with the mouse, Shift + wheel moves the
// grid sideways, the plain wheel over it still scrolls the window up and down.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/result_view.dart';
import 'package:deploiement/results.dart';
import 'package:deploiement/theme.dart';
import 'package:deploiement/widgets.dart';

void main() {
  testWidgets('the grid of a past deployment scrolls sideways', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    })));
    final cols = [for (var i = 0; i < 24; i++) 'column_$i'];
    final r = DeployResult(time: DateTime(2026, 11, 17), project: 'p', target: 't')
      ..ok = true
      ..changedFiles = [for (var i = 0; i < 30; i++) 'pages/page_$i.php']
      ..sync = [
        SyncResult('suppliers', 0, 2, 1364, 0, [], [], columns: cols, rows: [
          for (var i = 0; i < 2; i++) SyncRow('update', 'FRN-136$i', [for (final c in cols) '$c value $i'], {'column_3': 'old $i'}),
        ]),
        for (var i = 0; i < 10; i++) SyncResult('table_$i', 0, 0, 20, 0, [], []),
      ];
    showResult(ctx, r);
    await tester.pumpAndSettle();

    final grid = find.byType(DataGrid).first;
    final page = tester.state<ScrollableState>(find.ancestor(of: grid, matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first).position;
    final sideways = tester.state<ScrollableState>(find.descendant(of: grid, matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right)).first).position;
    expect(sideways.maxScrollExtent, greaterThan(500), reason: 'the grid is wider than the window');

    // the grid in the middle of the window
    page.jumpTo((page.pixels + tester.getRect(grid).top - 300).clamp(0, page.maxScrollExtent));
    await tester.pumpAndSettle();
    final rect = tester.getRect(grid);

    // ---- the bar under the grid, dragged with the mouse
    expect(sideways.pixels, 0);
    final mouse = await tester.startGesture(Offset(rect.left + 40, rect.bottom - 5), kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(200, 0));
    await mouse.moveBy(const Offset(200, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(sideways.pixels, greaterThan(300), reason: 'the dragged bar moves the grid');

    // ---- Shift + wheel over the grid: sideways
    final before = sideways.pixels;
    final wheel = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(wheel.hover(Offset(rect.left + 200, rect.top + 60)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, -150)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(sideways.pixels, lessThan(before), reason: 'Shift + wheel moves the grid sideways');

    // ---- the plain wheel over the grid: the window, up and down
    final top = page.pixels;
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();
    expect(page.pixels, greaterThan(top), reason: 'the window still scrolls');
  });
}
