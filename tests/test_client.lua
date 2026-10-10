dofile(ROOT .. "/tests/harness.lua")

-- Minimal world map: 1 tile = 2 px, origin at the top left.
local function setupMap()
    local prerenderCalls = 0
    ISWorldMap = {}
    function ISWorldMap:prerender() prerenderCalls = prerenderCalls + 1 end
    UIFont = { Small = "Small" }
    getTexture = function(path) return { path = path } end
    getTextManager = function() return { getFontHeight = function() return 10 end } end

    local map = setmetatable({ width = 800, height = 600, textures = {}, texts = {} }, { __index = ISWorldMap })
    map.mapAPI = {
        getZoomF = function() return 15 end,
        worldToUIX = function(_, x, y) return x * 2 end,
        worldToUIY = function(_, x, y) return y * 2 end,
    }
    function map:drawTextureScaledAspect(tex, x, y, w, h, a, r, g, b)
        self.textures[#self.textures + 1] = { tex = tex, x = x, y = y, w = w, r = r, g = g, b = b }
    end
    function map:drawText(text, x, y, r, g, b, a, font)
        self.texts[#self.texts + 1] = { text = text, x = x, y = y }
    end
    return map, function() return prerenderCalls end
end

local function loadClient()
    dofile(MOD .. "shared/FindYourDeadSelf/FYDS_Core.lua")
    dofile(MOD .. "client/FindYourDeadSelf/FYDS_Client.lua")
end

test("singleplayer: one red skull and name per record, vanilla prerender still runs", function()
    local game = setupGame()
    local map, prerenderCalls = setupMap()
    loadServer(game)
    loadClient()
    newPlayer({ x = 100, y = 50 }):kill(game)
    map:prerender()
    eq(prerenderCalls(), 1, "vanilla prerender")
    eq(#map.textures, 1, "skulls")
    local skull = map.textures[1]
    eq(skull.tex.path, "media/ui/LootableMaps/map_skull.png", "texture")
    eq(skull.x + skull.w / 2, 200, "centered on x")
    eq(skull.y + skull.w / 2, 100, "centered on y")
    truthy(skull.r > 0.5 and skull.g < 0.2 and skull.b < 0.2, "red")
    eq(map.texts[1].text, "Bob Smith", "label")
end)

test("singleplayer: a live zombie is drawn at its current position", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    local p = newPlayer({ infected = true, x = 100, y = 50 })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x, z.y = 120.2, 60 -- moved less than the store threshold? no: drawn live anyway
    map:prerender()
    eq(map.textures[1].x + map.textures[1].w / 2, 240.4, "live x")
end)

test("nothing is drawn without records", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    map:prerender()
    eq(#map.textures, 0, "skulls")
end)

test("off-screen skulls are skipped", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    newPlayer({ x = 5000, y = 5000 }):kill(game)
    map:prerender()
    eq(#map.textures, 0, "skulls")
end)

test("multiplayer: asks the server once at game start and draws what it sends", function()
    local game = setupGame({ client = true })
    local map = setupMap()
    loadServer(game) -- returns early on an MP client
    loadClient()
    fire("OnGameStart")
    eq(#game.clientSent, 1, "request sent")
    eq(game.clientSent[1].command, "request", "command")
    fire("OnServerCommand", FYDS.MOD_ID, "records", { records = {
        { id = "1", name = "Alice", x = 10, y = 20, state = "corpse" },
        { id = "2", name = "Dave", x = 30, y = 40, state = "zombie" },
    } })
    fire("OnServerCommand", "SomeOtherMod", "records", { records = {} })
    map:prerender()
    eq(#map.textures, 2, "skulls")
    eq(map.texts[2].text, "Dave", "label")
end)

finish("client")
