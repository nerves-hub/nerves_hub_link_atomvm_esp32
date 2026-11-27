# Changelog

Notable changes to this library. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `resume_update => Payload` starts the download of an offer the device kept
  from before a restart, once joined, and says so on the first join. NervesHub
  does not offer an update again while it is in flight, so a device that
  restarts to download (with only the agent running, say) needs the offer it
  already had.
- The `error_reports` extension (0.1.0): with `extensions => [error_reports]`,
  each crash report `proc_lib` logs goes to NervesHub as a structured report
  (kind, reason, frames, and free heap in `context`), grouped by the platform
  into issues. `nerves_hub_link:report_error/4` reports an error the
  application caught. Reports are held up to `report_buffer` (10) and sent in
  batches at most once a second; a drop is reported.
- `location => Fun` answers the `geo` extension's request with what the
  application knows (a GPS fix, say) instead of a GeoIP lookup: no second TLS
  session. `undefined` (no fix yet) sends nothing, so NervesHub's page still
  offers to set the location by hand.
- On an AtomVM with `esp32_internal_largest_free_block` and
  `esp32_internal_minimum_free_size`, health metrics and the console's
  `memory` add the same numbers for internal RAM only
  (`internal_largest_free_block_bytes`, `internal_minimum_free_heap_bytes`):
  with PSRAM in the heap, the others count megabytes of PSRAM.
- The WebSocket upgrade names the library in its `User-Agent`
  (`nerves_hub_link_atomvm_esp32/<version>`), so NervesHub records the client
  library of each connection. It takes an atomvm_websocket_client with the
  `user_agent` option; an older one ignores it and sends its default.
- `network_interface` may be a function, asked on each join and download,
  for a device that moves between networks without restarting the agent.
- `ping_interval_ms => Ms` sets how often the socket sends WebSocket pings,
  passed to the transport.
- `nerves_hub_link:flush_logs/2` sends the log lines waiting for a batch, for
  an application about to restart the device on purpose.
- `{download_resumed, Offset}` to the owner for each resume, which also counts
  as progress against `download_idle_ms`.
- `console_commands` adds the application's own console commands, as `{Name,
  Description, Fun}` or `{Section, Name, Description, Fun}`. `help` lists the
  commands by section (`device`, `network`, then the application's); one with a
  built-in's name replaces it, and one that raises prints the error. A wrong
  entry, or one named `help`, is refused at start as
  `{invalid_console_command, Entry}`.
- The console's up and down arrows walk through the last 20 lines entered, as
  a shell does, and `clear` clears the screen (and prints nothing in a support
  script). A line is at most 256 bytes.
- The `alarms` extension (0.1.0): with `extensions => [alarms]` and an
  `alarms => Fun`, the agent asks for the alarms every `alarms_interval_ms`
  (30 s by default) and sends `alarms:raised` / `alarms:cleared` as they
  change, and `alarms:snapshot` when NervesHub sends `alarms:sync`. Alarms
  raised while offline keep the time they were raised. With it attached, the
  health report leaves the `alarms` key out. A `Fun` of one argument is given
  the set it returned last time, for hysteresis without state of its own; a
  callback that fails leaves what was raised as it was.
- `alarms => Fun` alone puts the application's alarms on the health report,
  which sent `#{}` before.
- `keep_open_above` closes the socket while an update downloads, unless the
  largest free block of heap is at least that many bytes (`never`: always), and
  reopens it afterwards. An ESP32 without PSRAM has room for one TLS session,
  not two: with the socket open an update took 13 to 19 attempts, each ending
  in "Cannot handle out of memory". Closing waits for the transport to be gone
  and its memory back. Status updates made while the socket is closed are sent
  once the device has joined again. Without the option nothing changes.
- After a failed update the device joins again, so that NervesHub offers it
  again: before, a socket that stayed open never asked again, and the device
  kept its old firmware until something else made it reconnect. It waits
  `update_retry_backoff` first (30 s, doubling with each failure in a row up
  to an hour), so a failure that repeats at once is not a loop. Until then the
  firmware that failed is held: offered again sooner, it is not downloaded,
  and the owner hears `{update_ignored, backing_off}`. A socket closed for the
  download opens again at once, so the device stays reachable.
- `before_update`, a function run before a download starts, to free memory.
  One that does not return `ok` fails the update rather than the agent.

### Changed

- **Breaking:** `reschedule_update/3` takes its delay in whole minutes, not
  milliseconds, and the agent sends `delay_for` to NervesHub in minutes. That
  is the unit NervesHub's docs give and nerves_hub_link has always sent; this
  library sent milliseconds, which NervesHub read as milliseconds too, so a
  reschedule lasted a moment rather than the delay asked for. An application
  that passes a delay has to divide it by 60,000:
  `reschedule_update(Pid, 3600000, Reason)` becomes
  `reschedule_update(Pid, 60, Reason)`. A delay under 5 minutes, 0 included,
  is sent as 5, the minimum nerves_hub_link sends. Release this before
  NervesHub's change to read `delay_for` as minutes deploys. A device still
  sending milliseconds to that NervesHub would be held back 60,000 times
  longer than it asked (a minute becomes 41 days), while a device sending
  minutes to the NervesHub of today is only offered the update again sooner
  than it asked.
- The socket pings once a minute by default, not every 10 seconds as
  ESP-IDF does on its own. On a metered link (a cellular modem, say) the pings
  cost more than the heartbeats, and NervesHub needs only the
  heartbeats to keep the socket. A dead link is now noticed within 3 minutes
  rather than 2:10; set `ping_interval_ms` lower to get that back.
- A batch of log lines is encoded a line at a time. Encoded whole, a 2 KB
  batch took 9 KB off the lowest free heap of an ESP32 without PSRAM, at the
  flush that follows the extensions attaching; a line at a time, nothing
  measurable.
- A batch of log lines also stops at 4096 bytes of messages, not only at 100
  lines; the rest goes at the next flush. A batch is encoded in one go right
  after a rejoin, when the TLS handshake has just taken its share of the heap,
  and a hundred lines of a few hundred bytes each ran an ESP32 without PSRAM
  out of memory there. The first line always goes, however long.
- Log lines no longer wait for the batch timer when the device may be about
  to go down: a line at `error` or worse, and any line while an update
  downloads, goes soon, and a `reboot` sends what is waiting first. A batch
  still waiting went with a panic. The first such line goes at once and the
  ones within the next 250 ms together after it, so a burst of errors is a
  few messages a second, inside NervesHub's limit of 5, not one per line.
- An armed update counts as busy until the reboot: offered again before then,
  it is not downloaded into the other slot, which by then holds the previous
  firmware. The owner hears `{update_ignored, armed}`; `apply_update/2` gets
  `{update_decision_ignored, armed}`, and `request_update/1` `{error, armed}`.
- A status update made while the device is not joined (`started`, `completed`,
  `failed`) waits for the next join, in order, rather than being dropped; the
  latest of each status is kept.
- A download resumes for as long as connections keep bringing bytes, in place
  of five retries in all. Each connection is read with a deadline,
  `resume_after_ms` (10 s): one that goes quiet, fails or closes short is
  dropped and the rest asked for with `Range`. It gives up after `resumes` (3)
  connections in a row that brought no byte past the furthest any connection
  reached, waiting `resume_after_ms` times that count before each. A response
  that ends short of the size is resumed too, and one that ends after every
  byte arrived is done. The agent passes its `download_resume_after_ms` and
  `download_resumes` on as these two. Over a cellular modem every connection
  carried 20-200 KB and then went silent, and the retries ran out on a slow
  day.
  `max_retries` and `retry_backoff` are gone, and errors are no longer wrapped
  in `download_failed`: the reason is what failed (`{connect_failed, _}`,
  `{http_status, 503}`, `download_stalled`).
- Each flash sector is erased just before it is written, in place of the
  whole archive before the download. An erase holds the CPU, and AtomVM's
  scheduler with it: a ~460 KB archive erased up front stopped every process
  for seconds, long enough for a call elsewhere in the application to time out.
- An update bigger than the slot it would overwrite is refused before
  anything is erased, as `{error, {update_too_big, Size, SlotSize}}`, instead
  of failing halfway through the download with the slot already half
  rewritten.
- `extensions => all` includes `alarms`.
- The agent gives up on a quiet download after `download_idle_ms` or after
  `(download_resumes + 1) * download_resume_after_ms`, whichever is longer.
  Raising `download_resume_after_ms` for a slow link had the agent end a
  download as stalled while it waited to reconnect.
- The numbers in the config are checked at start: one that is not a positive
  integer (a `{Min, Max}` pair of them for the backoffs; a non-negative integer
  or `never` for `keep_open_above`) is `{error, {invalid_config, Key, Value}}`
  from `start_link`. `nerves_hub_link:config()` lists every key the agent reads.

### Fixed

- While an update is in flight, every join carries
  `currently_downloading_uuid`. Without it, the join after a socket closed for
  the download (`keep_open_above`) told NervesHub the device was idle, and it
  ended the update as abandoned.
- A send the transport refused with anything but `{error, _}` crashed the
  agent, and its owner with it: atomvm_websocket_client's port, before
  nerves-hub/atomvm_websocket_client#3, answered a bare `not_connected` when
  the socket closed under a queued send. Any refusal is now
  `{send_failed, Reason}`.
- Console output goes up in pieces of at most 256 bytes. Each `up` is
  JSON-encoded in the agent, which on AtomVM costs the process many times the
  output's size in heap: a 2 KB answer with quotes in it took more than an
  ESP32 without PSRAM had in one block, and the device panicked.
- Console output longer than one 256-byte piece is encoded in a short-lived
  process, not on the agent's heap. Encoding a piece builds several times its
  size in garbage (every quote in a command's JSON output is escaped); on the
  agent's heap that garbage grew it into one contiguous block of its whole new
  size, which an ESP32 without PSRAM short of memory did not have for a
  1.1 KB answer. Shorter output (the echo of a keystroke,
  a prompt) stays where it was: a process per keystroke would fragment the
  heap instead.
- `capture_io` with `register => Name` captures by the name, through one
  capture per name registered as `nh_io_capture_Name`; agents under other names
  have their own. An agent started again under the name used to
  get a new capture each time, and the old one stayed alive sending to the dead
  agent, along with every process that had inherited it.
- `client_cert` and `shared_secret` are kept sealed in a fun in the agent's
  state and opened only to build the socket's options. A crash prints the
  process's state, and with it the device's private key, to the serial log and
  the crash report; a fun prints as `#Fun<..>`. Either may also be given as
  such a fun.
- An agent started again before the reboot took an armed update for one the
  device had booted: it counted a boot that never happened, committed the
  update on the first join, and would download the next offer over the slot
  the device runs from. A small registered process, `nh_armed`, now marks an
  armed update until the reboot, and the owner hears `{update_ready, Slot}`
  again from the new agent.
- An update written and armed for the next boot was committed by any join
  before the reboot, while the device still ran the firmware it had: the slot
  a failed boot goes back to was dropped, and NervesHub heard the old firmware
  validate the new. Only a reconnect between the two did it before; with the
  socket closed for the download, reopening it after every update did.

## [0.2.0] - 2026-09-24

Upgrading changes what a device does by default. **Changed** lists what to
check before rolling this out to a fleet.

### Changed

- Firmware is on trial after an update, and on by default. An update that does
  not reach NervesHub within three boots, or within five minutes of any one of
  them, is reverted and the device restarts into what it ran before. Nothing
  reverted before. `firmware_trial => off` keeps the old behaviour, and
  `reboot => manual` reverts without restarting.
- The agent reconnects, not the transport. It opens the transport with
  `disable_auto_reconnect => true`, and a transport other than
  `websocket_client` must honour that or it will reconnect twice.
- New events reach the handler: `{update_mode, Mode, Allowed}` after every
  join, and `{firmware_trial, Slot, Boot}`, `{firmware_reverted, Slot}`,
  `{update_rejected, Reason}` and `{extension_detached, Name}` when they apply.
  A `gen_server` handler without a catch-all `handle_info/2` clause crashes on
  the first one it does not match.
- The extensions topic is joined after the device topic rather than alongside
  it: once NervesHub says which versions it speaks, or after five seconds.
- Against a NervesHub that speaks logging 0.1.0, log lines are sent in batches
  and arrive up to `log_flush_ms`, 10 seconds by default, after they were
  logged.

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

[Unreleased]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/releases/tag/v0.1.0
