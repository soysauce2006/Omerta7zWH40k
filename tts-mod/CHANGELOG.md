# Changelog

All notable changes to the WH40K TTS Mod Global Script.

Format: `[version] YYYY-MM-DD — summary`
Changes within each version are grouped by type.

---

## [0.9.0] 2026-06-17 — Yelloscribe Stratagem Pin

### Added
- **⚡ Pin from URL** button in the Yelloscribe sidebar — reads the current browser
  URL, converts the path slug to title case, and pre-fills the stratagem name field.
  Same pattern as the existing 📋 Pin from URL for data cards.
- **Stratagem sub-section** in the Yelloscribe sidebar — compact form (name, CP,
  phase, description) sits directly below the data cards list so players never need
  to leave the rules browser to save a strat.
  - **✚ Save Strat** writes to the shared `stratagems[]` list, spawns the physical
    notecard on the side table, clears the form, and updates both the Yelloscribe
    status line and the standalone ⚡ Strats panel simultaneously.
- `saveStratFromYS(player)` — dedicated save function for the sidebar form; shares
  state and notecard spawner with the standalone panel.
- `pinStratFromURL(player)` — URL-to-name parser targeting the sidebar name field.

### Workflow
1. Open **📜 Rules** (Yelloscribe panel).
2. Browse to a stratagem page on yelloscribe.com.
3. Click **⚡ Pin from URL** — name field fills automatically.
4. Set CP (1–3) and phase; optionally add a description.
5. Click **✚ Save Strat** — notecard appears on your side table.

---

## [0.8.0] 2026-06-17 — Stratagems System

### Added
- **⚡ Strats toolbar button** — opens the standalone Stratagems panel.
- `!strats` chat command — same as clicking the toolbar button.
- **Stratagems panel** (320 × 490 px, draggable, animate Grow/Shrink):
  - Name, CP (1–3), Phase, and multi-line description input fields.
  - **⚡ Add Stratagem** button — validates, saves, and spawns a notecard.
  - Scrollable list of up to 20 saved stratagems; each slot shows name (bold
    orange), CP + phase badge (gold), description, and a ✕ remove button.
  - Status line reflects current count.
- **Physical stratagem notecards** spawned on the player's side table at the far
  end (Z offset +5.0 from table centre), distinct from data cards:
  - Tinted amber (seat colour × 0.9/0.65/0.4) so they're visually separate.
  - Notecard title = stratagem name; body = `[CP: N]  |  Phase\n\nDescription`.
  - Tagged `WH40K_Stratagem` for targeted cleanup.
  - 4 per row, same gap constants as data cards.
- `clearPhysicalStratagems()` / `respawnAllPhysicalStratagems()` — mirrors data
  card physical management; called 25 frames after load.
- **Host-only gated** — `checkPerm` covers Add and Remove in both the standalone
  panel and the Yelloscribe sidebar.
- Stratagem list persists across save/load (`stratagems` key in save state).
- Toolbar width increased 750 → 824 px to accommodate new button.

---

## [0.7.0] 2026-06-17 — Host-Only Mode

### Added
- **Host-only lock** — `!hostonly on` / `!hostonly off` restricts all mod controls
  to the server host. Only the host can toggle this setting.
- **🔒 HOST badge** in the toolbar — visible to all players when host-only is active.
- Gated controls: turn advancement, army cycling, dice rolls, team setup, data card
  pinning, FTC import, model scale (chat `!scale`), and all `!` chat commands.
- Wound tracker ±HP buttons intentionally remain open for all players.
- Host-only state persists across save/load.

### Fixed
- `scaleAllModels` function signature corrected — TTS `|value` onClick callbacks pass
  only the value (not `player, value`). Button calls now work correctly.
  Chat `!scale` still goes through the permission gate via `onChat`.

---

## [0.6.0] 2026-06-17 — Model Scale

### Added
- **⚖ Scale panel** — toolbar button opens a three-button panel: 100%, 75%, 50%.
- `!scale <percent>` chat command — accepts 1–200, not just the preset values.
- Original model sizes are captured on first scale, so switching between factors
  and returning to 100% is always lossless.
- Targets every `Custom_Model` object and any object tagged **Miniature**.
- System objects (side tables, data cards, dice mats) are excluded automatically.
- Scale factor and base-scale table persist across save/load.

---

## [0.5.0] 2026-06-17 — Physical Data Cards

### Added
- When a player saves a data card via the Yelloscribe sidebar a **Notecard object**
  is spawned on their player side table, tinted their seat colour.
- Cards are laid out in rows of 4; removing a card respawns the row gap-free.
- Physical cards are rebuilt from saved state on every load (`respawnAllPhysicalDataCards`).
- Cards without a seat colour (saved before this version) stay in the sidebar only.

---

## [0.4.0] 2026-06-17 — Data Cards Sidebar & Player Side Tables

### Added
- **Yelloscribe data cards sidebar** — the rules browser panel gains a 312 px
  sidebar with name/faction/stat fields, **📌 Pin Page** (pre-fills unit name from
  the current URL), and **✚ Save Card** / **✕ Remove** per slot. Up to 30 cards.
- **Player side tables** — six `BlockRectangle` mats spawn around the play area
  perimeter, one per TTS seat colour, named with the seated player's Steam name.
  Tables update their label when players connect, disconnect, or change colour.
- `!tables` — respawn all side tables.
- `!cleartables` — remove all side tables.
- `onPlayerConnect` / `onPlayerDisconnect` / `onPlayerChangeColor` handlers refresh
  side table labels automatically.
- Data card state (all fields + player colour) persists across save/load.

---

## [0.3.0] 2026-06-16 — Help Panel & FTC Compatibility Layer

### Added
- **❓ Help panel** — scrollable in-game command reference; lists all chat commands
  with descriptions. Also available as `!help` in chat.
- **FTC compatibility layer** — Free the Codex (FTC) is auto-detected at load time.
  - Toolbar repositions to bottom-right to avoid FTC's left rail.
  - Turn Tracker hides; FTC owns phase/round control.
  - `onFTCPhaseStart`, `onFTCRoundStart`, `onFTCTurnStart` callbacks sync the
    Teams panel with FTC events.
  - **⚙ FTC** toolbar button and `!ftcimport` / `!ftcunit <GUID>` commands.
- `!history` command — print last 10 rolls to the requesting player's chat.

---

## [0.2.0] 2026-06-15 — Wound Tracker & Teams Panel

### Added
- **❤ HP panel** — model-aware wound tracker supporting up to 12 units.
  Damage fills the front model first; overflow carries to the next.
  HP badge format: `4/5×2W` (wounds remaining / W per model × model count).
- `!addunit "Name" <W/model> [models]` — add a unit.
- `!wound "Name" <n>` / `!heal "Name" <n>` — apply wounds / healing.
- **👥 Teams panel** — six match formats: FFA, 2v1, 2v2, 3v2, 3v3, 3-Team.
  Auto-assign from seated players, or assign manually by colour.
- `!setmode <mode>` / `!teams` chat commands.
- Army cycling: `!next` / `!prev` advance/retreat the active army through phases.
- Active-army display on the Turn Tracker refresh.

---

## [0.1.0] 2026-06-14 — Initial Release

### Added
- **🎲 Dice Roller panel** — presets (D6, 2D6, D3, scatter) and free NdS input.
- **Dice Mat auto-announce** — tag any object `DiceMat`; physical dice rolled on it
  broadcast results to all players with sum and individual values.
- **⚔ Attack panel** — full hit → wound → save → damage sequence.
  AP modifier applied to armour saves. Damage supports flat, D3, D6.
- **🛡 Save panel** — multi-dice armour save roller with AP.
- **💀 Morale panel** — Battleshock test (Ld + models lost → 2D6 vs Ld).
- **⏱ Turn Tracker** — 6 WH40K phases (Command, Movement, Shooting, Charge,
  Fight, Morale) with round counter.
- `!roll NdS` chat command.
- All panels are draggable. State persists across save/load via `onSave`/`onLoad`.
- Single-file design — paste `Global.lua` into Global Lua Script, done.
