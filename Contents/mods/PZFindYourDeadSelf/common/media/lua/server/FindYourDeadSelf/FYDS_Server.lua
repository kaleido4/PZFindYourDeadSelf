--[[
    Find Your Dead Self - record keeper.

    Runs in singleplayer and on the multiplayer server (never on MP clients):
      1. records every player death in global mod data and tags the dying
         character, so its corpse and the zombie it may turn into carry the tag;
      2. makes sure a corpse is always left behind (see "Guaranteed corpse");
      3. follows the reanimated zombie while it is in a loaded area, and keeps
         its last known position while it is not;
      4. removes records once the game would have removed the corpse, or keeps
         the corpse from rotting (see "Your Corpse Never Rots");
      5. in multiplayer, sends each player the records they are allowed to see
         and have not erased from their map.

    Guaranteed corpse:
    Dying happens in two steps. When health reaches 0 the game shows the death
    screen and deletes the character's save (IsoPlayer.OnDeath). A moment later,
    while the body lies on the ground, PlayerOnGroundState calls die(), which
    creates the corpse, but only if isDead() is still true. isDead() just reads
    the current health, so god mode switched on during the death animation heals
    the body back to "alive" and the corpse (and the zombie it would become) is
    never made. We watch every death until its corpse exists: if the character
    gets healed we switch god mode off and zero its health again, and if the
    corpse still does not appear we call die() ourselves.

    Your Corpse Never Rots (sandbox option):
    A corpse rots, and is eventually removed, by its age: world hours minus its
    death time (IsoDeadBody.updateBodies, which runs every tick on loaded
    corpses). While the option is on we keep resetting the death time of our
    tagged corpses, so they stay as fresh as when they fell. Loaded corpses are
    refreshed every few seconds; corpses in an area that is just loading are
    refreshed from LoadGridsquare, which fires before the game registers them
    for removal, so an old corpse is never removed on the first tick after load.

    Performance: nothing runs per tick but a few timestamp compares. Loaded
    zombies are only looked through while a record can still turn into or is a
    zombie that we have not found yet.
--]]

if isClient() then return end

require "FindYourDeadSelf/FYDS_Core"

local TRACK_INTERVAL_MS = 1000     -- update the position of zombies we already found
local SCAN_INTERVAL_MS = 5000      -- look for tagged zombies we have not found yet
local EXPIRE_INTERVAL_MS = 10000   -- check corpse countdowns
local FRESHEN_INTERVAL_MS = 10000  -- Your Corpse Never Rots: reset loaded corpses' age
local RESYNC_INTERVAL_MS = 30000   -- MP: resend everything (new joiners, faction changes)
local MOVE_THRESHOLD = 0.5         -- tiles a zombie has to move before we store it

-- Guaranteed corpse timings, counted in unpaused real time.
local REVIVED_GRACE_MS = 2000      -- after re-killing a healed character, let the game make the corpse
local STUCK_TIMEOUT_MS = 15000     -- dead but still no corpse: make it ourselves

local data                  -- global mod data: { nextId = n, records = { [id] = record } }
local zombies = {}          -- record id -> IsoZombie while loaded (never saved)
local pendingDeaths = {}    -- IsoPlayer -> { elapsedMs, revivedMs }
local corpseSquares = {}    -- x -> y -> true around our corpses (Your Corpse Never Rots only)
local hasCorpseSquares = false
local lastTickMs
local nextTrackMs, nextScanMs, nextExpireMs, nextFreshenMs, nextResyncMs = 0, 0, 0, 0, 0
local dirty = false         -- records changed since the last MP sync
local corpsesMoved = true   -- corpseSquares needs rebuilding

local function options()
    return SandboxVars.PZFindYourDeadSelf or {}
end

local function nowHours()
    return getGameTime():getWorldAgeHours()
end

local function keepCorpses()
    return options().KeepCorpse == true
end

-- Records were added, removed or changed state.
local function recordsChanged()
    dirty = true
    corpsesMoved = true
end

local function removePlayerCorpses()
    local serverOptions = getServerOptions()
    return serverOptions ~= nil and serverOptions:getBoolean("RemovePlayerCorpsesOnCorpseRemoval") == true
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function characterName(player)
    local desc = player:getDescriptor()
    if desc then
        local name = trim((desc:getForename() or "") .. " " .. (desc:getSurname() or ""))
        if name ~= "" then return name end
    end
    return player:getUsername() or "?"
end

local function isOurZombie(zombie, id)
    return zombie:hasModData() and zombie:getModData()[FYDS.TAG] == id
end

---------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------

local function onCharacterDeath(character)
    if not data or not instanceof(character, "IsoPlayer") or character:isAnimal() then return end

    local modData = character:getModData()
    local existing = modData[FYDS.TAG]
    if existing and data.records[existing] then return end

    local id = tostring(data.nextId)
    data.nextId = data.nextId + 1
    data.records[id] = FYDS.newRecord(id, character:getUsername() or "", characterName(character),
        character:getX(), character:getY(), character:getZ(), nowHours(),
        character:shouldBecomeZombieAfterDeath())
    -- The corpse copies the character's mod data when it is created, after this event.
    modData[FYDS.TAG] = id

    pendingDeaths[character] = { elapsedMs = 0 }
    recordsChanged()
end

local function forceCorpse(player)
    local ok, err = pcall(function() player:die() end)
    if not ok then
        print("[FindYourDeadSelf] could not create corpse: " .. tostring(err))
    end
end

local function updatePendingDeaths(deltaMs)
    local done = {}
    for player, watch in pairs(pendingDeaths) do
        if player:isOnDeathDone() then
            done[#done + 1] = player
        else
            watch.elapsedMs = watch.elapsedMs + deltaMs
            if not player:isDead() then
                -- Healed after the death was already final (god mode): undo it.
                if player:isGodMod() then player:setGodMod(false) end
                player:setHealth(0)
                local bodyDamage = player:getBodyDamage()
                if bodyDamage then bodyDamage:setOverallBodyHealth(0) end
                watch.revivedMs = watch.revivedMs or watch.elapsedMs
            end
            if (watch.revivedMs and watch.elapsedMs - watch.revivedMs >= REVIVED_GRACE_MS)
                    or watch.elapsedMs >= STUCK_TIMEOUT_MS then
                done[#done + 1] = player
                forceCorpse(player)
            end
        end
    end
    for i = 1, #done do
        pendingDeaths[done[i]] = nil
    end
end

---------------------------------------------------------------------------
-- Zombies
---------------------------------------------------------------------------

local function onZombieDead(zombie)
    if not data or not zombie:hasModData() then return end
    local id = zombie:getModData()[FYDS.TAG]
    local rec = id and data.records[id]
    if not rec or not FYDS.needsTracking(rec) then return end
    FYDS.markKilled(rec, zombie:getX(), zombie:getY(), zombie:getZ(), nowHours())
    zombies[id] = nil
    recordsChanged()
end

local function trackKnownZombies()
    local forget = {}
    for id, zombie in pairs(zombies) do
        local rec = data.records[id]
        if not rec or not isOurZombie(zombie, id) then
            forget[#forget + 1] = id
        elseif zombie:isDead() then
            -- Killed without us seeing OnZombieDead.
            FYDS.markKilled(rec, zombie:getX(), zombie:getY(), zombie:getZ(), nowHours())
            forget[#forget + 1] = id
            recordsChanged()
        elseif not zombie:isExistInTheWorld() then
            -- Unloaded: the record keeps its last known position.
            forget[#forget + 1] = id
        elseif rec.state ~= FYDS.STATE_ZOMBIE then
            FYDS.markReanimated(rec, zombie:getX(), zombie:getY(), zombie:getZ())
            recordsChanged()
        else
            local x, y = zombie:getX(), zombie:getY()
            if math.abs(x - rec.x) >= MOVE_THRESHOLD or math.abs(y - rec.y) >= MOVE_THRESHOLD then
                FYDS.setPosition(rec, x, y, zombie:getZ())
                dirty = true
            end
        end
    end
    for i = 1, #forget do
        zombies[forget[i]] = nil
    end
end

local function hasUnfoundZombies()
    for id, rec in pairs(data.records) do
        if FYDS.needsTracking(rec) and not zombies[id] then return true end
    end
    return false
end

local function scanForZombies()
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local zombie = list:get(i)
        if zombie:isReanimatedPlayer() and zombie:hasModData() then
            local id = zombie:getModData()[FYDS.TAG]
            local rec = id and data.records[id]
            if rec and FYDS.needsTracking(rec) and not zombie:isDead() then
                zombies[id] = zombie
            end
        end
    end
end

---------------------------------------------------------------------------
-- Countdown
---------------------------------------------------------------------------

local function expireRecords()
    local hours = SandboxVars.HoursForCorpseRemoval
    local now = nowHours()
    local removePlayer = removePlayerCorpses()
    local keep = keepCorpses()
    local expired = {}
    for id, rec in pairs(data.records) do
        if FYDS.isExpired(rec, now, hours, removePlayer, keep) then
            expired[#expired + 1] = id
        end
    end
    for i = 1, #expired do
        data.records[expired[i]] = nil
        zombies[expired[i]] = nil
        recordsChanged()
    end
end

---------------------------------------------------------------------------
-- Your Corpse Never Rots
---------------------------------------------------------------------------

-- Squares around each of our corpses, so LoadGridsquare can skip every other
-- square with one table lookup. One tile of slack covers a ragdoll slide.
local function rebuildCorpseSquares()
    corpseSquares = {}
    hasCorpseSquares = false
    if not keepCorpses() then return end
    for _, rec in pairs(data.records) do
        if rec.state == FYDS.STATE_CORPSE then
            local cx, cy = math.floor(rec.x), math.floor(rec.y)
            for x = cx - 1, cx + 1 do
                local column = corpseSquares[x] or {}
                corpseSquares[x] = column
                for y = cy - 1, cy + 1 do column[y] = true end
            end
            hasCorpseSquares = true
        end
    end
end

local function freshenBodies(square, now)
    local bodies = square:getDeadBodys()
    for i = 0, bodies:size() - 1 do
        local body = bodies:get(i)
        if body:hasModData() then
            local id = body:getModData()[FYDS.TAG]
            local rec = id and data.records[id]
            if rec and rec.state == FYDS.STATE_CORPSE then
                body:setDeathTime(now)
            end
        end
    end
end

local function freshenLoadedCorpses()
    local cell = getCell()
    local now = nowHours()
    for _, rec in pairs(data.records) do
        if rec.state == FYDS.STATE_CORPSE then
            local cx, cy, z = math.floor(rec.x), math.floor(rec.y), math.floor(rec.z or 0)
            for x = cx - 1, cx + 1 do
                for y = cy - 1, cy + 1 do
                    local square = cell:getGridSquare(x, y, z)
                    if square then freshenBodies(square, now) end
                end
            end
        end
    end
end

local function onLoadGridsquare(square)
    if not data then return end
    if corpsesMoved then
        corpsesMoved = false
        rebuildCorpseSquares()
    end
    if not hasCorpseSquares then return end
    local column = corpseSquares[square:getX()]
    if column and column[square:getY()] then
        freshenBodies(square, nowHours())
    end
end

---------------------------------------------------------------------------
-- Multiplayer sync
---------------------------------------------------------------------------

local function sameFaction(ownerName, viewerName)
    local ownerFaction = Faction.getPlayerFaction(ownerName)
    if not ownerFaction then return false end
    local viewerFaction = Faction.getPlayerFaction(viewerName)
    return viewerFaction ~= nil and viewerFaction:getName() == ownerFaction:getName()
end

local function canSee(rec, player)
    local visibility = options().Visibility or FYDS.VISIBILITY_ONLY_ME
    return FYDS.canSee(rec, player:getUsername(), visibility, sameFaction)
end

local function visibleRecordsFor(player)
    local list = {}
    local key = FYDS.viewerKey(player)
    for _, rec in pairs(data.records) do
        if canSee(rec, player) and not FYDS.isErasedFor(rec, key) then
            list[#list + 1] = { id = rec.id, name = rec.name, x = rec.x, y = rec.y, state = rec.state }
        end
    end
    return list
end

local function sendTo(player)
    sendServerCommand(player, FYDS.MOD_ID, "records", { records = visibleRecordsFor(player) })
end

local function syncAll()
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        sendTo(players:get(i))
    end
end

local function erase(player, id)
    local rec = id and data.records[id]
    -- Singleplayer shows every skull to whoever plays; MP only lets you erase what you see.
    if not rec or (isServer() and not canSee(rec, player)) then return end
    FYDS.markErased(rec, FYDS.viewerKey(player))
    dirty = true
end

local function onClientCommand(module, command, player, args)
    if module ~= FYDS.MOD_ID or not data then return end
    if command == "request" then
        sendTo(player)
    elseif command == "erase" and args then
        erase(player, args.id)
    end
end

---------------------------------------------------------------------------
-- Ticking
---------------------------------------------------------------------------

local function onTick()
    if not data then return end
    local nowMs = getTimestampMs()
    local deltaMs = lastTickMs and (nowMs - lastTickMs) or 0
    lastTickMs = nowMs

    if not FYDS.isEmpty(pendingDeaths) then
        updatePendingDeaths(isGamePaused() and 0 or deltaMs)
    end
    if nowMs >= nextTrackMs then
        nextTrackMs = nowMs + TRACK_INTERVAL_MS
        if not FYDS.isEmpty(zombies) then trackKnownZombies() end
    end
    if nowMs >= nextScanMs then
        nextScanMs = nowMs + SCAN_INTERVAL_MS
        if hasUnfoundZombies() then scanForZombies() end
    end
    if nowMs >= nextExpireMs then
        nextExpireMs = nowMs + EXPIRE_INTERVAL_MS
        expireRecords()
    end
    if nowMs >= nextFreshenMs then
        nextFreshenMs = nowMs + FRESHEN_INTERVAL_MS
        -- Rebuilt here too, so a sandbox option changed mid-game takes effect.
        corpsesMoved = false
        rebuildCorpseSquares()
        if hasCorpseSquares then freshenLoadedCorpses() end
    end
    if isServer() and (dirty or nowMs >= nextResyncMs) then
        dirty = false
        nextResyncMs = nowMs + RESYNC_INTERVAL_MS
        syncAll()
    end
end

local function onInitGlobalModData()
    data = ModData.getOrCreate(FYDS.DATA_KEY)
    data.nextId = data.nextId or 1
    data.records = data.records or {}
end

-- Singleplayer: the map code runs in this same Lua state and reads from here.
function FYDS.getAuthorityRecords()
    return data and data.records
end

function FYDS.eraseRecord(player, id)
    if data then erase(player, id) end
end

function FYDS.getLiveZombie(id)
    local zombie = zombies[id]
    if zombie and isOurZombie(zombie, id) and not zombie:isDead() then return zombie end
    return nil
end

Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.OnCharacterDeath.Add(onCharacterDeath)
Events.OnZombieDead.Add(onZombieDead)
Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
Events.LoadGridsquare.Add(onLoadGridsquare)
