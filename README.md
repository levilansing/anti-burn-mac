# AntiBurn OLED Guard (`anti-burn-mac`)

A lightweight, native macOS menu bar utility written in Swift & AppKit designed to prevent uneven subpixel degradation (burn-in) on external OLED monitors.

## Features

### 1. Native SkyLight & Overlay Menu Bar Dimming
* **Native SkyLight Menu Bar Alpha (`SLSSetMenuBarInsetAndAlpha`):** Directly fades the native macOS menu bar window against your desktop wallpaper without placing a dark box over the menu bar strip.
* **Classic Translucent Dimming:** Optional translucent overlay strip with independent brightness settings and alignment guides for the right-side **Clock** region.
* **Intelligent Mouse Vector & Proximity Intent:**
  * Tracks cursor position and 2D velocity vector at 60Hz with a critically-damped exponential filter (zero overshoot).
  * When your mouse enters the configurable proximity zone (default `100px`) moving *toward* the menu bar, it smoothly pre-fades the menu bar toward **50% visibility**.
  * Hovering directly over the menu bar restores **100% visibility**.
  * Moving away from the menu bar or keeping the cursor stationary inside the proximity zone automatically fades the menu bar back down.

### 2. HDR-Aware Full-Screen Idle Dimming
* Automatically detects whether your target external display is in **HDR / EDR** mode and supports hardware-linked brightness scaling via `DisplayServices.framework`.
* When idle for a configurable duration (default **3 minutes**), smoothly scales down native HDR brightness (or applies a full-screen overlay fallback in SDR mode) and restores your exact baseline brightness immediately on user input.
* **Smart Call & Media Detection:** Automatically pauses idle dimming when:
  * A **Microphone or Camera** is active via `CoreAudio` / `CoreMediaIO` (e.g., Microsoft Teams, Zoom, Webex, FaceTime, Discord calls).
  * Any application holds an `IOPMAssertion` preventing display sleep (`PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion`), covering windowed and full-screen video playback in Safari, Chrome, VLC, IINA, QuickTime, etc.
  * Optional toggle to pause during any active audio output.

### 3. Active Window Focus Backdrop Dimming
* Places a soft dimming backdrop immediately behind your currently focused window (or all windows of the active application) so static background windows and desktop wallpaper wear slower while you work.
* Smooth **150ms** transition animations with hover pre-warming and zero background flicker when switching or quitting apps.
* Optional **"Also Cover Menu Bar With Focus Dim"** toggle so the wallpaper behind the menu bar matches the dimmed desktop below while still un-dimming to 100% when your mouse approaches the menu bar.

---

## Requirements
* macOS 14.0 (Sonoma) or later
* Xcode Command Line Tools (`swiftc`)

## Building & Running

Build the standalone `.app` bundle using the included script:

```zsh
./build_app.sh
```

Then launch the app:

```zsh
open build/AntiBurn.app
```

 Look for the TV sparkles icon (`sparkles.tv`) in the macOS menu bar. Left-click to open the control panel, or right-click for quick actions.

## License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)** — see the [LICENSE](LICENSE) file for details.
