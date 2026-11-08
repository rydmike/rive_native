#ifndef _RIVE_NATIVE_GAMEPAD_INVOCATION_HPP_
#define _RIVE_NATIVE_GAMEPAD_INVOCATION_HPP_

#include "rive/animation/listener_invocation.hpp"
#include "rive/input/gamepad_snapshot.hpp"
#include "rive/input/standard_gamepad.hpp"

// Builds the listener invocation for a gamepad event Dart reports: kind 0
// connected, 1 event, 2 disconnected; changeKind 0 button, 1 axis. Mirrors
// fillStandardIntent in gamepad_batch.cpp for the event kind.
inline rive::ListenerInvocation gamepadListenerInvocation(
    uint8_t kind,
    int32_t deviceId,
    uint64_t buttonMask,
    const float* buttonValues,
    size_t buttonCount,
    const float* axes,
    size_t axisCount,
    uint8_t mapping,
    uint8_t changeKind,
    uint8_t changeIndex,
    float changeValue)
{
  using namespace rive;
  if (kind == 2)
  {
    return ListenerInvocation::gamepadDisconnected(deviceId);
  }
  GamepadSnapshot snapshot;
  snapshot.deviceId = deviceId;
  snapshot.buttonMask = buttonMask;
  if (buttonValues != nullptr && buttonCount > 0)
  {
    snapshot.buttonValues.assign(buttonValues, buttonValues + buttonCount);
  }
  if (axes != nullptr && axisCount > 0)
  {
    snapshot.axes.assign(axes, axes + axisCount);
  }
  snapshot.mapping = static_cast<GamepadMappingKind>(mapping);
  if (kind == 0)
  {
    return ListenerInvocation::gamepadConnected(snapshot);
  }
  GamepadEventInvocation ev;
  ev.fullState = snapshot;
  ev.change.kind = changeKind == 0 ? GamepadInputChangeKind::button
                                   : GamepadInputChangeKind::axis;
  ev.change.index = changeIndex;
  ev.change.value = changeValue;
  ev.hasStandardButtonIntent = false;
  ev.hasStandardAxisIntent = false;
  if (snapshot.mapping == GamepadMappingKind::standard)
  {
    if (ev.change.kind == GamepadInputChangeKind::button)
    {
      if (ev.change.index <= static_cast<uint8_t>(StandardGamepadButton::start))
      {
        ev.hasStandardButtonIntent = true;
        ev.standardButton = static_cast<StandardGamepadButton>(ev.change.index);
      }
    }
    else if (
        ev.change.index <=
        static_cast<uint8_t>(StandardGamepadAxis::rightTrigger))
    {
      ev.hasStandardAxisIntent = true;
      ev.standardAxis = static_cast<StandardGamepadAxis>(ev.change.index);
    }
  }
  return ListenerInvocation::gamepadEvent(std::move(ev));
}

#endif
