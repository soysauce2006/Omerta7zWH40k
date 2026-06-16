-- =============================================================================
--  WH40K Dice Mat · Yelloscribe · Turn Tracker · Wound Tracker
--  + Free the Codex (FTC) compatibility layer
--  Global script for Tabletop Simulator
-- =============================================================================
--
--  FTC COMPATIBILITY NOTES
--  ───────────────────────
--  This script detects Free the Codex at load time by checking for the `FTC`
--  global table.  When FTC is present the following changes apply automatically:
--
--  • Our turn tracker hides itself and syncs to FTC phase/round callbacks
--    (onFTCPhaseStart / onFTCRoundStart).
--  • Attack-sequence damage is routed through FTC.ApplyWounds() so FTC unit
--    cards update their own counters in addition to our wound tracker.
--  • !ftcimport pulls every unit FTC currently knows about into our wound
--    tracker so you can use our HP bars alongside FTC's counters.
--  • !ftcunit <guid> imports a single unit card by its TTS object GUID.
--  • The toolbar is anchored to the bottom-right corner to avoid FTC's
--    left-rail UI panels.
--
--  If FTC is NOT loaded everything works identically to before — no stubs,
--  no errors, no silent fallbacks with misleading output.
-- =============================================================================

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local MAX_HISTORY = 20
local MAX_UNITS   = 12

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

local TEAM_MODES = { "ffa", "2v1", "2v2", "3v2", "3v3" }

local TEAM_DEFAULTS = {
    { name = "Team Alpha", color = "#e63946" },  -- red
    { name = "Team Bravo", color = "#2dc653" },  -- green
}

-- Sizes for each mode: { teamA_size, teamB_size }
local MODE_SIZES = {
    ["ffa"] = nil,        -- computed from seated player count
    ["2v1"] = {2, 1},
    ["2v1r"]= {1, 2},     -- internal alias (1 vs 2)
    ["2v2"] = {2, 2},
    ["3v2"] = {3, 2},
    ["3v3"] = {3, 3},
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

local _prev_onFTCPhaseStart = onFTCPhaseStart  -- may be nil
function onFTCPhaseStart(phaseName, playerColor)
    if _prev_onFTCPhaseStart then _prev_onFTCPhaseStart(phaseName, playerColor) end
    local idx = FTC_PHASE_MAP[phaseName and phaseName:lower() or ""]
    if idx then
        turnState.phase = idx
        turnState.activePlayer = playerColor or turnState.activePlayer
    end
    printToAll(
        string.format("[FTC │ Turn] Round %d — %s  [%s]",
            turnState.round,
            phaseName or "?",
            playerColor or "?"),
        {r=0.6, g=0.9, b=1})
end

local _prev_onFTCRoundStart = onFTCRoundStart
function onFTCRoundStart(roundNumber)
    if _prev_onFTCRoundStart then _prev_onFTCRoundStart(roundNumber) end
    turnState.round = roundNumber or (turnState.round + 1)
    turnState.phase = 1
    log("=== FTC Round " .. turnState.round .. " begins! ===")
end

-- FTC also fires onFTCTurnStart(playerColor) when turn ownership swaps
local _prev_onFTCTurnStart = onFTCTurnStart
function onFTCTurnStart(playerColor)
    if _prev_onFTCTurnStart then _prev_onFTCTurnStart(playerColor) end
    turnState.activePlayer = playerColor or turnState.activePlayer
    log("FTC: " .. tostring(playerColor) .. "'s turn.")
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

    -- Team columns (only shown for non-FFA modes)
    local showTeams = (teamConfig.mode ~= "ffa")
    UI.setAttribute("tm_team_columns", "active", showTeams and "true" or "false")
    UI.setAttribute("tm_ffa_info",     "active", showTeams and "false" or "true")

    -- Team 1 / Team 2 player lists
    for ti = 1, 2 do
        local t = teamConfig.teams[ti]
        if t then
            local pStr = #t.players > 0
                and table.concat(t.players, ", ")
                or  "(none)"
            UI.setAttribute("tm_t" .. ti .. "_name",    "text", t.name)
            UI.setAttribute("tm_t" .. ti .. "_players", "text", pStr)
            UI.setAttribute("tm_t" .. ti .. "_name",    "color", t.color)
        end
    end

    -- FFA list
    if teamConfig.mode == "ffa" then
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
        log("Unknown mode '" .. modeStr .. "'. Valid: ffa 2v1 2v2 3v2 3v3")
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
        -- 2-team mode: split players by mode sizes
        local sizes = MODE_SIZES[modeStr] or {2, 2}
        for ti, def in ipairs(TEAM_DEFAULTS) do
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
                "Usage: !setmode <mode>  —  modes: ffa  2v1  2v2  3v2  3v3\n"..
                "Auto-assigns seated players.  Use Teams panel to reassign.",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        setTeamMode(mode)
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
            "!setmode <mode>              — set match format: ffa 2v1 2v2 3v2 3v3",
            "!teams                       — show current team setup",
            "!next / !prev                — advance/retreat turn phase (cycles armies)",
            "!turn                        — show current phase",
            "!yelloscribe                 — open Yelloscribe panel",
            "!history                     — last 10 rolls",
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
<HorizontalLayout id="toolbar" position="%s" width="620" height="46"
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
       position="-310 200 0" width="430" height="440"
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
      <Button id="tm_btn_ffa" text="FFA"  fontSize="13"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|ffa" />
      <Button id="tm_btn_2v1" text="2v1"  fontSize="13"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|2v1" />
      <Button id="tm_btn_2v2" text="2v2"  fontSize="13"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|2v2" />
      <Button id="tm_btn_3v2" text="3v2"  fontSize="13"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|3v2" />
      <Button id="tm_btn_3v3" text="3v3"  fontSize="13"
              color="#2d2d44" textColor="#aaaacc" flexibleWidth="1"
              onClick="setTeamMode|3v3" />
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
    <WebBrowser id="ys_browser" url="https://www.yelloscribe.com"
                width="940" height="654" />
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
    buildWoundRows()
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
        end
    end

    -- Register dice mat objects
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("DiceMat") then
            obj.registerCollisions(true)
            log("Dice mat registered: " .. obj.getGUID())
        end
    end

    Wait.time(function()
        refreshTurnUI()
        refreshWoundUI()
        refreshTeamUI()
        log("WH40K mod ready. Type !help for commands.")
    end, 0.5)
end

function onSave()
    return JSON.encode({
        rollHistory  = rollHistory,
        woundTracker = woundTracker,
        turnState    = turnState,
        teamConfig   = teamConfig,
    })
end
