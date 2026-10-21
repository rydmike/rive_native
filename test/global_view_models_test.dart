import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/utils.dart';

/// The fixture `global_view_models_test.riv` has a main view model named
/// "Main" and global view models named (in file order) "Sizes", "Colors",
/// "Labels".
void main() {
  late rive.File riveFile;

  setUpAll(() async {
    final bytes = loadFile('assets/global_view_models_test.riv');
    riveFile = await rive.File.decode(bytes, riveFactory: rive.Factory.flutter)
        as rive.File;
  });

  (rive.Artboard, rive.StateMachine) makeStateMachine() {
    final artboard = riveFile.defaultArtboard()!;
    final stateMachine = artboard.defaultStateMachine()!;
    return (artboard, stateMachine);
  }

  test('global view model names are listed in file order', () {
    expect(riveFile.globalViewModelNames, ['Sizes', 'Colors', 'Labels']);
  });

  test('global getter is null before set or bind', () {
    final (artboard, stateMachine) = makeStateMachine();
    expect(stateMachine.globalViewModelInstance('Colors'), isNull);
    stateMachine.dispose();
    artboard.dispose();
  });

  test('set returns false for unknown and non-global names', () {
    final (artboard, stateMachine) = makeStateMachine();
    final instance = makeDefaultInstance(riveFile, 'Colors');

    expect(
      stateMachine.setGlobalViewModelInstance('DoesNotExist', instance),
      isFalse,
    );
    // The main view model's name is not a valid global slot.
    expect(
      stateMachine.setGlobalViewModelInstance('Main', instance),
      isFalse,
    );
    expect(stateMachine.globalViewModelInstance('DoesNotExist'), isNull);
    expect(stateMachine.globalViewModelInstance('Main'), isNull);

    instance.dispose();
    stateMachine.dispose();
    artboard.dispose();
  });

  test('set stores the exact object passed, before and after bind', () {
    final (artboard, stateMachine) = makeStateMachine();
    final colors = makeDefaultInstance(riveFile, 'Colors');

    expect(stateMachine.setGlobalViewModelInstance('Colors', colors), isTrue);
    // Canonical wrapper: the getter returns the user's object, pre-bind...
    expect(identical(stateMachine.globalViewModelInstance('Colors'), colors),
        isTrue);

    stateMachine.bind();

    // ...and post-bind.
    expect(identical(stateMachine.globalViewModelInstance('Colors'), colors),
        isTrue);

    stateMachine.dispose();
    artboard.dispose();
    expect(colors.isDisposed, isFalse);
    colors.dispose();
  });

  test('bind with nothing set auto-creates main and every global', () {
    final (artboard, stateMachine) = makeStateMachine();

    stateMachine.bind();

    expect(stateMachine.boundRuntimeViewModelInstance, isNotNull);
    for (final name in riveFile.globalViewModelNames) {
      final instance = stateMachine.globalViewModelInstance(name);
      expect(instance, isNotNull, reason: 'global $name not auto-created');
      // Repeated gets return the identical wrapper.
      expect(
        identical(stateMachine.globalViewModelInstance(name), instance),
        isTrue,
        reason: 'global $name wrapper not canonical',
      );
    }

    stateMachine.dispose();
    artboard.dispose();
  });

  test('setViewModelInstance stages the main and is retrievable', () {
    final (artboard, stateMachine) = makeStateMachine();
    final main = riveFile.defaultArtboardViewModel(artboard)!;
    final mainInstance = main.createDefaultInstance()!;
    main.dispose();

    stateMachine.setViewModelInstance(mainInstance);
    expect(
      identical(stateMachine.boundRuntimeViewModelInstance, mainInstance),
      isTrue,
    );

    stateMachine.bind();
    expect(
      identical(stateMachine.boundRuntimeViewModelInstance, mainInstance),
      isTrue,
    );

    stateMachine.dispose();
    artboard.dispose();
    expect(mainInstance.isDisposed, isFalse);
    mainInstance.dispose();
  });

  test('rebind is a delta: untouched slots keep their instances', () {
    final (artboard, stateMachine) = makeStateMachine();

    stateMachine.bind();
    final autoColors = stateMachine.globalViewModelInstance('Colors');
    expect(autoColors, isNotNull);

    // Replace one other slot and rebind.
    final sizes = makeDefaultInstance(riveFile, 'Sizes');
    expect(stateMachine.setGlobalViewModelInstance('Sizes', sizes), isTrue);
    stateMachine.bind();

    // The untouched slot still holds the same instance and the same wrapper.
    expect(
      identical(stateMachine.globalViewModelInstance('Colors'), autoColors),
      isTrue,
    );
    expect(
      identical(stateMachine.globalViewModelInstance('Sizes'), sizes),
      isTrue,
    );

    stateMachine.dispose();
    artboard.dispose();
    expect(sizes.isDisposed, isFalse);
    sizes.dispose();
  });

  test('replacing a slot re-points the canonical wrapper', () {
    final (artboard, stateMachine) = makeStateMachine();

    final first = makeDefaultInstance(riveFile, 'Colors');
    final second = makeDefaultInstance(riveFile, 'Colors');
    expect(stateMachine.setGlobalViewModelInstance('Colors', first), isTrue);
    expect(stateMachine.setGlobalViewModelInstance('Colors', second), isTrue);
    expect(
      identical(stateMachine.globalViewModelInstance('Colors'), second),
      isTrue,
    );
    // The replaced user instance is not disposed by the state machine.
    expect(first.isDisposed, isFalse);

    stateMachine.dispose();
    artboard.dispose();
    first.dispose();
    second.dispose();
  });

  test('dispose releases minted wrappers but never user-passed instances', () {
    final (artboard, stateMachine) = makeStateMachine();

    final userSizes = makeDefaultInstance(riveFile, 'Sizes');
    expect(stateMachine.setGlobalViewModelInstance('Sizes', userSizes), isTrue);
    stateMachine.bind();

    // Auto-created and read back: this wrapper was minted by the state
    // machine.
    final mintedColors = stateMachine.globalViewModelInstance('Colors')!;
    final mintedMain = stateMachine.boundRuntimeViewModelInstance!;

    stateMachine.dispose();
    artboard.dispose();

    expect(mintedColors.isDisposed, isTrue);
    expect(mintedMain.isDisposed, isTrue);
    expect(userSizes.isDisposed, isFalse);

    userSizes.dispose();
  });

  test('read-back wrappers are views and cannot be staged', () {
    final (artboardA, machineA) = makeStateMachine();

    machineA.bind();
    final readBack = machineA.globalViewModelInstance('Colors')!;
    expect(readBack, isNot(isA<rive.BindableViewModelInstance>()));

    // Read-backs are plain ViewModelInstance, so staging one is normally a
    // compile error; the runtime constructs views from a class that does
    // not implement BindableViewModelInstance, so even the cast throws.
    expect(
      () => readBack as rive.BindableViewModelInstance,
      throwsA(isA<TypeError>()),
    );

    // A view stays readable and writable while its machine lives.
    final textColor = readBack.color('textColor');
    textColor!.value = const Color(0xFF123456);
    expect(textColor.value, const Color(0xFF123456));
    textColor.dispose();

    machineA.dispose();
    artboardA.dispose();
    expect(readBack.isDisposed, isTrue,
        reason: 'view wrappers are disposed with their machine');
  });

  test('navigating a view yields views; navigating yours stays bindable', () {
    final (artboard, stateMachine) = makeStateMachine();
    stateMachine.bind();

    final main = stateMachine.boundRuntimeViewModelInstance!;
    expect(main, isNot(isA<rive.BindableViewModelInstance>()));
    final nested = main.viewModel('sizes');
    if (nested != null) {
      expect(nested, isNot(isA<rive.BindableViewModelInstance>()));
      expect(
        () => nested as rive.BindableViewModelInstance,
        throwsA(isA<TypeError>()),
      );
      nested.dispose();
    }

    // A user-created instance and its nested parts stay bindable.
    final mine = makeDefaultInstance(riveFile, 'Main');
    expect(mine, isA<rive.BindableViewModelInstance>());
    final myNested = mine.viewModel('sizes');
    if (myNested != null) {
      expect(myNested, isA<rive.BindableViewModelInstance>());
      myNested.dispose();
    }
    mine.dispose();

    stateMachine.dispose();
    artboard.dispose();
  });

  test('a listener may read an unregistered global during the advance flush',
      () {
    final (artboard, stateMachine) = makeStateMachine();
    stateMachine.bind();

    final sizes = stateMachine.globalViewModelInstance('Sizes')!;
    final gaps = sizes.number('gaps')!;
    // First-reads 'Colors' inside the flush: this registers a new slot while
    // the state machine is iterating its bound instances.
    rive.ViewModelInstance? colors;
    gaps.addListener((_) {
      colors = stateMachine.globalViewModelInstance('Colors');
    });
    gaps.value += 1;

    stateMachine.advanceAndApply(0.016);

    expect(colors, isNotNull);
    expect(
      identical(stateMachine.globalViewModelInstance('Colors'), colors),
      isTrue,
    );

    stateMachine.dispose();
    artboard.dispose();
  });

  test('releasing one of two slots sharing an instance keeps advance requests',
      () {
    final (artboard, stateMachine) = makeStateMachine();
    final shared = makeDefaultInstance(riveFile, 'Colors');

    // The same instance occupies two slots.
    expect(stateMachine.setGlobalViewModelInstance('Colors', shared), isTrue);
    expect(stateMachine.setGlobalViewModelInstance('Labels', shared), isTrue);

    // Re-point one slot; the instance still occupies the other.
    final replacement = makeDefaultInstance(riveFile, 'Colors');
    expect(
        stateMachine.setGlobalViewModelInstance('Colors', replacement), isTrue);

    var advanceRequests = 0;
    stateMachine.addAdvanceRequestListener(() => advanceRequests++);
    shared.color('textColor')!.value = const Color(0xFF00FF00);
    expect(advanceRequests, greaterThan(0),
        reason: 'the shared instance is still bound under Labels');

    stateMachine.dispose();
    artboard.dispose();
    shared.dispose();
    replacement.dispose();
  });

  test('re-pointing a slot never disposes a wrapper aliased in another slot',
      () {
    final (artboard, stateMachine) = makeStateMachine();

    // A user-created wrapper occupying two slots at once.
    final w = makeDefaultInstance(riveFile, 'Colors');
    expect(stateMachine.setGlobalViewModelInstance('Colors', w), isTrue);
    expect(stateMachine.setGlobalViewModelInstance('Labels', w), isTrue);
    stateMachine.bind();

    // Re-point 'Colors'; w still occupies 'Labels'.
    final replacement = makeDefaultInstance(riveFile, 'Colors');
    expect(
        stateMachine.setGlobalViewModelInstance('Colors', replacement), isTrue);
    stateMachine.bind();

    expect(w.isDisposed, isFalse);
    expect(
        identical(stateMachine.globalViewModelInstance('Labels'), w), isTrue);

    stateMachine.dispose();
    artboard.dispose();
    expect(w.isDisposed, isFalse,
        reason: 'user-created instances are never disposed by the machine');
    w.dispose();
    replacement.dispose();
  });

  test('property listeners on global instances fire on advance', () {
    final (artboard, stateMachine) = makeStateMachine();
    stateMachine.bind();

    // The fixture's "Sizes" global has a number property "gaps".
    final sizes = stateMachine.globalViewModelInstance('Sizes')!;
    final gaps = sizes.number('gaps')!;
    var fired = 0;
    gaps.addListener((_) => fired++);
    gaps.value += 1;

    // The state machine flushes callbacks for global instances on advance,
    // exactly as it does for the main instance.
    stateMachine.advanceAndApply(0.016);
    expect(fired, 1);

    stateMachine.dispose();
    artboard.dispose();
  });
}
