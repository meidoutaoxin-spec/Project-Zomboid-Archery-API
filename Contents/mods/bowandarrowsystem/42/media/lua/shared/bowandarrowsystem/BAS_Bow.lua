-- Bow and Arrow System: bow registry, arrow nocking, arrow recovery.
--
-- NO VANILLA SHOT EVER HAPPENS. The bow is declared as a firearm-type item --
-- IsAimedFirearm keeps the vanilla aim state alive and MUST stay (removing it
-- crashes on a null BallisticsController, dictionary BAS2) -- but the arrow is
-- loosed entirely by the bow engine in BAS_Client.OnPlayerUpdate:
--   * ISReloadWeaponAction.canShoot() is forced to false  -> no hitscan, no
--     damage, no vanilla hit event
--   * the Attack hook returns before the vanilla handler  -> DoAttack() never
--     runs at all (dictionary BAS8)
-- Consequence for THIS file: the vanilla ammo counter is never read or written
-- and is always 0, and Events.OnHitZombie never fires for a bow. The nocked
-- state lives only in weapon ModData (BAS_nocked + BAS_lastArrow).
-- (An earlier version of this header claimed the bow "keeps a virtual round in
-- currentAmmoCount 0/1" -- that has not been true since the bow engine took
-- over the shot, and the recovery record is written from Lua instead; see
-- BAS_Projectile.hitZombie.)

-- MUST be global: BAS_Client.lua calls into this table.
BAS_Bow = {}

BAS_Bow.arrowTypes = {
	"BAS.BAS_Arrow",
}

BAS_Bow.recoveryChance = {
	["BAS.BAS_Arrow"] = 50,
}

-- How the bow engine claims a weapon. Three tiers, most declarative first:
--   1. item tag -- any item whose script says "Tags = BowEngine" (Java bridge)
--   2. registry -- BowAPI.BowAPI.registerBow(fullType, ...)       (Java bridge)
--   3. list     -- hard-coded fallback, works with no Java bridge at all
-- Tier 1 is the counterpart of the vanilla IsAimedFirearm: declare it in the
-- script and the engine takes over -- no code change, and it works for any
-- third-party bow. Tier 3 keeps the mod alive when the jar is unavailable
-- (ZombieBuddy not installed / not approved), so a missing bridge degrades to
-- "recognises only the built-in bows", never to "bow does nothing".
BAS_Bow.isBow = function(weapon)
	if not weapon then
		return false
	end
	local fullType = weapon:getFullType()
	-- The Java class is exposed under the DOTTED name "BowAPI.BowAPI"
	-- (@Exposer.LuaClass(name = "BowAPI.BowAPI") -> Exposer builds nested tables),
	-- so the static methods live one level deeper than the namespace table.
	-- Flat BowAPI.<method> is always nil, which silently skipped tiers 1 and 2.
	local api = BowAPI and BowAPI.BowAPI
	if api then
		if api.hasBowTag then
			local ok, tagged = pcall(function()
				return api.hasBowTag(weapon)
			end)
			if ok and tagged then
				return true
			end
		end
		if api.isBow then
			local ok2, known = pcall(function()
				return api.isBow(fullType)
			end)
			if ok2 and known then
				return true
			end
		end
	end
	return fullType == "BAS.BAS_Bow"
end

BAS_Bow.hasArrows = function(character)
	local inventory = character:getInventory()
	for i = 1, #BAS_Bow.arrowTypes do
		if inventory:getItemCountRecurse(BAS_Bow.arrowTypes[i]) > 0 then
			return true
		end
	end
	return false
end

-- consume one arrow from inventory, returns its full type or nil
-- (the mod ships a single arrow type now, so there is no priority order left)
BAS_Bow.consumeArrow = function(character)
	local inventory = character:getInventory()
	for i = 1, #BAS_Bow.arrowTypes do
		local fullType = BAS_Bow.arrowTypes[i]
		if inventory:getItemCountRecurse(fullType) > 0 then
			local items = inventory:getSomeTypeRecurse(fullType, 1)
			if items and not items:isEmpty() then
				local arrow = items:get(0)
				inventory:Remove(arrow)
				sendRemoveItemFromContainer(inventory, arrow)
				return fullType
			end
		end
	end
	return nil
end

-- Nock one arrow into the virtual chamber (server authority).
-- The arrow is consumed from the backpack here, NOT at shot time.
BAS_Bow.reload = function(character, weapon)
	if not BAS_Bow.isBow(weapon) then
		return
	end
	-- The nocked state lives ONLY in modData. The vanilla ammo counter is
	-- never read or written: a bow must not travel through the vanilla
	-- firearm engine at all.
	if weapon:getModData().BAS_nocked then
		return
	end
	local arrow = BAS_Bow.consumeArrow(character)
	if not arrow then
		return
	end
	weapon:getModData().BAS_lastArrow = arrow
	weapon:getModData().BAS_nocked = true
end

-- The nocked arrow was consumed at reload time; the vanilla onShoot handler
-- (ISReloadWeaponAction.onShoot) already emptied the virtual chamber after
-- the shot, so there is nothing left to do at swing time.

-- Recording which arrows are stuck in a zombie is done by
-- BAS_Projectile.hitZombie (the only code that ever hits anything with a bow --
-- see this file's header: the vanilla hit event never fires for one).
-- The old BAS_Bow.OnHitZombie lived here: it was registered nowhere, gated on
-- isServer(), and duplicated the same roll, so it could only ever double-count.
-- Dropped it.

-- Drop the recovered arrows on the ground next to the corpse.
BAS_Bow.OnZombieDead = function(zombie)
	-- NOT gated on isServer() (2026-09-19). isServer() is GameServer.server and
	-- it is measurably FALSE in singleplayer here (compendium note H13
	-- (8), notes 2026-08-11 final build, row 8: "isServer() is false on this setup -> the whole
	-- reload block never runs", backup notes 2026-08-18 bow system.md:43), so the guard here made
	-- this whole handler return early and the arrows never dropped: the roll in
	-- BAS_Projectile.hitZombie wrote modData.BAS_arrows, the corpse died, and
	-- nothing ever came back -- the mod's own "recover your arrows from fallen
	-- zombies" promise was dead. Safe to ungate: BAS_Bow is a SHARED file (loaded
	-- in both states) and clearing modData.BAS_arrows below makes it idempotent,
	-- so a double trigger cannot duplicate the drop.
	local modData = zombie:getModData()
	local arrows = modData.BAS_arrows
	if not arrows then
		return
	end
	local square = zombie:getSquare()
	if square then
		for fullType, count in pairs(arrows) do
			for i = 1, count do
				square:AddWorldInventoryItem(fullType, 0.2 + ZombRandFloat(0.0, 0.6), 0.2 + ZombRandFloat(0.0, 0.6), 0.0)
			end
		end
	end
	modData.BAS_arrows = nil
end

-- Prevent the unload key from spawning a free arrow from the virtual round.
local originalUnloadAnimEvent = ISUnloadBulletsFromFirearm.animEvent
function ISUnloadBulletsFromFirearm:animEvent(event, parameter)
	if self.gun and BAS_Bow.isBow(self.gun) then
		return
	end
	originalUnloadAnimEvent(self, event, parameter)
end

-- canShoot for the bow: ALWAYS false. Bows never fire through the vanilla
-- engine -- the bow engine looses the arrow itself in
-- BAS_Client.OnPlayerUpdate. (This used to gate on a loaded chamber plus a
-- fresh left-click edge; that mechanism is gone now that no vanilla shot
-- ever happens.)
local originalCanShoot = ISReloadWeaponAction.canShoot
function ISReloadWeaponAction.canShoot(player, weapon)
	-- Bows NEVER fire through the vanilla engine. The bow engine looses the
	-- arrow itself (see BAS_Client.OnPlayerUpdate), so returning false here
	-- also guarantees the vanilla hitscan never runs for this weapon --
	-- no damage, no hit reaction, no target list, nothing.
	if weapon and BAS_Bow.isBow(weapon) then
		return false
	end
	return originalCanShoot(player, weapon)
end

-- Attack hook: THE real takeover point (see dictionary entry BAS8).
-- IsoLivingCharacter.AttemptAttack() only calls DoAttack() itself when
-- TriggerHook("Attack") returns false, and Event.trigger() returns true
-- whenever ANY callback is registered. So the attack is launched BY THE HOOK,
-- never by the engine -- which is exactly why canShoot() alone was not enough:
-- the vanilla hook calls DoAttack(0) for ranged weapons even when canShoot()
-- is false (it only adds setRangedWeaponEmpty(true)), and DoAttack() reaches
-- CombatManager.attackCollisionCheck() where "isAimedFirearm" triggers
-- fireWeapon() -- the hitscan. Returning here for a bow means DoAttack() is
-- never called, so attackCollisionCheck() and fireWeapon() never run at all.
-- The arrow is loosed by BAS_Client.OnPlayerUpdate on left-button release.
do
	local vanillaAttackHook = ISReloadWeaponAction.attackHook
	if Hook and Hook.Attack and vanillaAttackHook then
		-- Add FIRST, Remove SECOND. Hook.Attack.Add captures the function
		-- value at registration time, so reassigning
		-- ISReloadWeaponAction.attackHook afterwards would have no effect --
		-- the registered closure has to be removed and a new one added.
		-- Order matters for safety: if Add fails we leave the vanilla hook
		-- installed (everything still works); the reverse order would leave
		-- NO attack hook at all if Add failed, breaking every weapon.
		local bowAttackHook = function(character, chargeDelta, weapon)
			if weapon and BAS_Bow.isBow(weapon) then
				return
			end
			vanillaAttackHook(character, chargeDelta, weapon)
		end
		local added = pcall(function()
			Hook.Attack.Add(bowAttackHook)
		end)
		if added then
			pcall(function()
				Hook.Attack.Remove(vanillaAttackHook)
			end)
		end
	end
end

-- MP: client pressed R, server performs the actual reload.
BAS_Bow.OnClientCommand = function(module, command, player, args)
	if module ~= "BAS" or command ~= "Reload" then
		return
	end
	BAS_Bow.reload(player, player:getPrimaryHandItem())
end

Events.OnClientCommand.Add(BAS_Bow.OnClientCommand)
Events.OnZombieDead.Add(BAS_Bow.OnZombieDead)
