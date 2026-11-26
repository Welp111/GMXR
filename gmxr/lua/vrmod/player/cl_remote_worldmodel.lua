if SERVER then return end

local IsValid, LocalPlayer = IsValid, LocalPlayer
local R_HAND = "ValveBiped.Bip01_R_Hand"
local R180 = Angle(0, 0, 180) -- cl_character's right hand bone: the tracked hand rolled 180
local EPS_POS, EPS_ANG = 0.0001, 0.01

local _ta, _tm, _hm = Angle(), Matrix(), Matrix()

-- Right hand of a remote VR player as the network frame has it this frame,
-- as an R_Hand bone pose. The angle is scratch: read it at once.
local function RemoteGunHand(ply)
	if ply == LocalPlayer() then return end
	local n = g_VR.net and g_VR.net[ply:SteamID()]
	local f = n and n.lerpedFrame
	local p, a = f and f.righthandPos, f and f.righthandAng
	if not (p and a) then return end
	_ta:SetUnpacked(a.p + R180.p, a.y + R180.y, a.r + R180.r)
	return p, _ta
end
vrmod.RemoteGunHand = RemoteGunHand

-- Left on the weapon for life: it answers only while its owner is a remote
-- VR player, so a dropped gun, a desktop owner or an exited session cost a
-- table lookup per bone build.
local function BBP(wep, n)
	local ow = wep:GetOwner()
	if not IsValid(ow) or not ow:IsPlayer() or ow:GetActiveWeapon() ~= wep then return end
	local p, a = RemoteGunHand(ow)
	if not p then return end
	local b = ow:LookupBone(R_HAND)
	local hm = b and ow:GetBoneMatrix(b)
	if not hm then return end
	local hp, ha = hm:GetTranslation(), hm:GetAngles()
	local dx, dy, dz = hp.x - p.x, hp.y - p.y, hp.z - p.z
	if dx * dx + dy * dy + dz * dz < EPS_POS then
		local dp, dyaw, dr = (ha.p - a.p + 180) % 360 - 180, (ha.y - a.y + 180) % 360 - 180, (ha.r - a.r + 180) % 360 - 180
		if dp * dp + dyaw * dyaw + dr * dr < EPS_ANG then return end -- already in the hand
	end
	_hm:Set(hm)
	_hm:InvertTR()
	_tm:SetTranslation(p)
	_tm:SetAngles(a)
	_tm:Mul(_hm) -- target * hand^-1
	for i = 0, n - 1 do
		local m = wep:GetBoneMatrix(i)
		if m then wep:SetBoneMatrix(i, _tm * m) end
	end
end

-- Hooked on the weapons remote VR players are drawn holding, once each.
local hooked = setmetatable({}, {__mode = "k"})
hook.Add("PrePlayerDraw", "vrmod_remote_worldmodel", function(ply)
	local w = ply:GetActiveWeapon()
	if not IsValid(w) or hooked[w] or ply == LocalPlayer() then return end
	local n = g_VR.net and g_VR.net[ply:SteamID()]
	if not n then return end
	hooked[w] = true
	w:AddCallback("BuildBonePositions", BBP)
end)
