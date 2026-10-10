dofile(ROOT .. "/tests/harness.lua")

-- Minimal world map: 1 tile = 2 px, origin at the top left.
local function setupMap()
    local prerenderCalls = 0
    ISWorldMap = {}
    function ISWorldMap:prerender() prerenderCalls = prerenderCalls + 1 end
    UIFont = { Small = "Small" }
    getTexture = function(path) return { path = path } end
    getTextManager = function() return { getFontHeight = function() return 10 end } end
    getText = function(key, arg) return key .. ":" .. tostring(arg) end

    -- Vanilla Remove tool and the confirmation dialog.
    VANILLA_REMOVE_CLICKS = 0
    ISWorldMapSymbolTool_RemoveAnnotation = {}
    function ISWorldMapSymbolTool_RemoveAnnotation:onMouseDown(x, y)
        VANILLA_REMOVE_CLICKS = VANILLA_REMOVE_CLICKS + 1
        return false
    end
    LAST_MODAL = nil
    ISModalRichText = { new = function(_, x, y, w, h, text, yesno, target, onclick, playerNum, param1)
        local modal = { text = text, target = target, onclick = onclick, param1 = param1 }
        function modal:initialise() end
        function modal:addToUIManager() end
        function modal:setAlwaysOnTop() end
        function modal:answer(internal) self.onclick(self.target, { internal = internal }, self.param1) end
        LAST_MODAL = modal
        return modal
    end }

    local map = setmetatable({ width = 800, height = 600, textures = {}, texts = {}, borders = {}, mouseX = 0, mouseY = 0 }, { __index = ISWorldMap })
    map.character = { sounds = {}, getUsername = function() return "Bob" end }
    function map.character:playSoundLocal(name) self.sounds[#self.sounds + 1] = name end
    map.symbolsUI = { tools = { RemoveAnnotation = "remove-tool" }, character = map.character }
    map.javaObject = { isMapEditor = function() return false end }
    function map:getMouseX() return self.mouseX end
    function map:getMouseY() return self.mouseY end
    function map:drawRectBorder(x, y, w, h) self.borders[#self.borders + 1] = { x = x, y = y } end
    -- The Remove tool instance the map hands mouse clicks to.
    map.removeTool = setmetatable({ mapUI = map, symbolsUI = map.symbolsUI, playerNum = 0 },
        { __index = ISWorldMapSymbolTool_RemoveAnnotation })
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

local function clickWithRemoveTool(map, x, y)
    map.symbolsUI.currentTool = "remove-tool"
    map.mouseX, map.mouseY = x, y
    map:prerender()
    return map.removeTool:onMouseDown(x, y)
end

test("Remove tool: hovering a skull highlights it, clicking asks first, yes erases it", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    newPlayer({ x = 100, y = 50 }):kill(game) -- skull centred at (200, 100)
    eq(clickWithRemoveTool(map, 201, 99), true, "click consumed")
    eq(#map.borders, 1, "hover highlight")
    eq(VANILLA_REMOVE_CLICKS, 0, "vanilla remove not called")
    truthy(LAST_MODAL, "confirmation shown")
    eq(LAST_MODAL.text, "IGUI_FYDS_EraseConfirm:Bob Smith", "confirmation text")
    LAST_MODAL:answer("NO")
    map.textures = {}
    map:prerender()
    eq(#map.textures, 1, "no keeps it")
    LAST_MODAL:answer("YES")
    eq(map.character.sounds[1], "MapRemoveMarking", "eraser sound")
    map.textures = {}
    map:prerender()
    eq(#map.textures, 0, "erased from the map")
    eq(count(records()), 1, "record itself kept")
end)

test("Remove tool: a click away from skulls is a normal vanilla remove", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    newPlayer({ x = 100, y = 50 }):kill(game)
    LAST_MODAL = nil
    clickWithRemoveTool(map, 400, 400)
    eq(VANILLA_REMOVE_CLICKS, 1, "vanilla remove called")
    eq(LAST_MODAL, nil, "no confirmation")
    eq(#map.borders, 0, "no highlight")
end)

test("no highlight unless the Remove tool is selected", function()
    local game = setupGame()
    local map = setupMap()
    loadServer(game)
    loadClient()
    newPlayer({ x = 100, y = 50 }):kill(game)
    map.mouseX, map.mouseY = 200, 100
    map:prerender()
    eq(#map.borders, 0, "no highlight")
end)

test("multiplayer: erasing tells the server and hides the skull right away", function()
    local game = setupGame({ client = true })
    local map = setupMap()
    loadServer(game)
    loadClient()
    fire("OnServerCommand", FYDS.MOD_ID, "records", { records = {
        { id = "7", name = "Alice", x = 100, y = 50, state = "corpse" },
    } })
    clickWithRemoveTool(map, 200, 100)
    LAST_MODAL:answer("YES")
    local sent = game.clientSent[#game.clientSent]
    eq(sent.command, "erase", "command")
    eq(sent.args.id, "7", "id")
    map.textures = {}
    map:prerender()
    eq(#map.textures, 0, "hidden immediately")
end)

finish("client")
