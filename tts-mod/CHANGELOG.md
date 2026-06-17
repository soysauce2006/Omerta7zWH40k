# Changelog

All notable changes to the WH40K TTS Mod Global Script.

Format: `[version] YYYY-MM-DD — summary`
Changes within each version are grouped by type.

---

## [1.4.0] 2026-06-17 — BattleScribe Data Card Import & ForgeOrg Compatibility

### Added
- **BattleScribe stat extraction** — `parseBSUnits` now reads all six datasheet
  profile stats (M, T, Sv, W, Ld, OC) and faction name from the XML, so imported
  units arrive with fully populated data cards instead of name-only placeholders.
- **`nrAddDataCards(units, color)`** helper — creates and physically spawns a data
  card notecard for every imported unit; called by both Import Units and Import All.
- **🌐 Fetch Stats from Page** button in the Yelloscribe data card sidebar — reads
  the current browser URL and fetches unit stats directly from the page using a
  multi-strategy parser (Next.js `__NEXT_DATA__`, generic SPA JSON blobs, HTML stat
  table, short-key JSON). Fills M, T, Sv, W, Ld, OC fields automatically.

### Changed
- **Import Units** no longer writes to the Wound Tracker. HP tracking is delegated
  to ForgeOrg (or whichever external mod the host uses). The button now creates data
  cards only; status message updated to `✓ N data cards imported`.
- **Import All** likewise skips the wound tracker loop; status now reads
  `✓ N data cards  ·  N stratagems`.
- Import panel status messages throughout updated to match.

### Compatibility
- **ForgeOrg** (Steam Workshop 3137407072) — no code conflicts. ForgeOrg has no
  exported Lua API or shared globals; our mod does not touch its objects. Model
  scaling (`!scale`) will affect any `Custom_Model` objects ForgeOrg spawns; tag
  those objects `Miniature` to opt them in, or leave them untagged and add a
  ForgeOrg guard to `isScalable()` once its global name is known.
- **Battleforged model pack** — no conflicts (pure asset pack, no Lua scripts).

---

## [1.3.0] 2026-06-17 — Toolbar Toggle

### Added
- **≡ persistent toggle button** — a small red `≡` button is pinned to the
  bottom-right corner of the screen at all times, independent of the toolbar.
  Clicking it hides or shows the toolbar without any chat command.
- When the toolbar is hidden the button label changes to **▲ WH40K** so it
  remains discoverable; restoring the toolbar reverts it to `≡`.
- `!toolbar` chat command — same toggle behaviour, useful as a keyboard
  fallback when the button is off-screen on non-standard resolutions.

---

## [1.2.0] 2026-06-17 — FTC Safety & Tables Button

### Added
- **🪑 Tables toolbar button** — direct one-click access to `spawnSideTables`
  (previously only available via `!tables` chat command).

### Fixed
- **Model scaling no longer affects FTC unit models** — `isScalable()` now
  returns `false` for untagged `Custom_Model` objects when Free the Codex is
  loaded. Only objects explicitly tagged `Miniature` are scaled in FTC mode,
  preventing accidental rescaling of FTC's own unit figures.
  Non-FTC behaviour is unchanged.

### Documented
- Added FTC dice mat wiring instructions to README and help panel: tag FTC
  dice trays with `DiceMat`, then run `!tables` to auto-position them on
  player side tables. Double-announce tip included.

---

## [1.1.0] 2026-06-17 — Surrender System

### Added
- **⚑ Yield toolbar button** — opens the surrender confirmation panel for the
  clicking player. Does not use a `|value` parameter so player identity is
  passed correctly.
- `!surrender` chat command — identical trigger for keyboard users.
- **Surrender confirmation panel** (360 × 230 px, dark red, draggable):
  - Displays the surrendering player's Steam name and seat colour.
  - Lists what will be removed before committing.
  - **Cancel** button — closes panel, no action taken.
  - **⚑ Confirm Surrender** button — executes cleanup.
- `doSurrenderCleanup(colorName)`:
  - Removes all `isScalable()` objects within radius 14 (XZ) of the
    player's side table (staged models).
  - Removes all data cards matching the player's seat colour and rebuilds
    physical notecards for remaining players.
  - Removes all stratagems matching the player's seat colour and rebuilds
    physical notecards for remaining players.
  - Broadcasts a colour-coded announcement to every seated player listing
    counts removed; notes that main-board deployed models must be cleared
    manually.
- `surrenderedColors` table tracks which colours have already surrendered;
  repeated `!surrender` calls are silently ignored.
- `!surrender` and `!toolbar` entries added to `!help` and the Help panel.

---

## [1.0.0] 2026-06-17 — New Recruit / BattleScribe XML Import

### Added
- **📥 Import panel** — new toolbar button (and `!import` chat command) opens a
  draggable panel with a large paste area and three import buttons.
- **🧬 Import Units** — parses `<selection type="unit">` entries from a
  BattleScribe `.ros` export; extracts unit name, W (wounds per model) from the
  datasheet profile, and model count from child `type="model"` selections.
  Loads all units directly into the ❤ HP wound tracker via `addUnit()`.
- **⚡ Import Strats** — parses `<profile profileTypeName="Stratagem">` entries;
  extracts name, CP cost (1–3), When/phase, and Effect description (≤ 200 chars).
  Saves to the shared `stratagems[]` list and spawns physical notecards on the
  player's side table, identical to manually-saved strats.
- **🧬+⚡ Import All** — runs both parsers in one click.
- Status line in the panel confirms what was imported or reports parse failures
  with a clear message (e.g. `✓ 8 units  +  12 stratagems imported`).
- Pure-Lua XML parser — no external libraries; handles both `<element>text</element>`
  and `<element value="…"/>` characteristic forms, and decodes `&amp;` / `&lt;` /
  `&gt;` / `&quot;` / `&apos;` entities.
- Help panel updated with step-by-step New Recruit export instructions and a
  description of each import button.
- Toolbar width increased 824 → 900 px to accommodate the new button.

### Workflow
1. New Recruit → open army list → **Export → BattleScribe (.ros)**.
2. Open the `.ros` file in a text editor, select all, copy.
3. In TTS click **📥 Import**, paste, click the appropriate button.

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
