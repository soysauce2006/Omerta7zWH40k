-- =============================================================================
--  WH40K Dice Mat, Yelloscribe, Turn Tracker & Wound Tracker Mod
--  Global script for Tabletop Simulator
-- =============================================================================

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local MAX_HISTORY    = 20
local MAX_UNITS      = 12     -- max units in wound tracker

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local rollHistory = {}

-- Turn tracker
local turnState = {
    round      = 1,
    phase      = 1,           -- 1-6 index into PHASES
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

-- Wound tracker: array of { name, maxWounds, currentWounds, player }
local woundTracker = {}

-- Pending wound-tracker entry being built from chat input
local pendingUnit = nil

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
--
--   !attack <attacks> <hit+> <wound+> <AP> <dmg> <save+>
--   e.g.    !attack 5 3 4 -1 2 3
--
--   AP is a negative number (-1, -2 …) or 0 for no AP
--   dmg is flat damage per unsaved wound (use D3 or D6 for variable)
--   save is the target's base save (e.g. 3 for 3+)
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
    printToAll(
        string.format("[%s │ Hit  ] %d+ : [%s] → %d hit(s)",
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
    printToAll(
        string.format("[%s │ Wound] %d+ : [%s] → %d wound(s)",
            who, toWound, fmt(woundRolls), wounds), col)
    pushHistory(who .. " wound", woundRolls, wounds)

    if wounds == 0 then
        printToAll(string.format("[%s] No wounds — sequence ends.", who), col)
        return
    end

    -- ── Armour Save ─────────────────────────────────────────────────
    local effectiveSave = baseSave - ap        -- AP is negative, so -(-1) = +1
    -- Invulnerable saves cap at the stated value, never better than the stat
    if effectiveSave > 6 then effectiveSave = 7 end   -- impossible save

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
    printToAll(
        string.format("[%s │ Save ] %s : [%s] → %d saved, %d failed",
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

    -- Auto-apply to wound tracker if a unit is selected
    applyDamageToSelected(totalDmg, who)
end

------------------------------------------------------------------------
-- SAVE-ONLY ROLL  (for when you just need armour/invuln dice)
--
--   !save <numDice> <save+> [AP]
--   e.g.  !save 4 3 -2
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
            who, saveStr, baseSave, ap, fmt(rolls), saved, numDice),
        col)
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
            failed and "FAILED (models flee!)" or "PASSED"),
        col)
end

------------------------------------------------------------------------
-- TURN TRACKER
------------------------------------------------------------------------
local function phaseLabel()
    return string.format("Round %d — %s  [%s]",
        turnState.round,
        PHASES[turnState.phase],
        turnState.activePlayer)
end

local function refreshTurnUI()
    UI.setAttribute("tt_round",  "text", "Round " .. turnState.round)
    UI.setAttribute("tt_phase",  "text", PHASES[turnState.phase])
    UI.setAttribute("tt_player", "text", turnState.activePlayer)
    -- Dim all phase buttons, highlight active
    for i, _ in ipairs(PHASES) do
        local id = "tt_phase_btn_" .. i
        local active = (i == turnState.phase)
        UI.setAttribute(id, "color",     active and "#e63946" or "#2d2d44")
        UI.setAttribute(id, "textColor", active and "White"   or "#aaaacc")
    end
    printToAll("[Turn] " .. phaseLabel(), {r=0.6, g=0.9, b=1})
end

function nextPhase()
    if turnState.phase < #PHASES then
        turnState.phase = turnState.phase + 1
    else
        turnState.phase  = 1
        turnState.round  = turnState.round + 1
        log("=== Round " .. turnState.round .. " begins! ===")
    end
    refreshTurnUI()
end

function prevPhase()
    if turnState.phase > 1 then
        turnState.phase = turnState.phase - 1
    else
        if turnState.round > 1 then
            turnState.round = turnState.round - 1
            turnState.phase = #PHASES
        end
    end
    refreshTurnUI()
end

function setPhase(player, phaseIndex)
    phaseIndex = tonumber(phaseIndex)
    if phaseIndex and PHASES[phaseIndex] then
        turnState.phase = phaseIndex
        refreshTurnUI()
    end
end

function resetTurn()
    turnState.round      = 1
    turnState.phase      = 1
    turnState.activePlayer = "Player 1"
    refreshTurnUI()
    log("Turn tracker reset.")
end

function toggleTurnTracker()
    local vis = UI.getAttribute("turn_tracker_panel", "active")
    if vis == "true" or vis == true then
        UI.hide("turn_tracker_panel")
    else
        UI.show("turn_tracker_panel")
    end
end

------------------------------------------------------------------------
-- WOUND TRACKER
------------------------------------------------------------------------
local function refreshWoundUI()
    -- Rebuild the wound list rows
    for i = 1, MAX_UNITS do
        local rowId   = "wt_row_" .. i
        local nameId  = "wt_name_" .. i
        local hpId    = "wt_hp_"   .. i
        local barId   = "wt_bar_"  .. i

        local unit = woundTracker[i]
        if unit then
            UI.setAttribute(rowId,  "active", "true")
            UI.setAttribute(nameId, "text", unit.name)

            local hp  = math.max(0, unit.current)
            local max = math.max(1, unit.max)
            local pct = math.floor((hp / max) * 100)

            -- Colour: green > 60%, yellow > 30%, red otherwise
            local barCol = pct > 60 and "#2dc653"
                        or pct > 30 and "#f4a261"
                        or             "#e63946"

            UI.setAttribute(hpId,  "text",  hp .. "/" .. max)
            UI.setAttribute(barId, "fillAmount", tostring(pct / 100))
            UI.setAttribute(barId, "color",      barCol)
        else
            UI.setAttribute(rowId, "active", "false")
        end
    end
end

-- Find a unit slot by name (case-insensitive)
local function findUnit(name)
    name = name:lower()
    for i, u in ipairs(woundTracker) do
        if u.name:lower() == name then return i, u end
    end
    return nil
end

-- Add a new unit to the tracker
function addUnit(name, maxWounds)
    maxWounds = tonumber(maxWounds) or 1
    if #woundTracker >= MAX_UNITS then
        log("Wound tracker full (" .. MAX_UNITS .. " units max).")
        return
    end
    local idx = findUnit(name)
    if idx then
        woundTracker[idx].max     = maxWounds
        woundTracker[idx].current = maxWounds
        log("Updated: " .. name .. " (" .. maxWounds .. "W)")
    else
        table.insert(woundTracker, {
            name    = name,
            max     = maxWounds,
            current = maxWounds,
            player  = "?",
        })
        log("Added: " .. name .. " (" .. maxWounds .. "W)")
    end
    refreshWoundUI()
end

-- Remove a unit
function removeUnit(indexStr)
    local i = tonumber(indexStr)
    if i and woundTracker[i] then
        log("Removed: " .. woundTracker[i].name)
        table.remove(woundTracker, i)
        refreshWoundUI()
    end
end

-- Apply damage to a unit (by name)
function applyWounds(name, amount)
    amount = tonumber(amount) or 0
    local idx, unit = findUnit(name)
    if not unit then
        log("Unit not found: " .. tostring(name))
        return
    end
    unit.current = math.max(0, unit.current - amount)
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

-- Heal a unit (by name)
function healUnit(name, amount)
    amount = tonumber(amount) or 1
    local idx, unit = findUnit(name)
    if not unit then log("Unit not found: " .. tostring(name)) return end
    unit.current = math.min(unit.max, unit.current + amount)
    printToAll(
        string.format("[Wounds] %s healed %d → %d/%d",
            unit.name, amount, unit.current, unit.max),
        {r=0.2, g=1, b=0.4})
    refreshWoundUI()
end

-- Apply damage to whichever unit is currently "selected" in the UI
-- (last row whose button was clicked — stored in selectedUnit)
local selectedUnit = nil

function selectUnit(indexStr)
    selectedUnit = tonumber(indexStr)
    local u = selectedUnit and woundTracker[selectedUnit]
    if u then
        UI.setAttribute("wt_selected_label", "text", "Selected: " .. u.name)
    end
end

function applyDamageToSelected(amount, sourceLabel)
    if not selectedUnit then return end
    local unit = woundTracker[selectedUnit]
    if not unit then selectedUnit = nil return end
    unit.current = math.max(0, unit.current - amount)
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

-- Called by the wound tracker UI's ±1 buttons
function woundBtnMinus(indexStr)
    local i    = tonumber(indexStr)
    local unit = i and woundTracker[i]
    if unit then applyWounds(unit.name, 1) end
end

function woundBtnPlus(indexStr)
    local i    = tonumber(indexStr)
    local unit = i and woundTracker[i]
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

-- Called by the "Set from Yelloscribe" button:
-- Reads the unit name and wound value typed into the Yelloscribe panel inputs
function ysSetUnit()
    local name = UI.getValue("ys_unit_name_input")
    local w    = tonumber(UI.getValue("ys_unit_wounds_input"))
    if not name or name == "" or not w then
        log("Enter unit name and wound value in the Yelloscribe panel first.")
        return
    end
    addUnit(name, w)
    -- Clear the inputs
    UI.setValue("ys_unit_name_input",   "")
    UI.setValue("ys_unit_wounds_input", "")
end

------------------------------------------------------------------------
-- YELLOSCRIBE PANEL
------------------------------------------------------------------------
function openYelloscribe()
    UI.show("yelloscribe_panel")
end

function closeYelloscribe()
    UI.hide("yelloscribe_panel")
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

    -- !roll NdS
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

    -- !attack <n> <hit> <wound> <AP> <dmg> <save>
    -- e.g. !attack 5 3 4 -1 2 3
    elseif cmd == "!attack" then
        local n,h,w,ap,dmg,sv = args:match(
            "(%d+)%s+(%d+)%+?%s+(%d+)%+?%s+([%-]?%d+)%s+(%S+)%s+(%d+)")
        n=tonumber(n); h=tonumber(h); w=tonumber(w)
        ap=tonumber(ap); sv=tonumber(sv)
        if not (n and h and w and ap and dmg and sv) then
            printToColor(
                "Usage: !attack <attacks> <hit+> <wound+> <AP> <dmg> <save+>\n"..
                "  e.g. !attack 5 3 4 -1 2 3  or  !attack 5 3 4 -1 D3 3",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        fullAttackSequence(player, n, h, w, ap, dmg, sv)
        return false

    -- !save <numDice> <save+> [AP]  e.g. !save 4 3 -2
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

    -- !morale <Ld> <lost>
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

    -- !addunit "Name" <maxWounds>  e.g. !addunit "Dreadnought" 8
    elseif cmd == "!addunit" then
        local name, w = args:match('"([^"]+)"%s+(%d+)')
        if not name then name, w = args:match("(%S+)%s+(%d+)") end
        w = tonumber(w)
        if not name or not w then
            printToColor('Usage: !addunit "Unit Name" <maxWounds>  e.g. !addunit "Dreadnought" 8',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        addUnit(name, w)
        return false

    -- !wound "Name" <amount>
    elseif cmd == "!wound" then
        local name, amt = args:match('"([^"]+)"%s+(%d+)')
        if not name then name, amt = args:match("(%S+)%s+(%d+)") end
        if not name or not amt then
            printToColor('Usage: !wound "Unit Name" <amount>  e.g. !wound "Dreadnought" 3',
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        applyWounds(name, tonumber(amt))
        return false

    -- !heal "Name" <amount>
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

    -- !next / !prev  — advance/retreat phase
    elseif cmd == "!next" then
        nextPhase()
        return false
    elseif cmd == "!prev" then
        prevPhase()
        return false

    -- !turn  — show current turn
    elseif cmd == "!turn" then
        printToColor("[Turn] " .. phaseLabel(), player.color, {r=0.6,g=0.9,b=1})
        return false

    -- !yelloscribe
    elseif cmd == "!yelloscribe" then
        openYelloscribe()
        return false

    -- !history
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

    -- !help
    elseif cmd == "!help" then
        local h = {
            "═══════════ WH40K Mod Commands ═══════════",
            "!roll <N>d<S>                — free dice roll",
            "!attack <n> <hit> <wound> <AP> <dmg> <save>",
            "   Full sequence (hit→wound→save→damage)",
            "   e.g.  !attack 5 3 4 -1 2 3",
            "   dmg can be D3 or D6 for variable damage",
            "!save <dice> <save+> [AP]    — armour save roll",
            "!morale <Ld> <lost>          — morale test",
            "!addunit \"Name\" <wounds>    — add unit to wound tracker",
            "!wound  \"Name\" <amount>     — deal wounds to unit",
            "!heal   \"Name\" <amount>     — heal wounds on unit",
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
-- UI  XML
------------------------------------------------------------------------
-- Build wound-tracker rows dynamically so the XML stays maintainable
local function buildWoundRows()
    local rows = ""
    for i = 1, MAX_UNITS do
        rows = rows .. string.format([[
      <HorizontalLayout id="wt_row_%d" active="false" height="38"
                        padding="4 4 2 2" spacing="6">
        <Button id="wt_sel_%d" text="●" fontSize="14" width="28" height="28"
                color="#2d2d44" textColor="#aaaacc"
                onClick="selectUnit|%d" />
        <Text id="wt_name_%d" fontSize="14" color="White"
              alignment="MiddleLeft" flexibleWidth="1">—</Text>
        <Text id="wt_hp_%d" fontSize="14" color="#f4a261"
              alignment="MiddleCenter" width="60">0/0</Text>
        <Image id="wt_bar_%d" image="white" color="#2dc653"
               width="80" height="16" fillAmount="1" type="Filled"
               fillMethod="Horizontal" fillOrigin="0" />
        <Button text="−" fontSize="16" width="28" height="28"
                color="#e63946" textColor="White"
                onClick="woundBtnMinus|%d" />
        <Button text="+" fontSize="16" width="28" height="28"
                color="#2dc653" textColor="White"
                onClick="woundBtnPlus|%d" />
        <Button text="✕" fontSize="13" width="24" height="24"
                color="#555566" textColor="#aaaacc"
                onClick="removeUnit|%d" />
      </HorizontalLayout>
        ]], i,i,i,i,i,i,i,i,i)
    end
    return rows
end

-- Build phase buttons for turn tracker
local function buildPhaseButtons()
    local btns = ""
    for i, name in ipairs(PHASES) do
        btns = btns .. string.format(
            '<Button id="tt_phase_btn_%d" text="%s" fontSize="13" height="32" '..
            'color="%s" textColor="%s" onClick="setPhase|%d" />\n',
            i, name,
            i == 1 and "#e63946" or "#2d2d44",
            i == 1 and "White"   or "#aaaacc",
            i)
    end
    return btns
end

local MOD_XML = string.format([[
<Canvas>

<!-- ═══════════════════════════════════════════════
     FLOATING TOOLBAR  (always visible)
     ═══════════════════════════════════════════════ -->
<HorizontalLayout id="toolbar" position="-460 -330 0" width="420" height="44"
                  color="#1a1a2e" padding="4 4 4 4" spacing="4">
  <Button text="📜 Rules" fontSize="14" color="#2d2d44" textColor="#aaaacc"
          width="90" onClick="openYelloscribe" />
  <Button text="⏱ Turn"  fontSize="14" color="#2d2d44" textColor="#aaaacc"
          width="80" onClick="toggleTurnTracker" />
  <Button text="❤ HP"    fontSize="14" color="#2d2d44" textColor="#aaaacc"
          width="70" onClick="toggleWoundTracker" />
  <Text text="!help for commands" fontSize="11" color="#555577"
        alignment="MiddleCenter" flexibleWidth="1" />
</HorizontalLayout>


<!-- ═══════════════════════════════════════════════
     TURN TRACKER PANEL
     ═══════════════════════════════════════════════ -->
<Panel id="turn_tracker_panel" active="false"
       position="300 200 0" width="340" height="260"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">

  <VerticalLayout padding="8 8 8 8" spacing="6">

    <!-- Header -->
    <HorizontalLayout height="40" color="#e63946" padding="6 6 4 4">
      <Text text="Turn Tracker" fontSize="18" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="16" color="#c1121f" textColor="White"
              width="36" height="36" onClick="toggleTurnTracker" />
    </HorizontalLayout>

    <!-- Round & Player -->
    <HorizontalLayout height="32" spacing="8">
      <Text id="tt_round"  text="Round 1" fontSize="16" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Text id="tt_player" text="Player 1" fontSize="14"
            color="#aaaacc" alignment="MiddleRight" flexibleWidth="1" />
    </HorizontalLayout>

    <!-- Current phase label -->
    <Text id="tt_phase" text="Command Phase" fontSize="15"
          color="#f4a261" alignment="MiddleCenter" height="24" />

    <!-- Phase buttons grid -->
    <GridLayout cellWidth="154" cellHeight="32" spacing="4">
      %s
    </GridLayout>

    <!-- Prev / Next -->
    <HorizontalLayout height="36" spacing="8">
      <Button text="◀ Prev" fontSize="14" color="#2d2d44" textColor="#aaaacc"
              flexibleWidth="1" onClick="prevPhase" />
      <Button text="Reset"  fontSize="14" color="#555566" textColor="#aaaacc"
              width="70"    onClick="resetTurn" />
      <Button text="Next ▶" fontSize="14" color="#e63946" textColor="White"
              flexibleWidth="1" onClick="nextPhase" />
    </HorizontalLayout>

  </VerticalLayout>
</Panel>


<!-- ═══════════════════════════════════════════════
     WOUND TRACKER PANEL
     ═══════════════════════════════════════════════ -->
<Panel id="wound_tracker_panel" active="false"
       position="-340 100 0" width="420" height="560"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">

  <VerticalLayout padding="8 8 8 8" spacing="4">

    <!-- Header -->
    <HorizontalLayout height="40" color="#e63946" padding="6 6 4 4">
      <Text text="Wound Tracker" fontSize="18" fontStyle="Bold"
            color="White" alignment="MiddleLeft" flexibleWidth="1" />
      <Button text="✕" fontSize="16" color="#c1121f" textColor="White"
              width="36" height="36" onClick="toggleWoundTracker" />
    </HorizontalLayout>

    <!-- Selected unit label -->
    <Text id="wt_selected_label" text="Selected: (none)"
          fontSize="12" color="#aaaacc" alignment="MiddleLeft" height="20" />

    <!-- Unit rows (built dynamically) -->
    <VerticalLayout id="wt_unit_list" spacing="2">
      %s
    </VerticalLayout>

    <!-- Quick-add row -->
    <HorizontalLayout height="34" spacing="4" color="#14142a" padding="4 4 2 2">
      <InputField id="wt_quick_name"  placeholder="Unit name"
                  fontSize="13" flexibleWidth="1" height="30" />
      <InputField id="wt_quick_wounds" placeholder="W"
                  fontSize="13" width="50" height="30"
                  characterValidation="Integer" />
      <Button text="Add" fontSize="13" color="#2dc653" textColor="White"
              width="50" height="30" onClick="quickAddUnit" />
    </HorizontalLayout>

    <Text text='Or use: !addunit "Name" wounds   !wound "Name" amount'
          fontSize="11" color="#555577" alignment="MiddleCenter" height="18" />

  </VerticalLayout>
</Panel>


<!-- ═══════════════════════════════════════════════
     YELLOSCRIBE PANEL
     ═══════════════════════════════════════════════ -->
<Panel id="yelloscribe_panel" active="false"
       position="0 0 0" width="940" height="740"
       color="#1a1a2e" allowDragging="true"
       showAnimation="Grow" hideAnimation="Shrink">

  <VerticalLayout padding="0 0 0 0" spacing="0">

    <!-- Title bar -->
    <HorizontalLayout height="46" color="#e63946" padding="8 8 4 4" spacing="6">
      <Text text="Yelloscribe — WH40K Rules Lookup" fontSize="20"
            fontStyle="Bold" color="White" alignment="MiddleLeft"
            flexibleWidth="1" />
      <Button text="✕" fontSize="18" color="#c1121f" textColor="White"
              width="40" height="40" onClick="closeYelloscribe" />
    </HorizontalLayout>

    <!-- Add-to-Wound-Tracker bar -->
    <HorizontalLayout height="42" color="#14142a" padding="6 6 4 4" spacing="6">
      <Text text="Add to Wound Tracker:" fontSize="13" color="#aaaacc"
            alignment="MiddleLeft" width="160" />
      <InputField id="ys_unit_name_input" placeholder="Unit name from datasheet"
                  fontSize="13" flexibleWidth="1" height="30" />
      <InputField id="ys_unit_wounds_input" placeholder="W"
                  fontSize="13" width="54" height="30"
                  characterValidation="Integer" />
      <Button text="✚ Track" fontSize="13" color="#2dc653" textColor="White"
              width="80" height="30" onClick="ysSetUnit" />
    </HorizontalLayout>

    <!-- Embedded browser -->
    <WebBrowser id="ys_browser" url="https://www.yelloscribe.com"
                width="940" height="652" />

  </VerticalLayout>
</Panel>

</Canvas>
]], buildPhaseButtons(), buildWoundRows())

------------------------------------------------------------------------
-- Quick-add unit button handler (wound tracker panel)
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
    UI.setXml(MOD_XML)

    -- Restore saved state
    if save_state and save_state ~= "" then
        local ok, data = pcall(JSON.decode, save_state)
        if ok and data then
            rollHistory  = data.rollHistory  or {}
            woundTracker = data.woundTracker or {}
            if data.turnState then
                turnState.round      = data.turnState.round      or 1
                turnState.phase      = data.turnState.phase      or 1
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

    -- Defer UI refresh until UI is ready
    Wait.time(function()
        refreshTurnUI()
        refreshWoundUI()
        log("WH40K mod loaded. Type !help for commands.")
    end, 0.5)
end

function onSave()
    return JSON.encode({
        rollHistory  = rollHistory,
        woundTracker = woundTracker,
        turnState    = turnState,
    })
end
