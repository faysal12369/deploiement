// Settings › Email alerts: the SMTP account that sends them, how often the targets are checked, a test email, a check
// now, and "Start with Windows" so the checks keep running after a restart (see watch.dart).
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'i18n.dart';
import 'models.dart';
import 'theme.dart';
import 'watch.dart';
import 'widgets.dart';

class AlertsBlock extends StatefulWidget {
  const AlertsBlock(this.app, {super.key});
  final AppState app;
  @override
  State<AlertsBlock> createState() => _AlertsBlockState();
}

class _AlertsBlockState extends State<AlertsBlock> {
  AlertSettings get s => widget.app.settings.alerts;
  late bool enabled = s.enabled, startWithWindows = s.startWithWindows, showPass = false;
  late int minutes = s.minutes;
  late String security = s.security;
  late final c = {
    'host': TextEditingController(text: s.host),
    'port': TextEditingController(text: '${s.port}'),
    'user': TextEditingController(text: s.user),
    'pass': TextEditingController(text: s.pass),
    'from': TextEditingController(text: s.from),
    'to': TextEditingController(text: s.to),
  };
  bool sending = false;

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  /// The settings as typed, without saving them.
  AlertSettings _typed() => AlertSettings()
    ..enabled = enabled
    ..minutes = minutes
    ..host = c['host']!.text.trim()
    ..port = int.tryParse(c['port']!.text.trim()) ?? (security == 'ssl' ? 465 : 587)
    ..security = security
    ..user = c['user']!.text.trim()
    ..pass = c['pass']!.text
    ..from = c['from']!.text.trim()
    ..to = c['to']!.text.trim();

  Future<void> _save() async {
    final app = widget.app, t = _typed();
    if (enabled && t.missing.isNotEmpty) {
      app.notify(tr('Email alerts need {what}.', {'what': t.missing}), severity: Severity.warning);
      return;
    }
    s
      ..enabled = t.enabled
      ..minutes = t.minutes
      ..host = t.host
      ..port = t.port
      ..security = t.security
      ..user = t.user
      ..pass = t.pass
      ..from = t.from
      ..to = t.to;
    if (startWithWindows != s.startWithWindows) {
      if (startWithWindows && !Startup.canInstall) {
        app.notify(tr('Only the installed Déploiement can start with Windows.'), severity: Severity.warning);
        setState(() => startWithWindows = false);
      } else {
        try {
          await Startup.set(startWithWindows);
          s.startWithWindows = startWithWindows;
        } catch (e) {
          app.notify(tr('"Start with Windows" not changed'), text: '$e', severity: Severity.error);
        }
      }
    }
    app.save();
    app.watcher.restart();
    app.notify(enabled ? tr('Email alerts on: the targets are checked every {n} minutes.', {'n': minutes}) : tr('Email alerts off.'));
  }

  Future<void> _test() async {
    final app = widget.app, t = _typed();
    setState(() => sending = true);
    try {
      await sendAlert(t, tr('[Déploiement] Test email'), tr('This is a test from Déploiement on {pc}: the alerts will arrive at this address.', {'pc': Platform.localHostname}));
      app.notify(tr('Test email sent.'), text: t.recipients.join(', '));
    } catch (e) {
      app.notify(tr('Test email not sent'), text: '$e'.replaceFirst('Bad state: ', ''), severity: Severity.error);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final ty = Ty.of(context);
    final w = app.watcher;
    final problems = [
      for (final pr in app.projects)
        for (final t in pr.targets)
          if (app.watchProblems[t.id] case final list?) for (final x in list) '${t.name}: ${x.text}',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final last = s.lastCheck;
    return FormBlock(
      title: tr('Email alerts'),
      description: tr(
          'Déploiement checks your targets every few minutes (site, agent, database, disk) and emails you when something goes wrong, then when it is back to normal. Sent from this PC by SMTP: it works even when the PHP or MySQL of the server is down. The checks run while Déploiement is open.'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CheckLine(tr('Watch the targets and send emails'), value: enabled, onChanged: (v) => setState(() => enabled = v)),
        const SizedBox(height: 12),
        FieldRow([
          Choice<int>(tr('Check every'),
              value: minutes,
              items: const [(5, '5 min', true), (15, '15 min', true), (30, '30 min', true), (60, '60 min', true)],
              onChanged: (v) => setState(() => minutes = v)),
          const SizedBox(),
        ], widths: const [200, -1]),
        const SizedBox(height: 14),
        FieldRow([
          Field(tr('SMTP server'), c['host']!, monospace: true, placeholder: 'smtp.gmail.com'),
          Field(tr('Port'), c['port']!, monospace: true),
          Choice<String>(tr('Security'),
              value: security,
              items: [('ssl', 'SSL / TLS', true), ('starttls', 'STARTTLS', true), ('none', tr('None'), true)],
              onChanged: (v) => setState(() {
                    security = v;
                    if (v == 'ssl' && c['port']!.text.trim() == '587') c['port']!.text = '465';
                    if (v == 'starttls' && c['port']!.text.trim() == '465') c['port']!.text = '587';
                  })),
        ], widths: const [-1, 90, 170]),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              tr('Gmail: smtp.gmail.com, 587, STARTTLS, with an app password · Outlook: smtp.office365.com, 587, STARTTLS · Hostinger: smtp.hostinger.com, 465, SSL'),
              style: ty.small),
        ),
        const SizedBox(height: 14),
        FieldRow([
          Field(tr('User'), c['user']!, monospace: true, placeholder: 'me@example.com'),
          Field(tr('Password'), c['pass']!, obscure: !showPass),
        ]),
        const SizedBox(height: 14),
        FieldRow([
          Field(tr('From'), c['from']!, monospace: true, help: tr('Empty: the user.')),
          Field(tr('Send to'), c['to']!, monospace: true, placeholder: 'me@example.com, it@example.com', help: tr('One or more addresses, separated by commas.')),
        ]),
        const SizedBox(height: 8),
        CheckLine(tr('Show passwords'), value: showPass, onChanged: (v) => setState(() => showPass = v)),
        CheckLine(
          tr('Start Déploiement with Windows, minimized'),
          value: startWithWindows,
          onChanged: (v) => setState(() => startWithWindows = v),
          help: tr('So the checks go on after this PC restarts.'),
        ),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton(key: const ValueKey('alerts-save'), onPressed: _save, child: Text(tr('Save'))),
          OutlinedButton(key: const ValueKey('alerts-test'), onPressed: sending ? null : _test, child: Text(sending ? tr('Sending…') : tr('Send a test email'))),
          OutlinedButton(
            key: const ValueKey('alerts-check'),
            onPressed: w.checking
                ? null
                : () async {
                    final sent = await w.check();
                    app.notify(problems.isEmpty && app.watchProblems.isEmpty ? tr('Every target answers.') : tr('Problems found: see below.'),
                        text: sent.isEmpty ? null : pl(sent.length, '{n} email sent', '{n} emails sent', '{n} e-mail envoyé', '{n} e-mails envoyés'));
                  },
            child: Text(w.checking ? tr('Checking…') : tr('Check now')),
          ),
        ]),
        const SizedBox(height: 12),
        if (last != null)
          Text(
            tr('Last check: {time}', {'time': '${two(last.day)}/${two(last.month)} ${two(last.hour)}:${two(last.minute)}'}) +
                (problems.isEmpty ? ' — ${tr('every target answers.')}' : ''),
            style: ty.small,
          ),
        for (final x in problems) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $x', style: ty.small.copyWith(color: ty.p.removed))),
      ]),
    );
  }
}
