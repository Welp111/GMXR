local U = vrmod.utils
vrmod.suppressViewModelUpdates = false
local IsValid, LocalToWorld, LocalPlayer = IsValid, LocalToWorld, LocalPlayer
-- WEP UTILS
-- Empty hands are ruled out before the viewmodel read
local function IsValidWep(wep, get)
    if not IsValid(wep) then return false end
    local class = wep:GetClass()
    if class == "weapon_vrmod_empty" then return false end
    local vm = wep:GetWeaponViewModel()
    if vm == "" or vm == "models/weapons/c_arms.mdl" then return false end
    if get then return class, vm end
    return true
end
U.IsValidWep = IsValidWep

function U.IsWeaponEntity(ent)
    if not IsValid(ent) then return false end
    local c = ent:GetClass()
    return ent:IsWeapon() or c:find("weapon_", 1, true) or c == "prop_physics" and ent:GetModel():find("w_", 1, true)
end

function U.WepInfo(wep)
    local class, vm = IsValidWep(wep, true)
    if class then return class, vm end
end

function U.UpdateViewModelPos(pos, ang, override)
    if vrmod.suppressViewModelUpdates and not override then
        U.UpdateViewModel()
        return
    end
    local ply = LocalPlayer()
    if not IsValid(ply) or not g_VR.active or not ply:Alive() then return end
    -- Recoil (vrmod_wm_recoil) turns the gun hand here, as the gun is placed
    -- off it: after every VRMod_Tracking hook has had the pose, so foregrip's
    -- two-hand aim can't replace the angle after the kick went on.
    local kick = vrmod_wmrecoil and vrmod_wmrecoil.Kick -- nil on an older recoil file
    if kick then ang = kick(ang) end
    local currentvmi = g_VR.currentvmi
    if currentvmi then
        -- pos is the gun hand's final pose (GunWallPivot and hull error, in
        -- cl_vrmod). This used to swap in the hand sphere's raw HMD->hand
        -- trace HitPos instead: a point ON the wall along the head ray,
        -- nowhere near the grip, so any gun with a vmi entry jumped there
        -- whenever the hand neared a wall.
        g_VR.viewModelPos, g_VR.viewModelAng = LocalToWorld(currentvmi.offsetPos, currentvmi.offsetAng, pos, ang)
    else
        g_VR.viewModelPos, g_VR.viewModelAng = pos, ang
    end
    U.UpdateViewModel()
end

-- Muzzle attachment index, resolved by name and cached per model. Index 1 is
-- the muzzle on purpose-built VR weapons, but on HL2 viewmodels it is often the
-- shell-eject/casing attachment.
--
-- Cached per model rather than in a single slot: worldmodel mode alternates
-- between the weapon's w_ model and the viewmodel across a frame, and a
-- one-entry cache re-ran LookupAttachment on every switch.
local muzIdxCache = {}
local function MuzzleIndex(ent, mdl)
    mdl = mdl or ent:GetModel()
    if not mdl then return 1 end
    local i = muzIdxCache[mdl]
    if i then return i end
    i = ent:LookupAttachment("muzzle") or 0
    if i <= 0 then i = ent:LookupAttachment("muzzle_flash") or 0 end
    if i <= 0 then i = 1 end
    muzIdxCache[mdl] = i
    return i
end

local SETTLE_HITS = 6      -- consecutive still frames required (~66ms @ 90fps)
local SETTLE_DIST = 0.01   -- squared units of allowed drift between samples
local SETTLE_ANG = 0.25    -- degrees of allowed drift, per axis
local FrameNumber, WorldToLocal, AUnpack = FrameNumber, WorldToLocal, FindMetaTable("Angle").Unpack
-- |math.AngleDifference| <= SETTLE_ANG on every axis, inlined
local function Settled(a, b)
    local p1, y1, r1 = AUnpack(a)
    local p2, y2, r2 = AUnpack(b)
    local d = (p1 - p2 + 180) % 360 - 180
    if not (d <= SETTLE_ANG and d >= -SETTLE_ANG) then return false end
    d = (y1 - y2 + 180) % 360 - 180
    if not (d <= SETTLE_ANG and d >= -SETTLE_ANG) then return false end
    d = (r1 - r2 + 180) % 360 - 180
    return d <= SETTLE_ANG and d >= -SETTLE_ANG
end
local capMdl, capFrame, capN, capPos, capAng = nil, -1, 0, nil, nil
concommand.Add("vrmod_muzzle_recapture", function()
    muzLocal, capMdl, capN = {}, nil, 0
end, nil, "Forget the cached rigid muzzle offsets and measure them again")

local muzBone = {} -- [model] = { bone, localPos, localAng } | false
local function MuzzleBone(vm, mdl)
    local c = muzBone[mdl]
    if c ~= nil then return c end
    c = false
    local cm = ClientsideModel(mdl, RENDERGROUP_OTHER)
    if IsValid(cm) then
        cm:SetupBones()
        local att = cm:GetAttachment(MuzzleIndex(vm, mdl))
        local b = att and att.Bone
        local mtx = b and b >= 0 and cm:GetBoneMatrix(b)
        if mtx then c = { b, WorldToLocal(att.Pos, att.Ang, mtx:GetTranslation(), mtx:GetAngles()) } end
        cm:Remove()
    end
    muzBone[mdl] = c
    return c
end

local _muz = {}
function U.RefreshViewModelMuzzle(vm)
    vm = vm or g_VR.viewModel
    -- _muz is shared, and muzzlefix wraps UpdateViewModel to rotate .Ang IN
    -- PLACE. Any path that leaves a previously-published _muz live while the
    -- wrapper still runs re-rotates the same Angle every frame, so the muzzle
    -- winds away from the barrel until it is pointing somewhere else entirely.
    -- Every exit from here must therefore either write a fresh transform or
    -- clear the muzzle outright.
    if not IsValid(vm) then
        g_VR.viewModelMuzzle = nil
        return
    end

    if vm:IsWeapon() then
        vm:InvalidateBoneCache()
        local att = vm:GetAttachment(MuzzleIndex(vm))
        if att then
            _muz.Pos, _muz.Ang = att.Pos, att.Ang
            g_VR.viewModelMuzzle = _muz
        else
            -- No usable attachment: drop it rather than leave the previous
            -- weapon's muzzle hanging around for the laser and aim vector.
            g_VR.viewModelMuzzle = nil
        end
        return
    end
    vm:InvalidateBoneCache()
    local rigid = rigidOn
    local mdl = vm:GetModel()
    local m = rigid and muzLocal[mdl]
    if m then
        _muz.Pos, _muz.Ang = LocalToWorld(m.Pos, m.Ang, pos, ang)
        g_VR.viewModelMuzzle = _muz
        return
    end
    -- Live path: build now so the bone read reflects the pose we just set
    -- rather than whatever it was cached at. This is also the sampler for the
    -- settle capture below, so an uncommitted model costs one bone build per
    -- frame -- exactly what the live path cost on its own.
    vm:SetupBones()
    local c = MuzzleBone(vm, mdl)
    local mtx = c and vm:GetBoneMatrix(c[1])
    local mp, ma
    if mtx then
        mp, ma = LocalToWorld(c[2], c[3], mtx:GetTranslation(), mtx:GetAngles())
    else
        local att = vm:GetAttachment(MuzzleIndex(vm, mdl))
        if not att then
            if rigid then muzLocal[mdl] = false end
            g_VR.viewModelMuzzle = nil
            return
        end
        mp, ma = att.Pos, att.Ang
    end

    _muz.Pos, _muz.Ang = mp, ma
    g_VR.viewModelMuzzle = _muz
    -- Settle sampler. Reads the RAW attachment: muzzlefix's per-weapon angle
    -- correction is applied by its UpdateViewModel wrapper only after this
    -- returns, so a committed offset can never bake that correction in and
    -- double-apply it. m is false here when rigid is off or the model has no
    -- attachment, and nil when it is still uncommitted.
    if m == false then return end
    local fn = FrameNumber()
    if fn == capFrame then return end
    capFrame = fn
    -- vm is already at pos/ang, so WorldToLocal against it yields the
    -- model-space offset directly.
    local lp, la = WorldToLocal(mp, ma, pos, ang)
    if capMdl ~= mdl then
        capMdl, capN = mdl, 1
    elseif lp:DistToSqr(capPos) <= SETTLE_DIST and Settled(la, capAng) then
        capN = capN + 1
        if capN >= SETTLE_HITS then muzLocal[mdl] = {Pos = lp, Ang = la} end
    else
        capN = 1
    end

    capPos, capAng = lp, la
end

-- muzzlefix wraps UpdateViewModel (callers go through U); Refresh is not wrapped
local RefreshMuzzle = U.RefreshViewModelMuzzle
function U.UpdateViewModel()
    RefreshMuzzle(g_VR.viewModel)
end

if CLIENT then
    local _view = {}
    local function CalcVRView(_, _, _, fov)
        local hmd = g_VR.threePoints and g_VR.tracking.hmd
        if not hmd then return end
        local muz = g_VR.viewModelMuzzle
        _view.origin = hmd.pos
        _view.angles = muz and (muz.Pos - hmd.pos):Angle() or hmd.ang
        _view.fov = fov
        return _view
    end
    hook.Add("VRMod_Start", "vrmod_muzzle_view", function(ply)
        if ply == LocalPlayer() then hook.Add("CalcView", "vrutil_hook_calcview", CalcVRView) end
    end)
    hook.Add("VRMod_Exit", "vrmod_muzzle_view", function(ply)
        if ply == LocalPlayer() then hook.Remove("CalcView", "vrutil_hook_calcview") end
    end)
end