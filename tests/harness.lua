--[[
    Test harness: assertions and a mock of the bits of the Project Zomboid API
    the mod uses. Mock behaviour follows the game code (B42.21) where it matters:
      * a corpse copies its character's mod data, a reanimated zombie copies
        its corpse's mod data;
      * setGodMod() is refused while the character is dead;
      * setHealth(0) is refused while god mode is on;
      * god mode heals the character back to full every update.
--]]

MOD = ROOT .. "/Contents/mods/PZFindYourDeadSelf/common/media/lua/"

local passed, failed = 0, 0

function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. ": " .. tostring(err))
    end
end

function finish(suite)
    print(suite .. ": " .. passed .. " passed, " .. failed .. " failed")
    if failed > 0 then error(suite .. ": " .. failed .. " test(s) failed") end
end

function eq(actual, expected, what)
    if actual ~= expected then
        error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

function truthy(v, what)
    if not v then error((what or "value") .. ": expected true, got " .. tostring(v)) end
end

function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

function javaList(t)
    return {
        size = function() return #t end,
        get = function(_, i) return t[i + 1] end,
    }
end

---------------------------------------------------------------------------
-- Game mock
---------------------------------------------------------------------------

function setupGame(opts)
    opts = opts or {}
    local game = {
        now = opts.now or 100,     -- world age hours
        ms = 1000000,              -- real time ms
        paused = false,
        client = opts.client or false,
        server = opts.server or false,
        store = opts.store or {},  -- global mod data, survives "reloads"
        zombieList = {},
        online = {},
        factions = {},
        serverOptions = {},
        sent = {},
        clientSent = {},
    }

    FYDS = nil
    Events = setmetatable({}, { __index = function(t, name)
        local ev = { handlers = {} }
        ev.Add = function(fn) ev.handlers[#ev.handlers + 1] = fn end
        rawset(t, name, ev)
        return ev
    end })

    require = function() end
    isClient = function() return game.client end
    isServer = function() return game.server end
    getGameTime = function() return { getWorldAgeHours = function() return game.now end } end
    getTimestampMs = function() return game.ms end
    isGamePaused = function() return game.paused end
    getServerOptions = function()
        return { getBoolean = function(_, name) return game.serverOptions[name] == true end }
    end
    SandboxVars = { HoursForCorpseRemoval = opts.hours or 216, PZFindYourDeadSelf = { Visibility = 1, AlwaysLeaveBody = true } }
    ModData = { getOrCreate = function(key)
        game.store[key] = game.store[key] or {}
        return game.store[key]
    end }
    instanceof = function(o, class) return type(o) == "table" and o.classes ~= nil and o.classes[class] == true end
    getCell = function() return { getZombieList = function() return javaList(game.zombieList) end } end
    getOnlinePlayers = function() return javaList(game.online) end
    sendServerCommand = function(player, module, command, args)
        game.sent[#game.sent + 1] = { player = player, module = module, command = command, args = args }
    end
    sendClientCommand = function(module, command, args)
        game.clientSent[#game.clientSent + 1] = { module = module, command = command, args = args }
    end
    Faction = { getPlayerFaction = function(name)
        local factionName = game.factions[name]
        if factionName then return { getName = function() return factionName end } end
        return nil
    end }
    return game
end

function fire(name, a, b, c, d)
    local ev = rawget(Events, name)
    if not ev then return end
    for i = 1, #ev.handlers do ev.handlers[i](a, b, c, d) end
end

function loadServer(game)
    dofile(MOD .. "shared/FindYourDeadSelf/FYDS_Core.lua")
    dofile(MOD .. "server/FindYourDeadSelf/FYDS_Server.lua")
    fire("OnInitGlobalModData", false)
end

-- Runs OnTick every stepMs for totalMs, letting god-mode characters heal in between.
function tickFor(game, totalMs, stepMs, gods)
    stepMs = stepMs or 100
    local elapsed = 0
    while elapsed < totalMs do
        game.ms = game.ms + stepMs
        elapsed = elapsed + stepMs
        if gods then
            for i = 1, #gods do gods[i]:update() end
        end
        fire("OnTick", 0)
    end
end

function records()
    return FYDS.getAuthorityRecords()
end

function onlyRecord()
    local only
    for _, rec in pairs(records()) do
        if only then error("more than one record") end
        only = rec
    end
    truthy(only, "a record")
    return only
end

---------------------------------------------------------------------------
-- Characters
---------------------------------------------------------------------------

function newPlayer(o)
    o = o or {}
    local p = {
        classes = { IsoPlayer = true, IsoGameCharacter = true },
        modData = {},
        x = o.x or 10.5, y = o.y or 20.5, z = o.z or 0,
        username = o.username or "bob",
        forename = o.forename or "Bob", surname = o.surname or "Smith",
        infected = o.infected or false,
        animal = o.animal or false,
        health = 100,
        godMod = false,
        deathDone = false,
        dieCalls = 0,
    }
    function p:getModData() return self.modData end
    function p:isAnimal() return self.animal end
    function p:getUsername() return self.username end
    function p:getDescriptor()
        local s = self
        return { getForename = function() return s.forename end, getSurname = function() return s.surname end }
    end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:shouldBecomeZombieAfterDeath() return self.infected end
    function p:isOnDeathDone() return self.deathDone end
    function p:isDead() return self.health <= 0 end
    function p:isGodMod() return self.godMod end
    function p:setGodMod(on) if not self:isDead() then self.godMod = on end end
    function p:setHealth(h) if h == 0 and self.godMod then return end self.health = h end
    function p:getBodyDamage()
        local s = self
        return { setOverallBodyHealth = function(_, h) s.health = h end }
    end
    function p:die()
        self.dieCalls = self.dieCalls + 1
        if self.deathDone then return end
        self.corpse = { modData = copy(self.modData), x = self.x, y = self.y, z = self.z }
        self.deathDone = true
    end
    -- One game update: god mode restores full health.
    function p:update() if self.godMod then self.health = 100 end end
    -- Health reaches 0: the game fires OnCharacterDeath.
    function p:kill(game)
        self.health = 0
        fire("OnCharacterDeath", self)
    end
    return p
end

function newZombie(modData, x, y)
    local z = {
        classes = { IsoZombie = true, IsoGameCharacter = true },
        modData = modData,
        x = x or 0, y = y or 0, z = 0,
        reanimatedPlayer = true,
        dead = false,
        inWorld = true,
    }
    function z:hasModData() return self.modData ~= nil end
    function z:getModData()
        self.modData = self.modData or {}
        return self.modData
    end
    function z:isReanimatedPlayer() return self.reanimatedPlayer end
    function z:isDead() return self.dead end
    function z:isExistInTheWorld() return self.inWorld end
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return self.z end
    return z
end

-- The corpse gets up: the new zombie copies the corpse's mod data.
function reanimate(game, corpse, x, y)
    local z = newZombie(copy(corpse.modData), x or corpse.x, y or corpse.y)
    game.zombieList[#game.zombieList + 1] = z
    return z
end

function removeFromList(game, zombie)
    for i = #game.zombieList, 1, -1 do
        if game.zombieList[i] == zombie then table.remove(game.zombieList, i) end
    end
end
