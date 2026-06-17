# WH40K TTS Mod — Installation Guide

Choose the method that fits your workflow.

---

## Method 1 — Manual Paste (simplest)

Works for any table. No Steam account required. No files to manage beyond `Global.lua`.

### Steps

1. **Open Tabletop Simulator** and load your WH40K table (or start a new one).

2. **Open the Scripting Editor**
   - Menu bar → **Modding → Scripting Editor**
   - Or press **Alt + L**

3. **Select the Global script**
   In the left panel of the editor, click **Global** (not an individual object).

4. **Paste the script**
   - Select all existing content (`Ctrl + A`) and delete it.
   - Open `tts-mod/Global.lua`, copy the entire file.
   - Paste into the TTS editor.

5. **Save & Play**
   Click **Save & Play** (top-right of the editor).
   The **WH40K toolbar** appears at the bottom of the screen.

6. **Save your table**
   - Menu bar → **Games → Save & Load → Save Game**
   - Name the save something memorable.
   - The script is now embedded in your table save — no need to re-paste after this.

> **Updating:** repeat steps 2–5 whenever you pull a new version of `Global.lua`.

---

## Method 2 — Steam Workshop

Players subscribe once and receive updates automatically.

### Step A — Upload to the Workshop (done once by the mod author)

1. In TTS go to **Configuration → Workshop → Upload New Item**.
2. Fill in:
   - **Name:** `WH40K TTS Mod — Dice · Attack · Turns · HP · Teams · FTC`
   - **Description:** paste the content from `workshop.json → description`
   - **Tags:** Scripting, Warhammer 40000
3. Under **Save File**, browse to `tts-mod/WH40K-Mod.json`.
4. Under **Preview Image**, choose a 512×512 PNG.
5. Click **Upload** and set visibility to **Public**.
6. Copy the Workshop item URL — share this with players.

> **To update an existing item:** Configuration → Workshop → Update Item → pick the same item → re-upload `WH40K-Mod.json`.

#### Alternative — CLI uploader

A community tool reads `workshop.json` automatically:

```bash
# https://github.com/nicorhs/tts-workshop-uploader
tts-workshop-uploader upload tts-mod/workshop.json
```

### Step B — Players subscribe

1. Player opens the Workshop link and clicks **Subscribe**.
2. In TTS: **Games → Workshop** — the mod appears.
3. Click **Load** to open it as a standalone table.  
   *Or* use **Option B** below to add it to an existing WH40K table.

#### Option B — Merge into an existing table

1. Open the Workshop item → **Modding → Scripting Editor → Global** → copy all.
2. Load your own WH40K table → **Modding → Scripting Editor → Global** → paste → **Save & Play**.

---

## Optional Setup

### Dice Mat

Any object can become a dice rolling surface that auto-announces results to all players.

1. Right-click an object on the table.
2. **Tags → Add Tag** → type `DiceMat` → confirm.
3. Physical dice rolled onto that object will broadcast results automatically.

You can tag as many objects as you like. A felt mat, a dedicated dice tray, or even a card all work.

### Player Side Tables

Six colour-coded rectangular mats spawn automatically around the play area perimeter
(one per TTS seat colour). They are created on first load.

- `!tables` — respawn all side tables
- `!cleartables` — remove all side tables

Side tables are excluded from model scaling and are never affected by `!scale`.

### Model Tagging

The scale system targets every `Custom_Model` object by default, plus any object
explicitly tagged **Miniature**.

If you want a `Custom_Model` to be excluded from scaling, tag it with any of:
`WH40K_SideTable`, `WH40K_DataCard`, or `DiceMat`.

---

## With Free the Codex (FTC)

FTC must be loaded **before** this script runs (i.e. already in your table).

1. Set up your table with FTC working (follow FTC's own install guide).
2. Follow Method 1 above to paste this script into Global.
3. **Save & Play** — the mod auto-detects FTC:
   - Toolbar moves to **bottom-right** to avoid FTC's left rail.
   - Turn Tracker hides; FTC owns phase/round control.
   - **⚙ FTC** button appears in the toolbar.

4. **Import FTC units** into the Wound Tracker (optional but recommended):
   - Click **⚙ FTC** in the toolbar, or type `!ftcimport` in chat.
   - To import one unit: `!ftcunit <GUID>` (GUID is the TTS object GUID of the FTC unit card).

> Do **not** load this script as a second Global via `require`. If you already have a custom
> Global script, merge the contents manually by placing the WH40K mod code before your existing
> `onLoad` / `onSave` handlers, then merging those two functions by hand.

---

## First-time Checklist

- [ ] Script pasted into Global and **Save & Play** clicked
- [ ] Toolbar visible at bottom of screen
- [ ] Table saved (`Games → Save & Load → Save Game`)
- [ ] (Optional) `DiceMat` tag added to a surface object
- [ ] (Optional) `!tables` run to confirm side tables spawned
- [ ] (FTC only) `!ftcimport` run to populate the Wound Tracker

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Toolbar not visible | Check Scripting Editor for Lua errors; click Save & Play again |
| Panels overlap FTC | FTC not detected — make sure FTC is loaded before this script; re-save & play |
| Scale reverts on reload | Table saved at non-100% — base scales are persisted in the save; this is expected |
| Dice Mat not firing | Confirm the object has exactly the tag `DiceMat` (case-sensitive) |
| `!ftcimport` returns 0 units | FTC units must be physically placed on the board before importing |
| Host-only locked out | Type `!hostonly off` in chat as the host to re-open controls |
