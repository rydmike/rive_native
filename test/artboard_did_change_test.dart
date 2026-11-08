import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/utils.dart';

void main() {
  late rive.File riveFile;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    riveFile = await rive.File.decode(
      loadFile('assets/rewards.riv'),
      riveFactory: rive.Factory.flutter,
    ) as rive.File;
  });

  tearDown(() => riveFile.dispose());

  void draw(rive.Artboard artboard) {
    final recorder = ui.PictureRecorder();
    final renderer = rive.Renderer.make(ui.Canvas(recorder));
    artboard.draw(renderer);
    renderer.dispose();
    recorder.endRecording().dispose();
  }

  test('didChange is set until drawn and again when content changes', () {
    final artboard = riveFile.defaultArtboard()!;
    addTearDown(artboard.dispose);
    final stateMachine = artboard.defaultStateMachine()!;
    addTearDown(stateMachine.dispose);

    expect(artboard.didChange, isTrue, reason: 'never drawn');
    stateMachine.advanceAndApply(0);
    draw(artboard);
    expect(artboard.didChange, isFalse);

    stateMachine.advanceAndApply(0.1);
    expect(artboard.didChange, isTrue);
    draw(artboard);
    expect(artboard.didChange, isFalse);
  });

  test('advancing settled content leaves didChange clear', () async {
    final settling = await rive.File.decode(
      loadFile('assets/rating.riv'),
      riveFactory: rive.Factory.flutter,
    ) as rive.File;
    addTearDown(settling.dispose);
    final artboard = settling.defaultArtboard()!;
    addTearDown(artboard.dispose);
    final stateMachine = artboard.defaultStateMachine()!;
    addTearDown(stateMachine.dispose);

    var frames = 0;
    while (stateMachine.advanceAndApply(0.016)) {
      expect(++frames, lessThan(1000), reason: 'never settled');
    }
    draw(artboard);

    stateMachine.advanceAndApply(0.016);
    expect(artboard.didChange, isFalse);
    // Reports keep going, as a zero advance always does, yet changes nothing.
    expect(stateMachine.advanceAndApply(0), isTrue);
    expect(artboard.didChange, isFalse);
  });
}
