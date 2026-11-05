import 'package:flutter/services.dart';

Future<void> prepareCashierSound() async {}

Future<void> playCashierBeep() => SystemSound.play(SystemSoundType.click);
