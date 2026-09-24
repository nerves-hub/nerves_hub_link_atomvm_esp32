# Changelog

Notable changes to this library. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A device authenticating with a shared secret could not reconnect once its
  first connection was more than 90 seconds old. The transport reconnected by
  itself and replayed the headers it was opened with, and NervesHub refuses a
  signature that old, so a Wi-Fi drop, a server deploy or the Reconnect button
  left the device refused until it rebooted. The agent now reconnects itself,
  with backoff and jitter, and signs each connection as it opens it.

### Added

- `device_api_version` 2.4.0 in the join, which is what NervesHub gates support
  scripts, extension negotiation and device-managed updates on. Before this it
  treated every device as 1.0.0.
- Support scripts: `scripts/run` runs console commands, one per line, and
  answers with their output. `reboot` is refused in a script.
- The full set of update statuses: `received`, `started` with the network
  interface, `completed`, `ignored` and `rescheduled` alongside `failed`.
- `apply_update/2`, `ignore_update/2` and `reschedule_update/3`, for an
  application running with `updates => manual`.
- Device-managed updates: `check_for_update/1`, `request_update/1`,
  `set_update_mode/2` and `update_mode/1`.
- Downloads resume from the last byte received after a dropped connection,
  retried with backoff, and a download that goes quiet is given up on.
- Firmware on trial is reverted if it does not join NervesHub within three
  boots or five minutes of one, and the join reports `firmware_validated` and
  `firmware_auto_revert_detected`. See `firmware_trial`.
- `report_network_interface` after every join. See `network_interface`.
- Extensions negotiate versions from NervesHub's `extensions:get`, and follow
  an operator turning one on or off while connected.
- Logging 0.1.0: lines are batched, held across a disconnect up to
  `log_buffer`, and a gap from dropped lines is reported.

## [0.1.2] - 2026-08-24

### Fixed

- Maintainer tooling moved from `plugins` to `project_plugins`. `plugins` is
  inherited, so anything depending on this library built seven packages it had
  no use for, erlfmt and rebar3_hex among them, before compiling a line of its
  own code.

## [0.1.1] - 2026-08-24

### Fixed

- The **Installing** snippet in the README asked for a git dependency, which is
  what it was before this package was on Hex. Documentation only; no code
  changed between 0.1.0 and this.

### Added

- `RELEASING.md`, listing every file a release has to touch. The README
  dependency snippet is the one nothing checks and the one that was wrong here.

## [0.1.0] - 2026-08-24

First release. A NervesHub device agent for AtomVM on the ESP32, verified on
hardware against a running NervesHub rather than only against tests.

### Added

- Shared-secret and client-certificate authentication, and the Phoenix channel
  protocol as a pure state machine with no processes, timers or socket of its
  own.
- Firmware description read out of flash: the packbeam AtomVM booted, found
  through the boot path `esp32init` records in NVS, hashed so the digest
  matches what NervesHub derived from the same archive on upload.
- Over-the-air updates into whichever of two packbeam slots the device is not
  running from, so a refused or corrupt download leaves it running what it had.
- Firmware signing and verification. Packbeam has no signature format, so this
  defines one: an entry appended after everything it signs, verified against
  the organization's existing fwup keys, checked before the boot path moves.
  `nh-avm` signs, verifies and generates keys.
- A remote console answering NervesHub's console channel with a fixed set of
  commands, since AtomVM has no shell.
- The health, geo and logging extensions, and the `identify` and `reboot`
  actions.
- `nh_logger`, a `logger` handler that ships what an application logs, and
  `nh_io_capture`, an opt-in group leader that ships what it prints.
- `priv/atomvm`, the partition table and build settings a device needs, so the
  VM is reproducible rather than described.

[Unreleased]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/releases/tag/v0.1.0
