# Beyond All Reason - LuaUI

Custom LuaUI configuration and widgets collection for [Beyond All Reason (BAR)](https://www.beyondallreason.info/).

## Directory Structure

- **Config/**: Configuration files and runtime state (`BYAR.lua`, `BAR_damageStats.lua`, `blueprints.json`).
- **Widgets/**: Custom and community UI widgets:
  - `gui_tactical_carpet_barrage`: Tactical Carpet Barrage & Time-On-Target (TOT) synchronized non-overlapping bombardment.
  - `gui_custom_build_menu`: Glassmorphic Build Menu with real-time 3D model previews, categorized tabs, and unit cost/stat displays.
  - `gui_build_watch`: Build Watch & ETA display.
  - `gui_construction_grid`: Construction placement grid.
  - `gui_default_high_priority`: High priority construction presets.
  - `gui_energy_conversion_meter`: Energy conversion balance meter.
  - `gui_military_formation_move`: Military formation move control.
  - `gui_top_bar_extra`: Extended top bar info.
  - `gui_unit_hp_bars`: Unit health and status bars.
  - `manifests.json`: Widget registry manifest.
- **Fonts/**: Custom fonts for UI rendering.

## Installation

Clone or copy the repository contents directly into your Beyond All Reason data directory:
`Beyond-All-Reason/data/LuaUI/`