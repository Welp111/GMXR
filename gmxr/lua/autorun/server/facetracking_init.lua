-- even more complex
print("[FaceTrack] Server init")
util.AddNetworkString("ft_flex")
AddCSLuaFile("facetracking/cl_facetracking.lua")
AddCSLuaFile("facetracking/cl_facetracking_ui.lua")
include("facetracking/sv_facetracking.lua")