--[[
    Find Your Dead Self - world map skulls.

    Draws a red skull and the character's name on the world map for every death
    record this player may see. Nothing runs unless the world map is open.

    Singleplayer: records are read straight from the record keeper
    (FYDS_Server.lua), which runs in the same Lua state, and a zombie that is in
    a loaded area is drawn at its live position.
    Multiplayer: the server sends the visible records (see FYDS_Server.lua);
    we ask for them once when the game starts.

    Erasing: the map's own Remove tool erases a skull, so like any map marking
    it needs an eraser (the game greys the tool out without one). It only hides
    the skull from this player's map; the corpse is not affected.
--]]

if isServer() then return end

require "FindYourDeadSelf/FYDS_Core"
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISWorldMapSymbols"

local SKULL_TEXTURE = "media/ui/LootableMaps/map_skull.png" -- vanilla map symbol
local RED, GREEN, BLUE = 0.85, 0.08, 0.08
local MIN_ICON_SIZE, MAX_ICON_SIZE = 18, 28
local MIN_ZOOM, MAX_ZOOM = 12, 18 -- icon grows between these map zoom levels

local receivedRecords = {} -- multiplayer only
local drawnSkulls = {}     -- skulls on screen in the last frame, for the Remove tool
local skullTexture

local function getRecords()
    if FYDS.getAuthorityRecords then
        return FYDS.getAuthorityRecords()
    end
    return receivedRecords
end

local function iconSize(map)
    local t = (map.mapAPI:getZoomF() - MIN_ZOOM) / (MAX_ZOOM - MIN_ZOOM)
    t = math.min(math.max(t, 0), 1)
    return MIN_ICON_SIZE + (MAX_ICON_SIZE - MIN_ICON_SIZE) * t
end

local function isRemoveToolActive(map)
    local symbolsUI = map.symbolsUI
    return symbolsUI ~= nil and symbolsUI.currentTool ~= nil
        and symbolsUI.currentTool == symbolsUI.tools.RemoveAnnotation
end

local function skullUnderMouse(map)
    local mx, my = map:getMouseX(), map:getMouseY()
    for i = #drawnSkulls, 1, -1 do
        local skull = drawnSkulls[i]
        if mx >= skull.x and my >= skull.y and mx < skull.x + skull.size and my < skull.y + skull.size then
            return skull
        end
    end
    return nil
end

local function renderSkulls(map)
    drawnSkulls = {}
    local records = getRecords()
    if not records or FYDS.isEmpty(records) then return end
    skullTexture = skullTexture or getTexture(SKULL_TEXTURE)
    if not skullTexture then return end

    local api = map.mapAPI
    local size = iconSize(map)
    local half = size / 2
    local font = UIFont.Small
    local fontHeight = getTextManager():getFontHeight(font)
    local character = map.character or getSpecificPlayer(map.playerNum or 0)
    local key = character and FYDS.viewerKey(character)

    for _, rec in pairs(records) do
        if not (key and FYDS.isErasedFor(rec, key)) then
            local x, y = rec.x, rec.y
            local zombie = FYDS.getLiveZombie and FYDS.getLiveZombie(rec.id)
            if zombie then
                x, y = zombie:getX(), zombie:getY()
            end
            local sx = api:worldToUIX(x, y)
            local sy = api:worldToUIY(x, y)
            if sx > -size and sy > -size and sx < map.width + size and sy < map.height + size then
                map:drawTextureScaledAspect(skullTexture, sx - half, sy - half, size, size, 1, RED, GREEN, BLUE)
                if rec.name then
                    map:drawText(rec.name, sx + half + 2, sy - fontHeight / 2, RED, GREEN, BLUE, 1, font)
                end
                drawnSkulls[#drawnSkulls + 1] = { id = rec.id, name = rec.name, x = sx - half, y = sy - half, size = size }
            end
        end
    end

    if isRemoveToolActive(map) then
        local skull = skullUnderMouse(map)
        if skull then
            map:drawRectBorder(skull.x - 2, skull.y - 2, skull.size + 4, skull.size + 4, 1, 1, 1, 1)
        end
    end
end

local function erase(character, id)
    if FYDS.eraseRecord then
        FYDS.eraseRecord(character, id)
    else
        sendClientCommand(FYDS.MOD_ID, "erase", { id = id })
        for i = #receivedRecords, 1, -1 do
            if receivedRecords[i].id == id then table.remove(receivedRecords, i) end
        end
    end
    character:playSoundLocal("MapRemoveMarking")
end

local function onConfirmErase(tool, button, id)
    if button.internal == "YES" and tool.symbolsUI.character then
        erase(tool.symbolsUI.character, id)
    end
end

local originalPrerender = ISWorldMap.prerender
function ISWorldMap:prerender()
    originalPrerender(self)
    renderSkulls(self)
end

-- Clicking a skull with the Remove tool asks to erase it; any other click is vanilla.
local originalRemoveMouseDown = ISWorldMapSymbolTool_RemoveAnnotation.onMouseDown
function ISWorldMapSymbolTool_RemoveAnnotation:onMouseDown(x, y)
    if not self.mapUI.javaObject:isMapEditor() and self.symbolsUI.character then
        local skull = skullUnderMouse(self.mapUI)
        if skull then
            local text = getText("IGUI_FYDS_EraseConfirm", skull.name or "?")
            local modal = ISModalRichText:new(0, 0, 380, 120, text, true, self, onConfirmErase, self.symbolsUI.playerNum, skull.id)
            modal:initialise()
            modal:addToUIManager()
            modal:setAlwaysOnTop(true)
            self.modal = modal
            return true
        end
    end
    return originalRemoveMouseDown(self, x, y)
end

local function onServerCommand(module, command, args)
    if module ~= FYDS.MOD_ID then return end
    if command == "records" then
        receivedRecords = args.records or {}
    end
end

local function onGameStart()
    if isClient() then
        sendClientCommand(FYDS.MOD_ID, "request", {})
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onGameStart)
