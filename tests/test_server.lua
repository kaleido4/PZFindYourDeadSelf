dofile(ROOT .. "/tests/harness.lua")

local H = 216

test("a death creates a corpse record and tags the character", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ x = 12.5, y = 34.5 })
    p:kill(game)
    local rec = onlyRecord()
    eq(rec.name, "Bob Smith", "name")
    eq(rec.owner, "bob", "owner")
    eq(rec.x, 12.5, "x")
    eq(rec.state, FYDS.STATE_CORPSE, "state")
    eq(p.modData[FYDS.TAG], rec.id, "tag on character")
end)

test("the corpse made by the game carries the tag", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p:die() -- PlayerOnGroundState
    eq(p.corpse.modData[FYDS.TAG], onlyRecord().id, "tag on corpse")
end)

test("animals and zombies do not create records", function()
    local game = setupGame()
    loadServer(game)
    local animal = newPlayer({ animal = true })
    animal:kill(game)
    fire("OnCharacterDeath", newZombie(nil, 1, 1))
    eq(count(records()), 0, "records")
end)

test("a repeated death event does not create a second record", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    fire("OnCharacterDeath", p)
    eq(count(records()), 1, "records")
end)

test("normal death: no forced corpse when the game makes one", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    tickFor(game, 1500)
    p:die()
    tickFor(game, 30000)
    eq(p.dieCalls, 1, "die calls")
end)

test("god mode during the death animation: god mode turned off, corpse forced", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p.godMod = true -- switched on a moment too late
    p:update()      -- heals the dying body back to "alive"
    eq(p:isDead(), false, "healed")
    tickFor(game, 100, 100, { p })
    eq(p.godMod, false, "god mode off")
    eq(p:isDead(), true, "dead again")
    tickFor(game, 2500, 100, { p })
    truthy(p.corpse, "corpse created")
    eq(p.corpse.modData[FYDS.TAG], onlyRecord().id, "corpse tagged")
    eq(p.dieCalls, 1, "die calls")
end)

test("stuck death (never reaches the ground state): corpse forced after 15s", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    tickFor(game, 14000)
    eq(p.corpse, nil, "not yet")
    tickFor(game, 1500)
    truthy(p.corpse, "corpse created")
end)

test("paused time does not count toward the stuck timeout", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    game.paused = true
    tickFor(game, 60000, 500)
    eq(p.corpse, nil, "no corpse while paused")
    game.paused = false
    tickFor(game, 15500)
    truthy(p.corpse, "corpse after unpausing")
end)

test("the god mode fix is always on, whatever the sandbox options", function()
    local game = setupGame()
    SandboxVars.PZFindYourDeadSelf = {}
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p.godMod = true
    p:update()
    tickFor(game, 2500, 100, { p })
    truthy(p.corpse, "corpse created")
end)

test("Never Rots off: corpses age normally", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p:die()
    local born = p.corpse.deathTime
    game.now = game.now + 100
    tickFor(game, 11000)
    eq(p.corpse.deathTime, born, "death time untouched")
end)

test("Never Rots on: a loaded corpse stays fresh and its skull never expires", function()
    local game = setupGame({ hours = 24 })
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    game.serverOptions.RemovePlayerCorpsesOnCorpseRemoval = true
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p:die()
    game.now = game.now + 100
    tickFor(game, 11000)
    eq(p.corpse.deathTime, game.now, "freshened")
    eq(count(records()), 1, "skull kept")
end)

test("Never Rots on: the corpse of our killed zombie stays fresh where it fell", function()
    local game = setupGame({ hours = 24 })
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x, z.y, z.dead = 33.5, 44.5, true
    fire("OnZombieDead", z)
    local body = dropBody(game, copy(z.modData), z.x, z.y, 0)
    game.now = game.now + 500
    tickFor(game, 11000)
    eq(body.deathTime, game.now, "freshened")
    eq(count(records()), 1, "skull kept")
end)

test("Never Rots on: a corpse is refreshed the moment its area loads", function()
    local game = setupGame()
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    loadServer(game)
    local p = newPlayer({ x = 10.5, y = 20.5 })
    p:kill(game)
    p:die()
    tickFor(game, 11000)
    local square = p.corpse.square
    unloadSquare(game, square)
    game.now = game.now + 1000
    tickFor(game, 11000)
    eq(p.corpse.deathTime < game.now, true, "not refreshed while unloaded")
    loadSquare(game, square)
    eq(p.corpse.deathTime, game.now, "refreshed on load")
end)

test("Never Rots on: other squares and other corpses are left alone", function()
    local game = setupGame()
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    loadServer(game)
    local p = newPlayer({ x = 10.5, y = 20.5 })
    p:kill(game)
    p:die()
    local stranger = dropBody(game, nil, 10.5, 20.5, 0)
    local far = newSquare(game, 500, 500, 0)
    game.now = game.now + 100
    loadSquare(game, far)
    eq(far.bodyQueries, 0, "far square not searched")
    tickFor(game, 11000)
    eq(stranger.deathTime < game.now, true, "untagged corpse untouched")
    eq(p.corpse.deathTime, game.now, "ours freshened")
end)

test("Never Rots switched on mid-game takes effect", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p:die()
    tickFor(game, 11000)
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    game.now = game.now + 100
    tickFor(game, 11000)
    eq(p.corpse.deathTime, game.now, "freshened")
end)

test("reanimation: found within the scan interval, countdown cleared, follows the zombie", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local rec = onlyRecord()
    truthy(rec.willReanimate, "willReanimate")
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    eq(rec.state, FYDS.STATE_ZOMBIE, "state")
    eq(rec.corpseSince, nil, "countdown cleared")
    z.x, z.y = 50.5, 60.5
    tickFor(game, 1100)
    eq(rec.x, 50.5, "x follows")
    eq(rec.y, 60.5, "y follows")
    eq(FYDS.getLiveZombie(rec.id), z, "live zombie for the map")
end)

test("small zombie movement is not stored", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true, x = 10, y = 10 })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x = 10.2
    tickFor(game, 1100)
    eq(onlyRecord().x, 10, "x unchanged")
end)

test("unloaded zombie keeps its last known position and is found again later", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x, z.y = 70, 80
    tickFor(game, 1100)
    z.inWorld = false
    removeFromList(game, z)
    z.x, z.y = 999, 999 -- position no longer valid once unloaded
    tickFor(game, 7000)
    local rec = onlyRecord()
    eq(rec.state, FYDS.STATE_ZOMBIE, "still a zombie")
    eq(rec.x, 70, "last known x")
    eq(FYDS.getLiveZombie(rec.id), nil, "not live")
    -- Back in a loaded area.
    z.inWorld, z.x, z.y = true, 75, 85
    game.zombieList[#game.zombieList + 1] = z
    tickFor(game, 6000)
    eq(rec.x, 75, "found again")
end)

test("zombie killed: static corpse with a fresh full countdown, then removed", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    game.now = 400
    z.x, z.y = 33, 44
    z.dead = true
    fire("OnZombieDead", z)
    local rec = onlyRecord()
    eq(rec.state, FYDS.STATE_CORPSE, "state")
    eq(rec.corpseSince, 400, "fresh countdown")
    eq(rec.x, 33, "where it fell")
    game.now = 400 + H - 1
    tickFor(game, 11000)
    eq(count(records()), 1, "still there just before")
    game.now = 400 + H
    tickFor(game, 11000)
    eq(count(records()), 0, "removed")
end)

test("zombie death noticed even without OnZombieDead", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.dead = true
    tickFor(game, 1100)
    eq(onlyRecord().state, FYDS.STATE_CORPSE, "state")
end)

test("other zombies are ignored", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    game.zombieList[1] = newZombie(nil, 1, 1)             -- ordinary zombie
    game.zombieList[2] = newZombie({ [FYDS.TAG] = "99" }, 2, 2) -- unknown id
    local ordinary = newZombie(nil, 3, 3)
    ordinary.reanimatedPlayer = false
    game.zombieList[3] = ordinary
    fire("OnZombieDead", ordinary)
    tickFor(game, 6000)
    eq(onlyRecord().state, FYDS.STATE_CORPSE, "unchanged")
end)

test("player corpse is kept forever by default, removed when the server option is on", function()
    local game = setupGame()
    loadServer(game)
    newPlayer():kill(game)
    game.now = game.now + 100000
    tickFor(game, 11000)
    eq(count(records()), 1, "kept")
    game.serverOptions.RemovePlayerCorpsesOnCorpseRemoval = true
    tickFor(game, 11000)
    eq(count(records()), 0, "removed")
end)

test("records survive a reload, and tracking resumes", function()
    local store = {}
    local game = setupGame({ store = store })
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local corpse = p.corpse
    -- Save, quit, load.
    game = setupGame({ store = store })
    loadServer(game)
    eq(count(records()), 1, "record kept")
    reanimate(game, corpse)
    tickFor(game, 6000)
    eq(onlyRecord().state, FYDS.STATE_ZOMBIE, "tracked after reload")
    local p2 = newPlayer({ username = "bob", forename = "Second" })
    p2:kill(game)
    eq(count(records()), 2, "ids do not collide")
end)

test("singleplayer sends nothing over the network", function()
    local game = setupGame()
    loadServer(game)
    newPlayer():kill(game)
    tickFor(game, 31000)
    eq(#game.sent, 0, "sent")
end)

test("MP client does not run the record keeper", function()
    local game = setupGame({ client = true })
    dofile(MOD .. "shared/FindYourDeadSelf/FYDS_Core.lua")
    dofile(MOD .. "server/FindYourDeadSelf/FYDS_Server.lua")
    eq(FYDS.getAuthorityRecords, nil, "no authority on client")
end)

local function lastSentTo(game, player)
    local last
    for i = 1, #game.sent do
        if game.sent[i].player == player then last = game.sent[i] end
    end
    return last
end

local function sentNames(msg)
    local names = {}
    for _, r in pairs(msg.args.records) do names[#names + 1] = r.name end
    table.sort(names)
    return table.concat(names, ",")
end

local function mpGame(visibility)
    local game = setupGame({ server = true })
    SandboxVars.PZFindYourDeadSelf.Visibility = visibility
    loadServer(game)
    local alice = newPlayer({ username = "alice", forename = "Alice", surname = "" })
    local carol = newPlayer({ username = "carol", forename = "Carol", surname = "" })
    local dave = newPlayer({ username = "dave", forename = "Dave", surname = "" })
    game.online = { alice, carol, dave }
    game.factions = { alice = "Red", carol = "Red", dave = "Blue" }
    local aliceOld = newPlayer({ username = "alice", forename = "OldAlice", surname = "" })
    local daveOld = newPlayer({ username = "dave", forename = "OldDave", surname = "" })
    aliceOld:kill(game)
    daveOld:kill(game)
    tickFor(game, 200)
    return game, alice, carol, dave
end

test("MP visibility: only me", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_ONLY_ME)
    eq(sentNames(lastSentTo(game, alice)), "OldAlice", "alice")
    eq(sentNames(lastSentTo(game, carol)), "", "carol")
    eq(sentNames(lastSentTo(game, dave)), "OldDave", "dave")
end)

test("MP visibility: me + faction", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_FACTION)
    eq(sentNames(lastSentTo(game, alice)), "OldAlice", "alice")
    eq(sentNames(lastSentTo(game, carol)), "OldAlice", "carol sees faction mate")
    eq(sentNames(lastSentTo(game, dave)), "OldDave", "dave")
end)

test("MP visibility: everyone", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_EVERYONE)
    eq(sentNames(lastSentTo(game, carol)), "OldAlice,OldDave", "carol")
end)

test("MP: a joining player's request is answered", function()
    local game, alice = mpGame(FYDS.VISIBILITY_ONLY_ME)
    game.sent = {}
    fire("OnClientCommand", FYDS.MOD_ID, "request", alice, {})
    eq(#game.sent, 1, "one reply")
    eq(sentNames(game.sent[1]), "OldAlice", "content")
    fire("OnClientCommand", "SomeOtherMod", "request", alice, {})
    eq(#game.sent, 1, "other modules ignored")
end)

test("MP: zombie movement is sent, an idle server is quiet until the resync", function()
    local game = setupGame({ server = true })
    loadServer(game)
    local alice = newPlayer({ username = "alice" })
    game.online = { alice }
    local old = newPlayer({ username = "alice", infected = true })
    old:kill(game)
    old:die()
    local z = reanimate(game, old.corpse)
    tickFor(game, 6000)
    game.sent = {}
    tickFor(game, 5000)
    eq(#game.sent, 0, "nothing while nothing changes")
    z.x = z.x + 5
    tickFor(game, 1100)
    eq(#game.sent, 1, "movement sent")
    eq(lastSentTo(game, alice).args.records[1].x, z.x, "new position")
end)

test("SP erase hides the skull but keeps the record, its countdown and Never Rots", function()
    local game = setupGame()
    SandboxVars.PZFindYourDeadSelf.KeepCorpse = true
    loadServer(game)
    local old = newPlayer({ username = "Bob" })
    old:kill(game)
    old:die()
    local rec = onlyRecord()
    local newChar = newPlayer({ username = "Alice" }) -- SP username can change per character
    FYDS.eraseRecord(newChar, rec.id)
    truthy(FYDS.isErasedFor(rec, FYDS.viewerKey(newChar)), "erased")
    eq(count(records()), 1, "record kept")
    game.now = game.now + 100
    tickFor(game, 11000)
    eq(old.corpse.deathTime, game.now, "still kept fresh")
end)

test("MP erase: only for the player who erased it, and only what they can see", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_FACTION)
    local aliceRecId
    for id, rec in pairs(records()) do
        if rec.name == "OldAlice" then aliceRecId = id end
    end
    fire("OnClientCommand", FYDS.MOD_ID, "erase", carol, { id = aliceRecId })
    tickFor(game, 200)
    eq(sentNames(lastSentTo(game, carol)), "", "gone for carol")
    eq(sentNames(lastSentTo(game, alice)), "OldAlice", "alice still sees hers")
    -- dave is in another faction and cannot see Alice's skull, so cannot erase it.
    local daveRecId
    for id, rec in pairs(records()) do
        if rec.name == "OldDave" then daveRecId = id end
    end
    fire("OnClientCommand", FYDS.MOD_ID, "erase", carol, { id = daveRecId })
    eq(FYDS.isErasedFor(records()[daveRecId], "carol"), false, "unseen skull not erasable")
    fire("OnClientCommand", FYDS.MOD_ID, "erase", alice, { id = "does-not-exist" })
    fire("OnClientCommand", FYDS.MOD_ID, "erase", alice, nil)
end)

finish("server")
