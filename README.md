# 76_Balboa.pm — FHEM Module for Balboa WiFi Spa Controllers

A native FHEM Perl module for direct TCP control of **Balboa WiFi** spa controllers (e.g. BP series, used in many hot tubs and whirlpools). No external dependencies, no middleware required.

---

## Features

- Direct TCP connection to the Balboa WiFi module (port 4257)
- **Poll mode** — connects briefly every N seconds, then disconnects. Keeps the connection free for the official **Balboa BWA app** to work in parallel
- Non-blocking polling via FHEM's `BlockingCall` — the main FHEM loop is never blocked
- **Command queue** — set commands are sent within the same TCP connection as the next poll cycle, avoiding connection conflicts
- **Automatic retry with 15-minute timeout** — if a command doesn't take effect (e.g. due to a WiFi dropout), it is retried automatically. After 15 minutes FHEM gives up, so you can still control the spa from the app or the display
- Reads: current temperature, target temperature, pump states, light, heating, heating mode, fault code
- Controls: target temperature, pump 1, pump 2, light

---

## Requirements

- FHEM installation
- Balboa WiFi module connected to local network (e.g. Balboa BP series)
- Perl modules (standard, included in all common FHEM installations):
  - `IO::Socket::INET`
  - `IO::Select`
  - `Time::HiRes`

---

## Installation

### FHEM Module

Copy `76_Balboa.pm` into your FHEM module directory:

```bash
cp 76_Balboa.pm /opt/fhem/FHEM/
```

Then reload the module in FHEM:

```
reload 76_Balboa
```

### Web App (optional)

A touch-friendly control interface is included in `webapp/index.html`. Deploy it directly onto the FHEM server so it can call the FHEM API without CORS issues:

```bash
mkdir -p /opt/fhem/www/balboa
cp webapp/index.html /opt/fhem/www/balboa/index.html
```

The app is then available at:

```
http://<fhem-ip>:8083/fhem/www/balboa/index.html
```

It automatically calls `/fhem` as the API base URL (same host, no extra configuration needed). If your FHEM instance uses a CSRF token (default since FHEM 5.8), the app fetches and includes it automatically.

> **Note:** If your FHEM web interface uses a custom `webname` attribute (default: `fhem`), adjust the URL accordingly. You can also override the API URL via the settings icon inside the app.

---

## Define

```
define <name> Balboa <ip> [<port>]
```

| Parameter | Description |
|-----------|-------------|
| `<ip>` | IP address of the Balboa WiFi module |
| `<port>` | TCP port (optional, default: **4257**) |

**Example:**
```
define Whirlpool Balboa 192.168.178.127
```

---

## Set Commands

| Command | Values | Description |
|---------|--------|-------------|
| `setTemp` | 10–37 | Target temperature in °C |
| `pump1` | `0`, `1`, `2` | Pump 1 (0 = off, 1 = on, 2 = high) |
| `pump2` | `0`, `1`, `2` | Pump 2 (0 = off, 1 = on, 2 = high) |
| `light` | `0`, `1` | Light (0 = off, 1 = on) |
| `heatMode` | `ready`, `rest` | Heating mode |
| `tempRange` | `low`, `high` | Temperature range |
| `tempScale` | `C`, `F` | Temperature unit |
| `setTime` | `HH:MM` | Set spa clock |
| `filterCycle1` | `HH:MM HH:MM` | Filter cycle 1: start time and duration |
| `filterCycle2` | `0\|1 HH:MM HH:MM` | Filter cycle 2: enable, start time, duration |
| `statusRequest` | — | Trigger an immediate poll |

**Examples:**
```
set Whirlpool setTemp 38
set Whirlpool pump1 1
set Whirlpool pump2 0
set Whirlpool light 1
set Whirlpool heatMode ready
set Whirlpool tempRange high
set Whirlpool tempScale C
set Whirlpool setTime 14:30
set Whirlpool statusRequest
```

> **Note on pumps:** Balboa pumps are toggled, not set directly. The module calculates how many toggle commands are needed to reach the desired state. A 2-speed pump cycles through: `0` (off) → `1` (on) → `2` (high) → `0` (off).

---

## Readings

| Reading | Values | Description |
|---------|--------|-------------|
| `temp` | 10.0–37.0 | Current water temperature (°C) |
| `setTemp` | 10.0–37.0 | Target temperature (°C) |
| `pump1` | `0` / `1` / `2` | Pump 1 state (0=off, 1=on, 2=high) |
| `pump2` | `0` / `1` / `2` | Pump 2 state (0=off, 1=on, 2=high) |
| `light` | `0` / `1` | Light state (0=off, 1=on) |
| `heating` | `0` / `1` | Heating element active (0=off, 1=on) |
| `heatingMode` | `ready` / `rest` / `ready_in_rest` | Heating mode |
| `tempScale` | `C` / `F` | Temperature unit reported by spa |
| `timeOfDay` | `HH:MM` | Current time stored in spa |
| `tempRange` | `low` / `high` | Active temperature range |
| `filter1Running` | `0` / `1` | Filter cycle 1 currently running |
| `filter2Running` | `0` / `1` | Filter cycle 2 currently running |
| `filter1Start` | `HH:MM` | Filter cycle 1 start time |
| `filter1Duration` | `HH:MM` | Filter cycle 1 duration |
| `filter2Enabled` | `0` / `1` | Filter cycle 2 enabled |
| `filter2Start` | `HH:MM` | Filter cycle 2 start time |
| `filter2Duration` | `HH:MM` | Filter cycle 2 duration |
| `faultCode` | `255` = no fault | Fault code (255 = OK) |
| `faultMessage` | Text | Fault description |
| `rawStatus` | Hex bytes | Raw status payload for debugging |
| `state` | `connected` / `disconnected` / `timeout` / `disabled` | Connection state |

---

## Attributes

| Attribute | Values | Default | Description |
|-----------|--------|---------|-------------|
| `interval` | 60, 120, 180, 300, 600 | 180 | Poll interval in seconds |
| `tempOffset` | −5 … +5 | 0 | Temperature calibration offset (°C) |
| `disable` | 0, 1 | 0 | Disable polling |

**Example:**
```
attr Whirlpool interval 180
attr Whirlpool tempOffset 0.5
```

---

## How it Works

### Poll Mode

The module does **not** maintain a persistent TCP connection. Instead, it connects briefly every `interval` seconds:

```
Connect → Read status frame → (Send queued commands) → Read updated status → Disconnect
```

This keeps the connection free so the official **Balboa BWA app** (in LAN direct mode) can connect at any time.

### Command Queue

When you issue a `set` command, it is placed in an internal queue. The command is then sent to the spa during the next poll cycle — within the same TCP connection as the status read. This prevents connection conflicts between set commands and ongoing polls.

If a poll is already running when you issue a `set` command, the command waits in the queue. As soon as the current poll finishes, a new poll is triggered within 1 second.

### Retry with 15-Minute Timeout

After sending a command, the module compares the expected value with the value reported by the spa in the next status read. If they don't match (e.g. due to a brief WiFi dropout):

- The command is automatically re-queued and retried
- The retry continues until the spa confirms the value
- After **15 minutes**, retrying stops automatically — so you can always override from the app, the spa display, or physically

The remaining retry time is logged at verbose level 2:
```
Balboa Whirlpool: setTemp erwartet=33.0 gelesen=34.0 -> Retry (noch 14 Min)
Balboa Whirlpool: setTemp 33.0 bestaetigt
```

### Protocol

The Balboa WiFi protocol is a binary TCP protocol:

```
Frame: 7E [LEN] [TYPE-3-Bytes] [PAYLOAD] [CRC-8] 7E
```

- **Port:** 4257
- **CRC-8:** polynomial 0x07, initial value 0x02, final XOR 0x02, computed over `[LEN, type, payload]`
- **LEN:** `len(type) + len(payload) + 2` (includes CRC byte and end delimiter)
- The spa broadcasts status frames automatically ~once per second after connection
- Temperature stored as `raw = °C × 2` (0.5°C precision in Celsius mode)

Protocol reference: [ccutrer/balboa_worldwide_app](https://github.com/ccutrer/balboa_worldwide_app), [garbled1/balboa_homeassistant](https://github.com/garbled1/balboa_homeassistant)

---

## Migrating from HTTPMOD + PHP Proxy

If you previously used an HTTPMOD device with a PHP proxy:

**Old:**
```
define Whirlpool HTTPMOD http://192.168.x.x:85/index.php 240
```

**New:**
```
define Whirlpool Balboa 192.168.178.127
attr Whirlpool interval 180
```

Reading names are identical (`temp`, `setTemp`, `pump1`, `pump2`, `light`, `heating`, `faultCode`, `faultMessage`). Note that `pump1`, `pump2`, `light` and `heating` now use numeric values (`0`/`1`/`2`) instead of strings (`off`/`on`/`high`). Existing `stateFormat`, `DbLog`, plots and DOIFs that compare against these strings must be updated accordingly.

**Adjust notify definitions** — replace HTTP calls with direct FHEM commands:

```perl
# Old:
notify Whirlpool_Heizung:on {
    HttpUtils_NonblockingGet({ url => "http://192.168.x.x:86/index.php?setTemp=35" })
}

# New:
notify Whirlpool_Heizung:on set Whirlpool setTemp 35
notify Whirlpool_Heizung:off set Whirlpool setTemp 10
```

**Important:** After migration, `faultCode` will always read `255` (no fault). If your DOIF or automations check `[Whirlpool:faultCode] eq "255"` as a precondition for heating, this will now always pass — which is the correct behaviour.

---

## Debugging

Enable verbose logging in FHEM:

```
attr Whirlpool verbose 4
```

At **verbose 4**, the log shows:
- Poll start / connection details
- Parsed temperature, pump, light, heating values
- Raw status bytes

At **verbose 3**, the log shows:
- Sent command hex frames (for verifying CRC and frame format)
- Command confirmation or retry messages

The `rawStatus` reading contains the raw payload bytes from the last status frame, useful for verifying byte positions if readings seem incorrect.

---

## Known Limitations

- The module does **not** yet read the spa's fault log (fault codes from the hardware). `faultCode` is always `255`.
- Only pump1 and pump2 are exposed as set commands. pump3 and blower toggle codes are defined internally but not surfaced.
- The official Balboa app in **LAN direct mode** and FHEM cannot connect simultaneously. FHEM holds the connection for only ~2–5 seconds per poll, so the app can connect freely in between.

---

## Tested With

- Balboa BP series controller with WiFi module
- FHEM 6.x on Linux / Raspberry Pi

---

## License

This module is free software. Use it at your own risk.

Protocol documentation based on:
- https://github.com/ccutrer/balboa_worldwide_app
- https://github.com/garbled1/balboa_homeassistant
