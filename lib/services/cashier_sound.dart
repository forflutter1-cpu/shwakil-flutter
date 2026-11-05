import 'cashier_sound_stub.dart'
    if (dart.library.html) 'cashier_sound_web.dart'
    as implementation;

Future<void> prepareCashierSound() => implementation.prepareCashierSound();

Future<void> playCashierBeep() => implementation.playCashierBeep();
