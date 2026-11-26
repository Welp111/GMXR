if SERVER then return end
local BLOCK = {boolean_right_pickup = true, boolean_primaryfire = true, boolean_secondaryfire = true}
local wrapper
local function Apply()
    local cv = GetConVar("vrmod_brushclimb")
    if not (cv and cv:GetBool()) then return end
    local t = hook.GetTable().VRMod_Input
    local orig = t and t.brushclimb
    if not orig or orig == wrapper then return end
    wrapper = function(action, pressed)
        if BLOCK[action] and not vrmod.UsingEmptyHands(LocalPlayer()) then return end
        return orig(action, pressed)
    end
    hook.Add("VRMod_Input", "brushclimb", wrapper)
end
local function Defer() timer.Simple(0, Apply) end
hook.Add("VRMod_Start", "vrmod_climbing_hook_blocker_weapon", Defer)
cvars.AddChangeCallback("vrmod_brushclimb", Defer, "vrmod_climbing_hook_blocker_weapon")