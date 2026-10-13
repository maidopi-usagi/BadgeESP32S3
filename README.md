<div align="center">
୨♡୧ ┈┈┈ † ┈┈┈ ♡ ┈┈┈ † ┈┈┈ ୨♡୧
</div>

# BadgeESP32S3
Interactive toy demos for the **Waveshare ESP32-S3-Touch-AMOLED-1.75** , with a simple pixel UI.🥺

Template from https://github.com/kassane/zig-esp-idf-sample

### Demos

| ♡ Fumo | ⋈ DICE |
| :---: | :---: |
| <img src="assets/screenshots/fumo.png" alt="Fumo demo" width="233" height="233" /><br />Textured 3D model, touch rotation, bounce and tilt parallax. | <img src="assets/screenshots/dice.png" alt="DICE demo" width="233" height="233" /><br />Physical 3D dice with touch and IMU input. |
| **† Cornell** | **♥ Doom** |
| <img src="assets/screenshots/cornell.png" alt="Cornell path tracer" width="233" height="233" /><br />Progressive software path tracing. | <img src="assets/screenshots/doom.png" alt="Doom demo" width="233" height="233" /><br />Touch controls and a 320 × 200 software renderer. |
| **♡ Sandbox** | **⋈ Orbit Beat** |
| <img src="assets/screenshots/sandbox.png" alt="Gravity sandbox" width="233" height="233" /><br />Gravity-driven sand and water. | <img src="assets/screenshots/rhythm.png" alt="Orbit Beat rhythm game" width="233" height="233" /><br />Multi-touch rhythm game. |
| **† RT Fluid** | **♥ Rigid Toys** |
| <img src="assets/screenshots/fluid.png" alt="RT Fluid demo" width="233" height="233" /><br />Real-time fluid simulation. | <img src="assets/screenshots/physics.png" alt="Rigid Toys demo" width="233" height="233" /><br />2D rigid bodies, multi-touch grabbing and throwing. |

Edge swipe switches demos and PWR toggles standby.

### Build

Pinned: **Zig 0.17.0-xtensa · ESP-IDF 5.5.2 · LVGL 9.4.0**.
Install Git, Python 3.12 and CMake, then:

```sh
./scripts/bootstrap-idf.sh
./scripts/idf.sh build
./scripts/idf.sh -p YOUR_SERIAL_PORT flash monitor
```

```sh
./scripts/zig.sh build test -Doptimize=ReleaseSafe
./scripts/zig.sh build preview -Dpreview-demo=dice -Dpreview-roll-ms=5000 > .local/dice.ppm
```

---

[NOTICE](NOTICE) lists sources and licenses. Doom is GPL-2.0-or-later;
game data has separate terms. 

<div align="center">

୨♡୧ ┈┈┈ † ┈┈┈ ♥ ┈┈┈ † ┈┈┈ ୨♡୧

</div>
