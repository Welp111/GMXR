--[[
MAX PAYNE
]]
g_VR = g_VR or {}
vrmod = vrmod or {}

local IsValid, CurTime, SysTime = IsValid, CurTime, SysTime
local NET = "vrmod_dualwield"
local OP_SET, OP_RELOAD, OP_MUZ, OP_DROP = 0, 1, 2, 3
-- A usercmd bit nothing reads: this command is the left hand's. Not
-- IN_BULLRUSH (TacRP's tactical toggle, ARC9's melee), IN_WEAPON1/2,
-- IN_GRENADE1/2 or IN_ALT1/2: those bases and their VR layers use them all.
local HAND = IN_SCORE
local RELOAD_T = 0.3     -- a reloaded gun fires after this
-- On the weapon: the hand whose pair it holds, and the other hand's pair
local NW_L, NW_C, NW_N = "vrdw_l", "vrdw_c", "vrdw_n"
local NW_X = "vrdw_x" -- copies of this weapon its owner has past the first
local NW_ON = "vrdw_on" -- on the player: dual wielding (everyone else draws the second gun off it)

local FL = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
local sv_dw = CreateConVar("vrmod_sv_dualwield", "1", FL, "Allow VR dual wielding", 0, 1)
local sv_chest = CreateConVar("vrmod_sv_chestreload", "1", FL, "Allow the VR chest reload (off while dual wielding: the reload button reloads both guns)", 0, 1)
local sv_chestAll = CreateConVar("vrmod_sv_chestreload_all", "1", FL, "Allow the VR chest reload on any weapon, not only while dual wielding", 0, 1)
local sv_ammoAll = CreateConVar("vrmod_sv_handammo_all", "1", FL, "Allow the rounds-over-the-hand counter on any weapon, not only while dual wielding", 0, 1)

-- [ply] = {wep, cur, clip = {[left] = n}, nxt = {[left] = t}, ...}. Hands are keyed by `left`.
-- Kept on vrmod: a lua refresh of this file carries on with the same sessions.
vrmod._dwS = vrmod._dwS or setmetatable({}, {__mode = "k"})
local S = vrmod._dwS
local Publish, Stop -- server

-- A scripted weapon's Reload, stubbed while it is dual wielded and put back
-- after. The original rides on the weapon (false: it had none of its own).
local function NoReload() end
local function Stub(wep, on)
	if not wep:IsScripted() then return end
	local t = wep:GetTable()
	if on then
		if t.vrDWReload == nil then t.vrDWReload = rawget(t, "Reload") or false end
		t.Reload = NoReload
	elseif t.vrDWReload ~= nil then
		t.Reload = t.vrDWReload or nil
		t.vrDWReload = nil
	end
end

local function Cap(w)
	local f = w.ArcCW and w.GetCapacity
	if f then return f(w) end
	f = w.ARC9 and w.GetProcessedValue
	if f then return f(w, "ClipSize") or 0 end
	return w:GetMaxClip1()
end

-- The weapon takes `left`'s pair. The hand it held keeps what the weapon made
-- of its own. A gun that has been ready for a while is ready now, no earlier:
-- the HL2 machine guns fire a round for every fire interval they find between
-- NextPrimaryFire and CurTime.
local function Load(wep, d, left)
	local cur = d.cur
	if left == cur then return end
	local clip, nxt = d.clip, d.nxt
	clip[cur], nxt[cur] = wep:Clip1(), wep:GetNextPrimaryFire()
	d.cur = left
	wep:SetClip1(clip[left])
	local t, now = nxt[left], CurTime()
	wep:SetNextPrimaryFire(t > now and t or now)
	if Publish then Publish(wep, d) end
end

hook.Add("SetupMove", "vrmod_dualwield", function(ply, mv, cmd)
	local d = S[ply]
	if not d then return end
	local wep = d.wep
	if not IsValid(wep) or ply:GetActiveWeapon() ~= wep then
		if Stop then Stop(ply) end
		return
	end

	if CLIENT then
		-- A prediction pass restarts from the server's state, and so do the slots
		local n = cmd:CommandNumber()
		if n ~= d.n + 1 then
			local l = wep:GetNW2Bool(NW_L)
			d.cur, d.clip[not l], d.nxt[not l] = l, wep:GetNW2Int(NW_C), wep:GetNW2Float(NW_N)
		end
		d.n = n
	end

	local left = cmd:KeyDown(HAND)
	Load(wep, d, left)
	-- Dry: the engine's empty-clip reload and empty-gun switch both wait for this
	if wep:Clip1() == 0 then wep:SetNextPrimaryFire(CurTime() + 0.1) end
	if CLIENT then return end

	-- Manual reload re-syncs its flag from the client now and then
	if d.norm ~= nil and not wep:GetNW2Bool("vrmr_norm") then wep:SetNW2Bool("vrmr_norm", true) end
	-- This hand's muzzle, as sent just ahead of the command: GetAimVector and
	-- the bullet source here, the shoot pos in FinishMove
	local t = d.mt[left]
	if t and SysTime() - t < 0.25 then
		local vr, p = d.vr, d.mp[left]
		vr.muzzlePos, vr.muzzleAng, d.eye = p, d.ma[left], p
	else
		d.eye = nil
	end
end)

if SERVER then
	util.AddNetworkString(NET)
	local BLOCK = {weapon_vrmod_empty = true, weapon_physgun = true, weapon_physcannon = true, gmod_tool = true, gmod_camera = true, weapon_medkit = true}
	local MUZ_MAX = 160 * 160
	local _vo = Vector()

	function Publish(wep, d)
		local o = not d.cur
		wep:SetNW2Bool(NW_L, d.cur)
		wep:SetNW2Int(NW_C, d.clip[o])
		wep:SetNW2Float(NW_N, d.nxt[o])
	end

	-- The gun and the hand it belongs in go both ways: ending needs nothing the client kept
	local function Tell(ply, on, wep, left)
		net.Start(NET)
		net.WriteBool(on)
		net.WriteEntity(wep)
		net.WriteBool(left)
		net.Send(ply)
	end

	-- ── Universal Dual Wield ────────────────────────────────────────────
	-- Its state is ply.DualWield_Offhands[class] plus three networked flags;
	-- its magazine split / merge are its own PlayerSwitchWeapon hooks, run
	-- here as (ply, old, NULL) and (ply, NULL, new). HL2 layer first: run
	-- second it adds the off-hand magazine on top of the merged one.
	local ADDON_SW = {"DualWield_HL2NativeMagazineSwitch", "DualWield_SwitchMagazine"}

	local function Flags(ply, class)
		local on = class ~= nil
		ply:SetNWBool("DualWield_Enabled", on)
		ply:SetNWBool("DualWield_HasOffhand", on)
		ply:SetNWString("DualWield_OffhandClass", class or "")
	end

	-- Returns the clone's magazine when the addon had an off-hand gun to take over
	local function Bridge(ply, wep, d, class)
		local off = ply.DualWield_Offhands
		if not off then return end
		local data = off[class]
		local t = hook.GetTable().PlayerSwitchWeapon
		local f = istable(data) and t and t[ADDON_SW[2]]
		if f then
			f(ply, wep, NULL) -- its split: one magazine stays in the gun, the other in data.clip1
			off[class] = nil  -- its doubled magazine and fire rate stand down while both guns are real
			d.adopt = data
		end
		-- Its flags come down: the second gun everyone else sees is ours (the
		-- client's PostPlayerDraw), not its third-person copy on top of it
		Flags(ply)
		return f and math.max(data.clip1 or 0, 0)
	end

	-- True when the clone's magazine went back to the addon
	local function Unbridge(ply, wep, d, n, switching)
		local off = ply.DualWield_Offhands
		if not off then return end
		local data = d.adopt
		if data then
			data.clip1, data.magazineActive, data.DW_HL2Combined = n, false, false
			off[wep:GetClass()] = data
		end
		-- A weapon switch is the addon's to sync: its own hooks run for it
		if switching then return data ~= nil end
		if not data then Flags(ply) return end
		Flags(ply, wep:GetClass())
		local t = hook.GetTable().PlayerSwitchWeapon
		for i = 1, 2 do
			local f = t and t[ADDON_SW[i]]
			if f then f(ply, NULL, wep) end
		end
		return true
	end

	-- ── Start / stop ────────────────────────────────────────────────────
	-- quiet: the server's own start (a copy gained in hand); a refusal says nothing
	local function Start(ply, left, quiet)
		if S[ply] then return end
		local vr, wep = g_VR[ply:SteamID()], ply:GetActiveWeapon()
		local class = IsValid(wep) and wep:GetClass()
		-- Every refusal is told: the client may have a holstered copy waiting on the answer
		if not (vr and class and sv_dw:GetBool() and ply:Alive()) or BLOCK[class] or wep.ArcticVR
			or class:find("akimbo", 1, true) or class:find("dual", 1, true) then
			if quiet then return end
			ply:PrintMessage(HUD_PRINTCONSOLE, "[Dual Wield] not available for this weapon\n")
			Tell(ply, false, wep, left)
			return
		end

		local o = not left
		local d = {wep = wep, cur = left, main = left, vr = vr,
			clip = {}, nxt = {[left] = 0, [o] = CurTime() + RELOAD_T},
			mp = {[true] = Vector(), [false] = Vector()}, ma = {[true] = Angle(), [false] = Angle()}, mt = {}}
		-- The clone's magazine: the addon's off-hand gun, else one out of the reserve
		local n, got = wep:Clip1(), Bridge(ply, wep, d, class)
		if n >= 0 then
			n = got
			if not n then
				local at = wep:GetPrimaryAmmoType()
				n = math.max(math.min(Cap(wep), ply:GetAmmoCount(at)), 0)
				ply:RemoveAmmo(n, at)
			end
		end
		d.clip[left], d.clip[o] = wep:Clip1(), n

		-- Manual reload stands down through its own "keeps its reload" flag
		if ply:GetInfoNum("vrmod_manualreload", 0) > 0 then
			d.norm = wep:GetNW2Bool("vrmr_norm")
			wep:SetNW2Bool("vrmr_norm", true)
			wep:SetNW2Bool("vrmr_out", false)
			wep:SetNW2Bool("vrmr_unch", false)
		end
		Stub(wep, true)
		S[ply] = d
		ply:SetNW2Bool(NW_ON, true)
		Publish(wep, d)
		Tell(ply, true, wep, left)
		hook.Run("VRMod_DualWield", ply, true)
	end

	-- A dropped hand's gun: a weapon in the world at that hand, with its magazine
	local function Throw(ply, class, left, n, vel)
		local e = ents.Create(class)
		if not IsValid(e) then return end
		local fp, fa = left and vrmod.GetLeftHandPos or vrmod.GetRightHandPos, left and vrmod.GetLeftHandAng or vrmod.GetRightHandAng
		e:SetPos(fp and fp(ply) or ply:GetShootPos())
		e:SetAngles(fa and fa(ply) or ply:EyeAngles())
		-- sh_manualpickup's stamps: no touch pickup while it leaves, no hand takes it straight back
		e.vrmod_dropCooldown, e.vrmod_dropT = CurTime() + 1, CurTime()
		e:Spawn()
		if n >= 0 then e:SetClip1(n) end
		local phys = e:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			-- NaN fails the comparison too
			phys:SetVelocity(vel:LengthSqr() <= 4e6 and ply:GetVelocity() + vel or ply:GetVelocity())
		end
	end

	-- keep: the hand whose gun stays (the one it started in unless said).
	-- vel: the other hand's gun is dropped, thrown at this.
	function Stop(ply, switching, keep, vel)
		local d = S[ply]
		if not d then return end
		S[ply] = nil
		if IsValid(ply) then ply:SetNW2Bool(NW_ON, false) end
		if keep == nil then keep = d.main end
		local wep = d.wep
		if IsValid(wep) then
			Load(wep, d, keep) -- the real gun leaves with that hand's magazine
			local n, x = d.clip[not keep], wep:GetNW2Int(NW_X)
			if not Unbridge(ply, wep, d, n, switching) then
				if vel and x > 0 then
					-- a real copy: it leaves the count and lands with its rounds
					wep:SetNW2Int(NW_X, x - 1)
					Throw(ply, wep:GetClass(), not keep, n, vel)
				elseif n > 0 then
					ply:GiveAmmo(n, wep:GetPrimaryAmmoType(), true)
				end
			end
			if d.norm ~= nil then wep:SetNW2Bool("vrmr_norm", d.norm) end
			Stub(wep, false)
		end
		Tell(ply, false, wep, keep)
		hook.Run("VRMod_DualWield", ply, false)
	end
	cvars.AddChangeCallback("vrmod_sv_dualwield", function(_, _, v)
		if v ~= "0" then return end
		for ply in pairs(S) do Stop(ply) end
	end, "vrmod_dualwield")

	-- A hand at the chest: its magazine filled out of the reserve. No d: a single gun.
	local function Refill(ply, wep, d, left)
		local cur = not d or left == d.cur
		local clip = cur and wep:Clip1() or d.clip[left]
		local at = wep:GetPrimaryAmmoType()
		local n = math.min(Cap(wep) - clip, ply:GetAmmoCount(at))
		if clip < 0 or n <= 0 then return end
		ply:RemoveAmmo(n, at)
		local t = CurTime() + RELOAD_T
		if cur then
			wep:SetClip1(clip + n)
			if wep:GetNextPrimaryFire() < t then wep:SetNextPrimaryFire(t) end
		else
			d.clip[left] = clip + n
			if d.nxt[left] < t then d.nxt[left] = t end
			Publish(wep, d)
		end
		ply:EmitSound("items/ammo_pickup.wav", 60, 100, 0.6)
	end

	-- 195 bits at most (the muzzle); one muzzle per firing command. Every
	-- message is its op and one bool: start / the left hand's
	vrmod.NetReceiveLimited(NET, 300, 256, function(_, ply)
		local op, a = net.ReadUInt(2), net.ReadBool()
		if op == OP_SET then
			local left = net.ReadBool()
			if a then Start(ply, left) else Stop(ply, false, left) end
			return
		end
		local d = S[ply]
		if op == OP_RELOAD then
			local wep = ply:GetActiveWeapon()
			if not (ply:Alive() and IsValid(wep)) then return end
			if d then
				if wep == d.wep then Refill(ply, wep, d, a) end
			elseif sv_chest:GetBool() and sv_chestAll:GetBool() and g_VR[ply:SteamID()] and not wep.ArcticVR and wep:GetPrimaryAmmoType() >= 0 then
				Refill(ply, wep)
			end
		elseif op == OP_DROP then
			local v = net.ReadVector()
			if d then
				Stop(ply, false, not a, v)
			else
				-- One gun, dropped by sh_dropweapon while a holster keeps its
				-- class (so the class isn't stripped): that is one copy less
				local wep = ply:GetActiveWeapon()
				local x = IsValid(wep) and wep:GetNW2Int(NW_X) or 0
				if x > 0 then wep:SetNW2Int(NW_X, x - 1) end
			end
		elseif op == OP_MUZ and d then
			local x, y, z = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
			local p, yw, r = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
			local pos = d.mp[a]
			pos:SetUnpacked(x, y, z)
			-- NaN and inf fail both tests; the cap is sh_network's own
			if (p + yw + r) * 0 == 0 and pos:DistToSqr(ply:GetPos()) <= MUZ_MAX then
				d.ma[a]:SetUnpacked(p, yw, r)
				d.mt[a] = SysTime()
			else
				d.mt[a] = nil
			end
		end
	end)

	-- After sh_network's own (hooks run in the order they were added): its
	-- muzzle is the hot hand's as of the last net tick, ours the command's
	hook.Add("FinishMove", "vrmod_dualwield", function(ply, mv)
		local d = S[ply]
		local m = d and d.eye
		if not m then return end
		_vo:Set(m)
		_vo:Sub(mv:GetOrigin())
		ply:SetCurrentViewOffset(_vo)
	end)

	hook.Add("PlayerSwitchWeapon", "vrmod_dualwield", function(ply, old)
		local d = S[ply]
		if d and d.wep == old then Stop(ply, true) end
	end)
	hook.Add("PlayerDeath", "vrmod_dualwield", function(ply)
		Stop(ply)
		-- the copies die with their owner: nothing is handed over when these are stripped
		for _, w in ipairs(ply:GetWeapons()) do w.vrDWOwner = nil end
	end)

	-- ── Copies ──────────────────────────────────────────────────────────
	-- stamp: the tick of what gave it (one give can be seen by two of the
	-- hooks below). held: the class was in hand then, so the copy goes into
	-- the other hand.
	local function AddCopy(ply, class, stamp, held)
		local w = ply:GetWeapon(class)
		if not IsValid(w) or w.vrDWStamp == stamp then return end
		w.vrDWStamp = stamp
		local n = w:GetNW2Int(NW_X) + 1
		w:SetNW2Int(NW_X, n)
		w.vrDWOwner = ply
		ply:PrintMessage(HUD_PRINTCONSOLE, "[Dual Wield] " .. class .. ": " .. (n + 1) .. " copies\n")
		if held and ply:GetActiveWeapon() == w then Start(ply, ply.vrGunLeft == true, true) end
	end
	local function Held(ply, class)
		local aw = ply:GetActiveWeapon()
		return IsValid(aw) and aw:GetClass() == class
	end
	-- A weapon entity of a class the player owns, gone right after they took
	-- it: the pickup consumed it (ammo to the reserve), and it is one more copy.
	local function Took(ply, ent, t)
		local class = ent:GetClass()
		if not ply:HasWeapon(class) or ent:GetOwner() == ply then return end
		local stamp, held = CurTime(), Held(ply, class)
		timer.Simple(t, function()
			if not IsValid(ent) and IsValid(ply) then AddCopy(ply, class, stamp, held) end
		end)
	end
	-- The hand: sh_manualpickup calls this just before it consumes a duplicate,
	-- and a held one let go into a holster is absorbed a moment after
	hook.Add("VRMod_Drop", "vrmod_dualwield", function(ply, ent)
		if IsValid(ply) and IsValid(ent) and ent:IsWeapon() then Took(ply, ent, 0.3) end
	end)
	-- The touch pickup. Says nothing itself: only watches what becomes of the weapon.
	hook.Add("PlayerCanPickupWeapon", "vrmod_dualwield", function(ply, wep)
		local now = CurTime()
		if (wep.vrDWT or 0) > now then return end
		wep.vrDWT = now + 0.2
		Took(ply, wep, 0)
	end)
	-- The spawn menu, on a class already owned (says nothing either)
	hook.Add("PlayerGiveSWEP", "vrmod_dualwield", function(ply, class)
		if not ply:HasWeapon(class) then return end
		local stamp, held = CurTime(), Held(ply, class)
		timer.Simple(0, function()
			if IsValid(ply) then AddCopy(ply, class, stamp, held) end
		end)
	end)

	-- The owned weapon leaves (dropped, or stripped by a drop) with copies
	-- left: the next copy takes its place, empty, with the rest of the count
	local function Lose(wep)
		local n, ply = wep:GetNW2Int(NW_X), wep.vrDWOwner
		wep.vrDWOwner = nil
		if n < 1 or not (IsValid(ply) and ply:Alive()) then return end
		wep:SetNW2Int(NW_X, 0)
		local class = wep:GetClass()
		timer.Simple(0, function()
			if not (IsValid(ply) and ply:Alive()) or ply:HasWeapon(class) then return end
			local aw = ply:GetActiveWeapon()
			local w = ply:Give(class, true)
			if not IsValid(w) then return end
			if w:Clip1() > 0 then w:SetClip1(0) end
			if n > 1 then
				w:SetNW2Int(NW_X, n - 1)
				w.vrDWOwner = ply
			end
			-- the give may have drawn it: the hand stays as it was
			if IsValid(aw) and ply:GetActiveWeapon() ~= aw then ply:SelectWeapon(aw:GetClass()) end
		end)
	end
	hook.Add("PlayerDroppedWeapon", "vrmod_dualwield", function(_, wep) Lose(wep) end)
	hook.Add("EntityRemoved", "vrmod_dualwield", function(e) if e.vrDWOwner then Lose(e) end end)
	hook.Add("VRMod_Exit", "vrmod_dualwield", function(ply) if IsValid(ply) then Stop(ply) end end)
	return
end

-- ── CLIENT ──────────────────────────────────────────────────────────────
local LocalPlayer, RealTime = LocalPlayer, RealTime
local band, math_sin, math_cos = bit.band, math.sin, math.cos
local U = vrmod.utils
local SP = game.SinglePlayer()
local KEEP = bit.bnot(IN_ATTACK + IN_ATTACK2 + IN_RELOAD + HAND)

local cv_btn = CreateClientConVar("vrmod_dualwield_reloadbutton", "0", true, false, "Dual wield: the reload button reloads both guns (0: only a hand at the chest does)", 0, 1)
local cv_ammo = CreateClientConVar("vrmod_dualwield_ammo", "1", true, false, "Dual wield: show each gun's rounds over its hand", 0, 1)
local cv_dbg = CreateClientConVar("vrmod_dualwield_debug", "0", false, false, "Dual wield: draw the chest reload zone", 0, 1)
local cv_chest = CreateClientConVar("vrmod_dualwield_chest", "2 13 7", true, false, "Dual wield chest reload zone, from the HMD: forward  down  radius")
local cv_chestOn = CreateClientConVar("vrmod_dualwield_chestreload", "1", true, false, "Dual wield: a hand at the chest reloads its gun (0: the reload button reloads both)", 0, 1)
local cv_drop = CreateClientConVar("vrmod_dualwield_drop", "1", true, false, "Dual wield: letting go of a grip drops that hand's gun (follows vrmod_weapondrop_enable too)", 0, 1)
local cv_hol = CreateClientConVar("vrmod_dualwield_holster", "1", true, false, "Taking the held gun's class out of a holster with the other hand dual wields it", 0, 1)
local cv_chestAll = CreateClientConVar("vrmod_chestreload_all", "0", true, false, "The gun hand at the chest reloads any gun, dual wielded or not", 0, 1)
local cv_ammoAll = CreateClientConVar("vrmod_handammo_all", "0", true, false, "Show the rounds over the gun hand for any gun, dual wielded or not", 0, 1)
local chestAll, ammoAll = cv_chestAll:GetBool(), cv_ammoAll:GetBool()
cvars.AddChangeCallback("vrmod_chestreload_all", function() chestAll = cv_chestAll:GetBool() end, "vrmod_dualwield")
cvars.AddChangeCallback("vrmod_handammo_all", function() ammoAll = cv_ammoAll:GetBool() end, "vrmod_dualwield")
local chF, chD, chR
local function Chest()
	local t = string.Explode(" ", cv_chest:GetString())
	chF, chD, chR = tonumber(t[1]) or 2, tonumber(t[2]) or 13, tonumber(t[3]) or 7
end
Chest()
cvars.AddChangeCallback("vrmod_dualwield_chest", Chest, "vrmod_dualwield")

local on, dwWep, mainLeft, lhFn = false
local frozen, latch, arcLeft       -- the gun hand's grip while on; the hand kept shut after; ArcVR's flag was set
local held, pend, was = {}, {}, {} -- [left]: trigger firing, press not yet sent, hand in the chest zone
local down, mute = {}, {}          -- [left]: trigger down at all; down since a menu had it
local fire, fireT, lastAtk, stay = false, 0, false, 0
local rP, rA                       -- the gun's pose in the right hand, from the tracking pass
local poseP, poseA = {}, {}        -- [left]: the gun's pose in that hand
local aimP, aimA = {}, {}          -- [left]: its muzzle there, as the server is to take it
local anim = {[true] = {}, [false] = {}} -- [left]: the animation the gun left that hand in
local clone, cloneSync            -- the other hand's gun; it has yet to take the viewmodel's looks
local hRaw, hL, hR                -- last frame: the weapon's clip, each hand's
local grip, beginT = {}, 0         -- [left]: the hand's real grip; no storing or dropping before this
local melee, cvDropEn              -- the weapon has a physical-melee tip; vrmod_weapondrop_enable
local syncT = 0                    -- the clone takes the viewmodel's looks again after this
local awLast, rOpen                -- the weapon last seen in hand; the right hand's open pose before this
local idleW, idleM, idleS          -- the clone's resting sequence, and what it was worked out for
local chest = Vector()

local function Request(want, left)
	net.Start(NET)
	net.WriteUInt(OP_SET, 2)
	net.WriteBool(want)
	net.WriteBool(left)
	net.SendToServer()
end

-- The reload zone, and a hand coming into it
local function ChestAt()
	local hmd = g_VR.tracking.hmd
	local hp, y = hmd.pos, hmd.ang.y * 0.017453292519943
	chest:SetUnpacked(hp.x + math_cos(y) * chF, hp.y + math_sin(y) * chF, hp.z - chD)
end
local function ChestEnter(left)
	local t = g_VR.tracking
	local inside = (left and t.pose_lefthand or t.pose_righthand).pos:DistToSqr(chest) < chR * chR
	local e = inside and not was[left]
	was[left] = inside
	return e
end

-- Grip, as HandleInput reads it: the runtime's boolean, else the squeeze axis
local GRIP = {[true] = {"boolean_left_pickup", "vector1_left_squeeze"}, [false] = {"boolean_right_pickup", "vector1_right_squeeze"}}
local function Gripped(inp, left)
	local k = GRIP[left]
	local b = inp[k[1]]
	if b == true or b == false then return b end
	return (tonumber(inp[k[2]]) or 0) >= 0.5
end
local function SetGrip(inp, left, v)
	local k = GRIP[left]
	inp[k[1]], inp[k[2]] = v, v and 1 or 0
end

-- A hand's pair, as this client has it: the weapon's own for the hand it
-- holds, else the slot (prediction's in multiplayer, the server's word in SP)
local function ClipOf(wep, d, left)
	if left == d.cur then return wep:Clip1() end
	return d.clip[left]
end
local function Ready(wep, d, left)
	return (left == d.cur and wep:GetNextPrimaryFire() or d.nxt[left]) <= CurTime()
end

local function Buzz(left)
	if vrmod.Haptic then vrmod.Haptic(left and "left" or "right", "impact") end
end

local function TryReload(wep, d, left)
	local c = d and ClipOf(wep, d, left) or wep:Clip1()
	if c < 0 or c >= Cap(wep) or LocalPlayer():GetAmmoCount(wep:GetPrimaryAmmoType()) <= 0 then return end
	net.Start(NET)
	net.WriteUInt(OP_RELOAD, 2)
	net.WriteBool(left)
	net.SendToServer()
	Buzz(left)
end

local function Trigger(wep, d, left, v, menu)
	local dn = v >= (down[left] and 0.4 or 0.5)
	local press = dn and not down[left]
	down[left] = dn
	-- A menu click is no shot, and the trigger that made it comes up first
	if not dn then mute[left] = false elseif menu then mute[left] = true end
	if mute[left] then held[left] = false return end
	if press then
		if ClipOf(wep, d, left) == 0 then
			LocalPlayer():EmitSound("Weapon_Pistol.Empty")
			Buzz(left)
		else
			pend[left] = true
		end
	end
	held[left] = dn
end

-- The real gun moves to `left`. The gun it leaves plays its animation out as the clone.
local function SetHot(left)
	local vm = g_VR.viewModel
	if IsValid(vm) then
		local a = anim[not left]
		a.seq, a.cyc, a.rate, a.t = vm:GetSequence(), vm:GetCycle(), vm:GetPlaybackRate(), CurTime()
	end
	anim[left].seq = nil
	g_VR.gunInLeftHand = left
end

-- Once a frame, inside HandleInput's VRMOD_GetActions (after the tracking
-- pass placed the gun, before anything reads the input)
local swapped
local function Mask(inp, changed)
	if not on then
		-- Ended with the gun hand's grip frozen shut: it stays shut until the
		-- hand has really closed again, or ending would drop the gun
		if latch == nil or Gripped(inp, latch) then
			latch, vrmod._dwMask = nil, nil
		else
			SetGrip(inp, latch, true)
		end
		return
	end
	local wep, lp = dwWep, LocalPlayer()
	local d = S[lp]
	if not (d and IsValid(wep)) then return end
	rP, rA = g_VR.viewModelPos, g_VR.viewModelAng

	-- A grip let go inside a free holster: that hand's gun goes in, the other stays
	local H = vrmod_holster
	for i = 1, 2 do
		local left = i == 1
		local g = Gripped(inp, left)
		if grip[left] and not g and RealTime() > beginT then
			if H and H.IsHandInHolster(left) then
				if H.StoreClass(left, wep:GetClass()) then Request(false, not left) end
			else
				-- Let go anywhere else: that hand's gun is dropped, where dropping is on
				cvDropEn = cvDropEn or GetConVar("vrmod_weapondrop_enable")
				if cv_drop:GetBool() and not g_VR.antiDrop and not (cvDropEn and not cvDropEn:GetBool()) then
					net.Start(NET)
					net.WriteUInt(OP_DROP, 2)
					net.WriteBool(left)
					net.WriteVector((left and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity)() * 2.5)
					net.SendToServer()
				end
			end
		end
		grip[left] = g
	end

	local chestOK = cv_chestOn:GetBool() and sv_chest:GetBool()
	SetGrip(inp, mainLeft, frozen)
	SetGrip(inp, not mainLeft, false)
	if inp.boolean_reload then inp.boolean_reload = false end
	if changed and changed.boolean_reload then
		changed.boolean_reload = nil
		if not chestOK or cv_btn:GetBool() then
			TryReload(wep, d, true)
			TryReload(wep, d, false)
		end
	end

	-- Triggers: read here, and gone for everything after. A menu keeps them (its clicks).
	local menu = g_VR.menuFocus
	local tR = tonumber(inp.vector1_primaryfire) or tonumber(inp.trigger_right_axis) or 0
	local tL = tonumber(inp.vector1_secondaryfire) or tonumber(inp.trigger_left_axis) or 0
	if swapped and g_VR.gunInLeftHand then tL, tR = tR, tL end
	if not menu then
		inp.vector1_primaryfire, inp.vector1_secondaryfire, inp.trigger_right_axis, inp.trigger_left_axis = 0, 0, 0, 0
		inp.boolean_primaryfire, inp.boolean_secondaryfire = false, false
	end
	Trigger(wep, d, true, tL, menu)
	Trigger(wep, d, false, tR, menu)

	-- Chest: a hand coming into the zone reloads its gun
	ChestAt()
	local l, r = ChestEnter(true), ChestEnter(false)
	if chestOK then
		if l then TryReload(wep, d, true) end
		if r then TryReload(wep, d, false) end
	end

	-- Whose gun the next command fires. A press goes first. With both
	-- triggers down the gun stays where it is until the other could fire and
	-- it can't: each then fires at the weapon's own rate.
	local hot = g_VR.gunInLeftHand and true or false
	local o = not hot
	local want
	if pend[hot] then
		want = hot
	elseif pend[o] then
		-- The hot gun's own shot may still be on its way back (singleplayer
		-- predicts nothing): it stays for that, the flash and animation are its own
		if RealTime() < stay and Ready(wep, d, hot) then
			if held[hot] then want = hot end
		else
			want = o
		end
	else
		local a = held[hot] and ClipOf(wep, d, hot) ~= 0
		local b = held[o] and ClipOf(wep, d, o) ~= 0
		if a and not (b and Ready(wep, d, o) and not Ready(wep, d, hot)) then
			want = hot
		elseif b then
			want = o
		end
	end
	fire, fireT = want ~= nil, RealTime()
	if want == o then
		SetHot(o)
	elseif melee and want == nil then
		-- No trigger at work on a melee weapon: it is the swinging hand's. The
		-- swing sweep, the server hull and the hit's damage all go by the gun hand.
		local a = (hot and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity)():LengthSqr()
		local b = (o and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity)():LengthSqr()
		if b > 3600 and b > a * 2.25 then SetHot(o) end
	end
end

-- First thing each frame. Singleplayer predicts nothing: the slots are the
-- server's word. And cl_haptics takes a shot to be the weapon's clip going
-- down, but that clip is whichever hand's is loaded: across a change of hands
-- it compares one gun's rounds with the other's. Each hand's own count says
-- which shots that test missed.
-- Holsters hold copies, they don't make them: no more of a class in holsters
-- and hands than the player has. A gun that reaches the hand any other way
-- than off its holster (weapon menu, a pickup's own select) leaves the holster.
local function Enforce(wep)
	local H = vrmod_holster
	if not (H and IsValid(wep)) then return end
	local cls = wep:GetClass()
	local over = H.CountHolstered(cls) + (on and 1 or 0) - wep:GetNW2Int(NW_X)
	for i = 1, 4 do
		if over < 1 then return end
		local cv = GetConVar("vrmod_pouch_weapon_" .. i)
		if cv and cv:GetString() == cls then
			RunConsoleCommand("vrmod_pouch_weapon_" .. i, "")
			over = over - 1
		end
	end
end

hook.Add("VRMod_Tracking", "vrmod_dualwield", function()
	local aw = LocalPlayer():GetActiveWeapon()
	if aw ~= awLast then
		awLast = aw
		Enforce(aw)
	end
	if not on then
		-- One gun: its hand at the chest, where the player and the server both want it
		if not chestAll then return end
		ChestAt()
		local left = U.GunInLeftHand() and true or false
		if ChestEnter(left) and sv_chest:GetBool() and sv_chestAll:GetBool() then
			local wep = LocalPlayer():GetActiveWeapon()
			if U.IsValidWep(wep) and not wep.ArcticVR then TryReload(wep, nil, left) end
		end
		return
	end
	local wep, d = dwWep, S[LocalPlayer()]
	if not (d and IsValid(wep)) then return end
	if SP then
		local l = wep:GetNW2Bool(NW_L)
		d.cur, d.clip[not l], d.nxt[not l] = l, wep:GetNW2Int(NW_C), wep:GetNW2Float(NW_N)
	end
	local raw, l, r = wep:Clip1(), ClipOf(wep, d, true), ClipOf(wep, d, false)
	if hRaw and raw >= hRaw and vrmod.Haptic then
		if l < hL then vrmod.Haptic(true, "shot") end
		if r < hR then vrmod.Haptic(false, "shot") end
	end
	hRaw, hL, hR = raw, l, r
end)

hook.Add("CreateMove", "vrmod_dualwield", function(cmd)
	if not on or cmd:CommandNumber() == 0 then return end
	local hot = g_VR.gunInLeftHand and true or false
	local atk = fire
	if RealTime() - fireT > 0.25 then
		-- No frames (paused, unfocused): nothing fires, and nothing waits to
		atk, pend[true], pend[false] = false, false, false
	elseif atk and pend[hot] then
		-- A press while the other trigger holds the button down: one command
		-- up first, a semi-auto fires on the edge
		if lastAtk then atk = false else pend[hot], stay = false, RealTime() + 0.05 end
	end
	lastAtk = atk
	local b = band(cmd:GetButtons(), KEEP)
	if hot then b = b + HAND end
	if atk then
		b = b + IN_ATTACK
		-- Ahead of the command, in its packet: the server has this hand's
		-- muzzle when the command runs
		local p, a = aimP[hot], aimA[hot]
		if p then
			net.Start(NET, true)
			net.WriteUInt(OP_MUZ, 2)
			net.WriteBool(hot)
			net.WriteFloat(p.x) net.WriteFloat(p.y) net.WriteFloat(p.z)
			net.WriteFloat(a.p) net.WriteFloat(a.y) net.WriteFloat(a.r)
			net.SendToServer()
		end
	end
	cmd:SetButtons(b)
end)

-- Both guns placed once a frame: the other hand's first, the hot one's last,
-- so the gun stays where it is hot. Left is sh_lefthand's own placement
-- (mirror mode and correction included), right is the tracking pass's.
-- Through U.UpdateViewModel each time: muzzlefix corrects the muzzle there.
local function Place(left)
	g_VR.gunInLeftHand = left
	if left then
		lhFn()
	else
		g_VR.viewModelPos, g_VR.viewModelAng = rP, rA
	end
	U.UpdateViewModel()
	poseP[left], poseA[left] = g_VR.viewModelPos, g_VR.viewModelAng
	local m = g_VR.viewModelMuzzle
	aimP[left], aimA[left] = m and m.Pos, m and m.Ang
end

hook.Add("VRMod_PreRender", "vrmod_dualwield", function()
	if not on or not rP or g_VR.wmActive or not IsValid(g_VR.viewModel) then return end
	local hot = g_VR.gunInLeftHand and true or false
	Place(not hot)
	Place(hot)
	-- The hot gun is drawn turned by its recoil; the weapon adds that itself
	local rc = vrmod_wmrecoil
	if rc and rc.Aim and aimA[hot] then aimA[hot] = rc.Aim(aimA[hot]) end
end)

-- The clone: a clientside copy of the viewmodel in the other hand. Its own
-- entity, because a second draw of the viewmodel itself under another sequence
-- is blended by the engine into the one it is really in (both guns showed
-- every shot). Looks (skin, bodygroups, material, bone edits) are taken from
-- the viewmodel twice a second: bases change them with attachments.
-- The sequence the gun rests in. GMXR seats a viewmodel on the idle it finds
-- by name; vrmod_tacrp and vrmod_arc9 re-seat theirs on the base's own idle,
-- and a clone resting in any other sequence sits off the hand.
local function IdleSeq(wep, vm)
	local mdl = vm:GetModel()
	if wep == idleW and mdl == idleM then return idleS end
	local s
	if wep.ArcticTacRP and wep.TranslateSequence then
		s = vm:LookupSequence(wep:TranslateSequence("idle") or "idle")
	elseif wep.ARC9 and wep.GetAnimationEntry then
		local e = wep:GetAnimationEntry("idle")
		e = e and e.Source or "idle"
		if istable(e) then e = e[1] end
		s = isnumber(e) and e or isstring(e) and vm:LookupSequence(e)
	end
	if not s or s < 0 then s = vrmod.GetIdleSequence(vm) end
	idleW, idleM, idleS = wep, mdl, s
	return s
end

local function Clone(vm)
	local c, mdl = clone, vm:GetModel()
	if not IsValid(c) then
		c = ClientsideModel(mdl, RENDERGROUP_OTHER)
		if not IsValid(c) then return end
		c:SetNoDraw(true)
		clone, cloneSync = c, true
	elseif c:GetModel() ~= mdl then
		c:SetModel(mdl)
		cloneSync = true
	end
	local now = RealTime()
	if cloneSync or now > syncT then
		cloneSync, syncT, idleW = false, now + 0.5, nil
		c:SetSkin(vm:GetSkin())
		c:SetMaterial(vm:GetMaterial())
		for i = 0, vm:GetNumBodyGroups() - 1 do c:SetBodygroup(i, vm:GetBodygroup(i)) end
		for i = 0, vm:GetBoneCount() - 1 do
			c:ManipulateBoneScale(i, vm:GetManipulateBoneScale(i))
			c:ManipulateBonePosition(i, vm:GetManipulateBonePosition(i))
			c:ManipulateBoneAngles(i, vm:GetManipulateBoneAngles(i))
		end
	end
	return c
end

-- What a weapon base draws on top of its viewmodel (attachment models placed
-- off the viewmodel's bones), drawn again on the clone: the base's own draw,
-- with its GetVM answering the clone for that call. The models are left on
-- the clone; the viewmodel's own draw, later in the frame, puts them back.
local function CloneVM() return clone end
local baseOff -- a base's draw threw: no more of it this session
local function TacRP(wep)
	-- vrmod_tacrp poses once a frame and only redraws after (tacvrDF): both
	-- passes have to pose, this one and the viewmodel's after it
	wep.tacvrDF = nil
	wep:DrawCustomModel(false, false, false)
	wep.tacvrDF = nil
end
local function Arc9(wep)
	render.DepthRange(0, 1)
	wep:DrawCustomModel(false)
	-- ARC9's own translucent pass: vrmod_arc9's wrapper adds the optics, which are the real gun's
	local s = ARC9 and ARC9._vr
	local f = s and s.DrawTranslucentPass or wep.DrawTranslucentPass
	f(wep, false, false)
end
local function BaseDraw(wep)
	local f = wep.ArcticTacRP and TacRP or wep.ARC9 and Arc9
	if not f or baseOff or not wep.DrawCustomModel then return end
	local gv = wep.GetVM
	wep.GetVM = CloneVM
	local ok, err = pcall(f, wep)
	wep.GetVM = gv
	render.DepthRange(0, 1)
	if not ok then
		baseOff = true
		ErrorNoHalt("[Dual Wield] attachments on the second gun are off: " .. tostring(err) .. "\n")
	end
end

-- From the translucent pass, where cl_vrmod draws the viewmodel itself, in
-- whatever scene render has one (a scope camera takes g_VR.viewModel away).
-- Not the opaque pass: drawn from there the clone never showed (in-headset,
-- every weapon, blend and colour at their defaults).
hook.Remove("PostDrawViewModel", "vrmod_dualwield")
hook.Remove("PostDrawOpaqueRenderables", "vrmod_dualwield")
local function DrawOff()
	local vm = g_VR.viewModel
	local o = not g_VR.gunInLeftHand
	local p = poseP[o]
	local c = p and IsValid(vm) and Clone(vm)
	if not c then return end
	local a = anim[o]
	local seq, cyc = a.seq, 0
	if seq then
		local dur, rate = vm:SequenceDuration(seq), a.rate
		cyc = a.cyc + (CurTime() - a.t) * (rate > 0 and rate or 1) / (dur > 0 and dur or 1)
		if cyc >= 1 then seq, a.seq = nil, nil end
	end
	local wep = dwWep
	if not IsValid(wep) then return end
	if not seq then seq, cyc = IdleSeq(wep, vm), 0 end
	c:SetSequence(seq)
	c:SetCycle(cyc)
	c:SetPos(p)
	c:SetAngles(poseA[o])
	c:SetupBones()
	render.SetBlend(1)
	c:DrawModel()
	BaseDraw(wep)
end

-- Rounds over each hand, and the chest zone
local COL, COL_DRY, COL_ZONE = Color(255, 255, 255), Color(255, 80, 60), Color(80, 255, 120)
local _tp, _ta = Vector(), Angle()
local function Rounds(c, p)
	_tp:SetUnpacked(p.x, p.y, p.z + 6)
	cam.Start3D2D(_tp, _ta, 0.05)
	draw.SimpleText(c, "DermaLarge", 0, 0, c == 0 and COL_DRY or COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	cam.End3D2D()
end
hook.Add("PostDrawTranslucentRenderables", "vrmod_dualwield", function(depth, sky)
	if depth or sky or not (on or ammoAll or chestAll) or not g_VR.active then return end
	if on and not g_VR.wmActive then DrawOff() end
	if (on or chestAll) and cv_dbg:GetBool() then render.DrawWireframeSphere(chest, chR, 12, 12, COL_ZONE, true) end
	local t = g_VR.tracking
	if not on then
		if not (ammoAll and sv_ammoAll:GetBool()) then return end
		local wep = LocalPlayer():GetActiveWeapon()
		local c = IsValid(wep) and wep:Clip1() or -1
		if c < 0 then return end
		_ta:SetUnpacked(0, EyeAngles().y - 90, 90)
		Rounds(c, (U.GunInLeftHand() and t.pose_lefthand or t.pose_righthand).pos)
		return
	end
	local wep, d = dwWep, S[LocalPlayer()]
	if not (d and cv_ammo:GetBool() and IsValid(wep)) or wep:Clip1() < 0 then return end
	_ta:SetUnpacked(0, EyeAngles().y - 90, 90)
	Rounds(ClipOf(wep, d, true), t.pose_lefthand.pos)
	Rounds(ClipOf(wep, d, false), t.pose_righthand.pos)
end)

-- ── Everyone else ───────────────────────────────────────────────────────
-- A dual wielder as other players see them. The engine draws the real gun's
-- worldmodel in the right hand; this draws a copy of it in the left, on every
-- client but their own (which has the clone above). The copy is seated by
-- its own right-hand bone, as the engine bonemerges the real one, and carried
-- to the left hand the way sh_lefthand carries a worldmodel: where it sits
-- from the right hand's attachment, kept from the left's. That offset, the
-- copy's looks and the lookups are taken twice a second, so a frame costs one
-- attachment and one LocalToWorld. A player model without the attachments:
-- off the left hand bone, as a right hand's (rolled 180).
local LocalToWorld, WorldToLocal = LocalToWorld, WorldToLocal
local R_HAND, R180 = "ValveBiped.Bip01_R_Hand", Angle(0, 0, 180)
-- [ply] = {c = the copy, t = its next sync, mdl, op, oa = its origin from its
-- hand bone, i / b = the left hand's attachment / bone, p, a = the copy in it}
local rem = setmetatable({}, {__mode = "k"})
hook.Add("PostPlayerDraw", "vrmod_dualwield", function(ply)
	local r = rem[ply]
	if not ply:GetNW2Bool(NW_ON) or ply == LocalPlayer() then
		if r then
			if IsValid(r.c) then r.c:Remove() end
			rem[ply] = nil
		end
		return
	end
	local now = RealTime()
	if not r or now > r.t or not IsValid(r.c) then
		local wep = ply:GetActiveWeapon()
		local mdl = IsValid(wep) and wep:GetModel()
		if not mdl or mdl == "" then return end
		if not r then
			r = {t = 0}
			rem[ply] = r
		end
		local c = r.c
		if not IsValid(c) then
			c = ClientsideModel(mdl, RENDERGROUP_OTHER)
			if not IsValid(c) then return end
			c:SetNoDraw(true)
			r.c, r.mdl = c, nil
		end
		if r.mdl ~= mdl then
			c:SetModel(mdl)
			c:SetPos(vector_origin)
			c:SetAngles(angle_zero)
			c:SetupBones()
			-- No bones yet: seated on its origin, and asked again next sync
			local m = c:GetBoneMatrix(c:LookupBone(R_HAND) or 0)
			r.mdl, r.op, r.oa = m and mdl, vector_origin, angle_zero
			if m then r.op, r.oa = WorldToLocal(vector_origin, angle_zero, m:GetTranslation(), m:GetAngles()) end
		end
		r.t = now + 0.5
		c:SetSkin(wep:GetSkin())
		c:SetMaterial(wep:GetMaterial())
		for i = 0, wep:GetNumBodyGroups() - 1 do c:SetBodygroup(i, wep:GetBodygroup(i)) end
		local iR, iL = ply:LookupAttachment("anim_attachment_RH"), ply:LookupAttachment("anim_attachment_LH")
		local rh = iR > 0 and iL > 0 and ply:GetAttachment(iR)
		local m = rh and ply:GetBoneMatrix(ply:LookupBone(R_HAND) or -1)
		if m then
			local p, a = LocalToWorld(r.op, r.oa, m:GetTranslation(), m:GetAngles())
			r.p, r.a = WorldToLocal(p, a, rh.Pos, rh.Ang)
			r.i, r.b = iL, nil
		else
			r.p, r.a = LocalToWorld(r.op, r.oa, vector_origin, R180)
			r.i, r.b = nil, ply:LookupBone("ValveBiped.Bip01_L_Hand")
		end
	end
	local pos, ang
	if r.i then
		local lh = ply:GetAttachment(r.i)
		if not lh then return end
		pos, ang = lh.Pos, lh.Ang
	else
		local m = r.b and ply:GetBoneMatrix(r.b)
		if not m then return end
		pos, ang = m:GetTranslation(), m:GetAngles()
	end
	local c = r.c
	pos, ang = LocalToWorld(r.p, r.a, pos, ang)
	c:SetPos(pos)
	c:SetAngles(ang)
	c:SetupBones()
	c:DrawModel()
end)

-- ── Begin / end (the server's call) ─────────────────────────────────────
-- sh_lefthand's own placement, by name: the left hand's gun pose is its to say
local function LH()
	local t = hook.GetTable().VRMod_PreRender
	lhFn = t and t.vrmod_lefthand
	return lhFn
end

-- wep, left: the gun and the hand it goes back to
local function End(wep, left)
	if on and frozen then latch = left else vrmod._dwMask = nil end
	on, g_VR.dualWield, dwWep = false, nil, nil
	local lp = LocalPlayer()
	S[lp] = nil
	if IsValid(wep) then
		Stub(wep, false)
		-- Same gun: back in the hand it started in. Another: sh_lefthand has already said.
		if lp:GetActiveWeapon() == wep then
			g_VR.gunInLeftHand = left
			if arcLeft and ArcticVR then ArcticVR.GunInLeftHand = true end
			if rOpen then vrmod.SetRightHandOpenFingerAngles(rOpen) end
		end
	end
	arcLeft, rOpen = nil, nil
	if IsValid(clone) then clone:Remove() end
	clone = nil
	vrmod.SetLeftHandOpenFingerAngles(vrmod.GetDefaultLeftHandOpenFingerAngles())
	vrmod.SetLeftHandClosedFingerAngles(vrmod.GetDefaultLeftHandClosedFingerAngles())
end

local function Begin(wep, left)
	on, dwWep, mainLeft, g_VR.dualWield = true, wep, left, true
	g_VR.gunInLeftHand = left
	-- sh_lefthand mirrors a left-held gun onto ArcVR's flag, and every "which
	-- hand" test ORs that in: down while the hot hand is ours to say
	arcLeft = ArcticVR and ArcticVR.GunInLeftHand
	if arcLeft then ArcticVR.GunInLeftHand = false end
	frozen, latch = Gripped(g_VR.input, left), nil
	grip[true], grip[false], beginT = Gripped(g_VR.input, true), Gripped(g_VR.input, false), RealTime() + 1
	local def = vrmod.PhysMeleeDef and vrmod.PhysMeleeDef(wep)
	melee = def and def.tip ~= nil or false
	-- was: a hand already at the chest has to leave it first
	held[true], held[false], pend[true], pend[false], was[true], was[false] = false, false, false, false, true, true
	down[true], down[false], mute[true], mute[false] = false, false, false, false
	fire, lastAtk, rP, hRaw, cloneSync = false, false, nil, nil, true
	poseP[true], poseP[false], anim[true].seq, anim[false].seq = nil, nil, nil, nil
	local c = wep:Clip1()
	S[LocalPlayer()] = {wep = wep, cur = left, n = -2, clip = {[true] = c, [false] = c}, nxt = {[true] = 0, [false] = 0}}
	-- Both hands shut on a grip: the left wears the right's, mirrored (-p, y, -r)
	local gc, f = g_VR.closedHandAngles, {}
	for i = 1, 15 do
		local a = gc[i + 15]
		f[i] = Angle(-a.p, a.y, -a.r)
	end
	vrmod.SetLeftHandOpenFingerAngles(f)
	vrmod.SetLeftHandClosedFingerAngles(f)
	-- and the right stays shut whatever its grip reads (the other hand's is held open)
	local get = vrmod.GetRightHandOpenFingerAngles
	rOpen = get and get() or nil
	if rOpen then
		f = {}
		for i = 1, 15 do f[i] = gc[i + 15] end
		vrmod.SetRightHandOpenFingerAngles(f)
	end
	Stub(wep, true)
	Enforce(wep)
	vrmod._dwMask = Mask
end

net.Receive(NET, function()
	local go, wep, left = net.ReadBool(), net.ReadEntity(), net.ReadBool()
	if on or not go then End(wep, left) end
	if not go then return end
	-- The server may start it itself (a copy gained in hand): what can't be shown is called off
	if IsValid(wep) and g_VR.active and not g_VR.wmActive and LH() then Begin(wep, left) else Request(false, left) end
end)

local function CanStart(wep)
	return not on and sv_dw:GetBool() and g_VR.active and LH() and not g_VR.wmActive and U.IsValidWep(wep) and not wep.ArcticVR
end

concommand.Add("vrmod_dualwield", function(_, _, a)
	local want = not on
	if a[1] then want = a[1] ~= "0" end
	if want == on then return end
	if not want then Request(false, mainLeft) return end
	if not CanStart(LocalPlayer():GetActiveWeapon()) then
		print("[Dual Wield] needs VR, a viewmodel weapon in hand and vrmod_sv_dualwield 1")
		return
	end
	Request(true, U.GunInLeftHand() and true or false)
end, nil, "Dual wield the held gun: no argument toggles, 0 / 1 sets")

-- ── Weapon menu ─────────────────────────────────────────────────────────
-- Copies of wep not in a hand
local function Spare(wep)
	local n = 1 + wep:GetNW2Int(NW_X)
	if LocalPlayer():GetActiveWeapon() == wep then n = n - (on and 2 or 1) end
	return n > 0 and n or 0
end
vrmod.DualWieldSpare = Spare

-- Picking a weapon: the held one again takes a spare copy into the other hand
function vrmod.DualWieldSelect(wep)
	if LocalPlayer():GetActiveWeapon() ~= wep then input.SelectWeapon(wep) return end
	if Spare(wep) > 0 and CanStart(wep) then Request(true, U.GunInLeftHand() and true or false) end
end

-- ── Holster ─────────────────────────────────────────────────────────────
-- The holster's own grip handler, wrapped: a draw of the held gun's class by
-- the other hand, with a copy to spare, is the second gun. Its draw runs as ever (slot emptied, its
-- sound, its net: the server finds the class already in hand and does
-- nothing); what it drew is read off the hand record it sets.
local holW
local function WrapHolster()
	local t = hook.GetTable().VRMod_Input
	local f = t and t.vrmod_holster_input
	if not f or f == holW then return end
	if f == vrmod._dwHolW then f = vrmod._dwHolF end -- an earlier load of this file
	holW = function(action, pressed)
		local left = action == "boolean_left_pickup"
		local H, wep = vrmod_holster, LocalPlayer():GetActiveWeapon()
		if not (pressed and H and (left or action == "boolean_right_pickup")) or left == (U.GunInLeftHand() and true or false)
			or not H.IsHandInHolster(left) or not cv_hol:GetBool() or not CanStart(wep) or Spare(wep) < 1 then
			return f(action, pressed)
		end
		local prev, arc = H.GetHand(left), ArcticVR and ArcticVR.GunInLeftHand
		H.ClearHand(left)
		f(action, pressed)
		local got = H.GetHand(left)
		if got == "" then H.SetHand(left, prev) return end
		if got ~= wep:GetClass() then return end
		if ArcticVR then ArcticVR.GunInLeftHand = arc end -- the draw pointed it at this hand
		Request(true, not left)
	end
	vrmod._dwHolF, vrmod._dwHolW = f, holW
	hook.Add("VRMod_Input", "vrmod_holster_input", holW)
end
WrapHolster()

-- ── Settings (VRMod menu) ───────────────────────────────────────────────
-- Into the menu's own tabs, found by name; a tab of its own if they aren't there
hook.Add("VRMod_Menu", "vrmod_dualwield", function(frame)
	local top = frame.DPropertySheet
	if not top then return end
	local function Tab(sheet, name)
		for _, it in ipairs(sheet:GetItems()) do
			if it.Name == name then return it.Panel end
		end
	end
	local function Sub(a, b)
		local p = Tab(top, a)
		if not p then return end
		for _, c in ipairs(p:GetChildren()) do
			if c.GetItems then return Tab(c, b) end
		end
	end
	local own
	local function Form(a, b, title)
		local p = Sub(a, b)
		if not p then
			if not own then
				own = vgui.Create("DScrollPanel", top)
				top:AddSheet("Dual Wield", own, "icon16/gun.png")
			end
			p = own
		end
		local f = vgui.Create("DForm", p)
		f:SetName(title)
		f:Dock(TOP)
		f:DockMargin(5, 5, 5, 0)
		f:SetExpanded(true)
		return f
	end

	local f = Form("Client", "Gameplay", "Dual Wield / Chest Reload")
	f:CheckBox("Dual wield from a holster", "vrmod_dualwield_holster")
	f:ControlHelp("With a second copy of the gun you hold (pick another one up), taking it out of a holster with your other hand dual wields it. The weapon menu does it too: pick the held gun again.")
	f:CheckBox("Let go of a grip to drop that hand's gun", "vrmod_dualwield_drop")
	f:ControlHelp("While dual wielding. Inside a free holster the gun is stored instead. Needs weapon dropping on.")
	f:CheckBox("Chest reload while dual wielding", "vrmod_dualwield_chestreload")
	f:ControlHelp("Touch a hand to your chest to reload its gun. Off: the reload button reloads both.")
	f:CheckBox("Reload button reloads both guns", "vrmod_dualwield_reloadbutton")
	f:ControlHelp("While dual wielding, with the chest reload on as well.")
	f:CheckBox("Chest reload on every gun", "vrmod_chestreload_all")
	f:ControlHelp("Touch your gun hand to your chest to reload any gun, dual wielded or not. The server can turn this off.")
	f:TextEntry("Chest zone", "vrmod_dualwield_chest")
	f:ControlHelp("Where the reload zone sits from your headset: forward, down, radius.")
	f:CheckBox("Show the chest zone", "vrmod_dualwield_debug")

	f = Form("Client", "HUD/UI", "Hand Ammo Counter")
	f:CheckBox("Rounds over each hand while dual wielding", "vrmod_dualwield_ammo")
	f:CheckBox("Rounds over the gun hand on every gun", "vrmod_handammo_all")
	f:ControlHelp("The server can turn this off.")

	f = Form("Server", "Combat", "Dual Wield / Chest Reload")
	f:CheckBox("Allow dual wielding", "vrmod_sv_dualwield")
	f:CheckBox("Allow the chest reload", "vrmod_sv_chestreload")
	f:ControlHelp("Off: dual wielders reload both guns with the reload button.")
	f:CheckBox("Allow the chest reload on every gun", "vrmod_sv_chestreload_all")
	f:CheckBox("Allow the hand ammo counter on every gun", "vrmod_sv_handammo_all")
end)

-- ── Universal Dual Wield, client side ───────────────────────────────────
-- Its first-person renderer draws at the viewmodel and swallows the
-- viewmodel's own draw, and its third-person copy lands on our own left
-- hand: neither while in VR. Wrapped once its hooks exist.
local GUARD = {{"Think", "DualWield_Controller"}, {"PreDrawViewModel", "DualWield_CustomViewmodelRenderer"}, {"PostPlayerDraw", "DualWield_ThirdPersonSecondWeapon", true}}
local guarded = {}
hook.Add("VRMod_Start", "vrmod_dualwield", function(ply)
	if ply ~= LocalPlayer() then return end
	WrapHolster()
	local t = hook.GetTable()
	for i = 1, #GUARD do
		local g = GUARD[i]
		local f = t[g[1]] and t[g[1]][g[2]]
		if f and not guarded[f] then
			local own = g[3]
			local w = function(a, ...)
				if g_VR.active and (not own or a == LocalPlayer()) then return end
				return f(a, ...)
			end
			guarded[w] = true
			hook.Add(g[1], g[2], w)
		end
	end
end)

hook.Add("VRMod_Exit", "vrmod_dualwield", function(ply)
	if ply ~= LocalPlayer() then return end
	if on then End(dwWep, mainLeft) end
	latch, vrmod._dwMask = nil, nil
end)

-- ── Wrappers, installed once (a lua refresh of this file reuses them) ───
-- Input: 1 = inside sh_lefthand's trigger swap (it loads after this file and
-- wraps us), 2 = outside it. Outside, sh_lefthand has to see its own wrapper
-- as the global or it wraps again at VRMod_Start, and two swaps are none.
-- HandleInput pcalls VRMOD_GetActions, so an error in the mask is reported
-- here: swallowed there it would silently take every input with it.
if VRMOD_GetActions and not vrmod._dwAct then
	local f = VRMOD_GetActions
	vrmod._dwAct = f == vrmod._lhActWrap and 2 or 1
	local function wrap()
		local inp, changed = f()
		local m = vrmod._dwMask
		if m and inp then
			local ok, err = pcall(m, inp, changed)
			if not ok then
				vrmod._dwMask = nil
				ErrorNoHalt("[Dual Wield] " .. tostring(err) .. "\n")
			end
		end
		return inp, changed
	end
	VRMOD_GetActions = wrap
	if vrmod._dwAct == 2 then vrmod._lhActWrap = wrap end
end
swapped = vrmod._dwAct == 2
-- A lua refresh mid-session: the locals that ran it are gone, so it ends. The
-- server's reply cleans up here (the gun's hand, its Reload, the fingers).
vrmod._dwMask = nil
if g_VR.dualWield then
	g_VR.dualWield = nil
	net.Start(NET)
	net.WriteUInt(OP_SET, 2)
	net.WriteBool(false)
	net.WriteBool(false)
	net.SendToServer()
end

-- sh_dropweapon's drop. Not while both hands hold a gun (a hand's own grip
-- drops it then). One gun, and a holster that keeps its class: the class
-- stays in the inventory, so the server is told that copy is gone.
if vrmod.SendWeaponDrop and vrmod.SendWeaponDrop ~= vrmod._dwDrop then vrmod._dwDropF = vrmod.SendWeaponDrop end
if vrmod._dwDropF then
	local f = vrmod._dwDropF
	vrmod._dwDrop = function(left)
		if g_VR.dualWield then return end
		local wep, H = LocalPlayer():GetActiveWeapon(), vrmod_holster
		if H and IsValid(wep) and wep:GetNW2Int(NW_X) > 0 and H.CountWeapon(wep:GetClass()) > 1 then
			net.Start(NET)
			net.WriteUInt(OP_DROP, 2)
			net.WriteBool(left and true or false)
			net.WriteVector(vector_origin)
			net.SendToServer()
		end
		return f(left)
	end
	vrmod.SendWeaponDrop = vrmod._dwDrop
end
