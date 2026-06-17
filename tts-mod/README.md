# WH40K TTS Mod — Global Script

A single-file Tabletop Simulator mod for Warhammer 40,000 10th Edition.
Paste `Global.lua` into your table's Global Lua Script slot and everything below becomes available instantly.

---

## Features

| Button | Feature | What it does |
|---|---|---|
| 🎲 Dice | Dice Roller | Free NdS rolls + Dice Mat auto-announce |
| ⚔ Attack | Attack Sequence | Hit → Wound → Save → Damage all in one |
| 🛡 Save | Armour Save | Multi-dice save roller with AP |
| 💀 Morale | Battleshock | Ld + models-lost test |
| ⏱ Turn | Turn Tracker | 6 WH40K phases, round counter, army cycling |
| ❤ HP | Wound Tracker | Model-aware HP (damage allocates front model first) |
| 👥 Teams | Match Formats | FFA / 2v1 / 2v2 / 3v2 / 3v3 / 3-Team |
| 📜 Rules | Yelloscribe | In-game browser + data card sidebar |
| ⚖ Scale | Model Scale | Scale all minis 100% / 75% / 50% |
| ❓ Help | Help Panel | Scrollable in-game command reference |
| ⚙ FTC | FTC Import | Free the Codex integration (auto-detected) |

Additional features with no toolbar button:

- **Player Side Tables** — colour-coded mats around the play area, one per seat
- **Physical Data Cards** — Notecard objects spawned on each player's side table
- **Host-Only Mode** — lock all mod controls to the server owner

---

## Files

```
tts-mod/
├── Global.lua        ← entire mod (paste this into TTS Global Lua slot)
├── WH40K-Mod.json    ← TTS save file for Steam Workshop upload
├── workshop.json     ← Workshop metadata (name, tags, description)
├── README.md         ← this file
├── INSTALL.md        ← step-by-step install guide
└── CHANGELOG.md      ← version history
```

---

## Quick Install

1. Open TTS → load your WH40K table.
2. **Modding → Scripting Editor → Global**
3. Select all, delete, paste `Global.lua`, click **Save & Play**.
4. The toolbar appears at the bottom of the screen.

See [INSTALL.md](INSTALL.md) for the full guide including FTC, Steam Workshop upload, and Dice Mat setup.

---

## Chat Commands

```
DICE
  !roll 2d6                   — roll any NdS combination
  !history                    — last 10 roll results

COMBAT
  !attack <n> <hit+> <wound+> <AP> <dmg> <save+>
  !save <dice> <save+> [AP]
  !morale <Ld> <lost>

UNITS / HP
  !addunit "Name" <W/model> [model count]
  !wound "Name" <amount>
  !heal  "Name" <amount>

TURN
  !next / !prev               — advance / retreat phase (cycles armies)
  !turn                       — show current phase

TEAMS
  !setmode <mode>             — ffa | 2v1 | 2v2 | 3v2 | 3v3 | 3team
  !teams                      — show current team layout

SCALE
  !scale <percent>            — scale all minis (e.g. !scale 75)

TABLES
  !tables                     — respawn player side tables
  !cleartables                — remove player side tables

HOST
  !hostonly on | off          — lock controls to server host only (host only)

MISC
  !yelloscribe                — open rules browser
  !ftcimport                  — import all FTC units (FTC only)
  !ftcunit <GUID>             — import one FTC unit by GUID (FTC only)
  !help                       — print command reference in chat
```

---

## Wound Tracker

Damage is allocated one wound at a time to the **front model**.
When that model's wounds reach 0 it is removed and overflow carries to the next.

HP badge format: `4/5×2W` = 4 wounds remaining on front model, 1 of 2 models left, each with 5W.

---

## Match Formats (Teams Panel)

| Mode | Armies | Players per army |
|---|---|---|
| FFA | One per seated player | 1 |
| 2v1 | Alpha vs Bravo | 2 vs 1 |
| 2v2 | Alpha vs Bravo | 2 vs 2 |
| 3v2 | Alpha vs Bravo | 3 vs 2 |
| 3v3 | Alpha vs Bravo | 3 vs 3 |
| 3-Team | Alpha / Bravo / Charlie | 2 / 2 / 2 |

---

## Model Scaling

The **⚖ Scale** panel (or `!scale <pct>`) resizes every `Custom_Model` object
and any object tagged **Miniature** on the table.

- **100%** restores originals — original sizes are captured on first scale.
- Scales from 1% to 200% via chat command.
- System objects (side tables, data cards, dice mats) are never scaled.
- Scale state persists across save/load.

---

## Host-Only Mode

```
!hostonly on    ← locks all controls to the server host
!hostonly off   ← re-opens controls to all players
```

A red **🔒 HOST** badge appears in the toolbar when active.
Gated controls: turn advancement, army cycling, dice rolls, team setup,
data card pinning, FTC import, model scale (chat), and all `!` commands.
Wound tracking (±HP buttons) remains open for all players.

---

## Data Cards

Open the **📜 Rules** panel → browse Yelloscribe → click **📌 Pin Page**
to pre-fill the unit name, then fill in stats and click **✚ Save Card**.

- Each card is stored in the sidebar and spawned as a **Notecard** on the
  player's side table, tinted their seat colour.
- Up to 30 cards. Remove with **✕** in the sidebar — physical notecard is
  also removed and remaining cards re-stack.
- Cards persist across save/load.

---

## FTC Integration

FTC is detected automatically at load time. When present:

- Toolbar moves to the **bottom-right** corner (avoids FTC's left rail).
- Turn Tracker hides; FTC owns phase/round control.
- Teams panel syncs active army from FTC turn events.
- An **⚙ FTC** button appears in the toolbar.

---

## Persistence

Saved automatically with the TTS save file (`onSave` / `onLoad`):

- Roll history
- Wound tracker units (names, W, model counts, current HP)
- Turn state (round, phase, active player)
- Team configuration (mode, names, assignments)
- Data cards (all fields + player colour)
- Model scale factor + original base scales
- Host-only mode state
