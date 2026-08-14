import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gamepads/gamepads.dart';

import '../../../util/focus/gamepad/controller_mapping_capture.dart';
import '../../../util/core_input_descriptors.dart';
import '../../../util/native_controller_mapping.dart';
import '../../../util/native_controller_player_assignments.dart';

/// A privacy-safe physical controller identifier. On Android it comes from the
/// gamepad channel and is stable across reconnects and never a raw descriptor;
/// on Windows and Linux it is a namespaced gamepads-package controller id (see
/// [desktopControllerDeviceId]).
class NativeControllerDevice {
  const NativeControllerDevice({
    required this.id,
    required this.name,
    this.connectionId,
    this.port,
    this.supported = true,
    this.deviceClass = NativeControllerDeviceClass.gamepad,
    this.assignable = true,
    this.pinned = false,
  });

  final String id;
  final String name;
  final String? connectionId;
  final int? port;
  final bool supported;
  final NativeControllerDeviceClass deviceClass;

  /// Whether the user may give this device a player slot. A remote may not; a
  /// keyboard may, though it is never given one automatically.
  final bool assignable;

  /// True only while the device sits in the player slot the user chose. A pad
  /// promoted into Player 1 because the pinned pad is absent reads as false, so
  /// the slot shows as borrowed rather than as a pin that silently changed.
  final bool pinned;

  String get runtimeId => connectionId ?? id;

  String get portLabel {
    if (!supported || port == null || port! < 0) return 'Unassigned';
    return 'Player ${port! + 1}';
  }

  /// The device's live role, as shown to the user.
  String get playerLabel {
    if (!supported || port == null || port! < 0) {
      // A remote or an unpinned keyboard holds no port but is not idle: it
      // still drives menus and Player 1 navigation.
      return deviceClass == NativeControllerDeviceClass.gamepad
          ? 'Unassigned'
          : 'Menu & navigation';
    }
    return pinned ? 'Player ${port! + 1} · pinned' : 'Player ${port! + 1}';
  }

  factory NativeControllerDevice.fromMap(Map<String, dynamic> map) {
    final deviceClass = switch (map['deviceClass']?.toString()) {
      'keyboard' => NativeControllerDeviceClass.keyboard,
      'remote' => NativeControllerDeviceClass.remote,
      _ => NativeControllerDeviceClass.gamepad,
    };
    return NativeControllerDevice(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Android gamepad',
      connectionId: map['connectionId']?.toString(),
      port: (map['port'] as num?)?.toInt(),
      supported: map['supported'] is bool ? map['supported'] as bool : true,
      deviceClass: deviceClass,
      // Older native builds send neither key. Defaulting `assignable` to "not a
      // remote" keeps them behaving exactly as before rather than hiding the
      // selector everywhere.
      assignable: map['assignable'] is bool
          ? map['assignable'] as bool
          : deviceClass != NativeControllerDeviceClass.remote,
      pinned: map['pinned'] is bool ? map['pinned'] as bool : false,
    );
  }
}

/// What kind of input device this is, as classified natively. Determines
/// whether it can hold a player slot at all.
enum NativeControllerDeviceClass { gamepad, keyboard, remote }

/// D-pad-navigable native RetroPad remapping panel.
///
/// The surrounding native game overlay owns pause/resume and forwards its
/// libretro button events through [handleButton]. Android sends a separate raw
/// key event only while this widget is waiting to capture a binding.
class NativeControllerMappingScreen extends StatefulWidget {
  const NativeControllerMappingScreen({
    super.key,
    required this.devices,
    required this.mappings,
    required this.onMappingChanged,
    this.coreId = '',
    this.controllerTypesByPort = const {},
    this.onControllerTypeChanged,
    this.onCopyMapping,
    this.assignments = NativeControllerPlayerAssignments.empty,
    this.onAssignmentChanged,
    this.inputDescriptors = CoreInputDescriptors.empty,
    required this.onClose,
  });

  final List<NativeControllerDevice> devices;
  final Map<String, NativeControllerMapping> mappings;
  final Future<void> Function(String deviceId, NativeControllerMapping mapping)
  onMappingChanged;
  final String coreId;
  final Map<int, List<CoreControllerType>> controllerTypesByPort;
  final Future<void> Function(String deviceId, int deviceType)?
  onControllerTypeChanged;
  final Future<void> Function(String sourceDeviceId)? onCopyMapping;
  final NativeControllerPlayerAssignments assignments;
  final Future<void> Function(NativeControllerPlayerAssignments assignments)?
  onAssignmentChanged;

  /// What the running core calls each button, when it says so at all.
  final CoreInputDescriptors inputDescriptors;

  final VoidCallback onClose;

  @override
  State<NativeControllerMappingScreen> createState() =>
      NativeControllerMappingScreenState();
}

class NativeControllerMappingScreenState
    extends State<NativeControllerMappingScreen> {
  static const _rowExtent = 58.0;

  final ScrollController _scroll = ScrollController();
  int _selected = 0;
  int _deviceIndex = 0;
  bool _confirmingCopy = false;
  bool _choosingControllerType = false;
  int _controllerTypeSelected = 0;
  bool _choosingPlayer = false;
  int _playerSelected = 0;
  RetroPadButton? _capturing;
  late NativeControllerMapping _mapping;
  final ControllerMappingCapture? _capture =
      ControllerMappingCapture.forPlatform();

  NativeControllerDevice? get _device =>
      widget.devices.isEmpty ? null : widget.devices[_deviceIndex];
  List<CoreControllerType> get _supportedControllerTypes {
    final port = _device?.port;
    if (port == null) return const [];
    final seenIds = <int>{};
    return (widget.controllerTypesByPort[port] ?? const [])
        .where((type) => type.isSupportedForCore(widget.coreId))
        .where((type) => seenIds.add(type.id))
        .toList(growable: false);
  }

  List<CoreControllerType> get _alternateControllerTypes =>
      _supportedControllerTypes
          .where((type) => !type.isCoreDefault)
          .toList(growable: false);

  bool get _showsControllerTypeSelector => _alternateControllerTypes.isNotEmpty;

  /// A remote cannot hold a player slot, so it gets no selector at all rather
  /// than a selector that always refuses.
  bool get _showsPlayerSelector =>
      _device?.assignable == true && widget.onAssignmentChanged != null;

  int get _playerRow => 1;
  int get _controllerTypeRow => 1 + (_showsPlayerSelector ? 1 : 0);
  int get _buttonStartRow =>
      _controllerTypeRow + (_showsControllerTypeSelector ? 1 : 0);
  int get _copyRow => _buttonStartRow + RetroPadButton.values.length;
  int get _resetRow => _copyRow + 1;
  int get _rowCount => _resetRow + 1;
  int get _copyConfirmRow => 0;
  int get _copyCancelRow => 1;

  List<String> get _copyTargets => widget.devices
      .where((device) => device.supported && device.port != null)
      .map((device) => device.id)
      .where((id) => id != _device?.id)
      .toSet()
      .toList(growable: false);

  bool get _canCopy =>
      _device?.supported == true &&
      _device?.port != null &&
      _copyTargets.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadSelectedDevice();
    _capture?.attach(_onCaptured);
  }

  @override
  void dispose() {
    _capture?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The device list can now change while this panel is open: Android's
  /// InputDeviceListener invalidates it on connect/disconnect, and a
  /// controller can drop mid-remap. Keep [_deviceIndex] valid, and if the
  /// device the user had selected is still present (just moved), follow it
  /// rather than resetting to whatever is now first. If it's gone, clamp to
  /// a neighbouring index — the row 0 label re-renders with the new device's
  /// name, so the switch is visible rather than silent.
  @override
  void didUpdateWidget(covariant NativeControllerMappingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.devices, widget.devices)) {
      final device = _device;
      if (_capturing == null &&
          device != null &&
          oldWidget.mappings[device.id] != widget.mappings[device.id]) {
        _loadSelectedDevice();
      }
      return;
    }

    final previousDevice = _deviceIndex < oldWidget.devices.length
        ? oldWidget.devices[_deviceIndex]
        : null;
    final matchedIndex = previousDevice == null
        ? -1
        : widget.devices.indexWhere(
            (d) => d.runtimeId == previousDevice.runtimeId,
          );
    if (matchedIndex != -1) {
      _deviceIndex = matchedIndex;
    } else if (widget.devices.isEmpty) {
      _deviceIndex = 0;
    } else {
      _deviceIndex = _deviceIndex.clamp(0, widget.devices.length - 1);
    }
    _loadSelectedDevice();
  }

  void _loadSelectedDevice() {
    _mapping = _device == null
        ? NativeControllerMapping.empty
        : widget.mappings[_device!.id] ?? NativeControllerMapping.empty;
  }

  /// Steps back one level *inside* this screen, returning true when it consumed
  /// the Back press.
  ///
  /// The host overlay otherwise treats this whole screen as a single level, so
  /// Back from the capture prompt closed the screen entirely and dropped the
  /// user at the pause menu instead of the button list they came from.
  ///
  /// Back is also the only way out of an armed capture: while capture is armed
  /// the native side routes physical buttons here to be bound, so a pad press
  /// binds rather than cancels, and Back is deliberately not consumed natively.
  bool handleBack() {
    if (_capturing != null) {
      setState(() => _capturing = null);
      unawaited(_capture?.end());
      return true;
    }
    if (_choosingPlayer) {
      setState(() => _choosingPlayer = false);
      return true;
    }
    if (_choosingControllerType) {
      setState(() => _choosingControllerType = false);
      return true;
    }
    if (_confirmingCopy) {
      setState(() => _confirmingCopy = false);
      return true;
    }
    return false;
  }

  /// Called by the native player screen for standard RetroPad overlay input.
  void handleButton(int index, bool pressed) {
    if (!pressed || _capturing != null) return;
    if (_choosingControllerType) {
      switch (index) {
        case 4:
          _moveControllerType(-1);
        case 5:
          _moveControllerType(1);
        case 0:
          _applyControllerType();
        case 8:
          setState(() => _choosingControllerType = false);
      }
      return;
    }
    if (_choosingPlayer) {
      switch (index) {
        case 4:
          _movePlayer(-1);
        case 5:
          _movePlayer(1);
        case 0:
          _applyPlayer();
        case 8:
          setState(() => _choosingPlayer = false);
      }
      return;
    }
    if (_confirmingCopy) {
      switch (index) {
        case 4:
        case 5:
          setState(() {
            _selected = _selected == _copyConfirmRow
                ? _copyCancelRow
                : _copyConfirmRow;
          });
        case 0:
          if (_selected == _copyConfirmRow) {
            _confirmCopy();
          } else {
            setState(() => _confirmingCopy = false);
          }
        case 8:
          setState(() => _confirmingCopy = false);
      }
      return;
    }
    switch (index) {
      case 4:
        _move(-1);
      case 5:
        _move(1);
      case 6:
        _changeDevice(-1);
      case 7:
        _changeDevice(1);
      case 0:
        _activateSelected();
      case 8:
        widget.onClose();
    }
  }

  Future<void> _onCaptured(String deviceId, int code) async {
    final capturing = _capturing;
    final selectedDevice = _device;
    // The device can be switched, or the panel closed, between arming capture
    // and the press arriving; binding to whatever is selected now would attach
    // the press to a controller the user never touched.
    if (capturing == null ||
        selectedDevice == null ||
        deviceId != selectedDevice.runtimeId) {
      return;
    }

    final mapping = _mapping.withBinding(code, capturing);
    if (!mounted) return;
    setState(() {
      _mapping = mapping;
      _capturing = null;
    });
    await _capture?.end();
    await widget.onMappingChanged(selectedDevice.id, mapping);
  }

  void _move(int delta) {
    final next = ((_selected + delta) % _rowCount + _rowCount) % _rowCount;
    setState(() => _selected = next);
    if (!_scroll.hasClients) return;
    final target = (next * _rowExtent)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  void _changeDevice(int delta) {
    if (widget.devices.length < 2) return;
    final next =
        ((_deviceIndex + delta) % widget.devices.length +
            widget.devices.length) %
        widget.devices.length;
    setState(() {
      _deviceIndex = next;
      _loadSelectedDevice();
    });
  }

  void _activateSelected() {
    if (_selected == 0) {
      _changeDevice(1);
      return;
    }
    if (_showsPlayerSelector && _selected == _playerRow) {
      _beginPlayerSelection();
      return;
    }
    if (_showsControllerTypeSelector && _selected == _controllerTypeRow) {
      _beginControllerTypeSelection();
      return;
    }
    if (_selected == _copyRow) {
      _beginCopy();
      return;
    }
    if (_selected == _rowCount - 1) {
      _reset();
      return;
    }
    final device = _device;
    final capture = _capture;
    if (device == null || capture == null) return;
    final button = RetroPadButton.values[_selected - _buttonStartRow];
    setState(() => _capturing = button);
    unawaited(capture.begin(device.runtimeId));
  }

  void _reset() {
    final device = _device;
    if (device == null) return;
    setState(() => _mapping = NativeControllerMapping.empty);
    unawaited(
      widget.onMappingChanged(device.id, NativeControllerMapping.empty),
    );
  }

  void _beginCopy() {
    if (widget.onCopyMapping == null || !_canCopy) return;
    setState(() {
      _confirmingCopy = true;
      _selected = _copyConfirmRow;
    });
  }

  void _confirmCopy() {
    final device = _device;
    final callback = widget.onCopyMapping;
    if (device == null || callback == null) return;
    setState(() => _confirmingCopy = false);
    unawaited(callback(device.id));
  }

  /// Null is "no player slot", which for a keyboard means it keeps driving menu
  /// and Player 1 navigation rather than becoming idle.
  List<int?> get _playerChoices => [
    null,
    for (var player = 1;
        player <= NativeControllerPlayerAssignments.maxPlayers;
        player++)
      player,
  ];

  String _playerChoiceLabel(int? player) {
    if (player != null) return 'Player $player';
    return _device?.deviceClass == NativeControllerDeviceClass.gamepad
        ? 'Unassigned'
        : 'Menu & navigation';
  }

  void _beginPlayerSelection() {
    final device = _device;
    if (!_showsPlayerSelector || device == null) return;
    final current = widget.assignments.playerFor(device.id);
    _playerSelected = _playerChoices.indexOf(current);
    if (_playerSelected < 0) _playerSelected = 0;
    setState(() => _choosingPlayer = true);
  }

  void _movePlayer(int delta) {
    final count = _playerChoices.length;
    setState(() {
      _playerSelected = ((_playerSelected + delta) % count + count) % count;
    });
  }

  void _applyPlayer() {
    final device = _device;
    final callback = widget.onAssignmentChanged;
    if (device == null || callback == null) return;
    final assignments = widget.assignments.withPlayer(
      device.id,
      _playerChoices[_playerSelected],
    );
    setState(() => _choosingPlayer = false);
    unawaited(callback(assignments));
  }

  List<CoreControllerType?> get _controllerTypeChoices => [
    null,
    ..._alternateControllerTypes,
  ];

  String get _controllerTypeLabel {
    final selected = _mapping.controllerTypeForCore(widget.coreId);
    return _alternateControllerTypes
            .where((type) => type.id == selected)
            .firstOrNull
            ?.label ??
        'Auto (Core default)';
  }

  void _beginControllerTypeSelection() {
    if (!_showsControllerTypeSelector) return;
    final selected = _mapping.controllerTypeForCore(widget.coreId);
    final choices = _controllerTypeChoices;
    _controllerTypeSelected = choices.indexWhere(
      (type) => type?.id == selected,
    );
    if (_controllerTypeSelected < 0) _controllerTypeSelected = 0;
    setState(() => _choosingControllerType = true);
  }

  void _moveControllerType(int delta) {
    final count = _controllerTypeChoices.length;
    if (count == 0) return;
    setState(() {
      _controllerTypeSelected =
          ((_controllerTypeSelected + delta) % count + count) % count;
    });
  }

  void _applyControllerType() {
    final device = _device;
    final callback = widget.onControllerTypeChanged;
    if (device == null || callback == null) return;
    final type = _controllerTypeChoices[_controllerTypeSelected];
    final deviceType = type?.id ?? retroDeviceJoypad;
    setState(() {
      _mapping = _mapping.withControllerType(widget.coreId, deviceType);
      _choosingControllerType = false;
    });
    unawaited(callback(device.id, deviceType));
  }

  /// How a stored binding is described back to the user.
  ///
  /// A bare "Key code 97" is the best that can be said of an Android keycode,
  /// but a desktop binding was captured as a known button and deserves its
  /// name. [desktopGamepadButtonsByCode] returning null is what distinguishes
  /// the two, so no platform check is needed here.
  String _bindingLabel(int? code) {
    if (code == null) return 'Default layout';
    final button = desktopGamepadButtonsByCode[code];
    if (button != null) return _desktopButtonLabel(button);
    return 'Key code $code';
  }

  String _desktopButtonLabel(GamepadButton button) => switch (button) {
    GamepadButton.a => 'A / Cross',
    GamepadButton.b => 'B / Circle',
    GamepadButton.x => 'X / Square',
    GamepadButton.y => 'Y / Triangle',
    GamepadButton.leftBumper => 'Left bumper',
    GamepadButton.rightBumper => 'Right bumper',
    GamepadButton.leftTrigger => 'Left trigger',
    GamepadButton.rightTrigger => 'Right trigger',
    GamepadButton.back => 'Back / Select',
    GamepadButton.start => 'Start / Menu',
    GamepadButton.home => 'Guide',
    GamepadButton.leftStick => 'Left stick click',
    GamepadButton.rightStick => 'Right stick click',
    GamepadButton.dpadUp => 'D-pad Up',
    GamepadButton.dpadDown => 'D-pad Down',
    GamepadButton.dpadLeft => 'D-pad Left',
    GamepadButton.dpadRight => 'D-pad Right',
    GamepadButton.touchpad => 'Touchpad',
  };

  /// A button's name, plus what the running core does with it when the core
  /// says so — "L1 — Insert Coin" rather than a bare "L1".
  ///
  /// The lookup keys on [RetroPadButton.retroPadIndex], which is the libretro
  /// id. Those integers are correct, but note the names disagree: libretro's
  /// `RETRO_DEVICE_ID_JOYPAD_B` is 0 and `_A` is 8 (SNES positional naming),
  /// while [RetroPadButton] uses Android/Xbox physical names, so the core's
  /// description for the button shown here as "A" arrives under libretro's
  /// name "B". This is not a bug; do not "correct" the indices.
  /// What the running core calls this button, or null when it says nothing
  /// useful.
  ///
  /// A core that merely restates the button name ("Start" for Start, "D-Pad Up"
  /// for D-pad Up) has told the user nothing, so it counts as saying nothing.
  /// Compared loosely, so casing and punctuation differences still register as
  /// a restatement.
  String? _buttonDescription(RetroPadButton button) {
    final port = _device?.port;
    if (port == null) return null;
    final description = widget.inputDescriptors.describe(
      port,
      button.retroPadIndex,
      // Descriptions are per controller type: a core can name the same id
      // differently for its alternate layouts, so ask for the one in effect.
      device: _mapping.controllerTypeForCore(widget.coreId),
    );
    if (description == null) return null;
    if (_squashed(description) == _squashed(button.label)) return null;
    return description;
  }

  /// The row's primary text: what the button *does* in this game, falling back
  /// to the RetroPad name. "Missiles" is what the player is looking for;
  /// "A" is the abstract slot it happens to occupy, and it stays visible in the
  /// subtitle. This also keeps long descriptions off a line already carrying
  /// the button name, so they rarely need truncating at all.
  String _buttonTitle(RetroPadButton button) =>
      _buttonDescription(button) ?? button.label;

  String _buttonSubtitle(RetroPadButton button, int? keycode) {
    final binding = _bindingLabel(keycode);
    return _buttonDescription(button) == null
        ? binding
        : '${button.label} · $binding';
  }

  String _squashed(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Names a profile id for the swap warning. A profile with a pin but nothing
  /// connected is still a real assignment, so it is described rather than
  /// hidden.
  String _nameForProfile(String profileId) =>
      widget.devices
          .where((device) => device.id == profileId)
          .firstOrNull
          ?.name ??
      'a disconnected controller';

  int? _keycodeFor(RetroPadButton button) {
    for (final entry in _mapping.keycodeToButton.entries) {
      if (entry.value == button) return entry.key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Connect a physical controller to change its mapping.',
          style: TextStyle(color: Colors.white70, fontSize: 18),
        ),
      );
    }

    if (_confirmingCopy) {
      final source = _device;
      return Flexible(
        child: ListView(
          controller: _scroll,
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Copy ${source?.portLabel ?? 'selected controller'} mapping and core controller type to ${_copyTargets.length} other controller profile${_copyTargets.length == 1 ? '' : 's'}?\n\nThis copies Android button keycodes and this core\'s selected layout. Use only with compatible controller layouts; analog axes are not copied.',
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
            _row(
              'Copy mappings',
              _copyConfirmRow,
              trailing: Icons.check,
              onTap: _confirmCopy,
            ),
            _row(
              'Cancel',
              _copyCancelRow,
              trailing: Icons.close,
              onTap: () => setState(() => _confirmingCopy = false),
            ),
          ],
        ),
      );
    }

    if (_capturing case final button?) {
      final description = _buttonDescription(button);
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          description == null
              ? 'Press the physical button to bind to ${button.label}.'
              : 'Press the physical button to bind to $description (${button.label}).',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 20),
        ),
      );
    }

    if (_choosingPlayer) {
      final choices = _playerChoices;
      final assigned = _device == null
          ? null
          : widget.assignments.playerFor(_device!.id);
      return Flexible(
        child: ListView.builder(
          controller: _scroll,
          shrinkWrap: true,
          itemExtent: _rowExtent,
          itemCount: choices.length,
          itemBuilder: (context, index) {
            final player = choices[index];
            final occupant = player == null
                ? null
                : widget.assignments.profileIdByPlayer[player];
            return _row(
              _playerChoiceLabel(player),
              index,
              subtitle: occupant != null && occupant != _device?.id
                  ? 'Currently ${_nameForProfile(occupant)} — they will swap'
                  : null,
              trailing: player == assigned ? Icons.check : null,
              onTap: () {
                setState(() => _playerSelected = index);
                _applyPlayer();
              },
            );
          },
        ),
      );
    }

    if (_choosingControllerType) {
      final choices = _controllerTypeChoices;
      return Flexible(
        child: ListView.builder(
          controller: _scroll,
          shrinkWrap: true,
          itemExtent: _rowExtent,
          itemCount: choices.length,
          itemBuilder: (context, index) {
            final type = choices[index];
            return _row(
              type?.label ?? 'Auto (Core default)',
              index,
              subtitle: type == null
                  ? 'Let the core choose its default layout'
                  : null,
              trailing: index == _controllerTypeSelected ? Icons.check : null,
              onTap: () {
                setState(() => _controllerTypeSelected = index);
                _applyControllerType();
              },
            );
          },
        ),
      );
    }

    return Flexible(
      child: ListView.builder(
        controller: _scroll,
        shrinkWrap: true,
        itemExtent: _rowExtent,
        itemCount: _rowCount,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _row(
              '${_device!.playerLabel} — ${_device!.name}',
              index,
              trailing: Icons.swap_horiz,
              onTap: () {
                setState(() => _selected = index);
                _changeDevice(1);
              },
            );
          }
          if (_showsPlayerSelector && index == _playerRow) {
            return _row(
              'Player assignment',
              index,
              subtitle: _device!.playerLabel,
              trailing: Icons.chevron_right,
              onTap: () {
                setState(() => _selected = index);
                _beginPlayerSelection();
              },
            );
          }
          if (_showsControllerTypeSelector && index == _controllerTypeRow) {
            return _row(
              'Core controller type',
              index,
              subtitle: _controllerTypeLabel,
              trailing: Icons.chevron_right,
              onTap: () {
                setState(() => _selected = index);
                _beginControllerTypeSelection();
              },
            );
          }
          if (index == _copyRow) {
            final targets = _copyTargets.length;
            final canCopy = _canCopy;
            return _row(
              !canCopy
                  ? 'Copy mapping to all controllers (none)'
                  : 'Copy mapping to all controllers',
              index,
              subtitle: !canCopy
                  ? 'Select a controller that holds a player slot'
                  : '$targets other profile${targets == 1 ? '' : 's'}',
              trailing: Icons.copy,
              onTap: () {
                setState(() => _selected = index);
                _beginCopy();
              },
            );
          }
          if (index == _resetRow) {
            return _row(
              'Reset to defaults',
              index,
              trailing: Icons.restart_alt,
              onTap: () {
                setState(() => _selected = index);
                _reset();
              },
            );
          }
          final button = RetroPadButton.values[index - _buttonStartRow];
          final keycode = _keycodeFor(button);
          return _row(
            _buttonTitle(button),
            index,
            subtitle: _buttonSubtitle(button, keycode),
            italicLabel: _buttonDescription(button) != null,
            trailing: Icons.chevron_right,
            onTap: () {
              setState(() => _selected = index);
              _activateSelected();
            },
          );
        },
      ),
    );
  }

  Widget _row(
    String label,
    int index, {
    String? subtitle,
    IconData? trailing,
    // Set when the label is text the core supplied rather than one of this
    // app's own names, so a game's vocabulary reads as a quotation.
    bool italicLabel = false,
    required VoidCallback onTap,
  }) {
    final selected = index == _selected;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? const Color(0x333F8CFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF3F8CFF) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontStyle: italicLabel
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) Icon(trailing, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}
