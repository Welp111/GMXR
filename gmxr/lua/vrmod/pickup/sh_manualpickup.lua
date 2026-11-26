local vrmod_manualpickup = CreateConVar("vrmod_manualpickups", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "vrmod manual pickup toggle")
local debug_arcvr = CreateConVar("vrmod_debug_arcvr_ammo", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Debug ArcticVR ammo stasis")
local arcvr_always_loaded = CreateConVar("vrmod_arcvr_always_loaded", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "If 1, picking up an ArcVR weapon will always fully load it with its default magazine.")

-- Per-player states
local PickupDisabled = {}
local PickupDisabledWeapons = {}

-- A weapon sh_dropweapon just threw (it carries vrmod_dropCooldown, and
-- vrmod_dropT, when):
--   DROP_HAND  seconds no hand takes it back, whatever asks. The dropping
--              hand's own re-arm (sh_dropweapon, client) is what keeps a
--              settling grip from taking it back; this is the server's
--              backstop for every other sender.
--   DROP_STAND seconds a touch keeps the touch block alive: whoever is still
--              standing on it doesn't get it the moment the cooldown runs out.
local DROP_HAND, DROP_STAND = 0.5, 0.25

-- Initialize pickup states on spawn
hook.Add("PlayerSpawn", "SpawnSetPickupState", function(ply)
	local id = ply:EntIndex()
	PickupDisabled[id] = true
	PickupDisabledWeapons[id] = true
end)

-- Set player as VR when entering VRMod
hook.Add("VRMod_Start", "VRModPickupStartState", function(ply)
	ply:SetNWBool("IsVR", true)
	local id = ply:EntIndex()
	PickupDisabled[id] = true
	PickupDisabledWeapons[id] = true
end)

-- Clear VR state when exiting VRMod
hook.Add("VRMod_Exit", "VRModPickupResetState", function(ply)
	ply:SetNWBool("IsVR", false)
	local id = ply:EntIndex()
	PickupDisabled[id] = nil
	PickupDisabledWeapons[id] = nil
end)

-- Fix VR state loss after respawn
timer.Create("VRModManualPickup_RespawnFixTimer", 1, 0, function()
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and ply:GetNWBool("IsVR", false) then
			local id = ply:EntIndex()
			if PickupDisabled[id] == nil then
				PickupDisabled[id] = true
				PickupDisabledWeapons[id] = true
			end
		end
	end
end)

-- Handle item drop to allow manual pickup
hook.Add("VRMod_Drop", "ManualItemPickupDropHook", function(ply, ent)
	if not IsValid(ent) then return end
	if ent:GetClass() == "prop_physics" then return end
	local id = ply:EntIndex()
	PickupDisabled[id] = false
	PickupDisabledWeapons[id] = false
	timer.Simple(0.3, function()
		if IsValid(ply) then
			PickupDisabled[id] = true
			PickupDisabledWeapons[id] = true
		end
	end)
end)

-- Handle weapon pickup by hand
hook.Add("VRMod_Pickup", "ManualWeaponPickupHook", function(ply, ent)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if not IsValid(ent) or not ent:IsWeapon() then return end
	if not ply.PickupWeapon then return end

	-- Just thrown: not this press (DROP_HAND). Past that the hand takes it,
	-- and the touch block goes with it: left on, PickupWeapon below was
	-- refused by our own PlayerCanPickupWeapon and the Give fallback handed
	-- over a fresh copy, without what the thrown one had on it (attachments).
	if ent.vrmod_dropCooldown then
		if CurTime() - (ent.vrmod_dropT or 0) < DROP_HAND then return false end
		ent.vrmod_dropCooldown = nil
	end

-- ── ArcticVR ammo stasis ─────────────────────────────────────────────────
	local avrState = nil
	local ignoreStasis = arcvr_always_loaded:GetBool()

	if SERVER and ent.VRMod_ArcVR_Stasis ~= nil then
		if not ignoreStasis then
			avrState = {
				LoadedRounds = ent.VRMod_ArcVR_Stasis.LoadedRounds,
				Chambered    = ent.VRMod_ArcVR_Stasis.Chambered or 0,
				Magazine     = ent.VRMod_ArcVR_Stasis.Magazine,      -- may be nil
			}

			if debug_arcvr:GetBool() then
				print("[VRMod ArcVR Debug] Picked up weapon: " .. ent:GetClass())
				print("[VRMod ArcVR Debug] Read Stamped State - LoadedRounds: " .. tostring(avrState.LoadedRounds) .. " Chambered: " .. tostring(avrState.Chambered) .. " Mag: " .. tostring(avrState.Magazine))
			end
		else
			if debug_arcvr:GetBool() then
				print("[VRMod ArcVR Debug] Picked up weapon: " .. ent:GetClass() .. " (IGNORING STASIS - Always Loaded is ON)")
			end
		end

		-- Clear these to prevent ArcVR from spawning a floating magazine on Remove()
		ent.LoadedRounds = 0
		ent.Chambered = 0
		ent.Magazine = nil
	end

	-- ─────────────────────────────────────────────────────────────────────────
	local wepClass = ent:GetClass()
	-- Temporarily disable pickup protection
	hook.Call("VRMod_Drop", nil, ply, ent)
	-- Try to replace with VR weapon
	local replacement = vrmod.utils.ReplaceWeapon and vrmod.utils.ReplaceWeapon(ply, ent)
	if replacement then wepClass = replacement end

local isDuplicate = ply:HasWeapon(wepClass)
     if SERVER and ArcticVR and ArcticVR.InterceptPickup then
         if ArcticVR.InterceptPickup(ply, ent, wepClass, isDuplicate, avrState) then

             -- Release from x64 pickup system so DW can take over
             if IsValid(ent) then
                 local sid = ply:SteamID()
                 if g_VR[sid] and g_VR[sid].heldItems then
                     for slot = 1, 2 do
                         local held = g_VR[sid].heldItems[slot]
                         if held and held.ent == ent then
                             pcall(vrmod.Drop, sid, held.left)
                             break
                         end
                     end
                 end
             end
             return
         end
     end

local picked = false

if isDuplicate then
    if avrState then
        -- Restore stasis directly to the existing weapon's ArcVR fields.
        -- Do NOT GiveAmmo — that adds to reserve on top of existing rounds,
        -- causing infinite ammo on every holster grab cycle.
        local existingWep = ply:GetWeapon(wepClass)
        if IsValid(existingWep) and existingWep.ArcticVR then
            existingWep.LoadedRounds = avrState.LoadedRounds
            existingWep.Chambered    = avrState.Chambered
            existingWep.Magazine     = avrState.Magazine
            if existingWep.SendWeapon then existingWep:SendWeapon(true, true) end
        end
    -- The engine's own ammo-only pickup (what touching a duplicate does on
    -- desktop): clip or not -- RPG, grenades and SLAM keep theirs off-clip,
    -- which Clip1() never saw -- secondary ammo, the ammo caps and the pickup
    -- notice. It bypasses PlayerCanPickupWeapon, and removes the weapon once
    -- it has taken anything.
    elseif not ply:PickupWeapon(ent, true) then
        -- Took nothing: a SWEP never deployed (spawnmenu, ents.Create) still
        -- has Clip1() -1, so fall back to what it declares it ships with.
        local ammoType = ent:GetPrimaryAmmoType()
        if ammoType < 0 then
            local p = ent.Primary
            ammoType = p and p.Ammo and game.GetAmmoID(p.Ammo) or -1
        end
        local clip = ent:Clip1()
        if clip < 0 then
            local p = ent.Primary
            clip = p and (p.DefaultClip or p.ClipSize) or ent:GetMaxClip1()
        end
        if ammoType >= 0 and clip and clip > 0 then ply:GiveAmmo(clip, ammoType, true) end
    end

    ply:SelectWeapon(wepClass)
	else
		-- The engine's own pickup, as walking over it does on desktop: you get
		-- THIS weapon with what's in it, so an NPC's dropped gun keeps its clip.
		-- Give(class, noAmmo) handed over an empty copy and threw the loaded
		-- one away. A replacement class (ArcVR swap) is a different weapon and
		-- is still given, as is anything the engine refuses (not visible from
		-- your eyes, say) -- with the floor gun's clip carried across.
		if not replacement and ply:PickupWeapon(ent) then
			picked = true
		else
			local w = ply:Give(wepClass, true)
			local c = replacement and -1 or ent:Clip1()
			if c > 0 and IsValid(w) then w:SetClip1(c) end
		end
		timer.Simple(0, function() if IsValid(ply) then ply:SelectWeapon(wepClass) end end)
	end

	if not picked and IsValid(ent) then ent:Remove() end

	-- ── ArcticVR ammo stasis restore ─────────────────────────────────────────
	if SERVER and not isDuplicate then
		timer.Simple(0, function()
			if not IsValid(ply) then return end
			local newWep = ply:GetWeapon(wepClass)

			if IsValid(newWep) then
				if debug_arcvr:GetBool() then
					print("[VRMod ArcVR Debug] Restoring to new weapon: " .. wepClass)
				end

				if newWep.ArcticVR or newWep.LoadedRounds ~= nil then
					if ignoreStasis then
						-- Force the weapon to be fully loaded with its default magazine
						local defMag = newWep.DefaultMagazine
						if defMag and ArcticVR and ArcticVR.MagazineTable and ArcticVR.MagazineTable[defMag] then
							newWep.Magazine = defMag
							newWep.LoadedRounds = ArcticVR.MagazineTable[defMag].Capacity or 0
							newWep.Chambered = 1
							if debug_arcvr:GetBool() then
								print("[VRMod ArcVR Debug] Forced Fully Loaded with mag: " .. tostring(defMag))
							end
						end
					elseif avrState then
						newWep.LoadedRounds = avrState.LoadedRounds
						newWep.Chambered = avrState.Chambered
						newWep.Magazine = avrState.Magazine
					end

					-- Network sync 1 (Immediately after setup)
					if newWep.SendWeapon then
					    newWep:SendWeapon(true, true)
					end

					-- Network sync 2 (Delayed to handle client ping & entity creation)
					local wepID = newWep:EntIndex()
					timer.Create("VRMod_ArcVR_Sync_" .. tostring(wepID), 0.25, 4, function()
					    if IsValid(newWep) and newWep.SendWeapon then
					        newWep:SendWeapon(true, true)
					    end
					end)

					if debug_arcvr:GetBool() then
						print("[VRMod ArcVR Debug] Successfully synced ammo state to client over 1s.")
					end
				end
			end
		end)
	end
	-- ─────────────────────────────────────────────────────────────────────────
	-- Handled: stop the physics grab. It used to carry on and put a weapon
	-- that was being removed (or is now in your inventory) in your hand.
	return false
end)

-- ── Manual item consumption (ammo, health, armor) ────────────────────────
-- A grabbed item is given, never held (return false: no physics grab). This
-- used to fall through to the grab: the item rode the hand until you let go
-- and it happened to touch you inside VRMod_Drop's window, and one you had no
-- use for, or one hidden waiting to respawn, stayed on the hand.
-- An engine item has no pickup Lua can call (its Use is the +use carry, which
-- VR blocks), and giving a copy would skip the map's OnPlayerTouch outputs
-- and the respawn rules. So the item itself is put on the player for GIVE_T
-- with the touch block lifted for it alone (vrmod_give), and the engine's own
-- touch takes it. Not taken (full health, full ammo): back where it was.
if SERVER then
	local GIVE_T = 0.15
	hook.Add("VRMod_Pickup", "ManualItemPickupHook", function(ply, ent)
		if not IsValid(ply) or not IsValid(ent) or ent:IsWeapon() then return end
		local class = ent:GetClass()
		local p5 = class:sub(1, 5)
		-- item_item_crate is a breakable prop, not an item: the hand keeps it
		if p5 ~= "item_" and p5 ~= "ammo_" and class:sub(1, 4) ~= "hl1_" or class == "item_item_crate" then return end
		-- HL1 item waiting to respawn, or already on its way to a player
		if ent.Pickable == false or ent.vrmod_give then return false end
		ent.vrmod_give = ply
		if ent.Pickup then
			ent:Pickup(ply)
			if IsValid(ent) then ent.vrmod_give = nil end
			return false
		end
		-- Scripted items that are taken with +use
		if ent:IsScripted() then
			ent:Use(ply, ply, USE_ON, 1)
			if not IsValid(ent) or ent:IsMarkedForDeletion() then return false end
		end
		local pos, ang, phys = ent:GetPos(), ent:GetAngles(), ent:GetPhysicsObject()
		local motion = IsValid(phys) and phys:IsMotionEnabled()
		if motion then phys:EnableMotion(false) end
		ent:SetPos(ply:WorldSpaceCenter())
		timer.Simple(GIVE_T, function()
			if not IsValid(ent) then return end
			ent.vrmod_give = nil
			if ent:IsEffectActive(EF_NODRAW) then return end -- taken: hidden until it respawns
			ent:SetPos(pos)
			ent:SetAngles(ang)
			if motion and IsValid(phys) then
				phys:EnableMotion(true)
				phys:Wake()
			end
		end)
		return false
	end)
end

-- Disable touch-based item pickup
hook.Add("PlayerCanPickupItem", "ItemTouchPickupDisablerVR", function(ply, item)
	local id = ply:EntIndex()
	if vrmod_manualpickup:GetBool() and item:GetClass() ~= "item_suit" and item.vrmod_give ~= ply and PickupDisabled[id] and ply:GetNWBool("IsVR", false) then return false end
end)

-- Disable touch-based weapon pickup.
--
-- PlayerCanPickupWeapon fires for Player:Give as well as for walking over a
-- weapon, so blocking it unconditionally also rejected every scripted give.
-- SpawnSetPickupState re-arms the block on every PlayerSpawn while the IsVR
-- flag survives death, so respawning in VR had its entire loadout refused --
-- the "dying in VR empties the inventory" bug. Scripted gives are let through
-- via an explicit flag where we can hook the caller, and otherwise by age: a
-- weapon Give creates and equips the entity in the same tick, while a weapon
-- lying on the floor was created at least one tick before you touched it.
local ScriptedGive = {}
local function FlagGive(ply)
	local id = ply:EntIndex()
	ScriptedGive[id] = true
	timer.Simple(0, function() ScriptedGive[id] = nil end)
end

hook.Add("PlayerGiveSWEP", "VRModManualPickup_SpawnFlag", FlagGive)
hook.Add("PlayerLoadout", "VRModManualPickup_LoadoutFlag", FlagGive)

local function TouchBlocked(ply, wep)
	if not IsValid(wep) then return end
	-- Ahead of everything below, the manual-pickup switch included. A weapon
	-- you just threw spawns on your hand, inside its own touch bounds:
	--   manual pickup off: nothing stood between it and the touch pickup (this
	--     check used to sit behind the switch), so it was back the same tick;
	--   manual pickup on: it is both freshly created (the give-age test lets
	--     it through) and dropped inside the VRMod_Drop window that clears
	--     PickupDisabledWeapons.
	-- Stamped by sh_dropweapon. Touches while it runs push it on (DROP_STAND):
	-- a gun dropped at your feet stays down until you have stepped off it, not
	-- until a second has gone by. A hand grab ends it (ManualWeaponPickupHook).
	local cd = wep.vrmod_dropCooldown
	if cd then
		local now = CurTime()
		if cd > now then
			if cd < now + DROP_STAND then wep.vrmod_dropCooldown = now + DROP_STAND end
			return false
		end
		wep.vrmod_dropCooldown = nil
	end
	if not vrmod_manualpickup:GetBool() or wep:GetClass() == "weapon_vrmod_empty" then return end
	local id = ply:EntIndex()
	if ScriptedGive[id] then return end
	if not PickupDisabledWeapons[id] or not ply:GetNWBool("IsVR", false) then return end
	if CurTime() - wep:GetCreationTime() < 0.05 then return end
	return false
end
hook.Add("PlayerCanPickupWeapon", "WeaponTouchPickupDisablerVR", TouchBlocked)

-- The first hook to answer PlayerCanPickupWeapon wins, and the order is not
-- ours to pick: an addon whose hook returns true for every weapon (seen:
-- HookStalker2ResetGunHealth) ran ahead of the block above, and walking over a
-- gun picked it up again. Every other hook on the event is wrapped to ask the
-- block first, whoever owns it. Wrapped once per function, at VR start and on
-- spawn (hooks added after ours at load are there by then).
if SERVER then
	local guarded = setmetatable({}, {__mode = "k"})
	local function GuardPickupHooks()
		local t = hook.GetTable().PlayerCanPickupWeapon
		if not t then return end
		for k, f in pairs(t) do
			if isstring(k) and f ~= TouchBlocked and not guarded[f] then
				local w = function(ply, wep, ...)
					if TouchBlocked(ply, wep) == false then return false end
					return f(ply, wep, ...)
				end
				guarded[w] = true
				hook.Add("PlayerCanPickupWeapon", k, w)
			end
		end
	end
	hook.Add("VRMod_Start", "VRModManualPickup_Guard", GuardPickupHooks)
	hook.Add("PlayerSpawn", "VRModManualPickup_Guard", GuardPickupHooks)
end

-- ── Visual Debug Overlay ─────────────────────────────────────────────────
if SERVER then
	hook.Add("Think", "VRMod_ArcVR_Debug_FloatingText", function()
		if not debug_arcvr:GetBool() then return end

		for _, ent in ipairs(ents.GetAll()) do
			if not IsValid(ent) then continue end

			local pos = ent:GetPos() + Vector(0, 0, 15)

			if ent.VRMod_ArcVR_Stasis then
				local txt = string.format("STAMPED - Loaded: %d, Chambered: %d, Mag: %s",
					ent.VRMod_ArcVR_Stasis.LoadedRounds or 0,
					ent.VRMod_ArcVR_Stasis.Chambered or 0,
					tostring(ent.VRMod_ArcVR_Stasis.Magazine)
				)
				debugoverlay.Text(pos, txt, 0.1, false)
			elseif ent.ArcticVR and ent.LoadedRounds ~= nil then
				local txt = string.format("ACTIVE - Loaded: %d, Chambered: %d, Mag: %s",
					ent.LoadedRounds or 0,
					ent.Chambered or 0,
					tostring(ent.Magazine)
				)
				debugoverlay.Text(pos + Vector(0, 0, 5), txt, 0.1, false)
			end
		end
	end)
end
-- ─────────────────────────────────────────────────────────────────────────
