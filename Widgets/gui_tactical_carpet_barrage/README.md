# Tactical Carpet Barrage (Time-on-Target / TOT)

An AAA-grade tactical combat widget for **Beyond All Reason (BAR)** that coordinates multiple artillery units to fire synchronized saturation strikes using real-world **Time-on-Target (TOT)** military doctrine and optimal hexagonal non-overlapping spatial packing.

---

## What is Time-on-Target (TOT)?
In standard gameplay, ordering multiple artillery pieces to attack an area causes each gun to fire immediately. Because the guns are located at different distances and have different ballistic arcs, their shells land scattered over several seconds, allowing enemy commanders, mobile armies, or shields to react and retreat.

**Time-on-Target (TOT)** solves this:
- The system calculates the exact 3D flight time ($t_f$) and turret slew alignment delay ($t_{\text{aim}}$) for every gun.
- The gun furthest away or with the highest trajectory fires first.
- Closer guns are delayed by calculated frame offsets.
- **Every shell impacts the ground at the exact same physical frame**, achieving 100% synchronized annihilation with 0ms warning.

---

## Core Features & Mathematical Precision

1. **Hexagonal Circle Packing (Zero Overkill Waste)**:
   - Uses an optimal hexagonal lattice based on the weapon's `damageAreaOfEffect` ($R_{\text{aoe}}$) to guarantee complete area coverage without redundant damage overlap.
2. **3D Parabolic Trajectory Solver**:
   - Resolves the exact Newtonian projectile equations under Spring gravity (`Game.gravity`):
     $$\vec{r}(t) = \vec{r}_0 + \vec{v}_0 t + \frac{1}{2} \vec{g} t^2$$
   - Supports both low-arc direct fire and high-trajectory lobbing depending on unit weapon capability.
3. **Terrain Collision Raycasting**:
   - Discretely samples 16 points along the 3D parabolic trajectory against the game heightmap (`Spring.GetGroundHeight`).
   - Warns and prevents shells from impacting intermediate hills, cliffs, or obstacles.
4. **Greedy Bipartite Turret Matching**:
   - Matches each artillery piece to its optimal impact point to minimize turret traverse angles and prevent crossed lines of fire.
5. **Glassmorphic 3D Holographic Display**:
   - High-contrast glowing hex grid on terrain with pulsing danger rings.
   - 3D parabolic guide curves with traveling photon tracer beads.
   - Dynamic 3D in-world HUD floating over target centroid with live TOT countdown in milliseconds.

---

## Controls & Usage

| Action | Control |
| :--- | :--- |
| **Activate Targeting Mode** | Select 1 or more artillery units and press **`B`** |
| **Set Saturation Zone** | **Left-Click and Drag** on the battlefield or minimap |
| **Adjust Blast Spacing** | **Mouse Wheel Up / Down** while dragging to tighten or widen hex density |
| **Instant Power-User Barrage** | Hold **`Alt + Right-Click Drag`** with artillery selected |
| **Cancel Targeting** | **Right-Click** or press **`Escape`** |
| **Execute Strike** | Release **Left Mouse Button** |

---

## Installation
Place the `gui_tactical_carpet_barrage` folder into:
`Beyond-All-Reason/data/LuaUI/Widgets/gui_tactical_carpet_barrage/`
