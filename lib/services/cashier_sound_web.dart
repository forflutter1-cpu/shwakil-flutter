import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.AudioContext? _audioContext;

web.AudioContext _context() => _audioContext ??= web.AudioContext();

Future<void> prepareCashierSound() async {
  try {
    final context = _context();
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }
  } catch (_) {
    // The browser may block audio until the cashier interacts with the page.
  }
}

Future<void> playCashierBeep() async {
  try {
    await prepareCashierSound();
    final context = _context();
    final oscillator = context.createOscillator();
    final gain = context.createGain();
    final now = context.currentTime;

    oscillator.type = 'sine';
    oscillator.frequency.setValueAtTime(880, now);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(0.08, now + 0.012);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.11);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start();
    oscillator.stop(now + 0.12);
  } catch (_) {
    // Keep barcode entry usable when audio is unavailable or blocked.
  }
}
