import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' show SemanticActionType;
import 'package:rive_native/semantics.dart';

/// Parity tripwires for the hand-maintained semantic enum copies.
///
/// SemanticRole, SemanticTrait, SemanticState, and SemanticActionType each
/// exist in several hand-written copies across the runtimes. The C++ side
/// derives trait/state bits from the generated SemanticDataBase (source of
/// truth: dev/defs/semantic/semantic_data.json); roles and actions are
/// hand-written enums in C++ headers. These tests parse the authoritative
/// files from the repo and fail the moment rive_native's Dart copies drift.
/// Proper single-sourcing through the generator is tracked in the backlog.

const _generatedDart =
    '../rive_core/lib/src/generated/semantic/semantic_data_base.dart';
const _roleHpp = '../runtime/include/rive/semantic/semantic_role.hpp';
const _actionHpp =
    '../runtime/include/rive/animation/semantic_listener_group.hpp';

Map<String, int> _parseBitmasks(String source) {
  final out = <String, int>{};
  final re = RegExp(r'static const int (is\w+Bitmask) = 1 << (\d+);');
  for (final m in re.allMatches(source)) {
    out[m.group(1)!] = 1 << int.parse(m.group(2)!);
  }
  return out;
}

Map<String, int> _parseCppEnum(String source) {
  final out = <String, int>{};
  final re = RegExp(r'^\s*(\w+) = (\d+),?\s*$', multiLine: true);
  for (final m in re.allMatches(source)) {
    out[m.group(1)!] = int.parse(m.group(2)!);
  }
  return out;
}

void main() {
  test('trait and state bits match the generated SemanticDataBase', () {
    final source = File(_generatedDart).readAsStringSync();
    final generated = _parseBitmasks(source);
    expect(generated, hasLength(19),
        reason: 'expected 7 trait + 12 state bitmasks in $_generatedDart '
            '(check state is a 2-bit field, asserted separately); a new '
            'bit means extending the Dart enums and this table');

    const expected = <String, int>{
      // Traits
      'isExpandableBitmask': SemanticTrait.expandable,
      'isSelectableBitmask': SemanticTrait.selectable,
      'isCheckableBitmask': SemanticTrait.checkable,
      'isToggleableBitmask': SemanticTrait.toggleable,
      'isRequirableBitmask': SemanticTrait.requirable,
      'isEnablableBitmask': SemanticTrait.enablable,
      'isFocusableBitmask': SemanticTrait.focusable,
      // States
      'isExpandedBitmask': SemanticState.expanded,
      'isSelectedBitmask': SemanticState.selected,
      'isToggledBitmask': SemanticState.toggled,
      'isRequiredBitmask': SemanticState.required,
      'isDisabledBitmask': SemanticState.disabled,
      'isFocusedBitmask': SemanticState.focused,
      'isHiddenBitmask': SemanticState.hidden,
      'isLiveRegionBitmask': SemanticState.liveRegion,
      'isReadOnlyBitmask': SemanticState.readOnly,
      'isModalBitmask': SemanticState.modal,
      'isObscuredBitmask': SemanticState.obscured,
      'isMultilineBitmask': SemanticState.multiline,
    };

    expect(generated, expected);

    // Check state is a 2-bit field, generated as offset + mask.
    int parseConst(String name) {
      final m = RegExp('static const int $name = (\\d+);').firstMatch(source);
      expect(m, isNotNull, reason: '$name not found in $_generatedDart');
      return int.parse(m!.group(1)!);
    }

    expect(parseConst('isCheckedBitOffset'), SemanticState.checkStateOffset);
    expect(parseConst('isCheckedFieldMask'), SemanticState.checkStateMask);
  });

  test('SemanticRole values match semantic_role.hpp', () {
    final cpp = _parseCppEnum(File(_roleHpp).readAsStringSync());

    for (final role in SemanticRole.values) {
      expect(cpp, contains(role.name),
          reason: 'Dart role ${role.name} missing from $_roleHpp');
      expect(cpp[role.name], role.value,
          reason: 'value mismatch for role ${role.name}');
    }
    expect(cpp, hasLength(SemanticRole.values.length),
        reason: 'role count differs - a role added in C++ must be added '
            'to the Dart enum');
  });

  test('SemanticActionType indices match semantic_listener_group.hpp', () {
    final cpp = _parseCppEnum(File(_actionHpp).readAsStringSync());

    // The Dart enum relies on declaration order (.index crosses the FFI).
    for (final action in SemanticActionType.values) {
      expect(cpp[action.name], action.index,
          reason: 'value mismatch for action ${action.name}');
    }
    expect(cpp, hasLength(SemanticActionType.values.length),
        reason: 'action count differs - an action added in C++ must be '
            'added to the Dart enum');
  });
}
