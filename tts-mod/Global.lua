-- WH40K Dice Mat & Yelloscribe Mod
-- Global script for Tabletop Simulator
-- Place this in Global > Lua Script in TTS

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local DICE_MAT_GUID   = "dice_mat"   -- set to your dice mat object GUID
local YELLOSCRIBE_URL = "https://www.yelloscribe.com"

-- Dice colours for WH40K factions (customise as you like)
local FACTION_COLOURS = {
    SpaceMarines  = {r=0.1,  g=0.3,  b=0.8},
    Chaos         = {r=0.6,  g=0.0,  b=0.0},
    Eldar         = {r=0.0,  g=0.7,  b=0.4},
    Orks          = {r=0.1,  g=0.5,  b=0.1},
    Tyranids      = {r=0.5,  g=0.0,  b=0.5},
    Necrons       = {r=0.0,  g=0.8,  b=0.3},
    Tau           = {r=0.2,  g=0.6,  b=0.8},
    ImperialGuard = {r=0.5,  g=0.4,  b=0.2},
}

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local rollHistory   = {}   -- stores last N roll results
local MAX_HISTORY   = 20
local yelloscribeUI = false

------------------------------------------------------------------------
-- UTILITY
------------------------------------------------------------------------
local function log(msg)
    printToAll("[WH40K Mod] " .. tostring(msg), {r=1, g=0.8, b=0.2})
end

local function tableSum(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s
end

local function tableFmt(t)
    local parts = {}
    for _, v in ipairs(t) do parts[#parts+1] = tostring(v) end
    return table.concat(parts, ", ")
end

------------------------------------------------------------------------
-- DICE ROLLING HELPERS
------------------------------------------------------------------------

-- Roll N dice with S sides; returns table of results
local function rollDice(num, sides)
    local results = {}
    for i = 1, num do
        results[i] = math.random(1, sides)
    end
    return results
end

-- Pretty-print a roll result to all players
local function announceRoll(label, results, colour)
    local total = tableSum(results)
    local msg   = string.format(
        "[%s] rolled %s  →  [%s]  (Total: %d)",
        label, "#" .. #results .. "d" .. results[1],
        tableFmt(results), total
    )
    printToAll(msg, colour or {r=1,g=1,b=1})

    -- Store in history
    table.insert(rollHistory, 1, {label=label, results=results, total=total})
    if #rollHistory > MAX_HISTORY then
        table.remove(rollHistory, MAX_HISTORY + 1)
    end
end

------------------------------------------------------------------------
-- WH40K SPECIFIC ROLLS
------------------------------------------------------------------------

-- Attack sequence: roll To-Hit, filter successes, then roll To-Wound
function rollAttack(player, numAttacks, toHit, toWound, apValue)
    local colour = player and player.color and
                   Player[player.color].color or {r=1,g=1,b=1}

    -- To-Hit
    local hitRolls = rollDice(numAttacks, 6)
    local hits = 0
    for _, v in ipairs(hitRolls) do
        if v >= toHit then hits = hits + 1 end
    end
    printToAll(
        string.format("[Attack] Hit rolls (%s+): [%s]  → %d hits",
            toHit, tableFmt(hitRolls), hits),
        colour)

    if hits == 0 then
        printToAll("[Attack] No hits — attack sequence ends.", colour)
        return
    end

    -- To-Wound
    local woundRolls = rollDice(hits, 6)
    local wounds = 0
    for _, v in ipairs(woundRolls) do
        if v >= toWound then wounds = wounds + 1 end
    end
    printToAll(
        string.format("[Attack] Wound rolls (%s+): [%s]  → %d unsaved wounds (AP%s)",
            toWound, tableFmt(woundRolls), wounds, apValue or "-"),
        colour)
end

-- Morale test
function moraleTest(player, unitLeadership, modelsLost)
    local roll   = math.random(1, 6)
    local target = unitLeadership
    local result = (roll + modelsLost) > target
    local colour = result and {r=1,g=0.2,b=0.2} or {r=0.2,g=1,b=0.2}
    printToAll(
        string.format("[Morale] Ld%d, lost %d → rolled %d+%d=%d  →  %s",
            target, modelsLost, roll, modelsLost, roll+modelsLost,
            result and "FAILED (flee!)" or "PASSED"),
        colour)
end

-- Generic WH40K dice mat roll (fires when dice are placed on the mat)
function onDiceMatRoll(player, rolls)
    local name  = player and player.steam_name or "Unknown"
    local c     = player and player.color or "White"
    local col   = Player[c] and Player[c].color or {r=1,g=1,b=1}
    announceRoll(name, rolls, col)
end

------------------------------------------------------------------------
-- CHAT COMMANDS
------------------------------------------------------------------------
-- Usage examples in TTS chat:
--   !roll 3d6
--   !attack 5 3+ 4+ -1
--   !morale 8 3
--   !yelloscribe
--   !history

function onChat(message, player)
    local cmd, args = message:match("^(!%S+)%s*(.*)")
    if not cmd then return end
    cmd = cmd:lower()

    -- !roll NdS
    if cmd == "!roll" then
        local num, sides = args:match("(%d+)d(%d+)")
        num   = tonumber(num)
        sides = tonumber(sides)
        if not num or not sides then
            printToColor("Usage: !roll <N>d<S>  e.g. !roll 3d6", player.color, {r=1,g=0.5,b=0})
            return false
        end
        local results = rollDice(num, sides)
        local col = Player[player.color] and Player[player.color].color or {r=1,g=1,b=1}
        announceRoll(player.steam_name, results, col)
        return false

    -- !attack <numAttacks> <toHit+> <toWound+> [AP]
    elseif cmd == "!attack" then
        local n, h, w, ap = args:match("(%d+)%s+(%d+)%+?%s+(%d+)%+?%s*([%-]?%d*)")
        n  = tonumber(n)
        h  = tonumber(h)
        w  = tonumber(w)
        ap = ap ~= "" and ap or "-"
        if not n or not h or not w then
            printToColor("Usage: !attack <attacks> <toHit> <toWound> [AP]  e.g. !attack 5 3 4 -1",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        rollAttack(player, n, h, w, ap)
        return false

    -- !morale <leadership> <modelsLost>
    elseif cmd == "!morale" then
        local ld, lost = args:match("(%d+)%s+(%d+)")
        ld   = tonumber(ld)
        lost = tonumber(lost)
        if not ld or not lost then
            printToColor("Usage: !morale <leadership> <modelsLost>  e.g. !morale 8 3",
                player.color, {r=1,g=0.5,b=0})
            return false
        end
        moraleTest(player, ld, lost)
        return false

    -- !history
    elseif cmd == "!history" then
        if #rollHistory == 0 then
            printToColor("No rolls yet this session.", player.color, {r=0.7,g=0.7,b=0.7})
        else
            printToColor("=== Roll History ===", player.color, {r=1,g=0.8,b=0.2})
            for i, entry in ipairs(rollHistory) do
                printToColor(
                    string.format("%d. [%s] [%s] → Total: %d",
                        i, entry.label, tableFmt(entry.results), entry.total),
                    player.color, {r=0.9,g=0.9,b=0.9})
                if i >= 10 then break end
            end
        end
        return false

    -- !yelloscribe  — open the Yelloscribe rulebook browser
    elseif cmd == "!yelloscribe" then
        openYelloscribe(player)
        return false

    -- !help
    elseif cmd == "!help" then
        local help = {
            "=== WH40K Mod Commands ===",
            "!roll <N>d<S>          — roll dice  (e.g. !roll 3d6)",
            "!attack <n> <hit+> <wound+> [AP]  — full attack sequence",
            "!morale <Ld> <lost>    — morale test",
            "!history               — show last 10 rolls",
            "!yelloscribe           — open Yelloscribe rulebook lookup",
            "!help                  — show this message",
        }
        for _, line in ipairs(help) do
            printToColor(line, player.color, {r=0.6,g=0.9,b=1})
        end
        return false
    end
end

------------------------------------------------------------------------
-- YELLOSCRIBE INTEGRATION
------------------------------------------------------------------------
-- Opens a WebUI panel pointing at yelloscribe.com so players can look up
-- rules, datasheets, and FAQs without leaving TTS.

function openYelloscribe(player)
    local targetColor = player and player.color or "White"

    -- Build a simple in-game UI window for the requesting player
    UI.show("yelloscribe_panel")
    log(targetColor .. " opened Yelloscribe.")
end

function closeYelloscribe()
    UI.hide("yelloscribe_panel")
end

------------------------------------------------------------------------
-- UI XML  (paste into the Global XML tab in TTS)
--
-- If you prefer to keep everything in one place, uncomment the block
-- below and call UI.setXml(YELLOSCRIBE_XML) inside onLoad().
------------------------------------------------------------------------
local YELLOSCRIBE_XML = [[
<Panel id="yelloscribe_panel" active="false"
       width="900" height="680"
       position="0 0 -15"
       rotation="0 0 0"
       color="#1a1a2e"
       allowDragging="true"
       showAnimation="Grow"
       hideAnimation="Shrink">

  <!-- Title bar -->
  <HorizontalLayout height="50" color="#e63946" padding="8 8 4 4">
    <Text fontSize="22" fontStyle="Bold" color="White"
          alignment="MiddleLeft">
      Yelloscribe — WH40K Rules Lookup
    </Text>
    <Button id="ys_close_btn" text="✕" fontSize="20" color="#c1121f"
            textColor="White" width="44" height="44"
            onClick="closeYelloscribe" />
  </HorizontalLayout>

  <!-- Embedded browser -->
  <WebBrowser id="ys_browser"
              url="https://www.yelloscribe.com"
              width="900" height="600" />

</Panel>
]]

------------------------------------------------------------------------
-- DICE MAT — collision / drop detection
------------------------------------------------------------------------
-- Tag your in-game dice mat object with the tag "DiceMat" in TTS.
-- When dice are dropped on it the results are auto-announced.

function onObjectCollisionEnter(registered_object, collision_info)
    local obj = collision_info.collision_object
    if not obj then return end

    -- Only care about dice landing on the mat
    if registered_object.hasTag("DiceMat") and obj.type == "Dice" then
        -- Short delay so physics settles and getValue() is accurate
        Wait.time(function()
            local val  = obj.getValue()
            local name = obj.getName() ~= "" and obj.getName() or "Die"
            -- Find who owns this die by checking the closest seated player
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
-- INIT
------------------------------------------------------------------------
function onLoad(save_state)
    math.randomseed(os.time())
    log("WH40K Dice Mat & Yelloscribe mod loaded.")
    log("Type !help in chat for available commands.")

    -- Inject the Yelloscribe XML panel
    UI.setXml(YELLOSCRIBE_XML)

    -- Register the dice mat for collision callbacks (finds by tag)
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("DiceMat") then
            obj.registerCollisions(true)
            log("Dice mat registered: " .. obj.getGUID())
        end
    end
end

function onSave()
    return JSON.encode({rollHistory = rollHistory})
end
