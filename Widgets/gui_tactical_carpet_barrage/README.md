# Carpet Barrage 2.0 (Tactical Carpet Barrage & TOT)

**Developer:** reforged25-source / Codex  
**Version:** 2.0  

A military-grade tactical bombardment widget for **Beyond All Reason (BAR)**. It transforms the standard `Attack`, `Set Target`, and `Launch` commands into a synchronized, non-overlapping carpet barrage system.

---

## 🎯 What It Does

When selecting multiple artillery units, rocket trucks, plasma cannons, or missile silos:
1. **Zero Overkill (Non-Overlapping Spacing)**:
   - Automatically spaces out impact points based on the weapon's exact **Area of Effect (AoE)** so blast radii touch seamlessly without overlapping or leaving dead zones.
2. **Time-on-Target (TOT) Synchronization**:
   - Calculates the exact ballistic flight time, trajectory arc, and turret slew time for every unit.
   - Closer units automatically hold fire until the distant units' shells are mid-air, ensuring **all explosions detonate at the exact same game frame**.
3. **Zero-Crisscross Assignment**:
   - Matches units to target coordinates along the barrage vector to guarantee guns fire strictly parallel, eliminating barrel crisscrossing and minimizing aiming delays.
4. **Holographic 3D Tactical Overlay**:
   - Renders high-tech holographic reticles on the terrain matching weapon blast radii with projected 3D ballistic laser arcs and TOT countdown timers.

---

## 🕹️ Controls (Works Directly on Existing Buttons)

No new hotkeys or cluttered UI buttons are needed:

- **Single Click** on `Attack`, `Set Target`, or `Launch`:
  - Normal in-game behavior (single target focus).
- **Click & Drag Line**:
  - Distributes units in a linear creeping barrage along the dragged line.
- **Click & Drag with `Ctrl` held**:
  - Distributes units in a **Hexagonal Close Packing (HCP)** cluster across the dragged area.
- **`Alt` + Right-Click Drag**:
  - Quick-drag barrage without selecting a command button first.

---

## 📐 Ballistics & Mathematical Architecture

- **Hexagonal Close Packing**: Optimal density covering 90.69% of the circular blast zone.
- **Parabolic Trajectory Solver**: Integrates Spring Engine gravitational constants ($g$) and weapon muzzle velocity ($v_0$) to calculate flight times down to sub-tick accuracy ($1/30\text{s}$).
- **Elevation Adjustment**: Uses `Spring.GetGroundHeight` and surface normal vectors to conform blast ellipses to sloping terrain and cliffs.

---

## 💻 Installation

Place the `gui_tactical_carpet_barrage` folder into your Beyond All Reason data directory:
`Beyond-All-Reason/data/LuaUI/Widgets/gui_tactical_carpet_barrage/`
