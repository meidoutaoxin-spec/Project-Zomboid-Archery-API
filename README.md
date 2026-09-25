![Uploading ProjectZomboid64_tfrOb9sfAE.gif…]()
# Bow and Arrow System — for Project Zomboid (Build 42)

A standalone archery mod for **Project Zomboid Build 42**: craftable bows and arrows, a
Minecraft-style hold-to-draw bow, real ballistic arrows with a 3D flight body, and arrows
that physically stick in the zombies they hit.

- **Mod ID:** `bowandarrowsystem`
- **Game version:** Build 42 (`42/` version folder)
- **Status:** work in progress / actively iterated
<img width="486" height="502" alt="3" src="https://github.com/user-attachments/assets/4effeec0-422c-40d4-9cf0-f5d1773a3c1f" />
<img width="730" height="548" alt="2" src="https://github.com/user-attachments/assets/cc2b1c22-ed8d-41c5-a83f-9acf6c3d3c03" />
<img width="368" height="363" alt="1" src="https://github.com/user-attachments/assets/86595006-9945-4b28-82ac-510daec22283" />
<img width="715" height="461" alt="4" src="https://github.com/user-attachments/assets/dfe2b94d-3543-400d-8e73-eb18567ea667" />

---

## Table of contents

1. [License](#license)
2. [What this is](#what-this-is)
3. [Features](#features)
4. [Installation](#installation)
5. [How to play](#how-to-play)
6. [Configuration](#configuration)
7. [Dependencies](#dependencies)
8. [Repository layout](#repository-layout)
9. [Building the Java part](#building-the-java-part)
10. [Development tooling](#development-tooling)
11. [Acknowledgements and references](#acknowledgements-and-references)
12. [Provenance and licensing caveats](#provenance-and-licensing-caveats-read-this)
13. [Credits](#credits)

---

## License

This project is licensed under the **GNU General Public License v3.0**
(SPDX: `GPL-3.0-or-later`).

> This program is free software: you can redistribute it and/or modify it under the terms of
> the GNU General Public License as published by the Free Software Foundation, either version 3
> of the License, or (at your option) any later version.
>
> This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
> without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
> See the GNU General Public License for more details.
>
> You should have received a copy of the GNU General Public License along with this program.
> If not, see <https://www.gnu.org/licenses/>.

**The licence text is included.** `LICENSE` in this package is an unmodified copy of the official
GPL-3.0 text as published at <https://www.gnu.org/licenses/gpl-3.0.txt> (674 lines, 35,149 bytes,
LF endings, pure ASCII). Keep it alongside the work when redistributing.

Third-party components keep their own licenses and are **not** covered by the above — see
[Dependencies](#dependencies) and [Provenance and licensing caveats](#provenance-and-licensing-caveats-read-this).

---

## What this is

The vanilla firearm engine is not used. This mod is a self-contained "bow engine":

- **Lua** owns the whole per-frame game logic — input, the draw/charge state machine, the
  ballistics solve, hit detection, damage, arrow recovery and the model swap.
- **Java** is used only for the two things Lua cannot do: creating a **self-drawn 3D world
  entity** for the arrow in flight, and reading a couple of engine-internal values. It is
  loaded through **ZombieBuddy**'s `@Exposer` bridge and contains **no bytecode patches at
  all** (`@Patch`-free), so a game update cannot break it at patch-apply time.
- The bow is a *vanilla-shaped* weapon item (`IsAimedFirearm`, `SubCategory = Firearm`, a fake
  9 mm ammo type) so that the engine's aim/anim plumbing recognises it, but every shot,
  hit and reaction is computed here — the vanilla hitscan path is explicitly disabled for the
  bow.

---

## Features

**Crafting and items**

- One craftable bow: `BAS.BAS_Bow` — 2 × Plank, 1 × Glue, 2 × Twine, 4 × Nails.
- Wooden arrow shafts (Plank + Saw → 6 shafts) and arrows (shaft + Sharped Stone → 1 arrow).
- Ammo is consumed only when an arrow is actually loosed; a let-down costs nothing.

**Minecraft-style draw**

- Hold the aim button to draw, release (or click) to loose.
- Draw curve `charge(t) = 100 · (t² + 2t) / 3` over 1.0 s — fast at the start, heavy at the end.
- A 0.3 s raise wind-up runs before the draw starts, timed to the raise animation.
- Charge scales launch speed linearly and damage `0.5× … 2.0×`.
- A crit on a full draw is a knocked-down zombie, not extra damage (the damage ceiling is
  a designed one).

**3D bow in hand**

- Two model families, chosen by the animation state:
  - *not drawing* → `BAS_BowIdle` (the bow body),
  - *drawing* → `BAS_BowFrame01…08`, one static pre-shaped mesh per draw position, stepped
    by the charge value. (`miaozhun` = the draw itself; `man` = held at full draw → frame 8.)
- The swap is a single string written into the item's `WeaponSprite` plus
  `player:resetEquippedHandsModels()` — pure Lua, no Java on the per-frame path.

**Character animation**

- Custom animation set: idle, raise, lower, draw, empty-string hold and full-draw hold
  (`ZoB_Gzhanli`, `ZoB_GMiaozhuguodu(S)`, `ZoB_GMiaozhun`, `ZoB_GMiaozhunkong`,
  `ZoB_GMiaozhunman`).
- AnimSet nodes gated on custom variables (`Weapon = BASBOW`, `BASDraw = kong|miaozhun|man`),
  with the draw pose scrubbed by the charge through `m_TrackTimeToVariable`.

**Ballistics**

- Gravity + drag-free integration, launch height, cursor-distance solve (low-angle solution)
  so the arrow lands where you point, clamped by physical reach and a 26-tile rule.
- Trajectory preview arc drawn by the client, colour-coded at the end point:
  **red** = will hit an entity, **green** = will hit a block, **orange** = a fence stops it,
  **white** = ground landing. A charge-scaled range ring shows the outer bound.
- Arrows respect fences: the arc has to clear the fence top, a flat shot is stopped (vanilla
  bullets ignore fences entirely).

**3D arrow in flight**

- The flying arrow is a **self-drawn `IsoMovingObject`** (Java, `BowArrow3D`) with a floating
  point position and per-frame yaw/pitch, so it follows the arc smoothly instead of snapping
  between grid squares.

**Hits, damage and recovery**

- Cylinder hit volume with height zones (head / chest / belly / legs).
- Damage: `0.25 – 0.40` of a zombie's health on a full draw, scaled by the draw at
  `0.5× … 2.0×`, plus knockback and a flinch/blood reaction.
- **Arrows stick in zombies** using the game's own attached-item system (slot picked by hit
  height) and are carried with the corpse on death through the vanilla handover, instead of
  vanishing.
- Arrows that miss land in the world and are picked up by simply walking over them.

**UI and multiplayer**

- Charge bar, reload progress and the trajectory preview.
- Arrow consumption and recovery are handled server-side; attached items are replicated with
  `sendAttachedItem`.

---

## Installation

### Players (Steam Workshop)

1. Subscribe to **Bow and Arrow System** on the Steam Workshop.
2. Subscribe to **[ZombieBuddy]** (workshop ID `3619862853`) — the Java half will not load
   without it. `mod.info` declares `require=\ZombieBuddy` and `ZBVersionMin=1.6.0`.
3. Enable both mods in the in-game mod list and restart.

### Manual / development install

Copy the mod folder so the game sees it:

```
<ProjectZomboid>/Zomboid/mods/bowandarrowsystem/
    mod.info
    42/
        media/...
        src/...
        _classes_bowrig/...   <- build output, not required at runtime
```

…or keep it inside a Workshop item folder (`<Workshop>/<item>/Contents/mods/bowandarrowsystem/`).
The **distributed** content is the `42/` folder only. Alongside it this source package carries the
Workshop item metadata shown below; the author's own working material (Blender sources, per-file
backups, reverse-engineering notes) is deliberately **not** part of it:

| Path | What it is |
|---|---|
| `README.md`, `LICENSE` | this document and the verbatim GPL-3.0 text |
| `workshop.txt`, `preview.png`, `mod.info` | Steam Workshop item metadata |
| Blender sources, frame sequences | art working files, kept in the author's workspace |
| timestamped per-file backups | history of every edited file, kept in the author's workspace |
| string-deformation notes | notes on the earlier approaches to the deforming string, kept in the author's workspace |

---

## How to play

| Action | Input |
|---|---|
| Aim / start drawing | hold **right mouse button** |
| Loose an arrow | **release right mouse**, or press **left mouse** mid-draw |
| Cancel a weak draw | release before the minimum draw — no arrow is spent |
| Reload | automatic. There is **no reload key** for this bow; an arrow is nocked automatically (`NOCK_TIME`) while the bow is held. `R` is unused. |

Crafting: Plank + Saw → arrow shafts; shaft + Sharped Stone → arrows; the bow recipe is above.
Keep arrows anywhere in your inventory (containers are searched recursively).

---

## Configuration

All tuning lives in Lua, at the top of the file that owns the behaviour:

| Setting | File | Effect |
|---|---|---|
| `CHARGE_MAX`, `CHARGE_TIME`, `chargeCurve` | `media/lua/client/.../BAS_Client.lua` | draw length and shape |
| `WINDUP_TIME` | `BAS_Client.lua` | raise-transition delay before charging |
| `NOCK_TIME`, `getReloadTime` | `BAS_Client.lua` | delay before the next arrow is nocked |
| `CHARGE_DMG_MIN`, `stats[...] = { dmgMin, dmgMax }` | `BAS_Projectile.lua` | damage curve; full draw doubles these |
| `CHARGE_SPEED_MIN`, `gravity`, `speed` | `BAS_Projectile.lua` | ballistics |
| `HIT_RADIUS`, `HIT_Z_LOW/HIGH`, `FENCE_HEIGHT` | `BAS_Projectile.lua` | hit volume and fence rule |
| `RANGE_MIN/MAX`, `LAUNCH_HEIGHT`, `LAUNCH_AHEAD` | `BAS_Projectile.lua` | reach rules |
| `ATTACH_SLOTS` | `BAS_Projectile.lua` | which body slot an arrow lodges in |
| `BOW_STATE_FRAMES`, `BOW_IDLE_MODEL` | `BAS_Client.lua` | which animation state wears which bow model |
| attachment offsets/rotations | `media/scripts/bowandarrowsystem/models_arrow.txt` | how a lodged arrow sits (tune in-game with *Debug → Dev → Attachment*) |

---

## Dependencies

**Runtime**

| Dependency | Why | Notes |
|---|---|---|
| **Project Zomboid, Build 42** | the game | B41 is not supported (`42/` folder, B42 anims/scripts) |
| **[ZombieBuddy]** (`3619862853`, ≥ 1.6.0) | loads the Java half and provides the `Exposer` Lua bridge | hard requirement — declared in `mod.info`; ships under its own license and is **not** bundled here |

**Build-time (Java half only)**

| Dependency | Why |
|---|---|
| JDK 17+ (built with **JDK 26**) | `javac --release 17` against the game's own jar; a JDK older than the game's class-file version cannot read it |
| `projectzomboid.jar` from the local install | compile-time classpath (`zombie.*` classes) |
| ZombieBuddy's `ZombieBuddy.jar` | compile-time classpath only (`@Exposer` annotations) |

Nothing else is bundled: no third-party Java library, no Maven/Gradle — the jar is a handful
of classes packed with a small Python helper.

---

## Repository layout

```
bowandarrowsystem/42/
├── media/
│   ├── AnimSets/player/            # anim state machine nodes (aim / idle / firearm)
│   ├── anims_X/Bob/                # the mod's own character animations (.glb)
│   ├── java/BowAPI.jar             # compiled Java half (media/java + javaPkgName in mod.info)
│   ├── lua/client/…/BAS_Client.lua      # input, draw/charge, camera-facing UI, model swap
│   ├── lua/client/…/BAS_Projectile.lua  # ballistics, hit detection, damage, lodging
│   ├── lua/shared/…/BAS_Bow.lua         # item recognition, arrow consume, corpse handover
│   ├── models_x/weapons/2handed/   # bow body + 8 draw frames (.fbx)
│   ├── scripts/bowandarrowsystem/  # items, model scripts, recipes
│   └── textures/weapons/           # bow and arrow textures
├── src/com/zoaz/bow/               # Java sources: BowAPI, BowArrow3D, Main
└── _classes_bowrig/                # javac output directory
```

---

## Building the Java part

```bash
javac -encoding UTF-8 --release 17 \
      -cp "/path/to/ZombieBuddy.jar;/path/to/projectzomboid.jar" \
      -d _classes_bowrig \
      src/com/zoaz/bow/BowAPI.java src/com/zoaz/bow/BowArrow3D.java src/com/zoaz/bow/Main.java
```

Then pack `_classes_bowrig` into `media/java/BowAPI.jar` (any zip tool works; the shipped jar
uses no manifest features). **The game must be closed** while the jar is replaced — Windows
holds an exclusive lock on a jar that is loaded as a mod.

Packaging notes:

- `_classes_bowrig/` is `javac` output and is **not** part of this source package; build it from `src/`.
- `media/ui/Reticle_transparent_backup/` is a set of stock reticle PNGs kept as reference; nothing
  references it. One of them is called `unknown_unused.png` here — literally "no idea what this was
  for", which is what the author had written on it.

---

## Development tooling

The project is accompanied by a set of Python checkers/simulators, kept in a `Tool/` folder outside
the mod itself. They are the reason most of the claims in this README can be verified rather than
assumed. They are **not** part of this package; they are listed here under descriptive English
names — in the author's workspace the files themselves carry short local names, and those are the
names quoted in a few source comments.

| Tool | What it proves |
|---|---|
| `bow_model_selection_sim.py` | runs the *actual* model-selection code from `BAS_Client.lua` in a Lua interpreter over an 11-step input timeline and asserts which model is in hand at each step |
| `bow_frame_wiring_check.py` / `frame_index_mapping_check.py` | the whole frame chain: source `.fbx` → installed `.fbx` → model script → item script → Lua, including identical node scaling across the frame family |
| `model_scale_audit.py` | flags a model family that was exported at mismatched scales (the classic "the bow suddenly changes size" bug) |
| `extract_cjk_lines.py` / `english_patch.py` | locate every non-ASCII line in the sources and rewrite them, verifying afterwards that no CJK character survives |
| `glb_*.py`, `fbx_*.py` | animation/model inspection: bone consistency with the player skeleton, keyframe pacing, hand-travel measurement, unit checks |

---

## Acknowledgements and references

This project was built by studying how other games and other mods *behave*. The ideas taken
from each source are listed below.

### Games and clients

| Source | What was drawn from it |
|---|---|
| **Minecraft** (Mojang) | the bow concept the mod deliberately imitates: hold to draw, release to loose, `charge(t) = (t² + 2t) / 3` draw curve, no reload key, arrows recoverable from what you hit |
| **Rust** (Facepunch) | projectile ballistics *field semantics* — gravity modifier, drag curve, string bonus velocity — used as the naming/shape of the physics parameters |
| **PUBG** (Krafton) | the arc/zeroing feel of a slow projectile and what a readable trajectory preview should look like |
| **Wurst Client** (GPL-3.0, Minecraft utility client) | the layout/utility style for small helper code; its licence is GPL-3.0 and therefore compatible with this project |

No code from Minecraft, Rust or PUBG is included — those are proprietary and their source is
not available for reuse. What was reused is *behaviour*, *publicly documented formulas* and
*parameter names*. See the caveats section below.

### Steam Workshop items studied

| ID | Name | What was drawn from it |
|---|---|---|
| `3775407541` | **RadArchery** | how a bow mod can re-skin its hand model through the engine's weapon-sprite field; the arrow-recovery / arrow-lodging flow and the `setAttachedItem` approach |
| `3617854007` | **ArcheryNexus** | the "bow disguised as a firearm" idea (`SubCategory = Firearm`, `IsAimedFirearm`) so the engine's aim plumbing accepts a bow |
| `2208315526` | *(name not resolved at the time of writing — the workshop page could not be reached from the build environment; the ID is listed as provided by the project author)* | earlier archery-mod reference material consulted during research |

Base-game behaviour that these mods also rely on (`setAttachedItem`, `setWeaponSprite`,
`resetEquippedHandsModels`, the `AnimSets` state machine) was re-verified independently
from the game's own scripts and bytecode, not copied from those mods.

---

## Provenance and licensing caveats (read this)

**This needs to be stated plainly, because it is a real risk to anyone redistributing this mod.**

- **Large parts of this codebase were written with AI assistance.** The implementation was
  produced iteratively by prompting a code-generating model, then verified against the game's
  own behaviour, scripts and bytecode (which is what the `Tool/` checkers exist for).
- **An AI has no reliable provenance record.** When a model emits a pattern — a helper layout,
  a formula, an unusual API call — it cannot say whether it is reproducing something from its
  training data or independently re-deriving it. The list of references above is therefore
  **best-effort attribution, not a verified audit**. A given block may be
  (a) reimplemented from observed behaviour, (b) derived from public documentation or
  community write-ups, or (c) reproduced from memory of public source code.
- **Consequences to review before any public release:**
  1. **Proprietary games** — Minecraft, Rust and PUBG source code is not licensed for reuse.
     If any fragment here turns out to be a *verbatim* copy of their code rather than a
     re-derivation of behaviour or a public formula, it must be removed or rewritten.
  2. **Steam Workshop mods** — Workshop items are generally **not** published under an
     open-source licence. Studying behaviour is fine; copying code or assets is not, without
     the author's permission. If any code here was derived beyond behaviour from
     `2208315526`, `3617854007` or `3775407541`, get permission and add explicit attribution
     before publishing.
  3. **Wurst Client** is GPL-3.0, which is compatible with this project's licence — but if
     code was derived from it, the upstream notice must be preserved alongside it.
  4. **ZombieBuddy** is a separate third-party mod with its own terms; it is a dependency, not
     part of this work, and its jar is not redistributed here.
- **Assets**: the bow/arrow models, the eight draw frames, the textures and the character
  animations were made for this project and are covered by the GPL-3.0 grant above unless a
  file says otherwise. No assets are copied from the games or from the workshop mods listed.
  **The mod ships no audio files at all** — every sound it plays is the base game's own,
  triggered by name (`FishingRodSwing`, `M9Jam`, `WoodenStickHit`, `SpearCraftedHit`, …). The
  stock reticle PNGs under `media/ui/Reticle_transparent_backup/` are base-game textures kept
  only as reference; no script references them.
- **Text**: `media/lua/shared/Translate/CN/*.json` are the mod's **Chinese** localisation tables and
  are Chinese by design — they are the only intentionally non-English text in this package.
  `media/lua/shared/Translate/EN/*.json` holds the English originals.
- **Comments and console output** in `src/` and `media/lua/` are in English throughout.
- **The game itself** (Project Zomboid, © The Indie Stone) is not covered by this licence, and
  no part of it is redistributed here.

If you are the author of any referenced work and you believe something here goes beyond
legitimate reference, please open an issue — it will be removed or re-implemented.

---

## Credits

- **Author / maintainer:** the Bow and Arrow System project author.
- **Java bridge and bytecode toolchain:** the **ZombieBuddy** mod (`3619862853`), whose
  `Exposer` makes Java↔Lua interop possible.
- **Reference material:** Minecraft, Rust, PUBG, Wurst Client, and the Steam Workshop items
  `2208315526`, `3617854007` (ArcheryNexus), `3775407541` (RadArchery).
- **Engine knowledge:** the Project Zomboid Lua scripts and `projectzomboid.jar` shipped with
  the game, plus the community's public reverse-engineering notes.
- **AI assistance:** substantial portions of the Lua/Java code and documentation were drafted
  with an AI assistant, then validated against the game (see the caveats above).

[ZombieBuddy]: https://steamcommunity.com/sharedfiles/filedetails/?id=3619862853
