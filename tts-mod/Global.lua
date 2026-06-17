-- =============================================================================
--  WH40K Dice Mat · Yelloscribe · Turn Tracker · Wound Tracker
--  + Free the Codex (FTC) compatibility layer
--  Global script for Tabletop Simulator
--
--  See tts-mod/README.md for full install instructions.
-- =============================================================================
--
--  QUICK INSTALL
--  ─────────────
--  1. In TTS: Modding → Scripting Editor → click "Global" in the left panel.
--  2. Delete all existing content, paste this entire file, click Save & Play.
--  3. The WH40K toolbar appears at the bottom of the screen.
--  4. (Optional) Tag any object "DiceMat" to enable dice auto-announce.
--  5. (FTC) Load FTC first, then paste this script — it auto-detects FTC.
--     Click ⚙ FTC in the toolbar (or type !ftcimport) to import FTC units.
--
--  Type !help in chat for a command reference, or click ❓ Help in the toolbar.
-- =============================================================================
--
--  FTC COMPATIBILITY NOTES
--  ───────────────────────
--  This script detects Free the Codex at load time by checking for the `FTC`
--  global table.  When FTC is present the following changes apply automatically:
--
--  • Our turn tracker hides itself and syncs to FTC phase/round callbacks
--    (onFTCPhaseStart / onFTCRoundStart).
--  • Teams panel stays live and syncs the active army from FTC turn events.
--    Each time FTC hands a turn to a player the correct team is highlighted.
--  • !ftcimport pulls every unit FTC currently knows about into our wound
--    tracker so you can use our HP bars alongside FTC's counters.
--  • !ftcunit <guid> imports a single unit card by its TTS object GUID.
--  • The toolbar is anchored to the bottom-right corner to avoid FTC's
--    left-rail UI panels.
--
--  If FTC is NOT loaded everything works identically — no stubs,
--  no errors, no silent fallbacks with misleading output.
-- =============================================================================

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local MAX_HISTORY   = 20
local MAX_UNITS     = 12
local MAX_DATACARDS = 30

------------------------------------------------------------------------
-- PLAYER SIDE TABLES
------------------------------------------------------------------------
-- Six side tables — one per player seat — placed around the play area.
-- Color and label match standard TTS seat colours.
local SIDE_TABLE_TAG = "WH40K_SideTable"
local SIDE_TABLE_CFG = {
    -- South side (Team A) — left → center → right
    { name="White",  clr={0.95,0.95,0.95},    pos={-16,1.0,-16}, rot={0,0,0}   },
    { name="Brown",  clr={0.55,0.27,0.07},     pos={  0,1.0,-18}, rot={0,0,0}   },
    { name="Red",    clr={0.86,0.10,0.10},     pos={ 16,1.0,-16}, rot={0,0,0}   },
    -- North side (Team B) — right → center → left (mirrored)
    { name="Orange", clr={0.96,0.42,0.07},     pos={ 16,1.0, 16}, rot={0,180,0} },
    { name="Green",  clr={0.19,0.70,0.17},     pos={  0,1.0, 18}, rot={0,180,0} },
    { name="Teal",   clr={0.13,0.85,0.60},     pos={-16,1.0, 16}, rot={0,180,0} },
}
local sideTableGuids = {}

-- Spawn (or re-spawn) all six side tables.
function spawnSideTables()
    clearSideTables()
    for _, cfg in ipairs(SIDE_TABLE_CFG) do
        local obj = spawnObject({
            type     = "BlockRectangle",
            position = cfg.pos,
            rotation = cfg.rot,
            scale    = {7, 0.2, 5},
            color    = cfg.clr,
        })
        obj.setName(cfg.name .. " — Player Area")
        obj.setDescription("Dice · Tokens · Reserves")
        obj.addTag(SIDE_TABLE_TAG)
        table.insert(sideTableGuids, obj.getGUID())
    end
    log("Player side tables placed — drag them wherever you like!")
end

-- When FTC is active, move every DiceMat object onto its matching side table
-- (one mat per table, cycling if there are more mats than tables).
function positionDiceMatsForFTC()
    local mats = {}
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("DiceMat") then
            table.insert(mats, obj)
        end
    end
    if #mats == 0 then
        log("No DiceMat objects found — tag an object 'DiceMat' to enable auto-announce.")
        return
    end
    for i, mat in ipairs(mats) do
        local cfg = SIDE_TABLE_CFG[((i - 1) % #SIDE_TABLE_CFG) + 1]
        -- Place on top of the side table surface (table Y + half-thickness + small gap)
        local targetPos = { cfg.pos[1], cfg.pos[2] + 0.35, cfg.pos[3] }
        mat.setPositionSmooth(targetPos, false, true)
        mat.setRotationSmooth({ cfg.rot[1], cfg.rot[2], cfg.rot[3] })
        mat.setName("DiceMat — " .. cfg.name)
    end
    log(#mats .. " dice mat(s) moved to player side tables.")
end

-- Destroy all tracked side tables.
function clearSideTables()
    for _, guid in ipairs(sideTableGuids) do
        local obj = getObjectFromGUID(guid)
        if obj then obj.destruct() end
    end
    sideTableGuids = {}
end

------------------------------------------------------------------------
-- DATA CARDS STATE
------------------------------------------------------------------------
-- Each entry: { name, faction, M, T, Sv, W, Ld, OC, notes }
local dataCards = {}

------------------------------------------------------------------------
-- FTC COMPATIBILITY STATE
------------------------------------------------------------------------
local FTC_PRESENT = false   -- set in onLoad after FTC detection

-- Safe wrapper: call an FTC API function only when FTC is loaded
local function ftcCall(fn, ...)
    if not FTC_PRESENT then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then
        -- FTC API changed or unit no longer exists — fail silently
        return nil
    end
    return result
end

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local rollHistory = {}

local turnState = {
    round        = 1,
    phase        = 1,
    activePlayer = "Player 1",
}
local PHASES = {
    "Command Phase",
    "Movement Phase",
    "Shooting Phase",
    "Charge Phase",
    "Fight Phase",
    "Morale Phase",
}

-- FTC phase name → our phase index map
local FTC_PHASE_MAP = {
    ["command"]  = 1,
    ["movement"] = 2,
    ["shooting"] = 3,
    ["charge"]   = 4,
    ["fight"]    = 5,
    ["morale"]   = 6,
}

local woundTracker = {}
local selectedUnit = nil
local pendingUnit  = nil  -- kept for API compat

------------------------------------------------------------------------
-- TEAM / MATCH CONFIG
------------------------------------------------------------------------
-- All structured modes use exactly 2 teams.
-- FFA gives every seated player their own 1-player "army".
--
-- teamConfig.teams[i] = { name, color, players }
--   name    — display name shown in turn tracker
--   color   — hex colour for the team badge
--   players — list of TTS player colour strings ("Red", "White", …)
--
-- teamConfig.activeTeam — index of the team currently taking their turn.
-- Advances when a full set of 6 phases completes.

local TEAM_MODES = { "ffa", "2v1", "2v2", "3v2", "3v3", "3team" }

local TEAM_DEFAULTS = {
    { name = "Team Alpha",   color = "#e63946" },  -- red
    { name = "Team Bravo",   color = "#2dc653" },  -- green
    { name = "Team Charlie", color = "#4fc3f7" },  -- blue
}

-- Sizes for each mode: { teamA_size, teamB_size [, teamC_size] }
local MODE_SIZES = {
    ["ffa"]   = nil,        -- computed from seated player count
    ["2v1"]   = {2, 1},
    ["2v1r"]  = {1, 2},     -- internal alias (1 vs 2)
    ["2v2"]   = {2, 2},
    ["3v2"]   = {3, 2},
    ["3v3"]   = {3, 3},
    ["3team"] = {2, 2, 2},  -- three factions, 2 players each
}

local teamConfig = {
    mode       = "ffa",
    activeTeam = 1,
    teams      = {},
}

------------------------------------------------------------------------
-- UTILITY
------------------------------------------------------------------------
local function log(msg)
    printToAll("[WH40K] " .. tostring(msg), {r=1, g=0.8, b=0.2})
end

local function pCol(player)
    if player and player.color and Player[player.color] then
        return Player[player.color].color
    end
    return {r=1, g=1, b=1}
end

local function tableSum(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s
end

local function fmt(t)
    local p = {}
    for _, v in ipairs(t) do p[#p+1] = tostring(v) end
    return table.concat(p, ", ")
end

local function rollDice(num, sides)
    local r = {}
    for i = 1, num do r[i] = math.random(1, sides) end
    return r
end

local function pushHistory(label, results, total)
    table.insert(rollHistory, 1, {label=label, results=results, total=total})
    if #rollHistory > MAX_HISTORY then
        table.remove(rollHistory, MAX_HISTORY + 1)
    end
end

------------------------------------------------------------------------
-- FULL ATTACK SEQUENCE  (To-Hit → To-Wound → Armour Save → Damage)
--   !attack <attacks> <hit+> <wound+> <AP> <dmg> <save+>
--   e.g.    !attack 5 3 4 -1 2 3
------------------------------------------------------------------------
function fullAttackSequence(player, attacks, toHit, toWound, ap, dmg, baseSave)
    local col = pCol(player)
    local who = player and player.steam_name or "?"

    -- ── To-Hit ──────────────────────────────────────────────────────
    local hitRolls = rollDice(attacks, 6)
    local hits = 0
    for _, v in ipairs(hitRolls) do
        if v >= toHit then hits = hits + 1 end
    end
    printToAll(string.format("[%s │ Hit  ] %d+ : [%s] → %d hit(s)",
        who, toHit, fmt(hitRolls), hits), col)
    pushHistory(who .. " hit", hitRolls, hits)

    if hits == 0 then
        printToAll(string.format("[%s] No hits — sequence ends.", who), col)
        return
    end

    -- ── To-Wound ────────────────────────────────────────────────────
    local woundRolls = rollDice(hits, 6)
    local wounds = 0
    for _, v in ipairs(woundRolls) do
        if v >= toWound then wounds = wounds + 1 end
    end
    printToAll(string.format("[%s │ Wound] %d+ : [%s] → %d wound(s)",
        who, toWound, fmt(woundRolls), wounds), col)
    pushHistory(who .. " wound", woundRolls, wounds)

    if wounds == 0 then
        printToAll(string.format("[%s] No wounds — sequence ends.", who), col)
        return
    end

    -- ── Armour Save ─────────────────────────────────────────────────
    -- AP is stored as negative integer; subtracting it raises the target number
    local effectiveSave = baseSave - ap
    if effectiveSave > 6 then effectiveSave = 7 end   -- save negated

    local saveRolls = rollDice(wounds, 6)
    local saved, failed = 0, 0
    for _, v in ipairs(saveRolls) do
        if effectiveSave <= 6 and v >= effectiveSave then
            saved = saved + 1
        else
            failed = failed + 1
        end
    end
    local saveStr = effectiveSave <= 6
        and string.format("%d+ (base %d+ AP%d)", effectiveSave, baseSave, ap)
        or  string.format("N/A (AP%d negates %d+ save)", ap, baseSave)
    printToAll(string.format("[%s │ Save ] %s : [%s] → %d saved, %d failed",
        who, saveStr, fmt(saveRolls), saved, failed), col)
    pushHistory(who .. " save", saveRolls, saved)

    if failed == 0 then
        printToAll(string.format("[%s] All wounds saved!", who), col)
        return
    end

    -- ── Damage ──────────────────────────────────────────────────────
    local totalDmg = 0
    local dmgBreakdown = {}
    for i = 1, failed do
        local d
        if dmg == "d3" or dmg == "D3" then
            d = math.ceil(math.random(1, 6) / 2)
        elseif dmg == "d6" or dmg == "D6" then
            d = math.random(1, 6)
        else
            d = tonumber(dmg) or 1
        end
        dmgBreakdown[i] = d
        totalDmg = totalDmg + d
    end
    printToAll(
        string.format("[%s │ Dmg  ] %s/wound : [%s] → %d total damage",
            who, tostring(dmg), fmt(dmgBreakdown), totalDmg),
        {r=1, g=0.35, b=0.35})
    pushHistory(who .. " damage", dmgBreakdown, totalDmg)

    applyDamageToSelected(totalDmg, who)
end

------------------------------------------------------------------------
-- SAVE-ONLY ROLL
--   !save <numDice> <save+> [AP]   e.g. !save 4 3 -2
------------------------------------------------------------------------
function rollSaves(player, numDice, baseSave, ap)
    local col = pCol(player)
    local who = player and player.steam_name or "?"
    ap = ap or 0
    local effectiveSave = baseSave - ap
    if effectiveSave > 6 then effectiveSave = 7 end

    local rolls = rollDice(numDice, 6)
    local saved, failed = 0, 0
    for _, v in ipairs(rolls) do
        if effectiveSave <= 6 and v >= effectiveSave then
            saved = saved + 1
        else
            failed = failed + 1
        end
    end
    local saveStr = effectiveSave <= 6
        and string.format("%d+", effectiveSave)
        or  "impossible"
    printToAll(
        string.format("[%s │ Save ] %s (base %d+ AP%d) : [%s] → %d/%d saved",
            who, saveStr, baseSave, ap, fmt(rolls), saved, numDice), col)
    pushHistory(who .. " save", rolls, saved)
end

------------------------------------------------------------------------
-- MORALE TEST
------------------------------------------------------------------------
function moraleTest(player, leadership, modelsLost)
    local roll   = math.random(1, 6)
    local total  = roll + modelsLost
    local failed = total > leadership
    local col    = failed and {r=1,g=0.2,b=0.2} or {r=0.2,g=1,b=0.2}
    printToAll(
        string.format("[Morale] Ld%d, lost %d → rolled %d + %d = %d  →  %s",
            leadership, modelsLost, roll, modelsLost, total,
            failed and "FAILED (models flee!)" or "PASSED"), col)
end

------------------------------------------------------------------------
-- TURN TRACKER
------------------------------------------------------------------------
-- Returns a short "Army" label for the currently active team
local function activeArmyLabel()
    local t = teamConfig.teams[teamConfig.activeTeam]
    if not t then return "—" end
    if #t.players == 0 then return t.name end
    return t.name .. " (" .. table.concat(t.players, "+") .. ")"
end

local function phaseLabel()
    local teamStr = (#teamConfig.teams > 0)
        and ("  ▸ " .. activeArmyLabel())
        or  ("  [" .. turnState.activePlayer .. "]")
    return string.format("Round %d — %s%s",
        turnState.round, PHASES[turnState.phase], teamStr)
end

local function refreshTurnUI()
    if FTC_PRESENT then return end
    local t = teamConfig.teams[teamConfig.activeTeam]
    UI.setAttribute("tt_round",  "text", "Round " .. turnState.round)
    UI.setAttribute("tt_phase",  "text", PHASES[turnState.phase])
    UI.setAttribute("tt_player", "text", t and t.name or turnState.activePlayer)
    -- Colour the army label badge with the active team colour
    local teamCol = t and t.color or "#aaaacc"
    UI.setAttribute("tt_team_label", "text",  t and activeArmyLabel() or "No teams configured")
    UI.setAttribute("tt_team_label", "color", teamCol)
    for i = 1, #PHASES do
        local active = (i == turnState.phase)
        UI.setAttribute("tt_phase_btn_" .. i, "color",
            active and "#e63946" or "#2d2d44")
        UI.setAttribute("tt_phase_btn_" .. i, "textColor",
            active and "White" or "#aaaacc")
    end
    printToAll("[Turn] " .. phaseLabel(), {r=0.6, g=0.9, b=1})
end

-- Advance to the next army's turn; wraps → new round when all armies done
local function advanceArmy()
    local n = #teamConfig.teams
    if n < 2 then
        turnState.round = turnState.round + 1
        printToAll("=== Round " .. turnState.round .. " begins! ===",
            {r=1, g=0.85, b=0.1})
        return
    end
    teamConfig.activeTeam = (teamConfig.activeTeam % n) + 1
    if teamConfig.activeTeam == 1 then
        turnState.round = turnState.round + 1
        printToAll("=== Round " .. turnState.round .. " begins! ===",
            {r=1, g=0.85, b=0.1})
    else
        local t = teamConfig.teams[teamConfig.activeTeam]
        printToAll("=== " .. (t and t.name or "Next army") .. "'s turn! ===",
            {r=0.6, g=0.9, b=1})
    end
end

function nextPhase()
    if FTC_PRESENT then
        log("Turn control is handled by Free the Codex — use FTC's phase buttons.")
        return
    end
    if turnState.phase < #PHASES then
        turnState.phase = turnState.phase + 1
    else
        turnState.phase = 1
        advanceArmy()
    end
    refreshTurnUI()
    -- Sync active-player with the first player of the now-active team (for FTC compat)
    local t = teamConfig.teams[teamConfig.activeTeam]
    if t and t.players[1] then
        turnState.activePlayer = t.players[1]
    end
end

function prevPhase()
    if FTC_PRESENT then return end
    if turnState.phase > 1 then
        turnState.phase = turnState.phase - 1
    else
        -- Step back one army
        local n = #teamConfig.teams
        if n > 1 then
            teamConfig.activeTeam = ((teamConfig.activeTeam - 2) % n) + 1
            if teamConfig.activeTeam == n then
                turnState.round = math.max(1, turnState.round - 1)
            end
        elseif turnState.round > 1 then
            turnState.round = turnState.round - 1
        end
        turnState.phase = #PHASES
    end
    refreshTurnUI()
end

function setPhase(player, phaseIndex)
    if FTC_PRESENT then return end
    phaseIndex = tonumber(phaseIndex)
    if phaseIndex and PHASES[phaseIndex] then
        turnState.phase = phaseIndex
        refreshTurnUI()
    end
end

function resetTurn()
    if FTC_PRESENT then return end
    turnState.round = 1
    turnState.phase = 1
    turnState.activePlayer = "Player 1"
    teamConfig.activeTeam  = 1
    refreshTurnUI()
    log("Turn tracker reset.")
end

function toggleTurnTracker()
    if FTC_PRESENT then
        log("Turn control is handled by Free the Codex.")
        return
    end
    local vis = UI.getAttribute("turn_tracker_panel", "active")
    if vis == "true" or vis == true then
        UI.hide("turn_tracker_panel")
    else
        UI.show("turn_tracker_panel")
    end
end

-- ── FTC phase/round callbacks ────────────────────────────────────────
-- FTC fires these as global functions; we override them here.
-- Always call the previous definition first so other mods can chain.

-- ── Sync helper: find which team owns a given player colour ──────────
local function syncTeamFromPlayer(playerColor)
    if not playerColor or #teamConfig.teams == 0 then return end
    local lc = playerColor:lower()
    for i, t in ipairs(teamConfig.teams) do
        for _, p in ipairs(t.players) do
            if p:lower() == lc then
                teamConfig.activeTeam = i
                return
            end
        end
    end
    -- Player not found in any team — leave activeTeam unchanged.
end

local _prev_onFTCPhaseStart = onFTCPhaseStart  -- may be nil
function onFTCPhaseStart(phaseName, playerColor)
    if _prev_onFTCPhaseStart then _prev_onFTCPhaseStart(phaseName, playerColor) end
    local idx = FTC_PHASE_MAP[phaseName and phaseName:lower() or ""]
    if idx then
        turnState.phase = idx
        turnState.activePlayer = playerColor or turnState.activePlayer
    end
    -- Keep the teams panel's active-army label in sync
    syncTeamFromPlayer(playerColor)
    refreshTeamUI()
    printToAll(
        string.format("[FTC │ Turn] Round %d — %s  [%s]  ▸ %s",
            turnState.round,
            phaseName or "?",
            playerColor or "?",
            activeArmyLabel()),
        {r=0.6, g=0.9, b=1})
end

local _prev_onFTCRoundStart = onFTCRoundStart
function onFTCRoundStart(roundNumber)
    if _prev_onFTCRoundStart then _prev_onFTCRoundStart(roundNumber) end
    turnState.round = roundNumber or (turnState.round + 1)
    turnState.phase = 1
    -- Don't reset activeTeam here — onFTCTurnStart fires immediately after
    -- and will sync to the correct army for whoever goes first.
    log("=== FTC Round " .. turnState.round .. " begins! ===")
    refreshTeamUI()
end

-- FTC fires onFTCTurnStart(playerColor) each time turn ownership swaps.
-- We use this to keep the Teams panel's active army badge current.
local _prev_onFTCTurnStart = onFTCTurnStart
function onFTCTurnStart(playerColor)
    if _prev_onFTCTurnStart then _prev_onFTCTurnStart(playerColor) end
    turnState.activePlayer = playerColor or turnState.activePlayer
    syncTeamFromPlayer(playerColor)
    refreshTeamUI()

    -- Announce army change in chat so all players see the handoff
    local t = teamConfig.teams[teamConfig.activeTeam]
    if t then
        -- Safe hex→RGB parse: colour strings are "#rrggbb"; fall back on cyan
        local function hexByte(s, pos)
            return (tonumber("0x" .. (s:sub(pos, pos+1))) or 0) / 255
        end
        local col = (t.color and #t.color == 7)
            and { r = hexByte(t.color,2), g = hexByte(t.color,4), b = hexByte(t.color,6) }
            or  { r = 0.6, g = 0.9, b = 1 }
        printToAll(
            string.format("[Teams] %s's turn — army: %s",
                playerColor or "?", activeArmyLabel()),
            col)
    else
        log("FTC: " .. tostring(playerColor) .. "'s turn.")
    end
end

------------------------------------------------------------------------
-- TEAMS & MATCH FORMAT
------------------------------------------------------------------------

-- Returns a flat list of player colour strings for all seated players.
local function seatedColors()
    local list = {}
    for _, p in ipairs(Player.getPlayers()) do
        if p.seated then list[#list+1] = p.color end
    end
    return list
end

-- Refresh the Teams panel display (mode buttons, player lists, active label)
local function refreshTeamUI()
    -- Mode buttons: highlight the active mode
    for _, m in ipairs(TEAM_MODES) do
        local active = (m == teamConfig.mode)
        UI.setAttribute("tm_btn_" .. m, "color",
            active and "#e63946" or "#2d2d44")
        UI.setAttribute("tm_btn_" .. m, "textColor",
            active and "White" or "#aaaacc")
    end

    local isFFA    = (teamConfig.mode == "ffa")
    local is3Team  = (teamConfig.mode == "3team")
    local showTeams = not isFFA

    -- Show/hide the main column block and FFA block
    UI.setAttribute("tm_team_columns", "active", showTeams and "true" or "false")
    UI.setAttribute("tm_ffa_info",     "active", isFFA     and "true" or "false")

    -- Show/hide the third team column, its VS separator, and its assign button
    UI.setAttribute("tm_t3_col",    "active", is3Team and "true" or "false")
    UI.setAttribute("tm_vs2",       "active", is3Team and "true" or "false")
    UI.setAttribute("tm_t3_assign", "active", is3Team and "true" or "false")

    -- Widen panel for 3-team so the three columns breathe
    UI.setAttribute("teams_panel", "width", is3Team and "580" or "430")

    -- Update all three team columns
    for ti = 1, 3 do
        local t = teamConfig.teams[ti]
        if t then
            local pStr = #t.players > 0
                and table.concat(t.players, ", ")
                or  "(none)"
            UI.setAttribute("tm_t" .. ti .. "_name",    "text",  t.name)
            UI.setAttribute("tm_t" .. ti .. "_players", "text",  pStr)
            UI.setAttribute("tm_t" .. ti .. "_name",    "color", t.color)
        end
    end

    -- FFA list
    if isFFA then
        local lines = {}
        for i, t in ipairs(teamConfig.teams) do
            local marker = (i == teamConfig.activeTeam) and "▶ " or "  "
            lines[#lines+1] = marker .. t.name ..
                (#t.players > 0 and " — " .. t.players[1] or "")
        end
        UI.setAttribute("tm_ffa_list", "text",
            #lines > 0 and table.concat(lines, "\n") or "(no players seated)")
    end

    -- Active army badge
    local t = teamConfig.teams[teamConfig.activeTeam]
    local lblCol = t and t.color or "#aaaacc"
    UI.setAttribute("tm_active_label", "text",  activeArmyLabel())
    UI.setAttribute("tm_active_label", "color", lblCol)

    -- Status line
    local n = #teamConfig.teams
    UI.setAttribute("tm_status", "text",
        string.format("Mode: %s  •  %d arm%s configured",
            teamConfig.mode:upper(), n, n == 1 and "y" or "ies"))
end

-- Build (or rebuild) teams from seated players for the given mode
function setTeamMode(modeStr)
    modeStr = modeStr and modeStr:lower() or "ffa"
    -- Normalise: accept "1v2" as "2v1"
    if modeStr == "1v2" then modeStr = "2v1" end

    -- Validate
    local valid = false
    for _, m in ipairs(TEAM_MODES) do
        if m == modeStr then valid = true break end
    end
    if not valid then
        log("Unknown mode '" .. modeStr .. "'. Valid: ffa 2v1 2v2 3v2 3v3 3team")
        return
    end

    teamConfig.mode       = modeStr
    teamConfig.activeTeam = 1
    teamConfig.teams      = {}

    local colors = seatedColors()

    if modeStr == "ffa" then
        -- One army per seated player
        local ffaCols = { "#e63946","#2dc653","#f4a261",
                          "#7ab8f5","#cc99ff","#aaffaa",
                          "#ffcc44","#ff88bb" }
        for i, c in ipairs(colors) do
            teamConfig.teams[#teamConfig.teams+1] = {
                name    = c .. "'s Army",
                color   = ffaCols[i] or "#aaaacc",
                players = { c },
            }
        end
        if #teamConfig.teams == 0 then
            -- No one seated yet — placeholder so UI doesn't crash
            teamConfig.teams = { { name="Army 1", color="#aaaacc", players={} } }
        end
    else
        -- Structured team mode: create exactly as many teams as there are size entries
        local sizes = MODE_SIZES[modeStr] or {2, 2}
        for ti = 1, #sizes do
            local def = TEAM_DEFAULTS[ti] or { name = "Team " .. ti, color = "#aaaacc" }
            teamConfig.teams[ti] = {
                name    = def.name,
                color   = def.color,
                players = {},
            }
        end
        local cursor = 1
        for ti, sz in ipairs(sizes) do
            for _ = 1, sz do
                if colors[cursor] then
                    teamConfig.teams[ti].players[#teamConfig.teams[ti].players+1]
                        = colors[cursor]
                    cursor = cursor + 1
                end
            end
        end
    end

    log(string.format("Match format set to %s  (%d arm%s).",
        modeStr:upper(), #teamConfig.teams,
        #teamConfig.teams == 1 and "y" or "ies"))
    refreshTeamUI()
    refreshTurnUI()
end

-- Auto-assign seated players into the current mode (re-runs distribution)
function autoAssignTeams()
    setTeamMode(teamConfig.mode)
    log("Auto-assigned seated players → " .. teamConfig.mode:upper())
end

-- Move a player (by their TTS colour) to the given team index (1 or 2)
function assignToTeam(teamIndexStr)
    local teamIndex = tonumber(teamIndexStr)
    local color     = UI.getValue("tm_assign_color_input")
    if not teamIndex or not color or color == "" then
        log('Enter a player colour in the Teams panel first  (e.g. "Red").')
        return
    end
    -- Remove from wherever they currently are
    for _, t in ipairs(teamConfig.teams) do
        for j, p in ipairs(t.players) do
            if p:lower() == color:lower() then
                table.remove(t.players, j)
                break
            end
        end
    end
    -- Add to the target team (in 2-team modes, clamp to 1 or 2)
    local t = teamConfig.teams[teamIndex]
    if t then
        t.players[#t.players+1] = color
        UI.setValue("tm_assign_color_input", "")
        log(color .. " → " .. t.name)
        refreshTeamUI()
        refreshTurnUI()
    else
        log("Team " .. teamIndex .. " doesn't exist. Run !setmode first.")
    end
end

-- Rename a team (1 or 2) using the text field in the panel
function renameTeam(teamIndexStr)
    local ti   = tonumber(teamIndexStr)
    local name = UI.getValue("tm_t" .. (ti or 0) .. "_name_input")
    local t    = ti and teamConfig.teams[ti]
    if not t or not name or name == "" then
        log("Enter a new name in the rename field first.")
        return
    end
    t.name = name
    UI.setValue("tm_t" .. ti .. "_name_input", "")
    log("Team " .. ti .. " renamed to: " .. name)
    refreshTeamUI()
    refreshTurnUI()
end

-- Manually step the active army forward / backward without advancing phase
function nextArmy()
    local n = #teamConfig.teams
    if n < 2 then log("Only one army configured.") return end
    teamConfig.activeTeam = (teamConfig.activeTeam % n) + 1
    local t = teamConfig.teams[teamConfig.activeTeam]
    printToAll("▶ Active army: " .. (t and t.name or "?"),
        t and {r=0.6,g=0.9,b=1} or {r=1,g=1,b=1})
    refreshTeamUI()
    refreshTurnUI()
end

function prevArmy()
    local n = #teamConfig.teams
    if n < 2 then log("Only one army configured.") return end
    teamConfig.activeTeam = ((teamConfig.activeTeam - 2) % n) + 1
    local t = teamConfig.teams[teamConfig.activeTeam]
    printToAll("◀ Active army: " .. (t and t.name or "?"),
        t and {r=0.6,g=0.9,b=1} or {r=1,g=1,b=1})
    refreshTeamUI()
    refreshTurnUI()
end

function toggleTeamsPanel()
    local vis = UI.getAttribute("teams_panel", "active")
    if vis == "true" or vis == true then
        UI.hide("teams_panel")
    else
        UI.show("teams_panel")
    end
end

function toggleHelpPanel()
    local vis = UI.getAttribute("help_panel", "active")
    if vis == "true" or vis == true then
        UI.hide("help_panel")
    else
        UI.show("help_panel")
    end
end

------------------------------------------------------------------------
-- WOUND TRACKER — model-aware damage allocation
--
--  Each unit stores:
--    woundsPerModel      — W characteristic from the datasheet
--    totalModels         — starting model count
--    models              — currently living models
--    currentModelWounds  — wounds left on the front model being damaged
--    max / current       — derived totals for the HP bar
--
--  Damage is allocated one wound at a time to the front model.
--  When that model reaches 0 it is removed and remaining damage
--  carries over to the next, exactly per the WH40K core rules.
------------------------------------------------------------------------

-- Recompute the derived totals from model state
local function syncUnitTotals(unit)
    unit.max     = unit.totalModels * unit.woundsPerModel
    unit.current = (unit.models > 0)
        and ((unit.models - 1) * unit.woundsPerModel + unit.currentModelWounds)
        or  0
end

local function refreshWoundUI()
    for i = 1, MAX_UNITS do
        local unit = woundTracker[i]
        if unit then
            UI.setAttribute("wt_row_"  .. i, "active", "true")
            UI.setAttribute("wt_name_" .. i, "text",   unit.name)

            local hp  = math.max(0, unit.current)
            local max = math.max(1, unit.max)
            local pct = math.floor((hp / max) * 100)

            local barCol = pct > 60 and "#2dc653"
                        or pct > 30 and "#f4a261"
                        or             "#e63946"

            -- Model count badge e.g. "4/5×2W"
            local wpm      = unit.woundsPerModel or 1
            local mCur     = unit.models         or 1
            local mTot     = unit.totalModels    or 1
            local modelStr = mTot > 1
                and string.format("%d/%d×%dW", mCur, mTot, wpm)
                or  string.format("%dW", wpm)

            UI.setAttribute("wt_models_".. i, "text",       modelStr)
            UI.setAttribute("wt_hp_"    .. i, "text",       hp .. "/" .. max)
            UI.setAttribute("wt_bar_"   .. i, "fillAmount",  tostring(pct / 100))
            UI.setAttribute("wt_bar_"   .. i, "color",       barCol)

            local ftcBadge = (unit.ftcGuid and unit.ftcGuid ~= "") and "⚙" or " "
            UI.setAttribute("wt_ftc_" .. i, "text", ftcBadge)
        else
            UI.setAttribute("wt_row_" .. i, "active", "false")
        end
    end
end

local function findUnit(name)
    name = name:lower()
    for i, u in ipairs(woundTracker) do
        if u.name:lower() == name then return i, u end
    end
    return nil
end

local function findUnitByGuid(guid)
    for i, u in ipairs(woundTracker) do
        if u.ftcGuid == guid then return i, u end
    end
    return nil
end

-- addUnit(name, woundsPerModel, modelsCount [, ftcGuid])
-- woundsPerModel = W stat from the datasheet (default 1)
-- modelsCount    = how many models in the unit  (default 1)
function addUnit(name, woundsPerModel, modelsCount, ftcGuid)
    woundsPerModel = tonumber(woundsPerModel) or 1
    modelsCount    = tonumber(modelsCount)    or 1
    ftcGuid        = ftcGuid or ""

    if #woundTracker >= MAX_UNITS then
        log("Wound tracker full (" .. MAX_UNITS .. " units max).")
        return
    end

    local idx = findUnit(name)
    if idx then
        local u = woundTracker[idx]
        u.woundsPerModel     = woundsPerModel
        u.totalModels        = modelsCount
        u.models             = modelsCount
        u.currentModelWounds = woundsPerModel
        u.ftcGuid            = ftcGuid
        syncUnitTotals(u)
        log(string.format("Updated: %s  (%d model(s) × %dW = %dW total)",
            name, modelsCount, woundsPerModel, u.max))
    else
        local u = {
            name             = name,
            woundsPerModel   = woundsPerModel,
            totalModels      = modelsCount,
            models           = modelsCount,
            currentModelWounds = woundsPerModel,
            ftcGuid          = ftcGuid,
            max              = 0,
            current          = 0,
        }
        syncUnitTotals(u)
        table.insert(woundTracker, u)
        log(string.format("Added: %s  (%d model(s) × %dW = %dW total)%s",
            name, modelsCount, woundsPerModel, u.max,
            ftcGuid ~= "" and " [FTC linked]" or ""))
    end
    refreshWoundUI()
end

function removeUnit(indexStr)
    local i = tonumber(indexStr)
    if i and woundTracker[i] then
        log("Removed: " .. woundTracker[i].name)
        table.remove(woundTracker, i)
        refreshWoundUI()
    end
end

-- ── Core model-aware damage engine ───────────────────────────────────
-- Allocates `totalDamage` one wound at a time to the front model.
-- Returns (modelsSlain, woundsDealt).
local function applyModelAwareDamage(unit, totalDamage)
    local modelsSlain = 0
    local woundsDealt = 0
    local dmg = totalDamage

    while dmg > 0 and unit.models > 0 do
        if dmg >= unit.currentModelWounds then
            -- Front model dies
            dmg           = dmg - unit.currentModelWounds
            woundsDealt   = woundsDealt + unit.currentModelWounds
            unit.models   = unit.models - 1
            modelsSlain   = modelsSlain + 1
            unit.currentModelWounds = unit.models > 0 and unit.woundsPerModel or 0
        else
            -- Wound but don't kill
            unit.currentModelWounds = unit.currentModelWounds - dmg
            woundsDealt = woundsDealt + dmg
            dmg = 0
        end
    end

    syncUnitTotals(unit)
    return modelsSlain, woundsDealt
end

-- ── Model-aware heal ─────────────────────────────────────────────────
-- Heals the currently-wounded model first, then restores full models.
local function applyModelAwareHeal(unit, amount)
    local healed = 0
    local gained = 0

    -- 1. Top up the currently damaged model
    if unit.models > 0 then
        local gap = unit.woundsPerModel - unit.currentModelWounds
        local restore = math.min(gap, amount)
        unit.currentModelWounds = unit.currentModelWounds + restore
        healed = healed + restore
        amount = amount - restore
    end

    -- 2. Resurrect full models with remaining heal
    while amount >= unit.woundsPerModel and unit.models < unit.totalModels do
        unit.models             = unit.models + 1
        unit.currentModelWounds = unit.woundsPerModel
        amount = amount - unit.woundsPerModel
        gained = gained + 1
    end
    -- Partial heal onto a new model if possible
    if amount > 0 and unit.models < unit.totalModels then
        unit.models             = unit.models + 1
        unit.currentModelWounds = math.min(amount, unit.woundsPerModel)
        gained = gained + 1
    end

    syncUnitTotals(unit)
    return healed, gained
end

-- ── Public wound / heal functions ────────────────────────────────────

function applyWounds(name, amount)
    amount = tonumber(amount) or 0
    local idx, unit = findUnit(name)
    if not unit then log("Unit not found: " .. tostring(name)) return end

    local slain, dealt = applyModelAwareDamage(unit, amount)

    -- FTC bridge
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function() FTC.ApplyWounds(unit.ftcGuid, dealt) end)
    end

    local col = unit.current == 0 and {r=1,g=0.2,b=0.2} or {r=1,g=0.85,b=0.1}
    local msg = string.format("[Wounds] %s  −%d wounds", unit.name, dealt)
    if slain > 0 then
        msg = msg .. string.format("  ☠ %d model(s) slain", slain)
    end
    msg = msg .. string.format("  → %d/%d W  (%d/%d models)",
        unit.current, unit.max, unit.models, unit.totalModels)
    printToAll(msg, col)

    if unit.current == 0 then
        printToAll(string.format("[Wounds] ☠  %s is DESTROYED!", unit.name),
            {r=1, g=0.2, b=0.2})
    end
    refreshWoundUI()
end

function healUnit(name, amount)
    amount = tonumber(amount) or 1
    local idx, unit = findUnit(name)
    if not unit then log("Unit not found: " .. tostring(name)) return end

    local healed, gained = applyModelAwareHeal(unit, amount)

    -- FTC bridge
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function()
            if FTC.HealWounds then FTC.HealWounds(unit.ftcGuid, healed) end
        end)
    end

    local msg = string.format("[Wounds] %s  +%dW healed", unit.name, healed)
    if gained > 0 then
        msg = msg .. string.format("  ✚ %d model(s) restored", gained)
    end
    msg = msg .. string.format("  → %d/%d W  (%d/%d models)",
        unit.current, unit.max, unit.models, unit.totalModels)
    printToAll(msg, {r=0.2, g=1, b=0.4})
    refreshWoundUI()
end

function selectUnit(indexStr)
    selectedUnit = tonumber(indexStr)
    local u = selectedUnit and woundTracker[selectedUnit]
    if u then
        UI.setAttribute("wt_selected_label", "text",
            string.format("Target: %s  (%d/%d models)%s",
                u.name, u.models, u.totalModels,
                u.ftcGuid ~= "" and " ⚙" or ""))
    end
end

function applyDamageToSelected(amount, sourceLabel)
    if not selectedUnit then return end
    local unit = woundTracker[selectedUnit]
    if not unit then selectedUnit = nil return end

    local slain, dealt = applyModelAwareDamage(unit, amount)

    -- FTC bridge
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function() FTC.ApplyWounds(unit.ftcGuid, dealt) end)
    end

    local col = unit.current == 0 and {r=1,g=0.2,b=0.2} or {r=1,g=0.85,b=0.1}
    local msg = string.format("[Wounds] %s → %s  −%d damage",
        sourceLabel or "?", unit.name, dealt)
    if slain > 0 then
        msg = msg .. string.format("  ☠ %d model(s) slain", slain)
    end
    msg = msg .. string.format("  → %d/%d W  (%d/%d models)",
        unit.current, unit.max, unit.models, unit.totalModels)
    printToAll(msg, col)

    if unit.current == 0 then
        printToAll(string.format("[Wounds] ☠  %s is DESTROYED!", unit.name),
            {r=1, g=0.2, b=0.2})
    end
    refreshWoundUI()
end

function woundBtnMinus(indexStr)
    local unit = tonumber(indexStr) and woundTracker[tonumber(indexStr)]
    if unit then applyWounds(unit.name, 1) end
end

function woundBtnPlus(indexStr)
    local unit = tonumber(indexStr) and woundTracker[tonumber(indexStr)]
    if unit then healUnit(unit.name, 1) end
end

function toggleWoundTracker()
    local vis = UI.getAttribute("wound_tracker_panel", "active")
    if vis == "true" or vis == true then
        UI.hide("wound_tracker_panel")
    else
        UI.show("wound_tracker_panel")
    end
end

-- ── FTC sync callbacks ───────────────────────────────────────────────
-- FTC fires onFTCUnitWounded(guid, amount, currentWounds) when its own
-- wound counters change (e.g. player clicks the FTC card directly).
-- We mirror that back into our tracker so both stay in sync.

local _prev_onFTCUnitWounded = onFTCUnitWounded
function onFTCUnitWounded(guid, amount, currentWounds)
    if _prev_onFTCUnitWounded then _prev_onFTCUnitWounded(guid, amount, currentWounds) end
    local idx, unit = findUnitByGuid(guid)
    if unit and currentWounds ~= nil then
        unit.current = tonumber(currentWounds) or unit.current
        refreshWoundUI()
    end
end

local _prev_onFTCUnitDestroyed = onFTCUnitDestroyed
function onFTCUnitDestroyed(guid)
    if _prev_onFTCUnitDestroyed then _prev_onFTCUnitDestroyed(guid) end
    local idx, unit = findUnitByGuid(guid)
    if unit then
        unit.current = 0
        refreshWoundUI()
        printToAll(string.format("[FTC │ Wounds] ☠  %s is DESTROYED!", unit.name),
            {r=1, g=0.2, b=0.2})
    end
end

------------------------------------------------------------------------
-- FTC IMPORT  —  pull FTC's unit roster into our wound tracker
------------------------------------------------------------------------

-- Import a single unit by TTS object GUID
-- FTC stores unit data on the object itself via getTable("Data") or similar
function importFtcUnit(guid)
    if not FTC_PRESENT then
        log("Free the Codex is not loaded.")
        return
    end
    local obj = getObjectFromGUID(guid)
    if not obj then
        log("Object not found: " .. tostring(guid))
        return
    end

    -- FTC unit cards store their data in a Lua table on the object.
    -- Try the two most common FTC data table names.
    local data = nil
    pcall(function() data = obj.getTable("Data") end)
    if not data then
        pcall(function() data = obj.getTable("UnitData") end)
    end

    local name      = (data and data.name)      or obj.getName()
    local maxWounds = (data and data.wounds)     or
                      (data and data.maxWounds)  or 1
    local curWounds = (data and data.curWounds)  or maxWounds

    if not name or name == "" then
        log("Could not read unit name from GUID " .. guid)
        return
    end

    -- FTC gives wounds-per-model and model count separately when available
    local wpm    = (data and (data.woundsPerModel or data.wounds_per_model)) or maxWounds
    local models = (data and (data.models or data.modelCount or data.count)) or 1

    -- Upsert into our tracker, preserving current state from FTC
    local idx = findUnit(name)
    if idx then
        local u = woundTracker[idx]
        u.woundsPerModel     = wpm
        u.totalModels        = models
        u.models             = models
        u.currentModelWounds = wpm
        u.ftcGuid            = guid
        syncUnitTotals(u)
    else
        if #woundTracker >= MAX_UNITS then
            log("Wound tracker full — could not import " .. name)
            return
        end
        local u = {
            name             = name,
            woundsPerModel   = wpm,
            totalModels      = models,
            models           = models,
            currentModelWounds = wpm,
            ftcGuid          = guid,
            max = 0, current = 0,
        }
        syncUnitTotals(u)
        table.insert(woundTracker, u)
    end
    log(string.format("FTC import: %s  (%d×%dW)", name, models, wpm))
    refreshWoundUI()
end

-- Bulk-import every unit FTC currently tracks
function importAllFtcUnits()
    if not FTC_PRESENT then
        log("Free the Codex is not loaded.")
        return
    end

    local units = ftcCall(function() return FTC.GetUnits() end)
    if not units or #units == 0 then
        log("No FTC units found. Make sure units are placed on the board.")
        return
    end

    local imported = 0
    for _, u in ipairs(units) do
        local guid   = u.guid or u.GUID
        local name   = u.name or u.Name
        local wpm    = u.woundsPerModel or u.wounds or u.Wounds or 1
        local models = u.models or u.modelCount or u.count or 1

        if name and guid then
            local idx = findUnit(name)
            if idx then
                local t = woundTracker[idx]
                t.woundsPerModel     = wpm
                t.totalModels        = models
                t.models             = models
                t.currentModelWounds = wpm
                t.ftcGuid            = guid
                syncUnitTotals(t)
            elseif #woundTracker < MAX_UNITS then
                local t = {
                    name             = name,
                    woundsPerModel   = wpm,
                    totalModels      = models,
                    models           = models,
                    currentModelWounds = wpm,
                    ftcGuid          = guid,
                    max = 0, current = 0,
                }
                syncUnitTotals(t)
                table.insert(woundTracker, t)
            end
            imported = imported + 1
        end
    end

    log(string.format("FTC: imported %d unit(s).", imported))
    refreshWoundUI()
end

------------------------------------------------------------------------
-- YELLOSCRIBE PANEL
------------------------------------------------------------------------
function openYelloscribe()   UI.show("yelloscribe_panel")  end
function closeYelloscribe()  UI.hide("yelloscribe_panel")  end

-- ── Data Cards ────────────────────────────────────────────────────────

-- Read the current Yelloscribe URL and pre-fill the unit name field
-- by converting the last URL path segment from slug to title case.
function pinCurrentYelloscribePage()
    local url  = UI.getAttribute("ys_browser", "url") or ""
    local slug = url:match("/([^/?#]+)%s*$") or ""
    -- Ignore root / domain segments that aren't unit names
    if slug ~= "" and not slug:find("%.") and slug ~= "yelloscribe.com" then
        local name = slug:gsub("[%-_]+", " ")
                        :gsub("(%a)([%a]*)", function(a, b)
                            return a:upper() .. b:lower()
                         end)
        UI.setValue("dc_name_input", name)
    end
end

function saveDataCard()
    local name = UI.getValue("dc_name_input")
    if not name or name == "" then
        log("Enter a unit name before saving a data card.")
        return
    end
    if #dataCards >= MAX_DATACARDS then
        log("Data card limit (" .. MAX_DATACARDS .. ") reached — remove one first.")
        return
    end
    dataCards[#dataCards + 1] = {
        name    = name,
        faction = UI.getValue("dc_faction_input") or "",
        M       = UI.getValue("dc_M_input")       or "",
        T       = UI.getValue("dc_T_input")       or "",
        Sv      = UI.getValue("dc_Sv_input")      or "",
        W       = UI.getValue("dc_W_input")       or "",
        Ld      = UI.getValue("dc_Ld_input")      or "",
        OC      = UI.getValue("dc_OC_input")      or "",
        notes   = UI.getValue("dc_notes_input")   or "",
    }
    for _, id in ipairs({ "dc_name_input","dc_faction_input","dc_M_input",
                          "dc_T_input","dc_Sv_input","dc_W_input",
                          "dc_Ld_input","dc_OC_input","dc_notes_input" }) do
        UI.setValue(id, "")
    end
    refreshDataCardsUI()
    log("📋 Data card pinned: " .. name)
end

function removeDataCard(slotStr)
    local slot = tonumber(slotStr)   -- 0-based slot from XML onClick
    if not slot then return end
    local idx = slot + 1             -- Lua 1-based index
    if dataCards[idx] then
        local n = dataCards[idx].name
        table.remove(dataCards, idx)
        refreshDataCardsUI()
        log("📋 Removed data card: " .. n)
    end
end

function refreshDataCardsUI()
    for i = 0, MAX_DATACARDS - 1 do
        local dc = dataCards[i + 1]
        if dc then
            local function val(v) return (v and v ~= "") and v or "?" end
            local stats = "M " .. val(dc.M)  ..
                         "  T " .. val(dc.T)  ..
                         "  Sv " .. val(dc.Sv) ..
                         "  W " .. val(dc.W)  ..
                         "  Ld " .. val(dc.Ld) ..
                         "  OC " .. val(dc.OC)
            UI.setAttribute("dc_slot_" .. i,              "active", "true")
            UI.setAttribute("dc_slot_" .. i .. "_name",    "text",   dc.name)
            UI.setAttribute("dc_slot_" .. i .. "_stats",   "text",   stats)
            UI.setAttribute("dc_slot_" .. i .. "_faction", "text",   dc.faction)
        else
            UI.setAttribute("dc_slot_" .. i, "active", "false")
        end
    end
    local n = #dataCards
    UI.setAttribute("dc_status", "text",
        n > 0 and (n .. " card" .. (n == 1 and "" or "s") .. " pinned")
              or "No cards pinned yet — browse Yelloscribe and click Pin")
end

function ysSetUnit()
    local name   = UI.getValue("ys_unit_name_input")
    local wpm    = tonumber(UI.getValue("ys_unit_wounds_input"))
    local models = tonumber(UI.getValue("ys_unit_models_input")) or 1
    if not name or name == "" or not wpm then
        log("Enter unit name and W (wounds/model) in the Yelloscribe panel first.")
        return
    end
    addUnit(name, wpm, models)
    UI.setValue("ys_unit_name_input",   "")
    UI.setValue("ys_unit_wounds_input", "")
    UI.setValue("ys_unit_models_input", "")
end

------------------------------------------------------------------------
-- DICE MAT — collision detection
------------------------------------------------------------------------
function onObjectCollisionEnter(registered_object, collision_info)
    local obj = collision_info.collision_object
    if not obj then return end
    if registered_object.hasTag("DiceMat") and obj.type == "Dice" then
        Wait.time(function()
            local val  = obj.getValue()
            local name = obj.getName() ~= "" and obj.getName() or "Die"
            local closest, dist = nil, math.huge
            for _, p in ipairs(Player.getPlayers()) do
                if p.seated then
                    local pd = Vector.Distance(obj.getPosition(),
                                               p.getHandTransform().position)
                    if pd < dist then closest, dist = p, pd end
                end
            end
            local pName = closest and closest.steam_name or "?"
            printToAll(
                string.format("[Dice Mat] %s's %s → %d", pName, name, val),
                {r=1, g=0.85, b=0.1})
        end, 0.6)
    end
end

------------------------------------------------------------------------
-- CHAT COMMANDS
------------------------------------------------------------------------
function onChat(message, player)
    local cmd, args = message:match("^(!%S+)%s*(.*)")
    if not cmd then return end
    cmd = cmd:lower()

    if cmd == "!roll" then
        local num, sides = args:match("(%d+)d(%d+)")
        num = tonumber(num); sides = tonumber(sides)
        if not num or not sides then
            printToColor("Usage: !roll <N>d<S>  e.g. !roll 3d6",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        local results = rollDice(num, sides)
        local total   = tableSum(results)
        printToAll(
            string.format("[%s] !roll %dd%d → [%s]  Total: %d",
                player.steam_name, num, sides, fmt(results), total),
            pCol(player))
        pushHistory(player.steam_name, results, total)
        return false

    elseif cmd == "!attack" then
        local n,h,w,ap,dmg,sv = args:match(
            "(%d+)%s+(%d+)%+?%s+(%d+)%+?%s+([%-]?%d+)%s+(%S+)%s+(%d+)")
        n=tonumber(n); h=tonumber(h); w=tonumber(w)
        ap=tonumber(ap); sv=tonumber(sv)
        if not (n and h and w and ap and dmg and sv) then
            printToColor(
                "Usage: !attack <attacks> <hit+> <wound+> <AP> <dmg> <save+>\n"..
                "  e.g. !attack 5 3 4 -1 2 3   dmg can be D3 or D6",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        fullAttackSequence(player, n, h, w, ap, dmg, sv)
        return false

    elseif cmd == "!save" then
        local nd, sv, ap = args:match("(%d+)%s+(%d+)%+?%s*([%-]?%d*)")
        nd=tonumber(nd); sv=tonumber(sv); ap=tonumber(ap) or 0
        if not (nd and sv) then
            printToColor("Usage: !save <dice> <save+> [AP]  e.g. !save 4 3 -2",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        rollSaves(player, nd, sv, ap)
        return false

    elseif cmd == "!morale" then
        local ld, lost = args:match("(%d+)%s+(%d+)")
        ld=tonumber(ld); lost=tonumber(lost)
        if not (ld and lost) then
            printToColor("Usage: !morale <Ld> <modelsLost>  e.g. !morale 8 3",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        moraleTest(player, ld, lost)
        return false

    elseif cmd == "!addunit" then
        -- Formats:
        --   !addunit "Name" <W>          — 1 model, W wounds
        --   !addunit "Name" <W> <models> — multi-model unit
        local name, wStr, mStr = args:match('"([^"]+)"%s+(%d+)%s*(%d*)')
        if not name then
            name, wStr, mStr = args:match("(%S+)%s+(%d+)%s*(%d*)")
        end
        local w = tonumber(wStr)
        local m = tonumber(mStr) or 1
        if not name or not w then
            printToColor(
                'Usage: !addunit "Name" <W/model> [models]\n'..
                '  e.g. !addunit "Intercessors" 2 5   (5 models, 2W each)\n'..
                '       !addunit "Dreadnought" 8       (1 model, 8W)',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        addUnit(name, w, m)
        return false

    elseif cmd == "!wound" then
        local name, amt = args:match('"([^"]+)"%s+(%d+)')
        if not name then name, amt = args:match("(%S+)%s+(%d+)") end
        if not name or not amt then
            printToColor('Usage: !wound "Unit Name" <amount>',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        applyWounds(name, tonumber(amt))
        return false

    elseif cmd == "!heal" then
        local name, amt = args:match('"([^"]+)"%s+(%d+)')
        if not name then name, amt = args:match("(%S+)%s+(%d+)") end
        if not name or not amt then
            printToColor('Usage: !heal "Unit Name" <amount>',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        healUnit(name, tonumber(amt))
        return false

    -- FTC-specific commands
    elseif cmd == "!ftcimport" then
        importAllFtcUnits()
        return false

    elseif cmd == "!ftcunit" then
        local guid = args:match("%S+")
        if not guid then
            printToColor("Usage: !ftcunit <GUID>  — import one FTC unit card by its TTS object GUID",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        importFtcUnit(guid)
        return false

    elseif cmd == "!next" then
        nextPhase()
        return false
    elseif cmd == "!prev" then
        prevPhase()
        return false

    elseif cmd == "!turn" then
        printToColor("[Turn] " .. phaseLabel(), player.color, {r=0.6,g=0.9,b=1})
        return false

    elseif cmd == "!yelloscribe" then
        openYelloscribe()
        return false

    elseif cmd == "!history" then
        if #rollHistory == 0 then
            printToColor("No rolls yet.", player.color, {r=0.7,g=0.7,b=0.7})
        else
            printToColor("=== Roll History ===", player.color, {r=1,g=0.8,b=0.2})
            for i, e in ipairs(rollHistory) do
                printToColor(
                    string.format("%d. [%s] [%s] → %d",
                        i, e.label, fmt(e.results), e.total),
                    player.color, {r=0.9,g=0.9,b=0.9})
                if i >= 10 then break end
            end
        end
        return false

    elseif cmd == "!teams" then
        local n = #teamConfig.teams
        printToColor(
            string.format("[Teams] Mode: %s  •  %d arm%s  •  Active: %s",
                teamConfig.mode:upper(), n, n==1 and "y" or "ies",
                activeArmyLabel()),
            player.color, {r=0.6,g=0.9,b=1})
        for i, t in ipairs(teamConfig.teams) do
            local marker = (i == teamConfig.activeTeam) and "▶ " or "  "
            printToColor(
                string.format("  %s%d. %s — players: %s",
                    marker, i, t.name,
                    #t.players > 0 and table.concat(t.players, ", ") or "(none)"),
                player.color, {r=0.9,g=0.9,b=0.9})
        end
        return false

    elseif cmd == "!setmode" then
        local mode = args:match("%S+")
        if not mode then
            printToColor(
                "Usage: !setmode <mode>  —  modes: ffa  2v1  2v2  3v2  3v3  3team\n"..
                "Auto-assigns seated players.  Use Teams panel to reassign.",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        setTeamMode(mode)
        return false

    elseif cmd == "!tables" then
        spawnSideTables()
        if FTC_PRESENT then
            Wait.frames(function() positionDiceMatsForFTC() end, 10)
        end
        return false
    elseif cmd == "!cleartables" then
        clearSideTables()
        log("Player side tables removed.")
        return false
    elseif cmd == "!help" then
        local ftcLine = FTC_PRESENT
            and "!ftcimport              — import all FTC units into wound tracker\n"..
                "!ftcunit <GUID>         — import one FTC unit card by GUID"
            or  "(FTC not detected — FTC commands inactive)"
        local h = {
            "═══════════ WH40K Mod Commands ═══════════",
            "!roll <N>d<S>                — free dice roll",
            "!attack <n> <hit> <wound> <AP> <dmg> <save>",
            "   Full sequence (hit→wound→save→damage)",
            "   e.g.  !attack 5 3 4 -1 2 3   (dmg: flat, D3, or D6)",
            "!save <dice> <save+> [AP]    — armour save roll",
            "!morale <Ld> <lost>          — morale test",
            "!addunit \"Name\" <W/model> [models]  — add unit (e.g. Intercessors 2 5)",
            "!wound  \"Name\" <amount>     — deal wounds to unit",
            "!heal   \"Name\" <amount>     — heal wounds on unit",
            ftcLine,
            "!setmode <mode>              — set match format: ffa 2v1 2v2 3v2 3v3 3team",
            "!teams                       — show current team setup",
            "!next / !prev                — advance/retreat turn phase (cycles armies)",
            "!turn                        — show current phase",
            "!yelloscribe                 — open Yelloscribe panel",
            "!history                     — last 10 rolls",
            "!tables                      — respawn player side tables",
            "!cleartables                 — remove player side tables",
            "!help                        — this message",
        }
        for _, line in ipairs(h) do
            printToColor(line, player.color, {r=0.6,g=0.9,b=1})
        end
        return false
    end
end

------------------------------------------------------------------------
-- FUNCTION PANEL TOGGLES
------------------------------------------------------------------------
local function togglePanel(id)
    local vis = UI.getAttribute(id, "active")
    if vis == "true" or vis == true then
        UI.hide(id)
    else
        UI.show(id)
    end
end

function toggleDicePanel()    togglePanel("dice_panel")    end
function toggleAttackPanel()  togglePanel("attack_panel")  end
function toggleSavePanel()    togglePanel("save_panel")    end
function toggleMoralePanel()  togglePanel("morale_panel")  end

------------------------------------------------------------------------
-- DICE ROLLER PANEL HANDLERS
------------------------------------------------------------------------

-- Quick preset roll triggered by a toolbar button: param = "NdS"
function quickRoll(param)
    local num, sides = tostring(param):match("(%d+)d(%d+)")
    num = tonumber(num); sides = tonumber(sides)
    if not num or not sides then return end
    local results = rollDice(num, sides)
    local total   = tableSum(results)
    printToAll(
        string.format("[Dice] %dd%d → [%s]  Total: %d",
            num, sides, fmt(results), total),
        {r=1, g=0.85, b=0.1})
    pushHistory("Quick " .. num .. "d" .. sides, results, total)
    UI.setAttribute("dice_result", "text",
        string.format("%dd%d → [%s]  = %d", num, sides, fmt(results), total))
end

-- Custom roll from the input fields in the dice panel
function rollCustomDice()
    local num   = tonumber(UI.getValue("dice_num_input"))   or 1
    local sides = tonumber(UI.getValue("dice_side_input"))  or 6
    num   = math.max(1, math.min(num, 30))
    sides = math.max(2, math.min(sides, 100))
    local results = rollDice(num, sides)
    local total   = tableSum(results)
    printToAll(
        string.format("[Dice] %dd%d → [%s]  Total: %d",
            num, sides, fmt(results), total),
        {r=1, g=0.85, b=0.1})
    pushHistory("Custom " .. num .. "d" .. sides, results, total)
    UI.setAttribute("dice_result", "text",
        string.format("%dd%d → [%s]  = %d", num, sides, fmt(results), total))
end

------------------------------------------------------------------------
-- ATTACK BUILDER PANEL HANDLERS
------------------------------------------------------------------------
function rollAttackPanel()
    local n   = tonumber(UI.getValue("atk_attacks")) or 1
    local h   = tonumber(UI.getValue("atk_hit"))     or 3
    local w   = tonumber(UI.getValue("atk_wound"))   or 4
    local ap  = tonumber(UI.getValue("atk_ap"))      or 0
    local dmg =          UI.getValue("atk_dmg")      or "1"
    local sv  = tonumber(UI.getValue("atk_save"))    or 5

    dmg = dmg ~= "" and dmg or "1"
    -- Clamp sensible ranges
    n  = math.max(1, math.min(n,  100))
    h  = math.max(2, math.min(h,  6))
    w  = math.max(2, math.min(w,  6))
    sv = math.max(2, math.min(sv, 6))

    -- Use a ghost player context (global, no colour)
    fullAttackSequence(nil, n, h, w, ap, dmg, sv)
end

-- Stepper helpers wired to the ▲▼ buttons next to each field
local function stepField(id, delta, minVal, maxVal)
    local v = tonumber(UI.getValue(id)) or 0
    v = math.max(minVal, math.min(maxVal, v + delta))
    UI.setValue(id, tostring(v))
end

function atkHitUp()    stepField("atk_hit",     1, 2, 6) end
function atkHitDn()    stepField("atk_hit",    -1, 2, 6) end
function atkWoundUp()  stepField("atk_wound",   1, 2, 6) end
function atkWoundDn()  stepField("atk_wound",  -1, 2, 6) end
function atkApUp()     stepField("atk_ap",      1, -6, 0) end
function atkApDn()     stepField("atk_ap",     -1, -6, 0) end
function atkSaveUp()   stepField("atk_save",    1, 2, 6) end
function atkSaveDn()   stepField("atk_save",   -1, 2, 6) end
function atkAttUp()    stepField("atk_attacks", 1, 1, 100) end
function atkAttDn()    stepField("atk_attacks",-1, 1, 100) end

------------------------------------------------------------------------
-- SAVE ROLLER PANEL HANDLERS
------------------------------------------------------------------------
function rollSavePanel()
    local nd = tonumber(UI.getValue("sv_dice"))  or 1
    local sv = tonumber(UI.getValue("sv_save"))  or 5
    local ap = tonumber(UI.getValue("sv_ap"))    or 0
    nd = math.max(1, math.min(nd, 50))
    sv = math.max(2, math.min(sv, 6))
    rollSaves(nil, nd, sv, ap)
end

function svDiceUp()  stepField("sv_dice",  1, 1, 50) end
function svDiceDn()  stepField("sv_dice", -1, 1, 50) end
function svSaveUp()  stepField("sv_save",  1, 2, 6)  end
function svSaveDn()  stepField("sv_save", -1, 2, 6)  end
function svApUp()    stepField("sv_ap",    1, -6, 0)  end
function svApDn()    stepField("sv_ap",   -1, -6, 0)  end

------------------------------------------------------------------------
-- MORALE PANEL HANDLERS
------------------------------------------------------------------------
function rollMoralePanel()
    local ld   = tonumber(UI.getValue("mr_ld"))   or 7
    local lost = tonumber(UI.getValue("mr_lost"))  or 1
    ld   = math.max(1, math.min(ld,   10))
    lost = math.max(0, math.min(lost, 20))
    moraleTest(nil, ld, lost)
end

function mrLdUp()    stepField("mr_ld",    1, 1, 10) end
function mrLdDn()    stepField("mr_ld",   -1, 1, 10) end
function mrLostUp()  stepField("mr_lost",  1, 0, 20) end
function mrLostDn()  stepField("mr_lost", -1, 0, 20) end

------------------------------------------------------------------------
-- UI XML
------------------------------------------------------------------------
-- Pre-build MAX_DATACARDS empty card slots for the Yelloscribe sidebar.
-- refreshDataCardsUI() shows/hides and fills them at runtime.
local function buildDataCardSlots()
    local rows = ""
    for i = 0, MAX_DATACARDS - 1 do
        rows = rows .. string.format([[
<Panel id="dc_slot_%d" active="false" height="72" color="#14142a" padding="4 4 3 3">
  <HorizontalLayout spacing="2">
    <VerticalLayout flexibleWidth="1" spacing="0">
      <Text id="dc_slot_%d_name"    text="" fontSize="12" fontStyle="Bold"
            color="#f0c060" height="17" alignment="MiddleLeft" />
      <Text id="dc_slot_%d_stats"   text="" fontSize="10"
            color="#aaaacc" height="13" alignment="MiddleLeft" />
      <Text id="dc_slot_%d_faction" text="" fontSize="10"
            color="#7788aa" height="13" alignment="MiddleLeft" />
    </VerticalLayout>
    <Button text="✕" fontSize="11" color="#2a0808" textColor="#ff8888"
            width="22" height="22" onClick="removeDataCard|%d" />
  </HorizontalLayout>
</Panel>
]], i, i, i, i, i)
    end
    return rows
end

local function buildWoundRows()
    local rows = ""
    for i = 1, MAX_UNITS do
        rows = rows .. string.format([[
      <HorizontalLayout id="wt_row_%d" active="false" height="40"
                        padding="4 4 2 2" spacing="3">

        <!-- Select target button -->
        <Button id="wt_sel_%d" text="●" fontSize="13" width="26" height="26"
                color="#2d2d44" textColor="#aaaacc" onClick="selectUnit|%d" />

        <!-- FTC badge -->
        <Text id="wt_ftc_%d" text=" " fontSize="11" color="#44bb88"
              alignment="MiddleCenter" width="14" />

        <!-- Unit name -->
        <Text id="wt_name_%d" text="—" fontSize="13" color="White"
              alignment="MiddleLeft" flexibleWidth="1" />

        <!-- Model count badge  e.g. "4/5×2W" -->
        <Text id="wt_models_%d" text="1W" fontSize="11" color="#aaddff"
              alignment="MiddleCenter" width="58" />

        <!-- Total wounds -->
        <Text id="wt_hp_%d" text="0/0" fontSize="12" color="#f4a261"
              alignment="MiddleCenter" width="44" />

        <!-- HP bar -->
        <Image id="wt_bar_%d" image="white" color="#2dc653"
               width="56" height="12" fillAmount="1" type="Filled"
               fillMethod="Horizontal" fillOrigin="0" />

        <!-- Wound / heal buttons -->
        <Button text="−" fontSize="15" width="24" height="26"
                color="#e63946" textColor="White" onClick="woundBtnMinus|%d" />
        <Button text="+" fontSize="15" width="24" height="26"
                color="#2dc653" textColor="White" onClick="woundBtnPlus|%d" />
        <Button text="✕" fontSize="12" width="20" height="22"
                color="#555566" textColor="#aaaacc" onClick="removeUnit|%d" />
      </HorizontalLayout>
        ]], i,i,i,i,i,i,i,i,i,i,i)
    end
    return rows
end

local function buildPhaseButtons()
    local btns = ""
    for i, name in ipairs(PHASES) do
        btns = btns .. string.format(
            '<Button id="tt_phase_btn_%d" text="%s" fontSize="12" height="30" '..
            'color="%s" textColor="%s" onClick="setPhase|%d" />\n',
            i, name,
            i == 1 and "#e63946" or "#2d2d44",
            i == 1 and "White"   or "#aaaacc",
            i)
    end
    return btns
end

-- Helper: a small labelled stepper row  <Label> [▼] [field] [▲]
local function stepRow(label, fieldId, dnFn, upFn, defaultVal, hint, w)
    w = w or 52
    return string.format([[
      <HorizontalLayout height="34" spacing="4">
        <Text text="%s" fontSize="13" color="#aaaacc"
              alignment="MiddleLeft" width="96" />
        <Button text="▼" fontSize="13" color="#2d2d44" textColor="#aaaacc"
                width="26" height="28" onClick="%s" />
        <InputField id="%s" text="%s" placeholder="%s"
                    fontSize="14" width="%d" height="28"
                    characterValidation="Integer" />
        <Button text="▲" fontSize="13" color="#2d2d44" textColor="#aaaacc"
                width="26" height="28" onClick="%s" />
      </HorizontalLayout>
    ]], label, dnFn, fieldId, tostring(defaultVal), hint, w, upFn)
end

-- Toolbar anchor: bottom-right when FTC present, bottom-centre otherwise.
local function buildXml(ftcMode)
    local toolbarPos = ftcMode and "460 -335 0" or "0 -335 0"
    local ftcBtn     = ftcMode
        and '<Button text="⚙ FTC" fontSize="12" color="#1a6644" textColor="#44ee88" width="62" onClick="importAllFtcUnits" />'
        or  ""
    local ftcBadge   = ftcMode
        and '<Text text="⚙ FTC" fontSize="11" color="#44bb88" alignment="MiddleCenter" width="52" />'
        or  ""

    return string.format([[
<Canvas>

<!-- ══════════════════════════════════════════════════════════════════
     MAIN TOOLBAR  (always visible, draggable)
     ══════════════════════════════════════════════════════════════════ -->
<HorizontalLayout id="toolbar" position="%s" width="670" height="46"
                  color="#12121e" padding="4 4 4 4" spacing="3"
                  allowDragging="true">

  <!-- Section label -->
  <Text text="WH40K" fontSize="11" fontStyle="Bold" color="#e63946"
        alignment="MiddleCenter" width="48" />

  <!-- Dice -->
  <Button text="🎲 Dice"   fontSize="12" color="#1e2a3a" textColor="#7ab8f5"
          width="68" onClick="toggleDicePanel" />

  <!-- Attack -->
  <Button text="⚔ Attack" fontSize="12" color="#1e2a3a" textColor="#f4a261"
          width="72" onClick="toggleAttackPanel" />

  <!-- Save -->
  <Button text="🛡 Save"   fontSize="12" color="#1e2a3a" textColor="#a8d8a8"
          width="66" onClick="toggleSavePanel" />

  <!-- Morale -->
  <Button text="💀 Morale" fontSize="12" color="#1e2a3a" textColor="#cc99ff"
          width="72" onClick="toggleMoralePanel" />

  <Text text="|" fontSize="14" color="#333355" alignment="MiddleCenter" width="10" />

  <!-- Turn tracker -->
  <Button text="⏱ Turn"   fontSize="12" color="#1e2a3a" textColor="#aaaacc"
          width="62" onClick="toggleTurnTracker" />

  <!-- Wound tracker -->
  <Button text="❤ HP"     fontSize="12" color="#1e2a3a" textColor="#ff7777"
          width="56" onClick="toggleWoundTracker" />

  <!-- Teams -->
  <Button text="👥 Teams"  fontSize="12" color="#1e2a3a" textColor="#ccaaff"
          width="68" onClick="toggleTeamsPanel" />

  <!-- Yelloscribe -->
  <Button text="📜 Rules"  fontSize="12" color="#1e2a3a" textColor="#aaaacc"
          width="68" onClick="openYelloscribe" />

  <!-- Help -->
  <Button text="❓ Help" fontSize="12" color="#1a1a2e" textColor="#f4d35e"
          width="62" onClick="toggleHelpPanel" />

  <!-- FTC (conditional) -->
  %s

</HorizontalLayout>


<!-- ══════════════════════════════════════════════════════════════════
     DICE ROLLER PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="dice_panel" active="false"
       position="-310 180 0" width="310" height="310"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">

    <HorizontalLayout height="38" color="#1e2a3a" padding="6 6 4 4">
      <Text text="🎲 Dice Roller" fontSize="16" fontStyle="Bold"
            color="#7ab8f5" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#1a1a2e" textColor="#aaaacc"
              width="32" height="32" onClick="toggleDicePanel" />
    </HorizontalLayout>

    <!-- Quick preset buttons — 2 rows of 4 -->
    <Text text="Quick rolls" fontSize="11" color="#555577"
          alignment="MiddleCenter" height="16" />
    <HorizontalLayout height="34" spacing="4">
      <Button text="1d6"  fontSize="14" color="#1e3050" textColor="#7ab8f5"
              flexibleWidth="1" onClick="quickRoll|1d6" />
      <Button text="2d6"  fontSize="14" color="#1e3050" textColor="#7ab8f5"
              flexibleWidth="1" onClick="quickRoll|2d6" />
      <Button text="3d6"  fontSize="14" color="#1e3050" textColor="#7ab8f5"
              flexibleWidth="1" onClick="quickRoll|3d6" />
      <Button text="4d6"  fontSize="14" color="#1e3050" textColor="#7ab8f5"
              flexibleWidth="1" onClick="quickRoll|4d6" />
    </HorizontalLayout>
    <HorizontalLayout height="34" spacing="4">
      <Button text="1d3"  fontSize="14" color="#1e3050" textColor="#aaddff"
              flexibleWidth="1" onClick="quickRoll|1d3" />
      <Button text="2d3"  fontSize="14" color="#1e3050" textColor="#aaddff"
              flexibleWidth="1" onClick="quickRoll|2d3" />
      <Button text="1d12" fontSize="13" color="#1e3050" textColor="#aaddff"
              flexibleWidth="1" onClick="quickRoll|1d12" />
      <Button text="1d20" fontSize="13" color="#1e3050" textColor="#aaddff"
              flexibleWidth="1" onClick="quickRoll|1d20" />
    </HorizontalLayout>

    <!-- Custom NdS row -->
    <Text text="Custom roll" fontSize="11" color="#555577"
          alignment="MiddleCenter" height="16" />
    <HorizontalLayout height="34" spacing="6">
      <InputField id="dice_num_input"  text="1"  placeholder="#"
                  fontSize="16" width="56" height="32"
                  characterValidation="Integer" />
      <Text text="d" fontSize="18" color="#7ab8f5"
            alignment="MiddleCenter" width="16" />
      <InputField id="dice_side_input" text="6"  placeholder="S"
                  fontSize="16" width="56" height="32"
                  characterValidation="Integer" />
      <Button text="Roll" fontSize="14" color="#1e5080" textColor="#7ab8f5"
              flexibleWidth="1" height="32" onClick="rollCustomDice" />
    </HorizontalLayout>

    <!-- Result display -->
    <Text id="dice_result" text="—" fontSize="13" color="#f4a261"
          alignment="MiddleCenter" height="26" />

  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     ATTACK BUILDER PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="attack_panel" active="false"
       position="0 120 0" width="320" height="400"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="5">

    <HorizontalLayout height="38" color="#2a1800" padding="6 6 4 4">
      <Text text="⚔ Attack Builder" fontSize="16" fontStyle="Bold"
            color="#f4a261" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#1a1a2e" textColor="#aaaacc"
              width="32" height="32" onClick="toggleAttackPanel" />
    </HorizontalLayout>

    <Text text="Hit→Wound→Save→Damage  (applies to selected HP unit)"
          fontSize="11" color="#555577" alignment="MiddleCenter" height="18" />

    %s

    <!-- Damage field (text — supports D3/D6) -->
    <HorizontalLayout height="34" spacing="4">
      <Text text="Damage" fontSize="13" color="#aaaacc"
            alignment="MiddleLeft" width="96" />
      <InputField id="atk_dmg" text="1" placeholder="1/D3/D6"
                  fontSize="14" flexibleWidth="1" height="28" />
    </HorizontalLayout>

    %s

    <Button text="⚔  Roll Full Attack Sequence" fontSize="14"
            color="#7a2000" textColor="#f4a261" height="40"
            onClick="rollAttackPanel" />

    <Text text="Damage auto-applies to selected Wound Tracker unit"
          fontSize="10" color="#444466" alignment="MiddleCenter" height="16" />

  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     SAVE ROLLER PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="save_panel" active="false"
       position="340 160 0" width="300" height="260"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">

    <HorizontalLayout height="38" color="#0d2a0d" padding="6 6 4 4">
      <Text text="🛡 Armour Save" fontSize="16" fontStyle="Bold"
            color="#a8d8a8" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#1a1a2e" textColor="#aaaacc"
              width="32" height="32" onClick="toggleSavePanel" />
    </HorizontalLayout>

    <Text text="Roll armour saves for incoming wounds"
          fontSize="11" color="#555577" alignment="MiddleCenter" height="16" />

    %s

    <Button text="🛡  Roll Saves" fontSize="15"
            color="#0d3a0d" textColor="#a8d8a8" height="40"
            onClick="rollSavePanel" />

    <Text text="AP reduces save target (AP -2 on a 3+ save = 5+)"
          fontSize="10" color="#444466" alignment="MiddleCenter" height="16" />

  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     MORALE TEST PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="morale_panel" active="false"
       position="340 -80 0" width="300" height="230"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">

    <HorizontalLayout height="38" color="#1e0a2a" padding="6 6 4 4">
      <Text text="💀 Morale Test" fontSize="16" fontStyle="Bold"
            color="#cc99ff" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#1a1a2e" textColor="#aaaacc"
              width="32" height="32" onClick="toggleMoralePanel" />
    </HorizontalLayout>

    <Text text="Roll + models lost vs Leadership"
          fontSize="11" color="#555577" alignment="MiddleCenter" height="16" />

    %s

    <Button text="💀  Roll Morale Test" fontSize="15"
            color="#2a0a3a" textColor="#cc99ff" height="40"
            onClick="rollMoralePanel" />

  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     TURN TRACKER PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="turn_tracker_panel" active="false"
       position="-310 -40 0" width="330" height="268"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">
    <HorizontalLayout height="38" color="#e63946" padding="6 6 4 4">
      <Text text="⏱ Turn Tracker" fontSize="16" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#c1121f" textColor="White"
              width="32" height="32" onClick="toggleTurnTracker" />
    </HorizontalLayout>
    <HorizontalLayout height="28" spacing="8">
      <Text id="tt_round"  text="Round 1" fontSize="15" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Text id="tt_player" text="Player 1" fontSize="12"
            color="#aaaacc" alignment="MiddleRight" flexibleWidth="1" />
    </HorizontalLayout>
    <Text id="tt_phase" text="Command Phase" fontSize="14"
          color="#f4a261" alignment="MiddleCenter" height="22" />

    <!-- Active army label — colour-coded to the team -->
    <Text id="tt_team_label" text="No teams configured" fontSize="12"
          color="#aaaacc" alignment="MiddleCenter" height="18" />

    <GridLayout cellWidth="148" cellHeight="28" spacing="4">
      %s
    </GridLayout>
    <HorizontalLayout height="32" spacing="6">
      <Button text="◀ Prev" fontSize="12" color="#2d2d44" textColor="#aaaacc"
              flexibleWidth="1" onClick="prevPhase" />
      <Button text="Reset"  fontSize="12" color="#555566" textColor="#aaaacc"
              width="60" onClick="resetTurn" />
      <Button text="Next ▶" fontSize="12" color="#e63946" textColor="White"
              flexibleWidth="1" onClick="nextPhase" />
    </HorizontalLayout>
    <!-- Army nav row -->
    <HorizontalLayout height="28" spacing="4">
      <Button text="◀ Army" fontSize="11" color="#2d2d44" textColor="#ccaaff"
              flexibleWidth="1" onClick="prevArmy" />
      <Button text="Army ▶" fontSize="11" color="#2d2d44" textColor="#ccaaff"
              flexibleWidth="1" onClick="nextArmy" />
    </HorizontalLayout>
  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     TEAMS & MATCH FORMAT PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="teams_panel" active="false"
       position="0 80 0" width="430" height="440"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">

    <!-- Header -->
    <HorizontalLayout height="38" color="#2a1a44" padding="6 6 4 4">
      <Text text="👥 Teams &amp; Match Format" fontSize="15" fontStyle="Bold"
            color="#ccaaff" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#1a1a2e" textColor="#aaaacc"
              width="32" height="32" onClick="toggleTeamsPanel" />
    </HorizontalLayout>

    <!-- Mode selector -->
    <HorizontalLayout height="34" spacing="3">
      <Text text="Mode:" fontSize="13" color="#aaaacc"
            alignment="MiddleLeft" width="46" />
      <Button id="tm_btn_ffa"    text="FFA"    fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|ffa" />
      <Button id="tm_btn_2v1"    text="2v1"    fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|2v1" />
      <Button id="tm_btn_2v2"    text="2v2"    fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|2v2" />
      <Button id="tm_btn_3v2"    text="3v2"    fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|3v2" />
      <Button id="tm_btn_3v3"    text="3v3"    fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|3v3" />
      <Button id="tm_btn_3team"  text="3-Team" fontSize="12"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|3team" />
    </HorizontalLayout>

    <!-- Auto-assign -->
    <Button text="⟳  Auto-assign seated players to teams"
            fontSize="13" color="#1e1e3a" textColor="#ccaaff" height="32"
            onClick="autoAssignTeams" />

    <!-- Status line -->
    <Text id="tm_status" text="Mode: FFA  •  0 armies configured"
          fontSize="11" color="#555577" alignment="MiddleCenter" height="16" />

    <!-- ─── TWO-TEAM COLUMNS (hidden in FFA) ─── -->
    <HorizontalLayout id="tm_team_columns" active="false"
                      spacing="6" flexibleHeight="1">

      <!-- Team 1 column -->
      <VerticalLayout flexibleWidth="1" spacing="4" color="#1a0505"
                      padding="6 6 4 4">
        <Text id="tm_t1_name" text="Team Alpha" fontSize="14"
              fontStyle="Bold" color="#e63946" alignment="MiddleCenter"
              height="22" />
        <Text text="Players:" fontSize="11" color="#888899"
              alignment="MiddleCenter" height="14" />
        <Text id="tm_t1_players" text="(none)" fontSize="13"
              color="#ffaaaa" alignment="MiddleCenter" flexibleHeight="1" />
        <!-- Rename -->
        <InputField id="tm_t1_name_input" placeholder="Rename Team 1…"
                    fontSize="12" height="26" />
        <Button text="✎ Rename" fontSize="12" color="#2d2d44" textColor="#aaaacc"
                height="26" onClick="renameTeam|1" />
      </VerticalLayout>

      <Text text="VS" fontSize="16" fontStyle="Bold" color="#555566"
            alignment="MiddleCenter" width="28" />

      <!-- Team 2 column -->
      <VerticalLayout flexibleWidth="1" spacing="4" color="#021a0a"
                      padding="6 6 4 4">
        <Text id="tm_t2_name" text="Team Bravo" fontSize="14"
              fontStyle="Bold" color="#2dc653" alignment="MiddleCenter"
              height="22" />
        <Text text="Players:" fontSize="11" color="#888899"
              alignment="MiddleCenter" height="14" />
        <Text id="tm_t2_players" text="(none)" fontSize="13"
              color="#aaffaa" alignment="MiddleCenter" flexibleHeight="1" />
        <!-- Rename -->
        <InputField id="tm_t2_name_input" placeholder="Rename Team 2…"
                    fontSize="12" height="26" />
        <Button text="✎ Rename" fontSize="12" color="#2d2d44" textColor="#aaaacc"
                height="26" onClick="renameTeam|2" />
      </VerticalLayout>

      <!-- Second VS separator — only visible in 3-team mode -->
      <Text id="tm_vs2" text="VS" fontSize="16" fontStyle="Bold" color="#555566"
            alignment="MiddleCenter" width="28" active="false" />

      <!-- Team 3 column — only visible in 3-team mode -->
      <VerticalLayout id="tm_t3_col" flexibleWidth="1" spacing="4" color="#001a2a"
                      padding="6 6 4 4" active="false">
        <Text id="tm_t3_name" text="Team Charlie" fontSize="14"
              fontStyle="Bold" color="#4fc3f7" alignment="MiddleCenter"
              height="22" />
        <Text text="Players:" fontSize="11" color="#888899"
              alignment="MiddleCenter" height="14" />
        <Text id="tm_t3_players" text="(none)" fontSize="13"
              color="#aaddff" alignment="MiddleCenter" flexibleHeight="1" />
        <!-- Rename -->
        <InputField id="tm_t3_name_input" placeholder="Rename Team 3…"
                    fontSize="12" height="26" />
        <Button text="✎ Rename" fontSize="12" color="#2d2d44" textColor="#aaaacc"
                height="26" onClick="renameTeam|3" />
      </VerticalLayout>
    </HorizontalLayout>

    <!-- ─── FFA ARMY LIST (shown in FFA mode) ─── -->
    <VerticalLayout id="tm_ffa_info" active="false" spacing="2">
      <Text text="Free-For-All — each player commands their own army"
            fontSize="11" color="#888899" alignment="MiddleCenter" height="16" />
      <Text id="tm_ffa_list" text="(no players seated)"
            fontSize="12" color="#ccaaff" alignment="MiddleLeft"
            flexibleHeight="1" />
    </VerticalLayout>

    <!-- ─── Player assign row ─── -->
    <HorizontalLayout height="30" spacing="4" color="#0a0a1a" padding="4 4 2 2">
      <Text text="Move player:" fontSize="12" color="#aaaacc"
            alignment="MiddleLeft" width="90" />
      <InputField id="tm_assign_color_input" placeholder="e.g. Red"
                  fontSize="13" flexibleWidth="1" height="26" />
      <Button text="→ T1" fontSize="12" color="#5a1010" textColor="#ffaaaa"
              width="48" height="26" onClick="assignToTeam|1" />
      <Button text="→ T2" fontSize="12" color="#0a3a15" textColor="#aaffaa"
              width="48" height="26" onClick="assignToTeam|2" />
      <Button id="tm_t3_assign" text="→ T3" fontSize="12"
              color="#0a2040" textColor="#aaddff"
              width="48" height="26" onClick="assignToTeam|3" active="false" />
    </HorizontalLayout>

    <!-- ─── Active army row ─── -->
    <HorizontalLayout height="32" spacing="4">
      <Button text="◀" fontSize="14" color="#2d2d44" textColor="#ccaaff"
              width="36" onClick="prevArmy" />
      <Text id="tm_active_label" text="—" fontSize="13"
            color="#ccaaff" alignment="MiddleCenter" flexibleWidth="1" />
      <Button text="▶" fontSize="14" color="#2d2d44" textColor="#ccaaff"
              width="36" onClick="nextArmy" />
    </HorizontalLayout>

  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     WOUND TRACKER PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="wound_tracker_panel" active="false"
       position="-310 200 0" width="430" height="570"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="4">
    <HorizontalLayout height="38" color="#e63946" padding="6 6 4 4">
      <Text text="❤ Wound Tracker" fontSize="16" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      %s
      <Button text="✕" fontSize="14" color="#c1121f" textColor="White"
              width="32" height="32" onClick="toggleWoundTracker" />
    </HorizontalLayout>
    <Text id="wt_selected_label" text="Selected: (none)"
          fontSize="12" color="#aaaacc" alignment="MiddleLeft" height="18" />
    <VerticalLayout id="wt_unit_list" spacing="2">
      %s
    </VerticalLayout>
    <!-- Quick-add row: Name | W/model | # models | Add -->
    <HorizontalLayout height="32" spacing="3" color="#0a0a1a" padding="4 4 2 2">
      <InputField id="wt_quick_name"   placeholder="Unit name"
                  fontSize="12" flexibleWidth="1" height="28" />
      <InputField id="wt_quick_wounds" placeholder="W"
                  fontSize="12" width="38" height="28"
                  characterValidation="Integer" />
      <Text text="×" fontSize="14" color="#aaddff"
            alignment="MiddleCenter" width="14" />
      <InputField id="wt_quick_models" placeholder="#"
                  fontSize="12" width="38" height="28"
                  characterValidation="Integer" />
      <Button text="Add" fontSize="12" color="#2dc653" textColor="White"
              width="44" height="28" onClick="quickAddUnit" />
    </HorizontalLayout>
    <Text text='Name | W/model × models  e.g. Intercessors 2 × 5'
          fontSize="10" color="#444466" alignment="MiddleCenter" height="16" />
  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     YELLOSCRIBE PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="yelloscribe_panel" active="false"
       position="0 0 0" width="940" height="740"
       color="#12121e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="0 0 0 0" spacing="0">
    <HorizontalLayout height="46" color="#e63946" padding="8 8 4 4" spacing="6">
      <Text text="📜 Yelloscribe — WH40K Rules Lookup" fontSize="19"
            fontStyle="Bold" color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="📋 Pin from URL" fontSize="13" color="#3a2800" textColor="#f0c060"
              width="112" height="36" onClick="pinCurrentYelloscribePage" />
      <Button text="✕" fontSize="18" color="#c1121f" textColor="White"
              width="40" height="40" onClick="closeYelloscribe" />
    </HorizontalLayout>
    <!-- Track bar: Name | W/model | × | # models | ✚ Track -->
    <HorizontalLayout height="40" color="#0a0a1a" padding="6 6 4 4" spacing="5">
      <Text text="Track:" fontSize="13" color="#aaaacc"
            alignment="MiddleLeft" width="46" />
      <InputField id="ys_unit_name_input"   placeholder="Unit name from datasheet"
                  fontSize="13" flexibleWidth="1" height="28" />
      <InputField id="ys_unit_wounds_input" placeholder="W"
                  fontSize="13" width="42" height="28"
                  characterValidation="Integer" />
      <Text text="×" fontSize="14" color="#aaddff"
            alignment="MiddleCenter" width="14" />
      <InputField id="ys_unit_models_input" placeholder="#"
                  fontSize="13" width="42" height="28"
                  characterValidation="Integer" />
      <Button text="✚ Track" fontSize="13" color="#2dc653" textColor="White"
              width="78" height="28" onClick="ysSetUnit" />
    </HorizontalLayout>

    <!-- Browser + Data Cards sidebar -->
    <HorizontalLayout spacing="0" height="654">
      <WebBrowser id="ys_browser" url="https://www.yelloscribe.com"
                  width="628" flexibleHeight="1" />

      <!-- ── Data Cards sidebar ───────────────────────────────────────── -->
      <VerticalLayout width="312" color="#0a0a14" padding="5 5 5 5" spacing="3">

        <Text text="📋 Data Cards" fontSize="13" fontStyle="Bold"
              color="#f0c060" alignment="MiddleCenter" height="19" />

        <!-- Unit name + faction -->
        <InputField id="dc_name_input" placeholder="Unit name  (auto-fills from URL)"
                    fontSize="12" height="26" />
        <InputField id="dc_faction_input" placeholder="Faction"
                    fontSize="12" height="24" />

        <!-- Stat row 1: M  T  Sv -->
        <HorizontalLayout height="26" spacing="2">
          <Text text="M"  fontSize="11" color="#888899" alignment="MiddleCenter" width="14" />
          <InputField id="dc_M_input"  placeholder='6"' fontSize="12" flexibleWidth="1" height="26" />
          <Text text="T"  fontSize="11" color="#888899" alignment="MiddleCenter" width="14" />
          <InputField id="dc_T_input"  placeholder="4"  fontSize="12" flexibleWidth="1" height="26"
                      characterValidation="Integer" />
          <Text text="Sv" fontSize="11" color="#888899" alignment="MiddleCenter" width="18" />
          <InputField id="dc_Sv_input" placeholder="3+" fontSize="12" flexibleWidth="1" height="26" />
        </HorizontalLayout>

        <!-- Stat row 2: W  Ld  OC -->
        <HorizontalLayout height="26" spacing="2">
          <Text text="W"  fontSize="11" color="#888899" alignment="MiddleCenter" width="14" />
          <InputField id="dc_W_input"  placeholder="2"  fontSize="12" flexibleWidth="1" height="26"
                      characterValidation="Integer" />
          <Text text="Ld" fontSize="11" color="#888899" alignment="MiddleCenter" width="18" />
          <InputField id="dc_Ld_input" placeholder="6+" fontSize="12" flexibleWidth="1" height="26" />
          <Text text="OC" fontSize="11" color="#888899" alignment="MiddleCenter" width="18" />
          <InputField id="dc_OC_input" placeholder="2"  fontSize="12" flexibleWidth="1" height="26"
                      characterValidation="Integer" />
        </HorizontalLayout>

        <InputField id="dc_notes_input" placeholder="Special abilities / notes…"
                    fontSize="11" height="24" />

        <!-- Action buttons -->
        <HorizontalLayout height="28" spacing="3">
          <Button text="📋 Pin from URL" fontSize="11" color="#1a1400" textColor="#f0c060"
                  flexibleWidth="1" height="28" onClick="pinCurrentYelloscribePage" />
          <Button text="✚ Save Card" fontSize="11" color="#0a1a0a" textColor="#88ee88"
                  flexibleWidth="1" height="28" onClick="saveDataCard" />
        </HorizontalLayout>

        <Text text="────────────────" fontSize="9" color="#2a2a44"
              alignment="MiddleCenter" height="10" />

        <Text id="dc_status" text="No cards pinned yet"
              fontSize="10" color="#555577" alignment="MiddleCenter" height="13" />

        <!-- Scrollable list of pinned cards -->
        <ScrollView flexibleHeight="1" scrollSensitivity="30">
          <VerticalLayout spacing="3">
            %s
          </VerticalLayout>
        </ScrollView>

      </VerticalLayout>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>


<!-- ══════════════════════════════════════════════════════════════════
     HELP PANEL
     ══════════════════════════════════════════════════════════════════ -->
<Panel id="help_panel" active="false"
       position="340 60 0" width="450" height="660"
       color="#0d0d1a" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="4">

    <!-- Header -->
    <HorizontalLayout height="38" color="#252540" padding="6 6 4 4">
      <Text text="❓ WH40K Mod — Help" fontSize="15" fontStyle="Bold"
            color="#f4d35e" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="14" color="#0d0d1a" textColor="#aaaacc"
              width="32" height="32" onClick="toggleHelpPanel" />
    </HorizontalLayout>

    <ScrollView flexibleHeight="1" scrollSensitivity="30">
      <VerticalLayout spacing="3" padding="2 2 6 2">

        <!-- ── TOOLBAR ─────────────────────────────────────────── -->
        <Text text="── TOOLBAR ──" fontSize="12" fontStyle="Bold"
              color="#f4d35e" alignment="MiddleCenter" height="20" />
        <Text text="All panels are draggable. Open/close each with its toolbar button."
              fontSize="11" color="#888899" alignment="MiddleLeft" height="16" />
        <Text text="🎲 Dice — dice roller panel"
              fontSize="11" color="#7ab8f5" alignment="MiddleLeft" height="15" />
        <Text text="⚔ Attack — full attack sequence panel"
              fontSize="11" color="#f4a261" alignment="MiddleLeft" height="15" />
        <Text text="🛡 Save — armour save roller"
              fontSize="11" color="#a8d8a8" alignment="MiddleLeft" height="15" />
        <Text text="💀 Morale — Battleshock test"
              fontSize="11" color="#cc99ff" alignment="MiddleLeft" height="15" />
        <Text text="⏱ Turn — turn / phase tracker"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="❤ HP — wound / model tracker"
              fontSize="11" color="#ff7777" alignment="MiddleLeft" height="15" />
        <Text text="👥 Teams — match format and army tracker"
              fontSize="11" color="#ccaaff" alignment="MiddleLeft" height="15" />
        <Text text="📜 Rules — Yelloscribe in-game rules browser"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />

        <!-- ── DICE ROLLER ─────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── 🎲 DICE ROLLER ──" fontSize="12" fontStyle="Bold"
              color="#7ab8f5" alignment="MiddleCenter" height="20" />
        <Text text="Panel: set Count + Sides, click Roll. Results announced to all."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="16" />
        <Text text="Dice Mat: drag physical TTS dice onto a tagged mat — auto-announces"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="16" />
        <Text text="the results in chat (tag an object DiceMat to enable)."
              fontSize="11" color="#888899" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !roll 2d6   !roll 3d3   !roll 1d100"
              fontSize="11" color="#7ab8f5" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !history — see your last 10 rolls"
              fontSize="11" color="#7ab8f5" alignment="MiddleLeft" height="15" />

        <!-- ── ATTACK SEQUENCE ─────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── ⚔ ATTACK SEQUENCE ──" fontSize="12" fontStyle="Bold"
              color="#f4a261" alignment="MiddleCenter" height="20" />
        <Text text="Full combat flow: Attacks → Hit → Wound → AP → Save → Damage."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="16" />
        <Text text="Set each value in the panel and step through the sequence."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Damage: flat number, D3, or D6 — enter d3 / d6 in the field."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !attack &lt;n&gt; &lt;hit+&gt; &lt;wound+&gt; &lt;AP&gt; &lt;dmg&gt; &lt;save+&gt;"
              fontSize="11" color="#f4a261" alignment="MiddleLeft" height="15" />
        <Text text='Example: !attack 5 3 4 -1 2 3  (5 attacks, hit 3+, wound 4+, AP-1, 2dmg, sv3+)'
              fontSize="10" color="#888899" alignment="MiddleLeft" height="15" />

        <!-- ── SAVE ────────────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── 🛡 ARMOUR SAVE ──" fontSize="12" fontStyle="Bold"
              color="#a8d8a8" alignment="MiddleCenter" height="20" />
        <Text text="Roll saves only (skips hit and wound steps)."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="16" />
        <Text text="Chat:  !save &lt;dice&gt; &lt;save+&gt; [AP]"
              fontSize="11" color="#a8d8a8" alignment="MiddleLeft" height="15" />
        <Text text='Example: !save 4 3 -1  (4 dice, save 3+, AP-1 → effective save 4+)'
              fontSize="10" color="#888899" alignment="MiddleLeft" height="15" />

        <!-- ── MORALE ──────────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── 💀 BATTLESHOCK ──" fontSize="12" fontStyle="Bold"
              color="#cc99ff" alignment="MiddleCenter" height="20" />
        <Text text="Rolls 2d6 + models lost vs Leadership. Fail = models flee."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="16" />
        <Text text="Chat:  !morale &lt;Ld&gt; &lt;models lost&gt;"
              fontSize="11" color="#cc99ff" alignment="MiddleLeft" height="15" />
        <Text text='Example: !morale 7 3  (Ld 7, 3 models lost this turn)'
              fontSize="10" color="#888899" alignment="MiddleLeft" height="15" />

        <!-- ── TURN TRACKER ────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── ⏱ TURN TRACKER ──" fontSize="12" fontStyle="Bold"
              color="#aaaacc" alignment="MiddleCenter" height="20" />
        <Text text="Tracks 6 WH40K phases per army:"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Command → Movement → Psychic → Shooting → Charge → Fight"
              fontSize="11" color="#ccccee" alignment="MiddleLeft" height="15" />
        <Text text="◀ / ▶ buttons step phases. After Fight, the next army begins."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Round counter increments when all armies complete their Fight phase."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !next   !prev   !turn"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="FTC mode: turn tracker hides; FTC controls phases instead."
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />

        <!-- ── WOUND TRACKER ───────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── ❤ WOUND TRACKER ──" fontSize="12" fontStyle="Bold"
              color="#ff7777" alignment="MiddleCenter" height="20" />
        <Text text="Model-aware HP: damage fills the front model first; that model is"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="removed when its wounds reach 0, then damage carries over."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Quick-add row: enter Name + W/model + model count, then ✚ Add."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="HP bar format:  4/5×2W  =  4 wounds left on 1 of 2 remaining 5W models"
              fontSize="10" color="#888899" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !addunit &quot;Name&quot; &lt;W/model&gt; [count]"
              fontSize="11" color="#ff7777" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !wound &quot;Name&quot; &lt;amount&gt;"
              fontSize="11" color="#ff7777" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !heal  &quot;Name&quot; &lt;amount&gt;"
              fontSize="11" color="#ff7777" alignment="MiddleLeft" height="15" />

        <!-- ── TEAMS ───────────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── 👥 TEAMS &amp; MATCH FORMAT ──" fontSize="12" fontStyle="Bold"
              color="#ccaaff" alignment="MiddleCenter" height="20" />
        <Text text="Choose a format and click Auto-assign to fill teams from seated players."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="FFA — one army per seated player (any count)"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="2v1 / 2v2 / 3v2 / 3v3 — two opposing teams (Alpha vs Bravo)"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="3-Team — three factions: Alpha / Bravo / Charlie (2 players each)"
              fontSize="11" color="#4fc3f7" alignment="MiddleLeft" height="15" />
        <Text text="Move player: type a TTS colour (e.g. Red) and click → T1 / T2 / T3."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Rename team: type new name in the rename field, click Rename."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Active army: ◀/▶ in Teams or Turn panel steps through armies."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !setmode &lt;mode&gt;   !teams"
              fontSize="11" color="#ccaaff" alignment="MiddleLeft" height="15" />

        <!-- ── YELLOSCRIBE ─────────────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── 📜 YELLOSCRIBE ──" fontSize="12" fontStyle="Bold"
              color="#aaaacc" alignment="MiddleCenter" height="20" />
        <Text text="Opens yelloscribe.com inside TTS — browse datasheets and"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="core rules without alt-tabbing. Use the Track row at the top"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="to add a unit directly to the Wound Tracker while you browse."
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="Chat:  !yelloscribe — opens the panel"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />

        <!-- ── FTC COMPATIBILITY ───────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── ⚙ FTC COMPATIBILITY ──" fontSize="12" fontStyle="Bold"
              color="#44ee88" alignment="MiddleCenter" height="20" />
        <Text text="When Free the Codex (FTC) is loaded alongside this mod:"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="  • Turn tracker hides — FTC manages phases and rounds"
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />
        <Text text="  • Teams panel stays live and syncs the active army automatically"
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />
        <Text text="  • When FTC hands a turn to a player, the correct team highlights"
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />
        <Text text="  • Phase chat messages include the active army name"
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />
        <Text text="  • Wound tracker works normally (FTC units can be imported)"
              fontSize="11" color="#44bb88" alignment="MiddleLeft" height="15" />
        <Text text="Import FTC units into wound tracker:"
              fontSize="11" color="#aaaacc" alignment="MiddleLeft" height="15" />
        <Text text="  Toolbar: click ⚙ FTC button   or   Chat: !ftcimport"
              fontSize="11" color="#44ee88" alignment="MiddleLeft" height="15" />
        <Text text="Import one unit by GUID:  !ftcunit &lt;GUID&gt;"
              fontSize="11" color="#44ee88" alignment="MiddleLeft" height="15" />
        <Text text="(GUID is the object GUID shown on the FTC unit card in TTS)"
              fontSize="10" color="#555577" alignment="MiddleLeft" height="15" />

        <!-- ── ALL CHAT COMMANDS ───────────────────────────────── -->
        <Text text=" " fontSize="6" height="4" />
        <Text text="── CHAT COMMANDS ──" fontSize="12" fontStyle="Bold"
              color="#f4d35e" alignment="MiddleCenter" height="20" />
        <Text text="!roll &lt;N&gt;d&lt;S&gt;                 — free dice roll"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!attack &lt;n&gt; &lt;hit&gt; &lt;wnd&gt; &lt;AP&gt; &lt;dmg&gt; &lt;sv&gt;  — full sequence"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!save &lt;dice&gt; &lt;save+&gt; [AP]       — armour saves only"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!morale &lt;Ld&gt; &lt;lost&gt;            — Battleshock test"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text='!addunit "Name" &lt;W&gt; [models]   — add unit to HP tracker'
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text='!wound "Name" &lt;n&gt;             — deal wounds'
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text='!heal  "Name" &lt;n&gt;             — heal wounds'
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!setmode &lt;mode&gt;               — ffa 2v1 2v2 3v2 3v3 3team"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!teams                         — show team setup"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!next / !prev                  — step turn phases"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!turn                          — show current phase"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!yelloscribe                   — open rules browser + data cards"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!history                       — last 10 rolls"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />
        <Text text="!ftcimport                     — import all FTC units (FTC only)"
              fontSize="11" color="#44ee88" alignment="MiddleLeft" height="15" />
        <Text text="!ftcunit &lt;GUID&gt;               — import one FTC unit (FTC only)"
              fontSize="11" color="#44ee88" alignment="MiddleLeft" height="15" />
        <Text text="!help                          — show this list in chat"
              fontSize="11" color="#f4d35e" alignment="MiddleLeft" height="15" />

        <Text text=" " fontSize="6" height="6" />

      </VerticalLayout>
    </ScrollView>

  </VerticalLayout>
</Panel>


</Canvas>
    ]],
    -- 1: toolbar position
    toolbarPos,
    -- 2: FTC button in toolbar
    ftcBtn,
    -- 3: Attack panel — top steppers (attacks, hit, wound, AP)
    stepRow("Attacks",  "atk_attacks", "atkAttDn", "atkAttUp", 5,  "#",  52) ..
    stepRow("Hit+",     "atk_hit",     "atkHitDn", "atkHitUp", 3,  "2-6",52) ..
    stepRow("Wound+",   "atk_wound",   "atkWoundDn","atkWoundUp",4,"2-6",52),
    -- 4: Attack panel — bottom steppers (AP, save)
    stepRow("AP",       "atk_ap",      "atkApDn",  "atkApUp",  0,  "0..-6",52) ..
    stepRow("Save+",    "atk_save",    "atkSaveDn","atkSaveUp", 5,  "2-6",52),
    -- 5: Save panel steppers
    stepRow("# Dice",   "sv_dice",     "svDiceDn", "svDiceUp", 4,  "#",  52) ..
    stepRow("Save+",    "sv_save",     "svSaveDn", "svSaveUp", 3,  "2-6",52) ..
    stepRow("AP",       "sv_ap",       "svApDn",   "svApUp",   0,  "0..-6",52),
    -- 6: Morale panel steppers
    stepRow("Leadership","mr_ld",      "mrLdDn",   "mrLdUp",   7,  "1-10",52) ..
    stepRow("Models Lost","mr_lost",   "mrLostDn", "mrLostUp", 1,  "0+",  52),
    -- 7: turn phase buttons
    buildPhaseButtons(),
    -- 8: FTC badge in wound tracker header
    ftcBadge,
    -- 9: wound tracker unit rows
    buildWoundRows(),
    -- 10: Yelloscribe data card slots
    buildDataCardSlots()
    )
end

------------------------------------------------------------------------
-- QUICK-ADD (wound tracker panel button)
------------------------------------------------------------------------
function quickAddUnit()
    local name   = UI.getValue("wt_quick_name")
    local w      = tonumber(UI.getValue("wt_quick_wounds"))
    local models = tonumber(UI.getValue("wt_quick_models")) or 1
    if not name or name == "" or not w then
        log("Enter a unit name and W (wounds per model).")
        return
    end
    addUnit(name, w, models)
    UI.setValue("wt_quick_name",   "")
    UI.setValue("wt_quick_wounds", "")
    UI.setValue("wt_quick_models", "")
end

------------------------------------------------------------------------
-- INIT
------------------------------------------------------------------------
function onLoad(save_state)
    math.randomseed(os.time())

    -- ── FTC detection ────────────────────────────────────────────────
    -- FTC registers itself as the global table `FTC` before onLoad fires.
    FTC_PRESENT = (type(FTC) == "table")
    if FTC_PRESENT then
        log("Free the Codex detected — FTC compatibility mode active.")
        log("Use !ftcimport to pull FTC units into the wound tracker.")
    else
        log("Free the Codex not detected — running standalone.")
    end

    -- Build and inject UI (toolbar position depends on FTC_PRESENT)
    UI.setXml(buildXml(FTC_PRESENT))

    -- Restore saved state
    if save_state and save_state ~= "" then
        local ok, data = pcall(JSON.decode, save_state)
        if ok and data then
            rollHistory  = data.rollHistory  or {}
            woundTracker = data.woundTracker or {}
            if data.turnState then
                turnState.round        = data.turnState.round        or 1
                turnState.phase        = data.turnState.phase        or 1
                turnState.activePlayer = data.turnState.activePlayer or "Player 1"
            end
            if data.teamConfig then
                teamConfig.mode       = data.teamConfig.mode       or "ffa"
                teamConfig.activeTeam = data.teamConfig.activeTeam or 1
                teamConfig.teams      = data.teamConfig.teams      or {}
            end
            if data.dataCards then
                dataCards = data.dataCards
            end
        end
    end

    -- Register dice mat objects
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("DiceMat") then
            obj.registerCollisions(true)
            log("Dice mat registered: " .. obj.getGUID())
        end
    end

    -- Auto-spawn side tables on first load (skip if already present from a save)
    local existingTables = false
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag(SIDE_TABLE_TAG) then
            existingTables = true
            table.insert(sideTableGuids, obj.getGUID())
        end
    end

    Wait.time(function()
        refreshTurnUI()
        refreshWoundUI()
        refreshTeamUI()
        refreshDataCardsUI()
        if not existingTables then
            spawnSideTables()
        end
        -- FTC mode: spread dice mats across player side tables after they settle
        if FTC_PRESENT then
            Wait.frames(function() positionDiceMatsForFTC() end, 10)
        end
        log("WH40K mod ready. Type !help for commands.")
    end, 0.5)
end

function onSave()
    return JSON.encode({
        rollHistory  = rollHistory,
        woundTracker = woundTracker,
        turnState    = turnState,
        teamConfig   = teamConfig,
        dataCards    = dataCards,
    })
end
