# Android device testing

How the Android GL present path is tested on real devices, what testing found,
and the decisions that followed. Read this before changing how Rive textures
reach Flutter on Android, and add to it when you test again.

## The present path

`ANDROID_HARDWARE_BUFFERS.md` describes the hardware buffer path in detail for
reviewers: the Flutter contract it relies on, buffer ownership, push timing,
threads and locks, teardown and fallbacks.

An app that opts in with `RiveNative.init(androidHardwareBuffers: true)` gets,
on API 29 and up, each Rive texture rendering straight into hardware buffers
it owns and handing Flutter the finished buffer as an `Image` through
`TextureRegistry.createImageTexture()`. There is no window surface, no swap
and no blit: Flutter samples the same buffer Rive drew into. The plugin keeps
four buffers per texture (an `ImageWriter` whose Images are dequeued once and
never queued), waits each frame's EGL fence on a thread of its own, and pushes
the buffer at the producer's next tick, before that frame's raster acquires
the texture. Flutter holds one pushed Image at a time and never closes one it
consumed, so the plugin infers consumption at the next push: a previous Image
still open was consumed, a closed one was dropped and its buffer is dequeued
again. A texture's first frame is pushed as soon as its fence signals (a
widget that recreates its texture every frame only ever pushes first frames),
and a frame no tick follows up, the last one when a ticker stops, is pushed
from a timer. Released buffer rings are pooled by size so texture churn reuses
them.

Apps that do not opt in, devices below API 29, GL contexts that cannot do it
(no OpenGL ES 3, no EGL fence sync, no EGLImage extensions), and
`debug.rive.gl_ahb=0` all take the Surface path that follows; the example app
opts in, and `debug.rive.gl_ahb=1` opts a device in regardless of the app.

Flutter's `ImageReader` waits for each buffer's GPU fence on the platform
thread before it can use the buffer. On native Mali and PowerVR drivers, the
fence a swap produces covers every command submitted on the swapping EGL
context, not only the surface being swapped. So swapping every Rive texture
from one shared render context makes each widget wait on every other widget's
GPU work, and stalls the app's platform thread with it.

On the Surface path each texture therefore renders offscreen on the render
context, and a present thread with its own context blits the finished frame
to the texture's window surface and swaps. The texture presents directly
from the render context instead whenever that cannot run: no present context
or pbuffer, no OpenGL ES 3 config or context, no EGL fence sync, a
multisampled window config, or GL provided by ANGLE (below).

## Running the benchmark

The example app has a renderer benchmark page that opens straight from a deep
link, which is what scripted runs use:

```sh
adb shell "am start -a android.intent.action.VIEW \
  -d 'riveexample://bench?asset=little_machine.riv&count=4&stats=1' \
  com.example.rive_example"
```

Parameters: `asset` (one of the page's feather-free and feathered files),
`count` (1-16 widgets), `shared=1` (one `RivePanel` texture instead of one per
widget), `move=1`, `dots` (0-60 animating Flutter dots), `layout=1`
(`RenderResolution.layout()`), `pages` (0-20 kept-alive pages),
`renderer=flutter`, and `stats=1`, which logs one `[rive-bench]` line a
second with the app's frame rate and Rive's replay rate.

Locally, measure from a perfetto trace rather than the app's own counters:
`queueBuffer` into each `ImageReader-*` is that texture's real update rate,
and the raster thread's `queueBuffer` is the app's frame rate. `dumpsys
meminfo <package>` reports `Graphics:` for the whole process, which includes
Flutter's buffers as well as Rive's textures, so compare two builds of the same
app rather than reading one total. `DIAGNOSTICS.md` documents the
`debug.rive.gl_fbo` and `debug.rive.gl_msaa` switches for A/B tests on one
build.

On a device farm, `packages/rive_flutter/example/tool/browserstack_bench.py`
runs the page on BrowserStack App Automate across a device list and prints a
table. Credentials come from the environment and outputs stay under the
example's ignored `build/` directory.

## What to compare against

Compare against 0.14.11, not 0.15.0-dev.2. The 0.15.0-dev releases used one
pacing budget for every texture, which starves whichever textures tick last:
with 8 widgets, 3 drew and the other 5 stayed blank. That makes dev.2 look
fast and cheap exactly where it is failing, both in frame rate and memory.
0.14.11 draws every widget. It predates the replay counters, but it draws
inside the app's frames, so its app frame rate is also its update rate.

Do not compare feathered content against the Flutter renderer: it does not draw
vector feathering, so it is rendering something different.

## Devices

Local: a Galaxy Tab A7 Lite (PowerVR GE8320, GPU bound) and a Pixel 8a
(Mali-G715). On BrowserStack, chosen for spread of GPU vendor, GL
implementation, refresh rate and tier:

| Device | Android | GPU | Why |
| --- | --- | --- | --- |
| Galaxy S20 | 10 | Mali-G77 | oldest driver available |
| Vivo Y21 | 11 | PowerVR GE8320 | low end, same GPU as the Tab A7 Lite |
| Galaxy M32 | 11 | Mali-G52 | low-end Mali |
| Pixel 6 | 12 | Mali-G78, 90 Hz | |
| Galaxy S22 | 12 | Xclipse 920 | GL through ANGLE on Vulkan 1.1 |
| Pixel 7 | 13 | Mali-G710, 90 Hz | |
| Galaxy S23 | 13 | Adreno 740 | |
| Galaxy S24 | 14 | Xclipse 940 | GL through ANGLE on Vulkan 1.3 |
| Galaxy Tab A9+ | 14 | Adreno | low-end tablet |

## Native GL and ANGLE

On Samsung's Xclipse GPUs, OpenGL ES is ANGLE translating to Vulkan rather
than a native driver. Logcat shows it at startup, for example `I/ANGLE ...
Renderer (ANGLE (Samsung Xclipse 920) on Vulkan 1.1.179)`, and the renderer
reports it as `isANGLESystemDriver`.

The offscreen present regressed badly there. On the S22, per widget:

| Scenario | 0.14.11 | Offscreen present | Direct present |
| --- | --- | --- | --- |
| 4 small | 30.3 | 24.1 | 30.0 |
| 8 small | 29.5 | 13.1 | 29.9 |
| 4 clip-heavy | 25.6 | 7.5 | 30.0 |

The direct present runs at full rate, so the context-wide fence the offscreen
path works around does not exist on ANGLE, and the offscreen path's context
switches and blits are pure cost. The S24's newer ANGLE regressed only
slightly (clip-heavy 24.4 against 25.9 direct), but never gained.

Decision: when GL is ANGLE, present directly. The log then reads `Rive GL
present: direct (ANGLE)`. Verified afterwards on the S22 (29.8, 29.9, 29.9)
and S24, with the Pixel 7 still on the offscreen path.

On these devices Vulkan is the native driver and Rive's Vulkan backend is the
long-term answer, since it removes the translation layer altogether.

## Results, 2026-09-22

Updates per second per widget, then the app's frame rate. 0.14.11 shows the app
frame rate only, which is also its update rate. The clip-heavy file was a
standalone app's `rope.riv`; the runner above uses the example app's
`vehicles.riv`, so its numbers are not directly comparable to these.

| Device | Scenario | 0.14.11 | 0.15.0-dev.2 | This change |
| --- | --- | --- | --- | --- |
| Galaxy S20 | 4 small | 53.6 | 29.9, app 60.4 | 59.7, app 59.7 |
| | 8 small | 45.6 | 14.9, app 60.1 | 55.3, app 57.9 |
| | 4 clip-heavy | 29.5 | 22.6, app 52.5 | 30.7, app 59.7 |
| Vivo Y21 | 4 small | not captured | 29.2, app 59.1 | 39.9, app 52.1 |
| | 8 small | not captured | 14.7, app 58.9 | 22.1, app 51.3 |
| | 4 clip-heavy | not captured | 5.8, app 14.7 | 5.0, app 59.2 |
| Galaxy M32 | 4 small | 31.0 | 29.6, app 60.0 | 59.2, app 58.7 |
| | 8 small | 23.9 | 14.9, app 60.3 | 50.4, app 55.7 |
| | 4 clip-heavy | 14.2 | 14.3, app 41.5 | 19.8, app 49.7 |
| Pixel 6 | 4 small | 59.9 | 30.0, app 60.1 | 59.9, app 59.4 |
| | 8 small | 59.6 | 15.0, app 60.2 | 60.0, app 60.0 |
| | 4 clip-heavy | 39.3 | 28.3, app 57.7 | 53.6, app 59.4 |
| Galaxy S22 | 4 small | 30.3 | 15.0, app 30.3 | 29.8, app 29.7 |
| | 8 small | 29.5 | 7.6, app 30.0 | 29.9, app 29.9 |
| | 4 clip-heavy | 25.6 | 14.6, app 29.8 | 29.9, app 30.2 |
| Pixel 7 | 4 small | 89.6 | 45.0, app 89.8 | 89.8, app 89.8 |
| | 8 small | 86.1 | 22.5, app 90.2 | 90.1, app 90.0 |
| | 4 clip-heavy | 42.9 | 32.0, app 64.7 | 49.8, app 90.9 |
| Galaxy S23 | 4 small | 30.1 | 15.1, app 30.0 | 30.0, app 30.3 |
| | 8 small | 29.9 | 7.6, app 30.1 | 30.0, app 30.2 |
| | 4 clip-heavy | 24.1 | 14.9, app 30.0 | 30.0, app 30.3 |
| Galaxy S24 | 4 small | 30.1 | 15.0, app 29.7 | 30.0, app 30.1 |
| | 8 small | 30.0 | 7.5, app 30.0 | 30.0, app 29.9 |
| | 4 clip-heavy | 22.5 | 14.2, app 28.9 | 25.9, app 25.8 |
| Galaxy Tab A9+ | 4 small | 51.8 | 34.5, app 72.5 | 66.0, app 66.7 |
| | 8 small | 39.0 | 17.9, app 72.0 | 52.9, app 59.4 |
| | 4 clip-heavy | 15.0 | 12.7, app 31.3 | 10.6, app 70.1 |

S22 and S24 rows for this change are from the verification run after the
ANGLE decision. One trade-off is visible on low-end Adreno: on the Tab A9+ a
clip-heavy widget updates about a third less often than on 0.14.11 (10.6
against 15.0 a second), while the app runs at 70 fps instead of 15, because
0.14.11 held the whole app to Rive's pace.

## Hardware buffer present against the Surface path, 2026-09-23

Same build, same scenario, the present chosen with `debug.rive.gl_ahb`, on the
two local devices. Per-widget updates/s, then the app's frame rate. "Present
CPU" is the threads that hand frames to Flutter, in ms of CPU per second: the
push thread for hardware buffers, the two present threads for the Surface path.

| Device | Scenario | Hardware buffers | Surface | Present CPU | Graphics |
| --- | --- | --- | --- | --- | --- |
| Pixel 8a | 1 small | 59.9, app 60 | 59.9, app 60 | 35 / 219 | 130 / 159 MB |
| | 8 small | 59.9, app 61 | 59.9, app 59 | 54 / 965 | 142 / 167 MB |
| | 16 small | 59.9, app 59 | 54-59, app 60 | 66 / 956 | 146 / 187 MB |
| | 1 feathered | 59.8, app 60 | 59.9, app 60 | 27 / 190 | 146 / 172 MB |
| | 4 feathered | 23.0, app 60 | 25.3, app 59 | 39 / 334 | 162 / 194 MB |
| | 4 feathered, panel | 36.9, app 59 | 33.3, app 59 | <20 / 122 | 202 / 235 MB |
| | 6 moving and scaling + 60 Flutter dots | app 51 | app 42 | 147 / 791 | 169 / 287 MB |
| Galaxy Tab A7 Lite | 1 small | 60.9, app 60 | 60.9, app 61 | 30 / 266 | 46 / 56 MB |
| | 4 small | 50.6, app 61 | 41.8, app 60 | - | - |
| | 8 small | 27.8-30.1, app 58-35 | 23.1, app 58 | 51 / 693 | 46 / 54 MB |
| | 8 small, panel | 52.3, app 57 | 46.9, app 58 | 43 / 224 | 53 / 69 MB |
| | 1 feathered | 24.8, app 61 | 24.1, app 60 | 41 / 125 | 58 / 66 MB |
| | 4 feathered | 9.9, app 55 | 10.0, app 57 | 49 / 177 | 55 / 59 MB |
| | 6 moving and scaling + 60 Flutter dots | app 14 | app 10 | - | 75 / 74 MB |

The Tab's 8-small row sits on an edge: the Surface path's present threads
held Rive at 23 updates/s there, which was also about 3 records per frame on
the main thread. Without that bottleneck the pacing gate admits 28-30/s, and
at ~1.3 ms per record on the A53 cores a run that lands at 30/s spends ~7
records a frame and drops the app to 35 fps, while a run at 28/s keeps 58.
Every other row keeps the app's frame rate and matches or raises the content
rate. The feathered rows on the Pixel are within the run-to-run spread (a
repeat gave 26.2 against 25.1).

## Hardware buffer present on BrowserStack, 2026-09-25

`browserstack_bench.py` with two example APKs: merged master (Surface path) and this branch with the example opted in. Updates per second per widget, then the app's frame rate. Every device took the hardware buffer path in the opted-in build, including the Galaxy S20 on Android 10 (API 29, the floor) and the two ANGLE devices; the usage the allocator granted was 0x330 with the pre-33 constructors and 0x300 from the Builder on 33+. The last column is Flutter's "Dropping PlatformView Frame" count as a share of pushes, excluding each scenario's first 3 seconds (startup pushes race the first rasters on every device, 0 to 29 drops there).

| Device | Scenario | Surface | Hardware buffers | Dropped |
| --- | --- | --- | --- | --- |
| Galaxy S20 | 4 small | 60.1, app 60.3 | 60.0, app 60.2 | 0.2% |
| | 8 small | 54.8, app 58.5 | 59.9, app 60.3 | 0.5% |
| | 4 complex | 60.1, app 59.8 | 59.9, app 60.2 | 0.2% |
| Vivo Y21 | 4 small | 40.5, app 55.7 | 41.8, app 57.3 | 0.5% |
| | 8 small | 22.5, app 54.1 | 23.3, app 57.4 | 0.5% |
| | 4 complex | 47.5, app 53.8 | 50.2, app 58.6 | 0.5% |
| Galaxy M32 | 4 small | 59.6, app 59.6 | 59.8, app 59.8 | 0.2% |
| | 8 small | 49.4, app 54.6 | 55.1, app 58.1 | 2.4% |
| | 4 complex | 60.3, app 59.9 | 60.3, app 60.4 | 0.3% |
| Pixel 6 | 4 small | 89.8, app 89.9 | 90.1, app 89.8 | 0.1% |
| | 8 small | 89.8, app 89.5 | 90.1, app 89.6 | 0.0% |
| | 4 complex | 89.8, app 89.7 | 90.0, app 89.8 | 0.0% |
| Galaxy S22 | 4 small | 29.9, app 29.6 | 29.9, app 30.1 | 0.0% |
| | 8 small | 29.7, app 29.7 | 29.9, app 29.9 | 0.2% |
| | 4 complex | 29.9, app 29.9 | 30.0, app 30.0 | 0.0% |
| Pixel 7 | 4 small | 89.8, app 90.7 | 89.6, app 89.4 | 0.0% |
| | 8 small | 90.2, app 91.0 | 89.9, app 89.4 | 0.0% |
| | 4 complex | 90.2, app 90.0 | 89.9, app 89.5 | 0.0% |
| Galaxy S23 | 4 small | 30.0, app 30.0 | 30.0, app 30.2 | 0.0% |
| | 8 small | 30.0, app 30.1 | 29.9, app 29.9 | 0.0% |
| | 4 complex | 30.0, app 29.8 | 29.9, app 29.9 | 0.0% |
| Galaxy S24 | 4 small | 30.0, app 30.0 | 30.0, app 30.2 | 0.1% |
| | 8 small | 30.0, app 29.9 | 30.0, app 30.2 | 0.0% |
| | 4 complex | 30.0, app 30.1 | 29.9, app 30.1 | 0.2% |
| Galaxy Tab A9+ | 4 small | 68.2, app 67.9 | 66.1, app 65.9 | 1.4% |
| | 8 small | 55.5, app 60.3 | 57.8, app 61.0 | 1.7% |
| | 4 complex | 70.3, app 70.2 | 67.4, app 67.0 | 2.0% |

The Flutter-renderer control scenario was within 1/s on every device. Where the Surface path's present threads had been the limit (8 small on the S20, M32 and Tab A9+), the hardware buffer path raises the rate by 2 to 11 updates a second across the two runs; everywhere else the two are within the run-to-run spread (the Surface column matches the 2026-09-22 run above within 1 to 3/s). A second run of the Tab A9+ and M32 put the spread at 1 to 4/s on the Tab A9+ (4 small 68.7 against 69.8, 4 complex 71.3 against 71.2, and its Flutter-renderer control moved from 64.3 to 72.8 between the two runs) and repeated the 8-small gain on both: Tab A9+ 53.2 to 64.3, M32 47.3 to 54.4. Drop rates repeated too (M32 8 small 2.3%, Tab A9+ 1.6 to 2.5%).

A dropped frame is one Flutter replaced with the next push before its raster acquired it: the newer frame is shown, the older one's render is wasted and its slot dequeues a fresh buffer. It happens when the UI thread runs two ticks between raster acquires, so it clusters on the devices whose raster thread runs behind the UI thread (the Tab A9+ and the M32 at 8 widgets), and never on the two local devices.

## After the rebase onto #14530, 2026-10-02

#14530 made the last render texture out release the render context's drawing memory and let a texture marked destroyed mid-frame flush; this branch now also counts image-mode textures toward that last-out release and empties the Kotlin ring pool with it. Re-measured, same build, present chosen with the switch:

| Device | Scenario | Hardware buffers | Surface | Present CPU (ms/s) | Graphics |
| --- | --- | --- | --- | --- | --- |
| Pixel 8a | 8 small | 59.7/s, app 59.9 | 59.8/s, app 59.5 | 52 / 968 | 142 / 172 MB |
| Pixel 8a | 6 moving and scaling + 60 dots | app 48 to 60 | app 38 to 54 | 55 / 802 | 153 to 192 / 210 to 340 MB |

Both rows are unchanged from the 2026-09-23 table within run-to-run spread, so #14530 changes nothing visible in these scenes. The churn row is three 90 s runs per present sampled every 10 s plus one traced run (53.1 against 41.4 fps, 168 against 239 MB, push thread 55 ms/s against present threads 802). A first pass at this row measured six static widgets: the bench reads every intent extra as a string, so `--ez move 1` arrives as "true" and parses as off, and the static scene runs at 60 fps on both presents. The churn scene is `--ei move 1 --ei dots 60`. Behind the keyguard the app reports 0 fps at about 24 MB, so a locked device reads as a failure, not a slow run.

The Tab A7 Lite's two reported rows were re-measured on the same build: 8 small 29.1/s at app 43 fps against 23.3/s at 56.8 (the documented edge), 8 small panel 52.0/s at 58.6 fps against 46.7/s at 55.4, graphics 46 and 54 MB against 54 and 70 MB.

Last texture out, 20 cycles of opening the example's one-widget "Rive Widget" page for 3 s and leaving it for 3 s (the texture is removed a second after the pop, with no texture left): same process, no error lines, and every open allocated fresh rings, which shows the pool was emptied each time. Graphics memory while open against after the release: Tab A7 Lite 76 against 71 MB, Pixel 8a 183 against 129 MB, both flat across the 20 cycles. The example's memory cleanup page (a texture created and destroyed 9 times a second) on the Tab for 2 min: 117 to 132 MB, no errors.

## Stress, 2026-09-22

Leaks show as growth, not as a level, so these are worth rerunning after any
change to texture lifetime. On the Tab A7 Lite and Pixel 8a:

| | 4 min churning widget count, mode and route | 45 s idle after | 3 min of a texture created and destroyed ~9 times a second |
| --- | --- | --- | --- |
| Galaxy Tab A7 Lite | 80 MB | 81 MB | 186-191 MB, flat |
| Pixel 8a | 200 MB | 198 MB | 434-491 MB, oscillating, no trend |

Hardware buffer present, 2026-09-23, 8 small widgets, 60 background and
foreground cycles with 1, 3 and 8 second pauses in rotation: no crash, same
process throughout, rendering resumed every cycle, graphics 46-47 MB flat on
the Tab A7 Lite and 154 MB rising to 162 MB by cycle 20 then flat on the
Pixel 8a; a foreground-only control of the same length held 144 MB flat, so
the extra ~18 MB is what backgrounding retains, not growth. Rotation to
landscape and back with 4 widgets: same process, no errors, textures
recreated at the new size.

The same page for 3 minutes on the hardware buffer path (2026-09-23): Pixel
8a 275-307 MB oscillating with no trend, Galaxy Tab A7 Lite 129 MB flat, no errors
on either.

Real-world soak on the hardware buffer path, 2026-09-24 (opt-in build). Every run kept the same process and logged no GL, Flutter or native error lines:

| | Galaxy Tab A7 Lite | Pixel 8a |
| --- | --- | --- |
| Bench app, 4 min churning widget count, mode and route | 74-126 MB, settled at 74 MB | 152-179 MB, no trend |
| Bench app, 8 small widgets for 12-15 min, memory-trim signal every 2 min, screen off and on every 3 min | 45-49 MB in the foreground; each screen cycle left the app behind the keyguard at 40-42 MB and it rendered again at 58-65 fps when the keyguard cleared | 142-145 MB flat at 54-63 fps; trim signals had no effect (screen cycles skipped, the device is fingerprint locked) |
| Example app, 50 rounds opening and closing the Rive Widget, Rive Widget Builder, Rive Panel and Data Binding pages | 102 MB rising to 104.5 MB by round 20, then flat | 188 MB rising to 192.6 MB by round 40, then flat |
| Example app Data Binding page, 60 rounds of setting the energy, bar color and lives bindings from the sheet and firing the Continue trigger | 75 MB flat, every change visible in the widget | 256-259 MB flat after 15 min in the same process, every change visible in the widget |

The memory-trim signal is `am send-trim-memory RUNNING_CRITICAL`; neither device changed graphics memory or frame rate on it.

The last column is the example app's "Memory cleanup test" page. The churn
columns came from a standalone harness that changes the widget count, mode
and route every 400 ms; the example app has no equivalent yet. After heavy
churn, Mali frees deleted textures lazily, so GL memory can sit high for up
to a minute before settling.

## Known gaps

- BrowserStack's Galaxy S22, S23 and S24 ran at 30 Hz, so there is no 120 Hz
  data. Rows capped at 30 show only that nothing regressed.
- The oldest Android on BrowserStack is 10, and every device tested took the OpenGL ES 3 path, so the ES 2 fallback has not run on a real device. The hardware buffer path has run on Android 10 through 14 there and on 13 and 16 locally; no device below API 29 has been tested, so its SDK gate has only been exercised through `debug.rive.gl_ahb=0` on newer devices.
- BrowserStack has no adb shell: no `dumpsys meminfo`, and no way to set the
  `debug.rive.*` switches. The direct-present comparison above used a build
  with the offscreen path turned off by default.
- 0.14.11 has no replay counters; its update rate is read from the app's
  frame rate.
