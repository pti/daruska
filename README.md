### What is it?
daruska 
- scans RuuviTags
- stores read information (temperature, humidity etc.) in a database
- provides a REST API for reading the data
- supports WebSockets for receiving real-time updates
- should run fine on a lower spec computer like a Raspberry Pi 3B

### BLE scanning
daruska relies on an external process to read advertisement data from BLE devices.
The process needs to output scanned data one line at a time in the following format:
`<Device address> <Advertisement data in hex>`. For example `12:34:56:78:9A:CB 9904037f073cbd5effc3fff804130b89`.
And naturally only data in the (format used by RuuviTags)[https://github.com/ruuvi/ruuvi-sensor-protocols] is supported.
For example (blepp_scan)[https://github.com/pti/blepp_scan] can be used.
The command to start the process can be defined with the `--command` option, e.g. `-c /path/to/blepp_scan -m 0x0499`.

By default RuuviTags are scanned in 60 second intervals (option `--interval`). 
Scanning will stop after the timeout (`--timeout`) has elapsed or after having
received advertisement data from all the devices. Scanner is kept active all the time if there are open WebSockets.

Unless specified otherwise daruska will scan for all tags within range. One can
also specify the devices to scan using the `--devices` option (comma separated
list of MAC-addresses, e.g. `AA:BB:CC:11:22:33,AA:BB:CC:11:22:44`). Or if the
database already lists all the relevant devices, specify the `--use_saved` option
to only scan for those.

### Usage
- Install (Dart SDK)[https://dart.dev/get-dart] - *Note* that at the moment on ARMv7 one must use a development version of the SDK (2.8.0) because dart:ffi isn't support on 2.7.0.
- Clone this repository and change to the clone directory.
- Run `pub get` to fetch the dependencies.
- Acquire (blepp_scan)[https://github.com/pti/blepp_scan] or a similar command line tool.
- The database will be created in the working directory.
- Start the process with `dart lib/main.dart -c /path/to/blepp_scan -m 0x0499` (+ any other option you need to specify).

Additionally you might want to compile daruska (faster startup, smaller memory footprint): `dart2native -o daruska lib/main.dart`.

### Database
daruska can write sensor events to database in three different intervals: 10 minutes, 1 hour and 1 day.
A separate table is used for each of these in order to keep the queries fast enough.
Events in the smallest interval table are kept for 1 year (option `--archive_after`).
Archiving is done only when daruska is started. Currently the archive table isn't used for anything other than writes.
