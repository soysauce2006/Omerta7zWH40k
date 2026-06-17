# WH40K TTS Mod — Global Script

Adds the following to any Warhammer 40,000 Tabletop Simulator table:

| Feature | What it does |
|---|---|
| 🎲 Dice Roller | Panel + Dice Mat auto-announce |
| ⚔ Attack Sequence | Hit → Wound → Save → Damage calculator |
| 🛡 Save | Armour save roller |
| 💀 Battleshock | Morale / Battleshock test |
| ⏱ Turn Tracker | 6 WH40K phases with round counter |
| ❤ Wound Tracker | Model-aware HP (damage fills front model first) |
| 👥 Teams | FFA / 2v1 / 2v2 / 3v2 / 3v3 / 3-Team match formats |
| 📜 Yelloscribe | In-game browser to yelloscribe.com |
| ⚙ FTC Compat | Full Free the Codex integration (auto-detected) |
| ❓ Help | Scrollable in-game help panel |

---

## Files

```
tts-mod/
├── Global.lua       ← the entire mod script
├── WH40K-Mod.json   ← TTS save file for Steam Workshop upload
├── workshop.json    ← Workshop metadata (name, tags, description)
└── thumbnail.png    ← Workshop preview image (add your own, 512×512 recommended)
```

---

## Install — Steam Workshop (easiest)

This is the recommended method. Players subscribe once and the mod auto-updates.

### Step 1 — Upload to Workshop (done once by the mod author)

#### Option A: Upload via Tabletop Simulator directly

1. In TTS go to **Configuration → Workshop → Upload New Item**.
2. Fill in:
   - **Name:** `WH40K TTS Mod — Dice · Attack · Turns · HP · Teams · FTC`
   - **Description:** paste the content from `workshop.json → description`
   - **Tags:** Scripting, Warhammer 40000
3. Under **Save File**, browse to `tts-mod/WH40K-Mod.json`.
4. Under **Preview Image**, choose a 512×512 PNG (`thumbnail.png`).
5. Click **Upload** and set visibility to **Public**.
6. Copy the Workshop item URL — share this with players.

> To update an existing item: Configuration → Workshop → Update Item → pick the same item → re-upload `WH40K-Mod.json`.

#### Option B: Upload via Steam Workshop Uploader tool

A community CLI tool ([tts-workshop-uploader](https://github.com/nicorhs/tts-workshop-uploader)) reads `workshop.json` automatically:

```bash
tts-workshop-uploader upload tts-mod/workshop.json
```

### Step 2 — Players subscribe & use

1. Player opens the Workshop link and clicks **Subscribe**.
2. In TTS: **Games → Workshop** — the mod appears in the list.
3. **Option A — Use as a standalone table:** click **Load**. The toolbar appears on an empty RPG table.
4. **Option B — Add to your own WH40K table (recommended):**
   - Load the Workshop item, open **Modding → Scripting Editor → Global**, copy all the script.
   - Load your WH40K table, open **Modding → Scripting Editor → Global**, paste, click **Save & Play**.

---

## Install — Standalone (no FTC)

1. **Open Tabletop Simulator** and load (or create) your WH40K table.

2. **Open the Lua editor**
   - Menu bar → **Modding** → **Scripting Editor**
   - Or press **Alt + L**

3. **Select Global**
   - In the editor's left panel, click **Global** (not an individual object).

4. **Paste the script**
   - Select all existing content in the editor and delete it.
   - Open `tts-mod/Global.lua` from this repo and copy its entire contents.
   - Paste into the TTS editor.

5. **Save & Play**
   - Click **Save & Play** (top-right of the editor).
   - The WH40K toolbar appears at the bottom-centre of the screen.

6. **Optional — Dice Mat**
   - Select any object you want to use as a dice rolling surface.
   - Right-click → **Tags** → add the tag `DiceMat`.
   - Physical dice rolled onto that object will auto-announce results to all players.

---

## Install — With Free the Codex (FTC)

FTC must be loaded **before** this script runs. The recommended approach:

1. Set up your table with FTC already working (follow FTC's own install guide).

2. Follow steps 1–5 above to paste this script into Global.

3. **Save & Play** — the mod detects FTC automatically at load time:
   - Toolbar moves to the **bottom-right** corner to avoid FTC's left rail.
   - Turn Tracker hides itself; FTC controls phases and rounds.
   - Teams panel stays live and syncs the active army from FTC turn events.
   - An **⚙ FTC** button appears in the toolbar.

4. **Import FTC units into the Wound Tracker** (optional but recommended):
   - Click **⚙ FTC** in the toolbar, or type `!ftcimport` in chat.
   - To import a single unit: `!ftcunit <GUID>` where GUID is the TTS object GUID of the FTC unit card.

> **Note:** Do not load this script as a second Global script via `require` — paste it directly into the Global slot. If you already have a custom Global script, merge the contents manually.

---

## First-time Setup Checklist

- [ ] Script pasted into Global and saved
- [ ] Table reloaded (Save & Play)
- [ ] Toolbar visible at bottom of screen
- [ ] (Optional) Dice Mat tag added to a surface object
- [ ] (FTC only) `!ftcimport` run to populate wound tracker

---

## Using the Mod

### Toolbar buttons

All panels are draggable. Click the button again or the **✕** in the panel header to close.

| Button | Opens |
|---|---|
| 🎲 Dice | Dice roller with presets and custom NdS |
| ⚔ Attack | Step-by-step attack sequence |
| 🛡 Save | Armour save roller |
| 💀 Morale | Battleshock test |
| ⏱ Turn | Phase tracker (hidden when FTC present) |
| ❤ HP | Wound / model tracker |
| 👥 Teams | Match format and army tracker |
| 📜 Rules | Yelloscribe in-game browser |
| ❓ Help | In-game scrollable help |
| ⚙ FTC | Import FTC units (only shown when FTC detected) |

### Chat commands (type in TTS chat)

```
Dice
  !roll 2d6               — free dice roll (any NdS)
  !history                — last 10 roll results

Combat
  !attack <n> <hit+> <wound+> <AP> <dmg> <save+>
                          — full hit→wound→save→damage sequence
                            dmg can be a flat number, d3, or d6
  !save <dice> <save+> [AP]
                          — armour saves only
  !morale <Ld> <lost>     — Battleshock test

Units / HP
  !addunit "Name" <W/model> [model count]
                          — add a unit to the wound tracker
  !wound "Name" <amount>  — deal wounds to a unit
  !heal  "Name" <amount>  — heal wounds on a unit

Teams
  !setmode <mode>         — set match format
                            modes: ffa  2v1  2v2  3v2  3v3  3team
  !teams                  — show current team setup

Turn
  !next                   — advance to next phase (cycles armies)
  !prev                   — step back one phase
  !turn                   — show current phase and round

Misc
  !yelloscribe            — open Yelloscribe rules browser
  !help                   — print command reference in chat

FTC (only active when FTC is detected)
  !ftcimport              — import all FTC units into wound tracker
  !ftcunit <GUID>         — import one FTC unit card by GUID
```

### Teams & Match Formats

| Mode | Teams | Players per team |
|---|---|---|
| FFA | One per player | 1 |
| 2v1 | Alpha vs Bravo | 2 vs 1 |
| 2v2 | Alpha vs Bravo | 2 vs 2 |
| 3v2 | Alpha vs Bravo | 3 vs 2 |
| 3v3 | Alpha vs Bravo | 3 vs 3 |
| 3-Team | Alpha / Bravo / Charlie | 2 / 2 / 2 |

Click **⟳ Auto-assign** in the Teams panel to fill teams from seated players, or use the Move Player row to assign manually.

### Wound Tracker — model-aware damage

Damage is allocated one wound at a time to the front model. When that model's wounds hit 0 it is removed and any overflow carries to the next model.

HP badge format: `4/5×2W` = 4 wounds remaining on the front model, 1 of 2 models left, each with 5W.

---

## FTC Integration Details

When Free the Codex is detected at load time:

| FTC event | What the mod does |
|---|---|
| Turn handed to player | Syncs active army in Teams panel; chat announcement includes army name |
| Phase advances | Refreshes Teams panel; phase chat message appends active army |
| Round starts | Refreshes Teams panel |

The mod's own Turn Tracker hides and lets FTC own phase/round control. All other panels (Dice, Attack, Wound Tracker, Teams, Yelloscribe, Help) work normally alongside FTC.

---

## Saving & Persistence

Game state is saved automatically with the TTS save file via `onSave`/`onLoad`:

- Roll history
- All wound tracker units (names, W, model counts, current HP)
- Turn state (round, phase, active player)
- Team configuration (mode, team names, player assignments)
