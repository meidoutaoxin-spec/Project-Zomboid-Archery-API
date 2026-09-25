-- Bow and Arrow System: client side
-- Manual loading: R key nocks one arrow into the virtual chamber
-- (currentAmmoCount 0/1, no MaxAmmo/AmmoType fields: a custom AmmoType
-- cannot register before scripts parse and a null ammo type crashes the
-- weapon tooltip, so the vanilla firearm engine is fed a fake round).

-- NOT a file-local, on purpose: BAS_Projectile.lua reads BAS_Client.charge and
-- BAS_Client.CHARGE_MAX from ITS OWN chunk, and a file-level `local` is
-- invisible across files. That silently made every arrow resolve at a FULL
-- draw -- `charge = (BAS_Client and BAS_Client.charge) or 100` always saw nil
-- and fell through to 100 -- so the damage curve was dead and every hit landed
-- at full power. (Same trap as dictionary CF: file-locals do not cross files.)
BAS_Client = BAS_Client or {}

BAS_Client.arrowTypes = {
	"BAS.BAS_Arrow",
}

BAS_Client.isBow = function(weapon)
	if not weapon then
		return false
	end
	if not instanceof(weapon, "InventoryItem") then
		return false
	end
	-- Single source of truth: defer to the shared tiered recognition
	-- (tag -> registry -> fallback list, see BAS_Bow.isBow).
	return BAS_Bow.isBow(weapon)
end

BAS_Client.hasArrows = function(character)
	local inventory = character:getInventory()
	for i = 1, #BAS_Client.arrowTypes do
		if inventory:getItemCountRecurse(BAS_Client.arrowTypes[i]) > 0 then
			return true
		end
	end
	return false
end

-- Nock delay (see NOCK_TIME below; it no longer scales with the Reloading
-- skill) and the charge/draw system.
-- ---------------------------------------------------------------------------
-- Charge system (2026-09-19, Minecraft draw curve)
--
-- Hold RMB to draw, release to loose. The charge runs 0..CHARGE_MAX along
-- Minecraft's own draw curve (BowItem.getPowerForTime):
--
--     charge(t) = CHARGE_MAX * (t * t + 2 * t) / 3
--
-- Fast at the start and slow at the end: a quarter of the draw already gives
-- 19% of the power and half the draw gives 42%, so the second half is where the
-- real gain is -- that is what turns a full draw into a real commitment.
-- (The previous curve, CHARGE_MAX * (1 - (1 - t)^2), handed over 75% at the
-- halfway mark and left the last stretch worth almost nothing.)
--
-- One-line alternatives if the feel is wrong:
--     CHARGE_MAX * (1 - (1 - t)^2)   -- the old front-loaded parabola
--     CHARGE_MAX * t * t             -- opens upward (slow start, rushed finish)
--     CHARGE_MAX * t                 -- the old straight ramp
-- ---------------------------------------------------------------------------
BAS_Client.CHARGE_MAX = 100          -- top of the scale
BAS_Client.CHARGE_TIME = 1.0         -- seconds from 0 to CHARGE_MAX (MC: 20 ticks)
-- Raise windup: the idle -> aim transition (ZoB_GMiaozhuguodu) owns the first
-- WINDUP_TIME seconds after the aim button goes down, and no string is being
-- pulled while the bow is still coming up -- so the charge must not start
-- until it is over. IdleBow.xml plays that clip at m_speedScale 3.3333, which
-- is 1.0000 s of clip packed into 0.3 s; keep the two numbers in step.
BAS_Client.WINDUP_TIME = 0.3
-- MC refuses to loose below power 0.1 (BowItem: `if (f >= 0.1)`); on the curve
-- above, power 0.1 is reached after 0.14 s of draw.
BAS_Client.CHARGE_MIN_SHOT = 10      -- below this the string is not drawn far enough to loose
-- NOTE: this file does NOT define how a charge turns into damage or speed.
-- Those two multipliers live in BAS_Projectile (CHARGE_DMG_MIN and
-- CHARGE_SPEED_MIN) right next to the code that applies them -- one source of
-- truth, so the preview and the real shot cannot drift apart. The RANGE is not
-- here either: it falls out of the speed (fixed launch angle), in BAS_Projectile.

-- Draw progress 0..1 -> charge value 0..CHARGE_MAX (Minecraft's curve above).
BAS_Client.chargeCurve = function(t)
	if t <= 0 then
		return 0
	end
	if t >= 1 then
		return BAS_Client.CHARGE_MAX
	end
	return BAS_Client.CHARGE_MAX * (t * t + 2 * t) / 3
end

-- Charge value 0..CHARGE_MAX -> 0..1 fraction (drives the damage/range scales).
BAS_Client.chargeFrac = function(charge)
	local c = charge or 0
	if c < 0 then
		c = 0
	elseif c > BAS_Client.CHARGE_MAX then
		c = BAS_Client.CHARGE_MAX
	end
	return c / BAS_Client.CHARGE_MAX
end

-- ---------------------------------------------------------------------------
-- Bow condition (durability), 2026-09-19
--
-- The bow is a Lua-driven weapon: the vanilla attack chain never runs for it
-- (BAS_Bow forces canShoot() false and intercepts the Attack hook), so the
-- engine never wears it down and the item script's ConditionMax /
-- ConditionLowerChanceOneIn were pure decoration -- the bow was unbreakable.
-- Both are wired up here, which keeps ONE place to tune a bow's lifespan: the
-- script. A full draw stresses the limbs more than a weak one (MC style: the
-- full draw is a commitment), and a worn-out bow simply refuses to loose --
-- the same let-down as an under-drawn string, costing no arrow -- instead of
-- vanishing, so the vanilla repair items can bring it back.
-- The chance is read from the script, so tuning is still one line per bow:
-- ConditionLowerChanceOneIn = 40 (primitive) / 50 (hunting) means ~400 / ~500
-- full-draw shots per bow, and roughly triple that if you always snap-shoot.
-- ---------------------------------------------------------------------------
BAS_Client.WEAR_AT_FULL = 1.0    -- chance multiplier at a full draw
BAS_Client.WEAR_AT_MIN = 3.0     -- ... and at the weakest shot that fires

BAS_Client.isBowBroken = function(weapon)
	return weapon:getCondition() <= 0
end

BAS_Client.wearBow = function(weapon, charge)
	local per = weapon:getConditionLowerChance()
	if not per or per <= 0 then
		return
	end
	-- lerp the 1-in-N chance by how hard the bow was drawn
	local frac = BAS_Client.chargeFrac(charge)
	local mult = BAS_Client.WEAR_AT_FULL + (BAS_Client.WEAR_AT_MIN - BAS_Client.WEAR_AT_FULL) * (1 - frac)
	local chance = math.floor(per * mult + 0.5)
	if chance < 1 then
		chance = 1
	end
	if ZombRand(chance) == 0 then
		-- setCondition(int) plays the vanilla damaged sound, and the break sound
		-- on the point that takes it to 0 -- free feedback, no extra audio work.
		weapon:setCondition(weapon:getCondition() - 1)
	end
end

-- Nock delay: how long after loosing before the next arrow is on the string.
-- Minecraft has no such delay at all (the string is ready the instant an arrow
-- is in the inventory), so this is deliberately short -- just long enough that
-- the nock sound does not run into the previous shot. Set it to 0 to remove the
-- beat entirely.
-- The old table made this a Reloading-skill progression (2.0s at level 0 down
-- to 0.6s at level 10):
--     { [0]=2.0, [1]=2.0, [2]=1.8, [3]=1.7, [4]=1.5,
--       [5]=1.4, [6]=1.2, [7]=1.1, [8]=0.9, [9]=0.8, [10]=0.6 }
-- To bring that back, return `table[level]` from getReloadTime() again.
BAS_Client.NOCK_TIME = 0.2

-- Mouse-wheel trajectory angle was tried here (2026-09-25) and REMOVED the same
-- day: the user judged it unusable. The findings from that round are worth
-- keeping, though --
--   * R is NOT taken by reloading for a bow. The vanilla reload key
--     (KeybindId.RELOAD_WEAPON, default R) fires Events.OnPressReloadButton and
--     vanilla's own handler, and R also opens the firearm radial menu -- which
--     this file already blocks for bows. Our own OnPressReloadButton handler
--     only calls startReload, and startReload writes a timestamp ONLY when the
--     timer is empty -- which it never is, because the automatic nock stamps it
--     on the first frame the bow is held. So pressing R can never do anything
--     visible on a bow.
--   * Events.OnMouseWheel is real and fires once per wheel event with a single
--     Double (UIManager:979-989), if this ever comes back.
BAS_Client.getReloadTime = function(player)
	return BAS_Client.NOCK_TIME
end

-- Session-only reload timers keyed by weapon ID (not saved to the world).
BAS_Client.reloadTimers = {}

BAS_Client.startReload = function(weapon)
	local wid = weapon:getID()
	if not BAS_Client.reloadTimers[wid] then
		BAS_Client.reloadTimers[wid] = getTimestampMs()
	end
end

-- The bow engine OWNS the bow: aiming, drawing, loosing and the ballistics
-- are all driven from here. The vanilla firearm engine is never involved --
-- ISReloadWeaponAction.canShoot() returns false for bows (see BAS_Bow.lua),
-- so no vanilla shot, no hitscan, no vanilla hit reaction ever runs for a bow.
-- The old shape was "vanilla engine -> bow -> hand over to bow engine";
-- this is "bow engine -> bow", straight from the input layer.
-- ---------------------------------------------------------------------------
-- Trajectory display switch (2026-09-19)
--
--   false (default) -- LIVE  : the arc is recomputed every frame while aiming
--                              and disappears the instant you release the aim
--                              button, run out of arrows, unequip the bow or
--                              loose the arrow. This is the "normal" display.
--
--   true            -- HOVER : the last computed arc is KEPT, frozen in the
--                              air, after you stop aiming or after the shot,
--                              so the curve can be studied at leisure. It is
--                              replaced as soon as a new arc is computed.
--
-- This switch controls the AIMING PREVIEW arc ONLY (the dot line that predicts
-- where the shot will land). It has nothing to do with making a fired arrow
-- visible in flight -- that is BAS_Projectile.trail drawn by BASArrowUI.
-- HOVER (true): leave the preview arc on screen after the aim button is let go.
-- LIVE  (false): the arc lives and dies with the aim.
-- ---------------------------------------------------------------------------
BAS_Client.TRAJECTORY_HOVER = false

-- Loose the arrow. BOTH release paths go through here, so letting go of RMB
-- and snapping off an LMB shot can never behave differently.
BAS_Client.loose = function(player, weapon)
	local charge = BAS_Client.charge or 0
	if BAS_Client.isBowBroken(weapon) then
		-- The bow is worn out. Same dry let-down as an under-drawn string, and
		-- NO arrow is spent -- the nocked arrow stays on the string, so the
		-- player only has to repair the bow to keep shooting.
		player:playSound("M9Jam")
	elseif charge >= BAS_Client.CHARGE_MIN_SHOT then
		BAS_Projectile.launch(player, weapon)
		-- The release itself. This is the ONLY place it can come from: the
		-- vanilla aim lifecycle that normally plays AimReleaseSound
		-- (IsoPlayer.updateBringToBearSound) never fires for a bow, because it
		-- gates on isWeaponReady() -> isRangedWeaponReady(), which requires a
		-- MUZZLE attachment on the hand model's model script -- and a bow has
		-- none. So the script field was silent dead data; now it is live.
		-- pcall'd because no VANILLA Lua calls getAimReleaseSound (only Java
		-- does), so its Lua visibility is unproven -- and a hard error here
		-- would break the shot's tail every single time. Same defensive style as
		-- the BowAPI calls in BAS_Bow.
		local okSnd, snd = pcall(function()
			return weapon:getAimReleaseSound()
		end)
		player:playSound((okSnd and snd) or "FishingRodSwing")
		BAS_Client.wearBow(weapon, charge)
		weapon:getModData().BAS_nocked = nil
	else
		-- Below CHARGE_MIN_SHOT the string was never drawn far enough: the draw
		-- is let down instead and NO arrow is spent, so a panicked click cannot
		-- waste ammunition.
		player:playSound("M9Jam")
	end
	BAS_Client.charge = 0
	BAS_Client.chargeT = 0
	BAS_Client.lastDraw = nil
	-- 🚩 drawStart IS NOT OURS TO CLEAR HERE. It is the AIM's clock: it is
	-- stamped on the RMB press edge and read by the windup test every frame.
	-- Clearing it on release used to kill the whole "shoot without letting go"
	-- combo -- after a shot the string is empty for NOCK_TIME, the aim button is
	-- still down, and the windup test then read (now - nil) as 0 s for ever, so
	-- the arrow came back but the draw never charged again until RMB was
	-- released and pressed afresh.
	-- It is cleared where the aim ends: the draw branch's else (only when RMB is
	-- up) and the "bow left the hand" branch. See both call sites.
	-- ALWAYS drop the arc that was just fired -- in HOVER mode too. That line
	-- has been used up, and leaving it on screen would show the PREVIOUS shot's
	-- prediction while the player is already drawing the next arrow. A brand
	-- new arc is computed on the next draw.
	BAS_Client.lastTrajectory = nil
end

-- ---------------------------------------------------------------------
-- THE 3D BOW IN THE HAND: TWO MODEL FAMILIES, ONE STRING.
--
-- The bow is NOT drawn by this mod -- it is handed to the ENGINE. The model
-- name lives in the item's WeaponSprite and the vanilla equipment path owns
-- position, orientation and bone (Bip01_Prop1), so this file only ever writes
-- one string, and only when the STATE changes:
--
--     BASDraw == miaozhun -> BAS_BowFrame01..08   (models_bowframes.txt)
--                            the draw: the charge picks the frame, 0 -> 1
--     BASDraw == man      -> BAS_BowFrame08       the fully-drawn string
--     everything else     -> BAS_BowIdle          (models_bowrig.txt)
--                            the body: BAS_BowRigAnim.fbx
--
-- "Everything else" is wider than it sounds, and that is on purpose: kong (the
-- empty-string hold) and the two 0.3 s aim transitions (raise/lower, which play
-- ZoB_GMiaozhuguodu(S) rather than an aim node) all wear the BODY -- none of
-- them is the draw. See BOW_STATE_FRAMES / aimAnimActive below.
--
-- WHY WeaponSprite AND NOT StaticModel: the bow is a HandWeapon, and
-- HandWeapon.getStaticModel() reads its own chain --
--     modelIndex + weaponSpritesByIndex  ->  staticModel  ->  weaponSprite
-- -- while the script's `StaticModel = ...` is only consulted by the
-- InventoryItem version (through scriptItem). For a WEAPON the staticModel
-- field is never written anywhere in the jar (verified: no putfield for it in
-- InventoryItem, getfield only in HandWeapon), so that script line is dead and
-- weaponSprite is what actually gets rendered. items_bow.txt therefore sets
-- WeaponSprite = BAS_BowIdle and carries no StaticModel at all.
--
-- FRAME RANGE -- fixed at both ends; this is the contract everything else is
-- built on:
--     first frame = 1   (un-drawn string, the instant the aim button goes down)
--     last  frame = 8   (full draw, charge == CHARGE_MAX)
-- Disk:  source frames 1.fbx .. 8.fbx
--     -> BAS_BowFrame01.fbx .. BAS_BowFrame08.fbx (md5 identical, verified)
--     -> models_bowframes.txt: model BAS_BowFrame01 .. BAS_BowFrame08
--     -> Lua: BAS_BowFrameNN, index 1..8, clamped both ends.
-- A mismatch anywhere in that chain shows up as "full draw renders frame 1".
-- Verify with Tool\bow_frame_wiring_check.py and Tool\frame_index_mapping_check.py.
--
-- The Java side is OFF the per-frame path entirely -- the swap is pure Lua
-- (item:setWeaponSprite + player:resetEquippedHandsModels, both public and both
-- called by vanilla's own Fishing code). Only the frame COUNT is still read
-- from BowAPI.BowAPI, whose LuaClass name is a DOT-SEPARATED path, so it lives
-- in a NESTED table and a flat BowAPI.zbX(...) is nil -- which, behind an `if`
-- guard, fails completely silently (that used to be the case for hasBowTag /
-- isBow / registerBow too):
--   zbBowFrameCount()      -- 8 = the last frame index (Java owns the number)
--
-- A write is only issued when the model actually has to change: the engine
-- rebuilds the hand model on the next frame (resetEquippedHandsModels ->
-- ModelManager.ResetEquippedNextFrame), so writing every frame would rebuild 60
-- times a second for nothing. The test is the engine's own answer
-- (item:getStaticModel()), not a Lua cache -- see updateBowModel.
-- ---------------------------------------------------------------------
-- bowModelLive / bowModelItem record the model name currently in the hand and
-- the ITEM it was written into. The pair exists for UNEQUIPPING: clearing must
-- write to the bow the model came off, never to whatever is in the hand by
-- then.
BAS_Client.BOW_FRAME_FIRST = 1
BAS_Client.BOW_FRAME_LAST = 8
-- Frame model name (BAS_BowFrame + two digits). NO "Base." prefix: this string
-- is written into the item's WeaponSprite, and script model names are written
-- unprefixed everywhere ("WeaponSprite = BAS_BowIdle"), which the engine
-- resolves against the Base module itself.
BAS_Client.BOW_FRAME_PREFIX = "BAS_BowFrame"
BAS_Client.bowFrameCountSynced = false

-- The bridge can legitimately be absent (older jar, Java disabled). A missing
-- bridge must never take the whole update loop down, so every call is guarded
-- and a failure only stops the bow frame from changing.
BAS_Client.bowAPI = function()
	local api = BowAPI and BowAPI.BowAPI
	-- Only the frame COUNT is still read from Java (single source of truth for
	-- "8"); the model swap itself is pure Lua now.
	if not (api and api.zbBowFrameCount) then
		return nil
	end
	return api
end

-- Charge fraction 0..1 -> frame index 1..8.
-- The two ends are pinned BY DEFINITION, which is the whole point of this
-- function: fraction 0 always yields frame 1 and fraction 1 always yields
-- frame 8, no matter how the middle is divided -- the draw cannot start on a
-- stretched string nor end one frame short of the full draw.
-- The 0..1 range is cut into eight equal slots, slot i belonging to frame i
-- (slot 1 = 0.00..0.125, ..., slot 8 = 0.875..1.00), so every frame gets the
-- same slice of the draw and the frame changes exactly seven times.
BAS_Client.bowFrameIndex = function(frac)
	local f = frac or 0
	if f <= 0 then
		return BAS_Client.BOW_FRAME_FIRST
	end
	if f >= 1 then
		return BAS_Client.BOW_FRAME_LAST
	end
	local count = BAS_Client.BOW_FRAME_LAST - BAS_Client.BOW_FRAME_FIRST + 1
	local idx = BAS_Client.BOW_FRAME_FIRST + math.floor(f * count)
	if idx > BAS_Client.BOW_FRAME_LAST then
		idx = BAS_Client.BOW_FRAME_LAST
	end
	return idx
end

-- Learn the last frame index from Java once per session: BOW_FRAME_COUNT in
-- BowAPI.java is the single source of truth. The 8 above is only a fallback
-- for a missing bridge, so the bow still steps through the real files.
BAS_Client.syncBowFrameRange = function(api)
	if BAS_Client.bowFrameCountSynced then
		return
	end
	BAS_Client.bowFrameCountSynced = true
	if not (api and api.zbBowFrameCount) then
		return
	end
	local ok, n = pcall(api.zbBowFrameCount)
	if ok and type(n) == "number" and n >= BAS_Client.BOW_FRAME_FIRST then
		BAS_Client.BOW_FRAME_LAST = math.floor(n)
	end
end

-- ---------------------------------------------------------------------
-- Install a model name into the hand:
--     item:setWeaponSprite(name)  +  player:resetEquippedHandsModels()
--
-- WHY NOT THE ALTERNATIVES (all measured on this machine, 2026-09-25):
--   * chr.overridePrimaryHandModel = ... -- Kahlua CANNOT assign a field on a
--     Java object: KahluaThread.tableSet raises "attempted index of
--     non-table", logged with the full Java stack, ONCE PER FRAME. Tried and
--     removed. (A residual value an old experiment left on the character is
--     cleared once at game start instead -- that is the only thing
--     zbSetBowHandFrame is still called for.)
--   * item:setStaticModel(name) -- writes modData.staticModel, which the
--     HandWeapon override never reads. It did nothing at all.
-- setWeaponSprite is the field the engine actually renders, and it is also
-- what 3781962845 does -- its 0/100 bow swap works for exactly this reason.
-- ---------------------------------------------------------------------
BAS_Client.bowFrameModelName = function(idx)
	return BAS_Client.BOW_FRAME_PREFIX .. string.format("%02d", idx)
end

-- The body: shown whenever the bow is in hand and the player is NOT aiming
-- (models_bowrig.txt -> models_x/weapons/2handed/BAS_BowRigAnim.fbx).
BAS_Client.BOW_IDLE_MODEL = "BAS_BowIdle"

BAS_Client.bowFrameBackend = nil

-- WHICH AIM STATE WEARS THE FRAMES -- one table, and the whole rule.
--     miaozhun -- the DRAW: ZoB_GMiaozhun is the clip whose left hand really
--                 travels (0.129 while the string is pulled 0.22 -> 0.34), and
--                 it is the only aim node scrubbed by BASDrawTime. The charge
--                 picks the frame, so the sequence runs 1 -> 8 with the draw.
--     man      -- held AT FULL DRAW: ZoB_GMiaozhunman is a 1 s loop that does
--                 not move the hand, so it wears the LAST frame -- the
--                 fully-drawn string.
-- A state that is NOT listed wears the body (BAS_BowIdle). kong is left out on
-- purpose: with nothing on the string the body is the honest model.
BAS_Client.BOW_STATE_FRAMES = {
	miaozhun = { charge = true },   -- 0..1 -> frame 1..8
	man = { last = true },          -- the last frame
}

-- True while the character is really PLAYING an aim node. Holding the aim
-- button is not enough: the raise (ZoB_GMiaozhuguodu) and lower
-- (ZoB_GMiaozhuguoduS) transitions run first, and the aim node only starts
-- after WINDUP_TIME -- the very same 0.3 s clock the charge waits for, because
-- the transition IS that 0.3 s (the clip played at 3.3333x).
BAS_Client.aimAnimActive = function()
	if not BAS_Client.aiming then
		return false
	end
	local t0 = BAS_Client.drawStart
	if not t0 then
		return false
	end
	return (getTimestampMs() - t0) / 1000 >= BAS_Client.WINDUP_TIME
end

-- The model name for the CURRENT state. This is the ONE place that decides
-- which model is in the hand; nothing else in the file picks one, so the body
-- and the draw frames can never disagree with each other or with the pose.
BAS_Client.bowModelFor = function()
	if not BAS_Client.aimAnimActive() then
		return BAS_Client.BOW_IDLE_MODEL
	end
	local rule = BAS_Client.BOW_STATE_FRAMES[BAS_Client.drawState or ""]
	if not rule then
		return BAS_Client.BOW_IDLE_MODEL
	end
	if rule.last then
		return BAS_Client.bowFrameModelName(BAS_Client.BOW_FRAME_LAST)
	end
	return BAS_Client.bowFrameModelName(
		BAS_Client.bowFrameIndex(BAS_Client.chargeFrac(BAS_Client.charge or 0)))
end

-- Write `name` into `item`. Pure: it deliberately does NOT touch
-- bowModelLive / bowModelItem (the callers own that pair, so a clear can never
-- leave the two out of step).
BAS_Client.applyBowModel = function(item, name)
	if not (item and item.setWeaponSprite) then
		BAS_Client.bowFrameBackend = "none"
		return false
	end
	-- getStaticModel() is the engine's own answer to "what will be drawn" (for
	-- a HandWeapon it returns weaponSprite), so it is the honest way to ask
	-- "is it already this model?" -- no write, no rebuild.
	if item:getStaticModel() == name then
		return true
	end
	-- pcall: a build without these members must cost us the frame, never the
	-- update loop.
	local ok = pcall(function()
		item:setWeaponSprite(name)
		local pl = getSpecificPlayer(0)
		if pl then
			pl:resetEquippedHandsModels()
		end
	end)
	if not ok then
		BAS_Client.bowFrameBackend = "none"
		return false
	end
	BAS_Client.bowFrameBackend = "weaponSprite"
	BAS_Client.bowFrameMsg = "weaponSprite=" .. name
	return true
end

-- The model currently in the hand, and the ITEM it was written into.
-- The item is kept because CLEARING must write to the bow the model came off,
-- never to whatever happens to be in the hand at that moment: the old version
-- asked for getPrimaryHandItem() on the unequip path, which re-skinned the
-- player's NEXT weapon with the bow's model.
BAS_Client.bowModelLive = nil
BAS_Client.bowModelItem = nil

-- Install the model for the CURRENT state (the body, or the frame the current
-- aim state wants -- see BOW_STATE_FRAMES). Called on every frame the bow is
-- held, not only while aiming: the body has to be right while idling and
-- walking too, which is exactly why the body family exists.
-- Held frames are cheap by construction: the name is computed every frame, but
-- only a real state change -- aim on/off, or a slot crossing while aiming --
-- reaches item:setWeaponSprite. A held frame stops inside applyBowModel.
-- bowModelLive / bowFrameMsg / bowFrameBackend are the observing values for the
-- Lua console (print(BAS_Client.bowModelLive) etc.); nothing branches on them.
--
-- NOTE there is deliberately NO pre-load of all eight models any more. It used
-- to call zbPreloadBowFrames() on the first frame after equipping, which loads
-- all eight in ONE synchronised go (ModelManager.tryGetLoadedModel(ms, true))
-- -- a visible hitch at the exact moment the bow comes up, for eight meshes of
-- 264 vertices that are cheap enough to load one at a time as the draw reaches
-- them. The cost is the same, just spread over seven frame crossings instead
-- of stacked onto the equip frame.
BAS_Client.updateBowModel = function(weapon)
	if not BAS_Client.bowFrameCountSynced then
		BAS_Client.syncBowFrameRange(BAS_Client.bowAPI())
	end
	local name = BAS_Client.bowModelFor()
	-- The cached name is NOT what decides whether to skip the call: the engine
	-- can write weaponSprite itself (its own reset/original-sprite paths), and
	-- a stale cache would then leave the bow stuck on the wrong model for the
	-- rest of the draw. applyBowModel asks the ENGINE "is it already this
	-- model?" (item:getStaticModel()), so a held frame costs one getter and no
	-- rebuild, and any outside write is healed on the next frame.
	if BAS_Client.applyBowModel(weapon, name) then
		BAS_Client.bowModelItem = weapon
		BAS_Client.bowModelLive = name
	end
end

-- Back to the body model once the bow leaves the hand (unequip, swap, death).
-- Written to the bow the model came from -- see bowModelItem.
BAS_Client.clearBowModel = function()
	local item = BAS_Client.bowModelItem
	BAS_Client.bowModelItem = nil
	BAS_Client.bowModelLive = nil
	if item then
		BAS_Client.applyBowModel(item, BAS_Client.BOW_IDLE_MODEL)
	end
end

BAS_Client.OnPlayerUpdate = function(player)
	-- projectiles keep flying even after the bow is unequipped
	BAS_Projectile.update()
	-- Stuck arrows are pulled out by walking over them -- with or without the
	-- bow in hand, which is why this sits above the bow check below.
	if player and not player:isDead() then
		BAS_Projectile.updateLanded(player)
	end
	if not player or player:isDead() then
		BAS_Client.clearBowModel()
		return
	end
	local weapon = player:getPrimaryHandItem()
	if not BAS_Client.isBow(weapon) then
		-- the 3D bow leaves the moment the bow does (unequip, swap, death)
		BAS_Client.clearBowModel()
		BAS_Client.aiming = false
		BAS_Client.charge = 0
		BAS_Client.chargeT = 0
		BAS_Client.lastDraw = nil
		BAS_Client.drawState = nil
		BAS_Client.drawTime = nil
		BAS_Client.drawStart = nil
		BAS_Client.wasLmbDown = false
		BAS_Client.wasRmbDown = false
		BAS_Client.lastTrajectory = nil
		return
	end
	-- select the custom bow AnimSet nodes (aim_bow.xml + BASBowDefault.xml)
	player:setVariable("Weapon", "BASBOW")
	local modData = weapon:getModData()
	-- Own aim state (right mouse button). Deliberately NOT player:isAiming():
	-- that belongs to the vanilla firearm engine and we do not want to be
	-- gated on it.
	BAS_Client.aiming = isMouseButtonDown(1)
	-- Reload cycle: one arrow is consumed and nocked after a skill-based
	-- delay. The nocked state lives in modData, never in the vanilla ammo
	-- counter. NOT gated on isServer(): in this user's game isServer() can be
	-- false even in singleplayer, which silently disabled the whole block.
	if not modData.BAS_nocked then
		local wid = weapon:getID()
		if BAS_Client.hasArrows(player) then
			if not BAS_Client.reloadTimers[wid] then
				BAS_Client.reloadTimers[wid] = getTimestampMs()
			end
			local elapsed = (getTimestampMs() - BAS_Client.reloadTimers[wid]) / 1000
			local need = BAS_Client.getReloadTime(player)
			if elapsed >= need then
				BAS_Client.reloadTimers[wid] = nil
				BAS_Bow.reload(player, weapon)
				if weapon:getInsertAmmoSound() then
					player:playSound(weapon:getInsertAmmoSound())
				end
			end
		else
			BAS_Client.reloadTimers[wid] = nil
		end
	end
	-- Solve the ballistics every frame while aiming so currentAim is always
	-- fresh for the shot. This used to hang off the charge UI, which meant
	-- the entire bow went dead whenever that UI was not alive.
	if BAS_Client.aiming and modData.BAS_nocked then
		BAS_Client.lastTrajectory = BAS_Client.traceTrajectory(player, weapon)
	elseif not BAS_Client.TRAJECTORY_HOVER then
		-- LIVE mode: never leave a stale arc behind. This used to be implicit
		-- (the UI cleared its own copy), so any path that skipped the UI left
		-- the last arc frozen on screen -- the "hovering in mid-air" artefact.
		BAS_Client.lastTrajectory = nil
	end
	-- ---------------------------------------------------------------------
	-- Draw and loose (MC style): RMB is BOTH the aim button and the draw
	-- button. Hold it to aim and build charge, let go to loose. A left click
	-- looses early with whatever draw has been built up -- handy to snap a shot
	-- off the moment the arc lines up instead of waiting for a full draw.
	--
	-- Priority, highest first:
	--   1. LMB press edge -- fires NOW with the current charge
	--   2. RMB release    -- fires with the current charge
	--   3. RMB held       -- keeps drawing
	-- LMB wins because it is a single-frame edge and it clears BAS_nocked, so on
	-- the very next frame the draw branch is already disarmed and the RMB
	-- release cannot fire a second arrow out of the same draw.
	--
	-- The trajectory preview above runs off BAS_Client.aiming (== RMB held) and
	-- is recomputed EVERY frame, so the arc and the landing point shrink and
	-- grow live with the charge -- see the range scaling in BAS_Projectile.getAim.
	-- ---------------------------------------------------------------------
	local rmbDown = BAS_Client.aiming
	local lmbDown = isMouseButtonDown(0)
	local lmbEdge = lmbDown and not BAS_Client.wasLmbDown
	local rmbEdge = BAS_Client.wasRmbDown and not rmbDown
	-- The windup clock starts on the RMB PRESS EDGE, not on "nocked and held":
	-- the press is what the engine turns into the idle -> aim transition, and
	-- the raise clip is exactly what the windup is timing. Holding RMB with no
	-- arrow yet is fine -- the stamp is already running, so nocking one later
	-- starts the draw straight away, by which time the bow is up anyway.
	if rmbDown and not BAS_Client.wasRmbDown then
		BAS_Client.drawStart = getTimestampMs()
	end

	if lmbEdge and modData.BAS_nocked then
		BAS_Client.loose(player, weapon)
	elseif rmbDown and modData.BAS_nocked then
		-- WINDUP FIRST. The raise transition owns the first WINDUP_TIME seconds
		-- (IdleBow.xml plays ZoB_GMiaozhuguodu at 3.3333x = 1.0000 s of clip in
		-- 0.3 s) and the bow is still on its way up through all of it: there is
		-- nothing to draw yet, so the charge must NOT tick. Only lastDraw is
		-- kept fresh during the windup, so the first charging frame after it
		-- sees an ordinary one-frame delta instead of swallowing the whole 0.3 s.
		local now = getTimestampMs()
		local windup = (now - (BAS_Client.drawStart or now)) / 1000
		if windup >= BAS_Client.WINDUP_TIME then
			-- accumulate DRAW PROGRESS (0..1, linear in time) and map it
			-- through the curve: the charge value itself is a parabola of that
			-- progress
			local delta = BAS_Client.lastDraw and (now - BAS_Client.lastDraw) / 1000 or 0
			local t = (BAS_Client.chargeT or 0) + delta / BAS_Client.CHARGE_TIME
			if t > 1 then
				t = 1
			end
			BAS_Client.chargeT = t
			BAS_Client.charge = BAS_Client.chargeCurve(t)
		end
		BAS_Client.lastDraw = now
	elseif rmbEdge and modData.BAS_nocked then
		BAS_Client.loose(player, weapon)
	else
		-- 🚩 NOTHING TO DRAW THIS FRAME. The windup clock may only die with the
		-- AIM, never while the aim button is still down.
		--
		-- Clearing drawStart here unconditionally used to break the whole
		-- "keep the aim held" combo: after a shot the string is empty for the
		-- nock delay, so the very next frame landed in this branch and threw the
		-- stamp away -- and since drawStart is only ever set on the RMB PRESS
		-- EDGE, the windup test below then read (now - nil) as 0 s forever. The
		-- arrow came back after NOCK_TIME and the bow just stood there, because
		-- the charge never ticked, until RMB was released and pressed again.
		BAS_Client.lastDraw = nil
		if not rmbDown then
			BAS_Client.drawStart = nil
		end
	end
	-- ---------------------------------------------------------------------
	-- Which aim animation is playing (AnimSets/player/aim/aim_bow*.xml).
	--
	-- The engine picks WHICH node matches; this file only supplies the value.
	-- The three bow aim nodes in AnimSets/player/aim/ are separated purely by
	-- their m_Conditions, and every one of them reads this ONE variable, so
	-- this is the single place the choice is made and the xmls stay dumb:
	--     kong     -- nothing on the string yet (no arrows left, or the nock
	--                 delay has not elapsed) -> ZoB_GMiaozhunkong
	--     miaozhun -- arrow nocked and being drawn  -> ZoB_GMiaozhun
	--     man      -- drawn all the way to CHARGE_MAX -> ZoB_GMiaozhunman
	--
	-- The charge read here is THIS file's own value -- the same number that
	-- fills the charge bar and scales the shot -- so the pose can never
	-- disagree with the power, and there is no second charge system to keep
	-- in sync.
	--
	-- Written only when it changes: setVariable goes through a global variable
	-- name lookup, and this runs on every frame the bow is held.
	-- ---------------------------------------------------------------------
	local drawState = "kong"
	if modData.BAS_nocked then
		if (BAS_Client.charge or 0) >= BAS_Client.CHARGE_MAX then
			drawState = "man"
		else
			drawState = "miaozhun"
		end
	end
	if BAS_Client.drawState ~= drawState then
		BAS_Client.drawState = drawState
		player:setVariable("BASDraw", drawState)
	end
	-- ---------------------------------------------------------------------
	-- HOW FAR THE DRAW POSE IS, driven by the charge value itself.
	--
	-- aim_bow.xml carries <m_TrackTimeToVariable>BASDrawTime</m_TrackTimeToVariable>,
	-- which the engine re-reads on EVERY frame (LiveAnimNode.update ->
	-- getTrackTimeToVariable) and uses as  animTime = clipLength * value  --
	-- so the value is a 0..1 FRACTION OF THE CLIP, not a time in seconds, and
	-- the pose is pinned to the charge: whatever the bar shows, the arms do.
	--
	-- Because the POSITION is the charge fraction, the playback RATE is that
	-- curve's derivative: chargeCurve(t) = (t*t + 2t) / 3, so the rate is
	-- (2t + 2) / 3 -- 0.667x on the first frame, 1.0x at half the draw, 1.333x
	-- as it completes. The string comes back fast and turns heavy at the end,
	-- and the full-draw pose lands exactly when the charge reaches CHARGE_MAX
	-- (clip 1.000 s == CHARGE_TIME 1.0 s, so the draw is still one second).
	--
	-- Written every frame the number moves -- it is a float slot, no string
	-- alloc -- and skipped when unchanged, so a held draw writes nothing.
	-- Same mechanism the vanilla reload uses: AnimSets/player/actions/
	-- InsertBullets.xml drives Bob_IdleLoadMagazine from UpdateLoadBulletsTime.
	-- ---------------------------------------------------------------------
	local drawTime = BAS_Client.chargeFrac(BAS_Client.charge or 0)
	if BAS_Client.drawTime ~= drawTime then
		BAS_Client.drawTime = drawTime
		player:setVariable("BASDrawTime", drawTime)
	end
	-- ---------------------------------------------------------------------
	-- Pick the model for the hand. Runs on EVERY frame the bow is held, not
	-- only while aiming, because the model has to be right while idling and
	-- walking too -- which is what the body model is for:
	--     BASDraw miaozhun -> BAS_BowFrame01..08 (the charge picks the frame)
	--     BASDraw man      -> BAS_BowFrame08
	--     anything else    -> BAS_BowIdle  (kong, and both aim transitions)
	-- `weapon` is passed in rather than read back from the player: on the
	-- unequip path the bow is already out of the hand and asking would return
	-- whatever replaced it.
	-- ---------------------------------------------------------------------
	BAS_Client.updateBowModel(weapon)
	BAS_Client.wasLmbDown = lmbDown
	BAS_Client.wasRmbDown = rmbDown
	if not BAS_Client.aiming then
		-- keep a stale empty flag from sticking (it would make every swing
		-- play the endless dry-click animation)
		player:setRangedWeaponEmpty(false)
	end
	-- dry-fire reminder: aiming with no arrows left, click every 2s
	if BAS_Client.aiming and not BAS_Client.hasArrows(player) then
		local now3 = getTimestampMs()
		if not BAS_Client.lastDrySound or now3 - BAS_Client.lastDrySound > 2000 then
			BAS_Client.lastDrySound = now3
			player:playSound("M9Jam")
		end
	end
end

-- Manual loading: R key nocks one arrow from the backpack into the virtual
-- chamber (with a visible load animation). The arrow is consumed when the
-- nock anim finishes, matching a real bow: nock, draw, release.
BAS_Client.ReloadBow = function(player, weapon)
	if not BAS_Client.isBow(weapon) then
		return
	end
	if weapon:getModData().BAS_nocked then
		return
	end
	if not BAS_Client.hasArrows(player) then
		return
	end
	-- Manual R: start the skill-based reload timer (same as the automatic one).
	BAS_Client.startReload(weapon)
end

BAS_Client.OnPressReloadButton = function(player, weapon)
	if not BAS_Client.isBow(weapon) then
		return
	end
	BAS_Client.ReloadBow(player, weapon)
end

-- The bow loads arrows automatically; hide the vanilla ammo menu (it shows
-- "Load -1 9mm bullets" because the fake AmmoType has maxAmmo 0).
local originalDoReloadMenuForWeapon = ISInventoryPaneContextMenu.doReloadMenuForWeapon
function ISInventoryPaneContextMenu.doReloadMenuForWeapon(playerObj, weapon, context)
	if weapon and BAS_Client.isBow(weapon) then
		return
	end
	originalDoReloadMenuForWeapon(playerObj, weapon, context)
end

-- OnWeaponSwingHitPoint is deliberately NOT used any more. It was the old
-- hook that let the vanilla firearm engine trigger the shot ("vanilla engine
-- -> bow -> hand over to bow engine"). The bow engine looses the arrow itself
-- in OnPlayerUpdate, and leaving this hooked up would fire a second arrow
-- whenever a vanilla swing happened to connect.

-- The two debug hooks that used to live here (OnPlayerAttackFinished and
-- AttackDiag) were removed: they watched the vanilla attack lifecycle, which
-- no longer runs for bows at all (canShoot() is always false), so they could
-- only print misleading state -- notably getCurrentAmmoCount(), which is
-- always 0 now because the bow engine never writes the vanilla ammo counter.

-- Block the firearm radial menu (R key) for bows.
-- The bow keeps a virtual round and no real ammo type, so the radial menu
-- crashes on weapon:getAmmoType() being nil.
local originalFirearmRadialCheckKey = ISFirearmRadialMenu.checkKey
function ISFirearmRadialMenu.checkKey(key)
	local playerObj = getSpecificPlayer(0)
	if playerObj and playerObj:getPrimaryHandItem() then
		if BAS_Client.isBow(playerObj:getPrimaryHandItem()) then
			return false
		end
	end
	return originalFirearmRadialCheckKey(key)
end

Events.OnPlayerUpdate.Add(BAS_Client.OnPlayerUpdate)
Events.OnPressReloadButton.Add(BAS_Client.OnPressReloadButton)

-- Custom draw/charge indicator: visible ANYWHERE while holding the bow,
-- no zombie target required (the vanilla reticle is target-driven).
BASChargeUI = ISUIElement:derive("BASChargeUI")

function BASChargeUI:new(x, y, width, height)
	local o = ISUIElement.new(self, x, y, width, height)
	o.charge = 0          -- 0..CHARGE_MAX, the draw; mirrors BAS_Client.charge
	o.reloadProgress = 0  -- 0..1, the reload bar -- a DIFFERENT scale on purpose
	o.visible = false
	return o
end

function BASChargeUI:update(dt)
	local player = getSpecificPlayer(0)
	self.player = player
	self.visible = false
	if not player or player:isDead() then
		return
	end
	local weapon = player:getPrimaryHandItem()
	-- Own aim state, not player:isAiming() -- the bow engine decides when we
	-- are aiming, not the vanilla firearm engine.
	if BAS_Client.isBow(weapon) and BAS_Client.aiming then
		self.visible = true
		-- attack range barrier: the SAME world marker the debug horde
		-- spawner uses (getWorldMarkers:addGridSquareMarker, Java-rendered,
		-- perfectly world-anchored). size = this shot's range + 1 = one tile
		-- past the shot limit, and that range is charge-scaled, so the ring
		-- grows with the draw; tinted red.
		BAS_Client.updateRangeMarker(player)
		if not weapon:getModData().BAS_nocked then
			self.trajectory = nil
			if BAS_Client.hasArrows(player) then
				-- reloading: show the reload progress (skill-based)
				self.reloading = true
				local wid = weapon:getID()
				local t = BAS_Client.reloadTimers[wid]
				local required = BAS_Client.getReloadTime(player)
				local elapsed = t and (getTimestampMs() - t) / 1000 or 0
				self.reloadProgress = math.min(1, elapsed / required)
				self.loaded = false
			else
				-- no arrows: red empty state, no reload loop
				self.reloading = false
				self.loaded = false
				self.charge = 0
			end
		else
			self.reloading = false
			self.loaded = true
			-- Charge and trajectory are owned by the bow engine
			-- (BAS_Client.OnPlayerUpdate). This UI only mirrors them, so the
			-- bar and the actual shot can never disagree -- and if the UI is
			-- ever removed again, the bow keeps working.
			self.charge = BAS_Client.charge or 0
			self.trajectory = BAS_Client.lastTrajectory
		end
	elseif BAS_Client.TRAJECTORY_HOVER and BAS_Client.lastTrajectory then
		-- HOVER mode: keep the last arc frozen on screen even though the
		-- player is no longer aiming, so the curve can be studied at leisure.
		self.visible = true
		self.charge = 0
		self.reloading = false
		self.loaded = false
		self.trajectory = BAS_Client.lastTrajectory
		if BAS_Client.rangeMarker then
			BAS_Client.rangeMarker:setActive(false)
		end
	else
		self.charge = 0
		self.trajectory = nil
		if BAS_Client.rangeMarker then
			BAS_Client.rangeMarker:setActive(false)
		end
	end
end

-- Same marker API as ISSpawnHordeUI (debug horde spawner): a real world
-- marker rendered by the Java WorldMarkers system. It is anchored to the
-- player's square, follows the character and the camera 1:1, and its size
-- rule (size+1)*1.5 is the exact spawner behavior the user validated.
-- Radius = the outer bound of the CURRENT shot (aim.maxRange = this draw's
-- physical reach, capped by the range rule), which is charge-dependent: a weak
-- draw cannot reach past a few tiles at all. It is the "nothing goes past this"
-- boundary; WHERE the shot lands is the arc's tip, marked by the gold box.
-- Color via setR/setG/setB.
BAS_Client.updateRangeMarker = function(player)
	local rangeTiles = BAS_Projectile.RANGE_MAX
	local aim = BAS_Projectile.currentAim
	if aim and aim.maxRange then
		rangeTiles = aim.maxRange
	end
	local x, y, z = player:getX(), player:getY(), player:getZ()
	local marker = BAS_Client.rangeMarker
	if not marker then
		local square = getCell():getGridSquare(x, y, z)
		if not square then
			return
		end
		marker = getWorldMarkers():addGridSquareMarker(square, 1.0, 0.0, 0.0, true, rangeTiles + 1)
		BAS_Client.rangeMarker = marker
	else
		marker:setPosAndSize(x, y, z, rangeTiles + 1)
		marker:setActive(true)
	end
end

-- Simulate the arrow's arc ahead of time with EXACTLY the same integration
-- and collision stops as BAS_Projectile.step (2 substeps per frame,
-- semi-implicit, ground + wall + zombie stops). The computed launch state
-- is stored in BAS_Projectile.currentAim so the real shot uses the IDENTICAL
-- values (no drift from mouse movement between the preview frame and the
-- shot). Returns { pts = {...}, hitType = "miss"|"block"|"entity" }.
BAS_Client.traceTrajectory = function(player, weapon)
	-- pitch is the solved launch angle for THIS shot's speed, v is the
	-- charge-scaled launch speed, maxRange is this shot's outer bound, and `dist`
	-- is the distance it is solved to land on (= the cursor unless the draw is
	-- too weak to carry it that far).
	local dx, dy, pitch, stats, dist, v, maxRange = BAS_Projectile.getAim(player, weapon)
	if not stats then
		return nil
	end
	local g = stats.gravity
	local startX = player:getX() + dx * BAS_Projectile.LAUNCH_AHEAD
	local startY = player:getY() + dy * BAS_Projectile.LAUNCH_AHEAD
	local startZ = player:getZ() + BAS_Projectile.LAUNCH_HEIGHT
	local xSpeed = dx * v * math.cos(pitch)
	local ySpeed = dy * v * math.cos(pitch)
	local zSpeed = v * math.sin(pitch)
	-- The HARD CEILING only: the arc is never allowed past the range rule
	-- (RANGE_MAX from the player). The normal landing is the ground branch --
	-- the arc's last point IS the landing point, and there is deliberately no
	-- separate theoretical target any more.
	local targetDist = dist - BAS_Projectile.LAUNCH_AHEAD
	BAS_Projectile.currentAim = {
		stats = stats,
		-- This shot's outer bound (min(RANGE_MAX, physical reach)); the red
		-- radius ring reads it so the ring describes THIS shot rather than a
		-- static constant.
		maxRange = maxRange,
		startX = startX,
		startY = startY,
		startZ = startZ,
		xSpeed = xSpeed,
		ySpeed = ySpeed,
		zSpeed = zSpeed,
		targetDist = targetDist,
	}
	local x = startX
	local y = startY
	local z = startZ
	-- the ground the arrow was fired from: it has LANDED only when it comes
	-- back down to this plane. The old test was "fractional part of z is near
	-- zero", which also fired while the arc was still climbing past ANY integer
	-- height (z ~ 1.00 -> 1.002 - 1 = 0.002 <= 0.02), so as soon as the apex
	-- passed z = 1 the arc got cut off in mid-air and its length jumped around
	-- with every mouse move.
	local groundZ = math.floor(startZ)
	local pts = {}
	local divisions = 2
	local cell = getCell()
	local hitType = "miss"
	for frame = 1, 400 do
		for d = 1, divisions do
			local dt = 1 / divisions
			-- Exact integration of z(t) = z + v*t - g*t^2/2 (trapezoid rule).
			-- The old `z + (zSpeed/2)*dt` moved only HALF the distance, which
			-- flattened the arc and left its tip hanging ~0.2 tiles above the
			-- ground, out of sync with the pitch solved from the continuous
			-- formula in getAim.
			local nx = x + xSpeed * dt
			local ny = y + ySpeed * dt
			local nz = z + zSpeed * dt - 0.5 * g * dt * dt
			zSpeed = zSpeed - g * dt
			-- one point per substep: dense dots -> the preview draws as a
			-- continuous line (thickness is set by `s` in BASChargeUI:render)
			table.insert(pts, { x = nx, y = ny, z = nz })
			-- hard stop at the range boundary: the arc simply ENDS at the last
			-- integrated point, and that last point is the landing point.
			-- A point used to be appended here at the theoretical target on the
			-- ground (targetX/targetY/targetZ); because the previous point is
			-- still in mid-air, that drew a stray white dot detached from the
			-- arc. Removed -- the tail of the arc is the predictor.
			local dxd = nx - startX
			local dyd = ny - startY
			local nowDist = math.sqrt(dxd * dxd + dyd * dyd)
			if nowDist >= targetDist then
				-- Land EXACTLY on targetDist instead of on the first substep
				-- that overshot it. The point already appended is replaced by
				-- the interpolated one, so the tip sits on the crosshair rather
				-- than up to a whole substep (~0.35 tiles) past it.
				local k = targetDist / nowDist
				pts[#pts] = {
					x = startX + dxd * k,
					y = startY + dyd * k,
					-- clamped to the ground plane, exactly like the shot:
					-- the interpolated z can otherwise dip a few thousandths
					-- below it (measured -0.009), which floors to a different
					-- map level and made the arrow vanish instead of landing
					z = math.max(groundZ, z + (nz - z) * k),
				}
				return { pts = pts, hitType = hitType }
			end
			if nz <= groundZ then
				-- interpolate onto the ground plane, with the SAME formula the
				-- shot uses: the tip then rests exactly on the ground instead of
				-- on the first substep that happened to touch it (up to ~0.35
				-- tiles short, which is what kept it off the crosshair)
				local k = (z - groundZ) / (z - nz)
				if k < 0 then
					k = 0
				elseif k > 1 then
					k = 1
				end
				pts[#pts] = {
					x = x + (nx - x) * k,
					y = y + (ny - y) * k,
					z = groundZ,
				}
				return { pts = pts, hitType = hitType }
			end
			local prev = cell:getGridSquare(x, y, z)
			local curr = cell:getGridSquare(nx, ny, nz)
			-- Exactly the same order and test as BAS_Projectile.step, so the
			-- preview cannot disagree with the shot: a fence is decided by
			-- HEIGHT and is checked BEFORE the wall test (isBlockedTo reports a
			-- map fence as a full wall), and clearing it does not fall through
			-- to the wall test.
			if prev and curr and prev ~= curr then
				if BAS_Projectile.hasFenceBetween(prev, curr) then
					if nz <= math.floor(nz) + BAS_Projectile.FENCE_HEIGHT then
						-- Same interpolation the real arrow now uses: the tip
						-- of the arc has to sit ON the fence, or the preview and
						-- the shot disagree by up to a substep.
						local bx, by, bz = BAS_Projectile.clampToBoundary(x, y, z, nx, ny, nz, prev)
						pts[#pts] = { x = bx, y = by, z = bz }
						hitType = "fence"
						return { pts = pts, hitType = hitType }
					end
				elseif prev:isBlockedTo(curr) then
					local bx, by, bz = BAS_Projectile.clampToBoundary(x, y, z, nx, ny, nz, prev)
					pts[#pts] = { x = bx, y = by, z = bz }
					hitType = "block"
					return { pts = pts, hitType = hitType }
				end
			end
			-- zombie check on the arrow's own level AND the one below, through
			-- the SAME helper the real shot uses (see BAS_Projectile.zombieAt):
			-- a character is ~1.33 z-levels tall, so an arrow at z = 1.2 can be
			-- inside a zombie whose feet are at z = 0, while getGridSquare(...)
			-- would be asking about LEVEL 1, which holds no ground zombies.
			-- Without the second lookup the preview and the shot could disagree
			-- about a lobbed arrow coming down onto a zombie.
			local hitZ = BAS_Projectile.zombieAt(cell, nx, ny, nz)
			if hitZ then
				hitType = "entity"
				return { pts = pts, hitType = hitType }
			end
			x, y, z = nx, ny, nz
		end
	end
	return { pts = pts, hitType = hitType }
end

function BASChargeUI:render()
	if not self.visible then
		return
	end
	local pl = self.player
	if not pl then
		return
	end
	local x = getMouseX()
	local y = getMouseY()
	local zoom = getCore():getZoom(0)
	-- thickness factor: world size on screen is 1/zoom (higher zoom value =
	-- wider view), clamped to [50%, 125%] of the base size so the line never
	-- gets too thin when zoomed in or too fat when zoomed out
	local f = 1 / zoom
	if f < 0.5 then
		f = 0.5
	elseif f > 1.25 then
		f = 1.25
	end
	-- trajectory preview dots (same physics as the launch). Dots are centred
	-- on their world point; see the note on isoToScreenX/Y further down.
	-- The end marker is color-coded: red = will hit an entity,
	-- orange = a low fence will stop this shot (aim higher to arc over it),
	-- white = falls to the ground.
	if self.trajectory then
		-- preview line thickness (px, base 8 * clamp factor): raise this to
		-- make the parabola thicker
		local s = 8 * f
		local pts = self.trajectory.pts
		local total = #pts
		for idx, pt in ipairs(pts) do
			local sx = isoToScreenX(0, pt.x, pt.y, pt.z)
			local sy = isoToScreenY(0, pt.x, pt.y, pt.z)
			-- The LAST point of the arc is where the arrow really ends up
			-- (same integration as the shot), so it carries the hit colour:
			-- red = will hit an entity, green = will hit a block,
			-- orange = a fence will stop it, white = plain ground landing.
			-- There is no separate landing marker any more: it used to be
			-- drawn at the theoretical target point, which is NOT where the
			-- arrow lands, so it was misleading.
			local r, g2, b = 1, 1, 1
			if idx == total then
				local ht = self.trajectory.hitType
				if ht == "block" then
					r, g2, b = 0.2, 1, 0.2
				elseif ht == "fence" then
					r, g2, b = 1, 0.55, 0.1
				elseif ht == "entity" then
					r, g2, b = 1, 0, 0
				end
			end
			self:drawRect(sx - s / 2, sy - s / 2, s, s, r, g2, b, 0.8)
		end
		-- WHERE THIS SHOT WILL LAND. Under the MC aim model that is no longer
		-- the cursor -- the fixed launch angle plus the charge-scaled speed put
		-- the landing point wherever physics says -- so the box is drawn on the
		-- arc's own last point (pts[total], already computed above). This is the
		-- key piece of feedback for judging a draw: a full draw parks it out at
		-- the 26-tile rule, a half draw parks it visibly closer.
		local land = pts[total]
		if land then
			local rx = isoToScreenX(0, land.x, land.y, land.z)
			local ry = isoToScreenY(0, land.x, land.y, land.z)
			local rs = 7 * f
			self:drawRectBorder(rx - rs / 2, ry - rs / 2, rs, rs, 1, 0.85, 0.1, 0.9)
		end
	end
	-- charge/reload bar below the mouse
	local w = 64
	local h = 8
	local bx = x - w / 2
	local by = y + 24
	self:drawRect(bx, by, w, h, 0.1, 0.1, 0.1, 0.8)
	if self.reloading then
		-- blue = reloading (its own 0..1 scale, not the charge scale)
		self:drawRect(bx, by, w * (self.reloadProgress or 0), h, 0.3, 0.5, 0.9, 0.9)
	elseif self.loaded then
		local frac = BAS_Client.chargeFrac(self.charge)
		local fill = w * frac
		if self.charge >= BAS_Client.CHARGE_MAX then
			-- full draw: gold, plus a white cap so "maxed" is unmissable
			self:drawRect(bx, by, fill, h, 1.0, 0.8, 0.1, 0.95)
			self:drawRect(bx + w - 2, by - 2, 2, h + 4, 1.0, 1.0, 1.0, 0.9)
		elseif self.charge < BAS_Client.CHARGE_MIN_SHOT then
			-- pale red: not drawn far enough to loose, clicking now is a let-down
			self:drawRect(bx, by, fill, h, 0.8, 0.35, 0.3, 0.9)
		else
			-- green, warming toward gold as the draw deepens
			self:drawRect(bx, by, fill, h, 0.25 + 0.75 * frac, 0.9 - 0.25 * frac, 0.2, 0.9)
		end
	else
		self:drawRect(bx, by, w * 0.15, h, 0.8, 0.3, 0.3, 0.8)
	end
	self:drawRectBorder(bx, by, w, h, 0.0, 0.0, 0.0, 0.9)
end

-- Register the built-in bows in the Java registry (tier 2 of the recognition
-- chain in BAS_Bow.isBow). The numbers mirror BAS_Projectile.stats so the Lua
-- and Java engines never disagree about a bow.
-- The Java class is exposed under the dotted name "BowAPI.BowAPI", so the static
-- methods sit one level below the BowAPI namespace table; flat BowAPI.registerBow
-- was always nil and this function silently returned false.
BAS_Client.registerBows = function()
	local api = BowAPI and BowAPI.BowAPI
	if not (api and api.registerBow) then
		return false
	end
	local ok = pcall(function()
		api.registerBow("BAS.BAS_Bow", 0.7, 0.004, 0.0, 60.0, 0.8, 1.4, 25.0)
	end)
	return ok
end

-- ---------------------------------------------------------------------------
-- Arrow flight trail (2026-09-19)
--
-- The arrow ITSELF is drawn by the Java flight body BowArrow3D -- a custom
-- IsoMovingObject carrying its own SpriteModel, so the head follows the flight
-- direction (dictionary BAS14; the plain world item cannot rotate). The world
-- item path is only the fallback used when the Java bridge is unavailable.
-- This UI adds the trail BEHIND it, drawn with drawRect -- the one UI primitive
-- proven to work in this mod (the aiming preview uses it too). An earlier
-- version drew a ROTATED SPRITE here via drawTextureAllPoint(); that call never
-- produced anything on screen, and it is gone now.
-- ---------------------------------------------------------------------------

BASArrowUI = ISUIElement:derive("BASArrowUI")

function BASArrowUI:new(x, y, width, height)
	local o = ISUIElement.new(self, x, y, width, height)
	return o
end

function BASArrowUI:render()
	local arrows = BAS_Projectile.active
	if not arrows or #arrows == 0 then
		return
	end
	local zoom = getCore():getZoom(0)
	if not zoom or zoom == 0 then
		zoom = 1
	end
	for i = 1, #arrows do
		-- Newest sample is bright and large, the tail fades out.
		local trail = arrows[i].trail
		if trail then
			local n = #trail
			for j = 1, n do
				local pt = trail[j]
				local tx = isoToScreenX(0, pt.x, pt.y, pt.z)
				local ty = isoToScreenY(0, pt.x, pt.y, pt.z)
				local age = j / n
				local size = (2 + 5 * age) / zoom
				self:drawRect(tx - size / 2, ty - size / 2, size, size,
					1, 0.85, 0.35, 0.10 + 0.70 * age)
			end
		end
	end
end

Events.OnGameStart.Add(function()
	-- Custom aiming UI (parabola preview, charge bar, range ring).
	-- NOTE: this UI is display-only now. It used to be load-bearing -- turning
	-- it off killed the whole bow, because its update() was the only caller of
	-- traceTrajectory(). Ballistics are solved in OnPlayerUpdate these days, so
	-- this UI can be removed freely without breaking the bow.
	BAS_Client.chargeUI = BASChargeUI:new(0, 0, 100, 100)
	BAS_Client.chargeUI:setVisible(true)
	BAS_Client.chargeUI:addToUIManager()
	-- Separate, always-visible UI that draws the arrows in flight (rotated).
	-- It has to be independent of the charge UI, which is hidden whenever the
	-- player is not aiming.
	BAS_Client.arrowUI = BASArrowUI:new(0, 0, 1, 1)
	BAS_Client.arrowUI:setVisible(true)
	BAS_Client.arrowUI:addToUIManager()
	BAS_Client.registerBows()
	-- Clear any hand-model override left behind by the earlier experiment.
	-- While it is set the engine mounts an EXTRA model on Bip01_Prop1 that does
	-- not follow the item's WeaponSprite, so the model swap looked like it did
	-- nothing (two bows in hand, one of them frozen). The Java bridge is no
	-- longer used for the swap -- this one-shot cleanup is its only caller.
	if BowAPI and BowAPI.BowAPI and BowAPI.BowAPI.zbSetBowHandFrame then
		BowAPI.BowAPI.zbSetBowHandFrame(0)
	end
end)
