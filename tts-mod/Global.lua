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
local function phaseLabel()
    return string.format("Round %d — %s  [%s]",
        turnState.round, PHASES[turnState.phase], turnState.activePlayer)
end

local function refreshTurnUI()
    -- When FTC is present our turn panel is hidden, so skip attribute writes
    -- to avoid harmless-but-noisy "element not found" errors from TTS.
    if FTC_PRESENT then return end
    UI.setAttribute("tt_round",  "text", "Round " .. turnState.round)
    UI.setAttribute("tt_phase",  "text", PHASES[turnState.phase])
    UI.setAttribute("tt_player", "text", turnState.activePlayer)
    for i = 1, #PHASES do
        local active = (i == turnState.phase)
        UI.setAttribute("tt_phase_btn_" .. i, "color",
            active and "#e63946" or "#2d2d44")
        UI.setAttribute("tt_phase_btn_" .. i, "textColor",
            active and "White" or "#aaaacc")
    end
    printToAll("[Turn] " .. phaseLabel(), {r=0.6, g=0.9, b=1})
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
        turnState.round = turnState.round + 1
        log("=== Round " .. turnState.round .. " begins! ===")
    end
    refreshTurnUI()
end

function prevPhase()
    if FTC_PRESENT then return end
    if turnState.phase > 1 then
        turnState.phase = turnState.phase - 1
    elseif turnState.round > 1 then
        turnState.round = turnState.round - 1
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
    turnState.round = 1; turnState.phase = 1
    turnState.activePlayer = "Player 1"
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
-- WOUND TRACKER
------------------------------------------------------------------------
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
            UI.setAttribute("wt_hp_"  .. i, "text",       hp .. "/" .. max)
            UI.setAttribute("wt_bar_" .. i, "fillAmount",  tostring(pct / 100))
            UI.setAttribute("wt_bar_" .. i, "color",       barCol)
            -- Show FTC indicator badge
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

function addUnit(name, maxWounds, ftcGuid)
    maxWounds = tonumber(maxWounds) or 1
    ftcGuid   = ftcGuid or ""
    if #woundTracker >= MAX_UNITS then
        log("Wound tracker full (" .. MAX_UNITS .. " units max).")
        return
    end
    local idx = findUnit(name)
    if idx then
        woundTracker[idx].max     = maxWounds
        woundTracker[idx].current = maxWounds
        woundTracker[idx].ftcGuid = ftcGuid
        log("Updated: " .. name .. " (" .. maxWounds .. "W)")
    else
        table.insert(woundTracker, {
            name    = name,
            max     = maxWounds,
            current = maxWounds,
            ftcGuid = ftcGuid,
        })
        log("Added: " .. name .. " (" .. maxWounds .. "W)"
            .. (ftcGuid ~= "" and " [FTC linked]" or ""))
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

-- Core wound application — routes through FTC.ApplyWounds if the unit is linked
function applyWounds(name, amount)
    amount = tonumber(amount) or 0
    local idx, unit = findUnit(name)
    if not unit then
        log("Unit not found: " .. tostring(name))
        return
    end
    unit.current = math.max(0, unit.current - amount)

    -- ── FTC bridge: also update the FTC unit card counter ───────────
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function()
            FTC.ApplyWounds(unit.ftcGuid, amount)
        end)
    end

    printToAll(
        string.format("[Wounds] %s takes %d wound(s) → %d/%d remaining",
            unit.name, amount, unit.current, unit.max),
        unit.current == 0 and {r=1,g=0.2,b=0.2} or {r=1,g=0.85,b=0.1})
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
    unit.current = math.min(unit.max, unit.current + amount)

    -- ── FTC bridge: heal via FTC.HealWounds if available ────────────
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function()
            if FTC.HealWounds then
                FTC.HealWounds(unit.ftcGuid, amount)
            end
        end)
    end

    printToAll(
        string.format("[Wounds] %s healed %d → %d/%d",
            unit.name, amount, unit.current, unit.max),
        {r=0.2, g=1, b=0.4})
    refreshWoundUI()
end

function selectUnit(indexStr)
    selectedUnit = tonumber(indexStr)
    local u = selectedUnit and woundTracker[selectedUnit]
    if u then
        UI.setAttribute("wt_selected_label", "text",
            "Selected: " .. u.name .. (u.ftcGuid ~= "" and " ⚙" or ""))
    end
end

function applyDamageToSelected(amount, sourceLabel)
    if not selectedUnit then return end
    local unit = woundTracker[selectedUnit]
    if not unit then selectedUnit = nil return end
    unit.current = math.max(0, unit.current - amount)

    -- ── FTC bridge ───────────────────────────────────────────────────
    if FTC_PRESENT and unit.ftcGuid and unit.ftcGuid ~= "" then
        ftcCall(function() FTC.ApplyWounds(unit.ftcGuid, amount) end)
    end

    printToAll(
        string.format("[Wounds] %s → %s takes %d damage → %d/%d",
            sourceLabel or "?", unit.name, amount, unit.current, unit.max),
        unit.current == 0 and {r=1,g=0.2,b=0.2} or {r=1,g=0.85,b=0.1})
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

    -- Upsert into our tracker, preserving current HP from FTC
    local idx = findUnit(name)
    if idx then
        woundTracker[idx].max     = maxWounds
        woundTracker[idx].current = curWounds
        woundTracker[idx].ftcGuid = guid
    else
        if #woundTracker >= MAX_UNITS then
            log("Wound tracker full — could not import " .. name)
            return
        end
        table.insert(woundTracker, {
            name    = name,
            max     = maxWounds,
            current = curWounds,
            ftcGuid = guid,
        })
    end
    log("FTC import: " .. name .. " (" .. curWounds .. "/" .. maxWounds .. "W)")
    refreshWoundUI()
end

-- Bulk-import every unit FTC currently tracks
function importAllFtcUnits()
    if not FTC_PRESENT then
        log("Free the Codex is not loaded.")
        return
    end

    -- FTC.GetUnits() returns an array of unit data tables
    local units = ftcCall(function() return FTC.GetUnits() end)
    if not units or #units == 0 then
        log("No FTC units found. Make sure units are placed on the board.")
        return
    end

    local imported = 0
    for _, u in ipairs(units) do
        local guid      = u.guid or u.GUID
        local name      = u.name or u.Name
        local maxWounds = u.wounds or u.maxWounds or u.Wounds or 1
        local curWounds = u.curWounds or u.currentWounds or maxWounds

        if name and guid then
            local idx = findUnit(name)
            if idx then
                woundTracker[idx].max     = maxWounds
                woundTracker[idx].current = curWounds
                woundTracker[idx].ftcGuid = guid
            elseif #woundTracker < MAX_UNITS then
                table.insert(woundTracker, {
                    name    = name,
                    max     = maxWounds,
                    current = curWounds,
                    ftcGuid = guid,
                })
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
    local name = UI.getValue("ys_unit_name_input")
    local w    = tonumber(UI.getValue("ys_unit_wounds_input"))
    if not name or name == "" or not w then
        log("Enter unit name and wound value in the Yelloscribe panel first.")
        return
    end
    addUnit(name, w)
    UI.setValue("ys_unit_name_input",   "")
    UI.setValue("ys_unit_wounds_input", "")
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
        local name, w = args:match('"([^"]+)"%s+(%d+)')
        if not name then name, w = args:match("(%S+)%s+(%d+)") end
        w = tonumber(w)
        if not name or not w then
            printToColor('Usage: !addunit "Unit Name" <maxWounds>',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        addUnit(name, w)
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
            "!addunit \"Name\" <wounds>    — add unit to wound tracker",
            "!wound  \"Name\" <amount>     — deal wounds to unit",
            "!heal   \"Name\" <amount>     — heal wounds on unit",
            ftcLine,
            "!next / !prev                — advance/retreat turn phase",
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
-- UI XML
------------------------------------------------------------------------
local function buildWoundRows()
    local rows = ""
    for i = 1, MAX_UNITS do
        rows = rows .. string.format([[
      <HorizontalLayout id="wt_row_%d" active="false" height="38"
                        padding="4 4 2 2" spacing="4">
        <Button id="wt_sel_%d"  text="●" fontSize="13" width="26" height="26"
                color="#2d2d44" textColor="#aaaacc" onClick="selectUnit|%d" />
        <Text   id="wt_ftc_%d"  text=" " fontSize="12" color="#44bb88"
                alignment="MiddleCenter" width="16" />
        <Text   id="wt_name_%d" text="—" fontSize="13" color="White"
                alignment="MiddleLeft" flexibleWidth="1" />
        <Text   id="wt_hp_%d"   text="0/0" fontSize="13" color="#f4a261"
                alignment="MiddleCenter" width="56" />
        <Image  id="wt_bar_%d"  image="white" color="#2dc653"
                width="70" height="14" fillAmount="1" type="Filled"
                fillMethod="Horizontal" fillOrigin="0" />
        <Button text="−" fontSize="15" width="26" height="26"
                color="#e63946" textColor="White" onClick="woundBtnMinus|%d" />
        <Button text="+" fontSize="15" width="26" height="26"
                color="#2dc653" textColor="White" onClick="woundBtnPlus|%d" />
        <Button text="✕" fontSize="12" width="22" height="22"
                color="#555566" textColor="#aaaacc" onClick="removeUnit|%d" />
      </HorizontalLayout>
        ]], i,i,i,i,i,i,i,i,i,i)
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

-- Toolbar anchor: bottom-right when FTC present, bottom-centre otherwise.
-- We build the XML as a string so the position can be set at runtime before
-- UI.setXml() is called (inside onLoad, after FTC detection).
local function buildXml(ftcMode)
    local toolbarPos    = ftcMode and "460 -330 0" or "0 -340 0"
    local turnPanelVis  = ftcMode and "false" or "false"   -- always starts hidden

    return string.format([[
<Canvas>

<!-- ── TOOLBAR ─────────────────────────────────────────────────── -->
<HorizontalLayout id="toolbar" position="%s" width="430" height="44"
                  color="#1a1a2e" padding="4 4 4 4" spacing="4">
  <Button text="📜 Rules"   fontSize="13" color="#2d2d44" textColor="#aaaacc"
          width="84"  onClick="openYelloscribe" />
  <Button text="⏱ Turn"    fontSize="13" color="#2d2d44" textColor="#aaaacc"
          width="74"  onClick="toggleTurnTracker" />
  <Button text="❤ HP"      fontSize="13" color="#2d2d44" textColor="#aaaacc"
          width="64"  onClick="toggleWoundTracker" />
  %s
  <Text text="!help" fontSize="11" color="#555577"
        alignment="MiddleCenter" flexibleWidth="1" />
</HorizontalLayout>

<!-- ── TURN TRACKER ─────────────────────────────────────────────── -->
<Panel id="turn_tracker_panel" active="%s"
       position="300 160 0" width="340" height="260"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="6">
    <HorizontalLayout height="40" color="#e63946" padding="6 6 4 4">
      <Text text="Turn Tracker" fontSize="18" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="16" color="#c1121f" textColor="White"
              width="36" height="36" onClick="toggleTurnTracker" />
    </HorizontalLayout>
    <HorizontalLayout height="30" spacing="8">
      <Text id="tt_round"  text="Round 1" fontSize="16" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Text id="tt_player" text="Player 1" fontSize="13"
            color="#aaaacc" alignment="MiddleRight" flexibleWidth="1" />
    </HorizontalLayout>
    <Text id="tt_phase" text="Command Phase" fontSize="15"
          color="#f4a261" alignment="MiddleCenter" height="24" />
    <GridLayout cellWidth="152" cellHeight="30" spacing="4">
      %s
    </GridLayout>
    <HorizontalLayout height="34" spacing="8">
      <Button text="◀ Prev" fontSize="13" color="#2d2d44" textColor="#aaaacc"
              flexibleWidth="1" onClick="prevPhase" />
      <Button text="Reset"  fontSize="13" color="#555566" textColor="#aaaacc"
              width="66" onClick="resetTurn" />
      <Button text="Next ▶" fontSize="13" color="#e63946" textColor="White"
              flexibleWidth="1" onClick="nextPhase" />
    </HorizontalLayout>
  </VerticalLayout>
</Panel>

<!-- ── WOUND TRACKER ─────────────────────────────────────────────── -->
<Panel id="wound_tracker_panel" active="false"
       position="-340 80 0" width="430" height="570"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="8 8 8 8" spacing="4">
    <HorizontalLayout height="40" color="#e63946" padding="6 6 4 4">
      <Text text="Wound Tracker" fontSize="18" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      %s
      <Button text="✕" fontSize="16" color="#c1121f" textColor="White"
              width="36" height="36" onClick="toggleWoundTracker" />
    </HorizontalLayout>
    <Text id="wt_selected_label" text="Selected: (none)"
          fontSize="12" color="#aaaacc" alignment="MiddleLeft" height="18" />
    <VerticalLayout id="wt_unit_list" spacing="2">
      %s
    </VerticalLayout>
    <HorizontalLayout height="34" spacing="4" color="#14142a" padding="4 4 2 2">
      <InputField id="wt_quick_name"   placeholder="Unit name"
                  fontSize="13" flexibleWidth="1" height="30" />
      <InputField id="wt_quick_wounds" placeholder="W"
                  fontSize="13" width="50" height="30"
                  characterValidation="Integer" />
      <Button text="Add" fontSize="13" color="#2dc653" textColor="White"
              width="50" height="30" onClick="quickAddUnit" />
    </HorizontalLayout>
    <Text text='!addunit &quot;Name&quot; wounds  |  !wound &quot;Name&quot; n  |  !ftcimport'
          fontSize="11" color="#555577" alignment="MiddleCenter" height="18" />
  </VerticalLayout>
</Panel>

<!-- ── YELLOSCRIBE ───────────────────────────────────────────────── -->
<Panel id="yelloscribe_panel" active="false"
       position="0 0 0" width="940" height="740"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">
  <VerticalLayout padding="0 0 0 0" spacing="0">
    <HorizontalLayout height="46" color="#e63946" padding="8 8 4 4" spacing="6">
      <Text text="Yelloscribe — WH40K Rules Lookup" fontSize="20"
            fontStyle="Bold" color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="18" color="#c1121f" textColor="White"
              width="40" height="40" onClick="closeYelloscribe" />
    </HorizontalLayout>
    <HorizontalLayout height="42" color="#14142a" padding="6 6 4 4" spacing="6">
      <Text text="Add to Wound Tracker:" fontSize="13" color="#aaaacc"
            alignment="MiddleLeft" width="160" />
      <InputField id="ys_unit_name_input"   placeholder="Unit name from datasheet"
                  fontSize="13" flexibleWidth="1" height="30" />
      <InputField id="ys_unit_wounds_input" placeholder="W"
                  fontSize="13" width="54" height="30"
                  characterValidation="Integer" />
      <Button text="✚ Track" fontSize="13" color="#2dc653" textColor="White"
              width="80" height="30" onClick="ysSetUnit" />
    </HorizontalLayout>
    <WebBrowser id="ys_browser" url="https://www.yelloscribe.com"
                width="940" height="652" />
  </VerticalLayout>
</Panel>

</Canvas>
    ]],
    toolbarPos,
    -- FTC import button in toolbar (only when FTC present)
    ftcMode and '<Button text="⚙ FTC" fontSize="13" color="#1a6644" textColor="#44ee88" width="72" onClick="importAllFtcUnits" />' or "",
    turnPanelVis,
    buildPhaseButtons(),
    -- FTC sync badge in wound tracker header
    ftcMode and '<Text text="⚙ FTC Linked" fontSize="12" color="#44bb88" alignment="MiddleCenter" flexibleWidth="1" />' or "",
    buildWoundRows()
    )
end

------------------------------------------------------------------------
-- QUICK-ADD (wound tracker panel button)
------------------------------------------------------------------------
function quickAddUnit()
    local name = UI.getValue("wt_quick_name")
    local w    = tonumber(UI.getValue("wt_quick_wounds"))
    if not name or name == "" or not w then
        log("Enter a unit name and wound value.")
        return
    end
    addUnit(name, w)
    UI.setValue("wt_quick_name",   "")
    UI.setValue("wt_quick_wounds", "")
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
        log("WH40K mod ready. Type !help for commands.")
    end, 0.5)
end

function onSave()
    return JSON.encode({
        rollHistory  = rollHistory,
        woundTracker = woundTracker,
        turnState    = turnState,
    })
end
