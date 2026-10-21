import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/utils.dart';

void main() {
  test('artboardNames lists every artboard in file order', () async {
    final file = (await rive.File.decode(
      loadFile('assets/focus.riv'),
      riveFactory: rive.Factory.flutter,
    ))!;
    addTearDown(file.dispose);

    final names = file.artboardNames;
    expect(names, contains('Buttons'));
    expect(names, contains('PointerFocus'));
    for (var i = 0; i < names.length; i++) {
      final artboard = file.artboardAt(i)!;
      expect(artboard.name, names[i], reason: 'index $i');
      artboard.dispose();
    }
    expect(file.artboardAt(names.length), isNull);
  });
}
