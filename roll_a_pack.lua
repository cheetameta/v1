-- Roll-A-Pack | Auto Rebirth Only (30s interval)
print("[RollAPack] script chunk started")

-- SERVICES
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Workspace           = game:GetService("Workspace")
local UserInputService    = game:GetService("UserInputService")
local VirtualUser         = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- CONFIG
local CONFIG = {
    AUTO_REBIRTH = false,
    REBIRTH_INTERVAL = 5,
    AUTO_LUCKY = false,
    LUCKY_SCAN_INTERVAL = 5,
    LUCKY_TP_INTERVAL = 20,
    SHOP_HOTKEY = Enum.KeyCode.P,
    AUTO_BUY_SHOP = false,
    BUY_DELAY = 1,
    SELECTED_PACK = nil,
    ANTI_AFK = false,
    DEBUG = true,
}

-- RUNTIME / EJECT
local RUNTIME = {
    EJECTED     = false,
    CONNECTIONS = {},
}
local rebirthing = false
local luckyLooping = false
local buyingShop = false

local function addConnection(sig, fn)
    local conn = sig:Connect(fn)
    table.insert(RUNTIME.CONNECTIONS, conn)
    return conn
end

local function ejectScript()
    if RUNTIME.EJECTED then return end
    RUNTIME.EJECTED = true
    CONFIG.AUTO_REBIRTH = false
    CONFIG.AUTO_LUCKY = false
    CONFIG.AUTO_BUY_SHOP = false
    CONFIG.ANTI_AFK = false
    rebirthing = false
    luckyLooping = false
    buyingShop = false
    for _, conn in ipairs(RUNTIME.CONNECTIONS) do
        pcall(conn.Disconnect, conn)
    end
    RUNTIME.CONNECTIONS = {}
    local gui = PlayerGui:FindFirstChild("RollAPackUI")
    if gui then gui:Destroy() end
    pcall(function()
        local h = gethui and gethui()
        if h then
            local g2 = h:FindFirstChild("RollAPackUI")
            if g2 then g2:Destroy() end
        end
    end)
    print("[RollAPack] EJECTED — all loops stopped, GUI removed.")
end

-- UTILITY
local function log(...)
    if CONFIG.DEBUG then
        print("[RollAPack]", ...)
    end
end

-- Cmdr SUPPORT
local CmdrClient = nil
do
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj.Name == "CmdrClient" then
            local ok, mod = pcall(require, obj)
            if ok then
                CmdrClient = mod
                log("CmdrClient loaded from " .. obj:GetFullName())
            end
            break
        end
    end
end

local function cmdrExec(cmd, ...)
    if not CmdrClient then return false end
    local args = { ... }
    local ok, err = pcall(function()
        CmdrClient:Execute(cmd, table.unpack(args))
    end)
    if not ok then
        log("Cmdr exec error for '" .. cmd .. "':", err)
        return false
    end
    return true
end

-- REMOTE AUTO-DETECTION (rebirth + shop/packs)
local REMOTES = {
    rebirth = { "rebirth", "prestige", "reset" },
    buy     = { "buy", "purchase", "shop", "pack", "openpack", "unlockpack" },
    folders = { "Remotes", "RemoteEvents", "Events", "Functions", "RE", "RF", "Network", "Net" },
}
local foundRemotes = {}
local function scanInstance(parent, depth)
    depth = depth or 0
    if depth > 6 then return end
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
            local low = child.Name:lower()
            for cat, patterns in pairs(REMOTES) do
                if cat == "folders" then continue end
                for _, pat in ipairs(patterns) do
                    if low:find(pat) then
                        foundRemotes[cat] = foundRemotes[cat] or {}
                        if not table.find(foundRemotes[cat], child) then
                            table.insert(foundRemotes[cat], child)
                            log("Found [" .. cat .. "]: " .. child:GetFullName())
                        end
                    end
                end
            end
        end
        scanInstance(child, depth + 1)
    end
end
scanInstance(ReplicatedStorage)
scanInstance(Workspace)
if PlayerGui then scanInstance(PlayerGui) end
for _, folderName in ipairs(REMOTES.folders) do
    local f = ReplicatedStorage:FindFirstChild(folderName)
    if f then scanInstance(f) end
end
local function getRemote(cat)
    local arr = foundRemotes[cat]
    if arr and #arr > 0 then return arr[1] end
    return nil
end
local rebirthRemote = getRemote("rebirth")
local buyRemote = getRemote("buy")
log("Rebirth remote:", rebirthRemote and rebirthRemote:GetFullName() or "NOT FOUND")
log("Buy/Pack remote:", buyRemote and buyRemote:GetFullName() or "NOT FOUND")

-- LUCKY AREA (any LuckyCircle* — number changes each server)
local function getLuckyParts()
    local parts = {}
    pcall(function()
        -- find any LuckyCircle* container (LuckyCircle3, LuckyCircle8, etc.)
        for _, child in ipairs(Workspace:GetChildren()) do
            if child.Name:lower():find("luckycircle") then
                local gc = child:FindFirstChild("GradientCylinder")
                if gc and gc:IsA("BasePart") then table.insert(parts, gc) end
                local ic = child:FindFirstChild("InnerCylinder")
                if ic and ic:IsA("BasePart") then table.insert(parts, ic) end
                -- if container itself is a part, also use it
                if child:IsA("BasePart") then table.insert(parts, child) end
            end
            if child.Name:lower():find("lucky") and child:IsA("BasePart") then
                table.insert(parts, child)
            end
        end
        -- also scan whole workspace for GradientCylinder/InnerCylinder under Lucky
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj.Name == "GradientCylinder" or obj.Name == "InnerCylinder" then
                local parent = obj.Parent
                if parent and parent.Name:lower():find("lucky") and obj:IsA("BasePart") then
                    if not table.find(parts, obj) then table.insert(parts, obj) end
                end
            end
        end
    end)
    -- fallback
    if #parts == 0 then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name:lower():find("lucky") then
                table.insert(parts, obj)
            end
        end
    end
    return parts
end

local function getLuckyPart()
    local parts = getLuckyParts()
    return parts[1]
end

local function getHRP()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

local function doLucky()
    if not CONFIG.AUTO_LUCKY then return end
    if luckyLooping then return end
    luckyLooping = true
    task.spawn(function()
        log("Lucky TP started (scan 5s, TP 20s)")
        local lastTP = 0
        while not RUNTIME.EJECTED do
            if not CONFIG.AUTO_LUCKY then break end
            local parts = getLuckyParts()
            if #parts == 0 then
                -- no circle, just scan again in 5s
                task.wait(CONFIG.LUCKY_SCAN_INTERVAL)
            else
                -- circle exists, TP only every 20s
                if tick() - lastTP >= CONFIG.LUCKY_TP_INTERVAL then
                    local hrp = getHRP()
                    local target = parts[1]
                    if hrp and target and target:IsA("BasePart") then
                        pcall(function()
                            hrp.CFrame = target.CFrame + Vector3.new(0, 3, 0)
                            log("Lucky TP to:", target:GetFullName())
                        end)
                        lastTP = tick()
                    end
                end
                task.wait(CONFIG.LUCKY_SCAN_INTERVAL)
            end
        end
        luckyLooping = false
        log("Lucky TP stopped")
    end)
end

-- PACK SHOP OPENER (only PackShop, one time) - Hitboxes.PackShop.TouchInterest
local function getPackShopPart()
    local ok, part = pcall(function()
        return Workspace:FindFirstChild("Hitboxes")
            and Workspace.Hitboxes:FindFirstChild("PackShop")
    end)
    if ok and part and part:IsA("BasePart") then return part end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find("packshop") then return obj end
    end
    return nil
end

local function openPackShop()
    local packPart = getPackShopPart()
    local hrp = getHRP()
    if packPart and hrp and firetouchinterest then
        pcall(function()
            firetouchinterest(hrp, packPart, 0)
            task.wait()
            firetouchinterest(hrp, packPart, 1)
        end)
        log("PackShop opened (one-time touch):", packPart:GetFullName())
        return true
    end
    log("PackShop part not found for touch")
    return false
end

-- REBIRTH HELPERS
local function fireRebirth(rem, label)
    if not rem then
        log(label .. ": no remote found")
        return
    end
    local ok, err = pcall(function()
        if rem:IsA("RemoteFunction") then
            rem:InvokeServer()
        else
            rem:FireServer()
        end
    end)
    if ok then
        log(label .. " fired: " .. rem:GetFullName())
    else
        log(label .. " error:", err)
    end
end

local function pressButton(btn)
    if not btn then return false end
    if btn:IsA("TextButton") or btn:IsA("ImageButton") then
        local ok = false
        pcall(function() btn:Activate() ok = true end)
        if firesignal then
            pcall(function() firesignal(btn.MouseButton1Click) ok = true end)
            pcall(function() firesignal(btn.Activated) ok = true end)
        end
        return ok
    elseif btn:IsA("ClickDetector") and fireclickdetector then
        pcall(function() fireclickdetector(btn) end)
        return true
    end
    return false
end

-- PACK DISCOVERY + AUTO BUY SHOP (via buyRemote)
local function findPacks()
    local packs = {}
    local function consider(obj)
        if obj.Name:lower():find("pack") then
            if not table.find(packs, obj) then table.insert(packs, obj) end
        end
    end
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("Folder") or obj:IsA("StringValue") or obj:IsA("Part") or obj:IsA("MeshPart") then
            consider(obj)
        end
    end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("Part") or obj:IsA("MeshPart") then consider(obj) end
    end
    for _, gui in ipairs(PlayerGui:GetDescendants()) do
        if gui:IsA("TextButton") or gui:IsA("ImageButton") then consider(gui) end
    end
    return packs
end

local function doAutoBuyShop()
    if not CONFIG.AUTO_BUY_SHOP then return end
    if buyingShop then return end
    buyingShop = true
    task.spawn(function()
        log("Auto-Buy Shop started")
        local packs = findPacks()
        local packName = CONFIG.SELECTED_PACK or (packs[1] and packs[1].Name) or "Pack"
        log("Buying pack:", packName, "found", #packs)
        while CONFIG.AUTO_BUY_SHOP and not RUNTIME.EJECTED do
            -- ensure shop is considered open (silent touch) before buying
            local packPart = getPackShopPart()
            local hrp = getHRP()
            if packPart and hrp and firetouchinterest then
                pcall(function() firetouchinterest(hrp, packPart, 0); task.wait(); firetouchinterest(hrp, packPart, 1) end)
            end
            if buyRemote then
                pcall(function()
                    if buyRemote:IsA("RemoteFunction") then buyRemote:InvokeServer(packName) else buyRemote:FireServer(packName) end
                end)
            end
            cmdrExec("buypack", packName)
            cmdrExec("buy", packName)
            task.wait(CONFIG.BUY_DELAY)
        end
        buyingShop = false
    end)
end

local function pressRebirthButton()
    -- no GUI forcing — only try if button is already interactable
    local ok, container = pcall(function()
        return PlayerGui:FindFirstChild("Main")
            and PlayerGui.Main:FindFirstChild("Frames")
            and PlayerGui.Main.Frames:FindFirstChild("Rebirth")
            and PlayerGui.Main.Frames.Rebirth:FindFirstChild("Rebirth")
    end)
    if ok and container then
        if container:IsA("TextButton") or container:IsA("ImageButton") then
            if pressButton(container) then
                log("Rebirth pressed exact:", container:GetFullName())
                return true
            end
        end
        -- try inner buttons without forcing Visible
        for _, d in ipairs(container:GetDescendants()) do
            if d:IsA("TextButton") or d:IsA("ImageButton") then
                if pressButton(d) then
                    log("Rebirth pressed inner:", d:GetFullName())
                    return true
                end
            end
        end
    end
    return false
end

local function doRebirth()
    if not CONFIG.AUTO_REBIRTH then return end
    if rebirthing then return end
    rebirthing = true
    task.spawn(function()
        log("Auto-Rebirth started, interval:", CONFIG.REBIRTH_INTERVAL, "s (silent, no GUI)")
        while CONFIG.AUTO_REBIRTH and not RUNTIME.EJECTED do
            wait(CONFIG.REBIRTH_INTERVAL)
            if not CONFIG.AUTO_REBIRTH or RUNTIME.EJECTED then break end
            log("Rebirthing (30s timer) — silent")
            -- primary: remotes only, no GUI forcing
            cmdrExec("rebirth")
            cmdrExec("rebirth", "1")
            fireRebirth(rebirthRemote, "Rebirth(remote)")
            -- optional GUI press only if already visible (no forcing)
            -- pressRebirthButton() is silent and won't pop GUI
        end
        rebirthing = false
    end)
end

-- UI — holy clean white/grey + Minecraft font (no self-clipping)
local UI_ACCENT = Color3.fromRGB(255, 255, 255)
local UI_GREEN  = Color3.fromRGB(220, 220, 220)
local UI_RED    = Color3.fromRGB(180, 180, 180)
local UI_GOLD   = Color3.fromRGB(240, 240, 240)
local UI_TEXT   = Color3.fromRGB(35, 35, 35)
local UI_DIM    = Color3.fromRGB(110, 110, 110)
local UI_BG     = Color3.fromRGB(245, 245, 245)
local UI_CARD   = Color3.fromRGB(255, 255, 255)

local MC_FONT = Enum.Font.GothamBold -- clean white/grey

local function uiStroke(parent, color)
    local s = Instance.new("UIStroke")
    s.Color = color or Color3.fromRGB(210, 210, 210)
    s.Thickness = 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = parent
    return s
end

local function uiCorner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = parent
    return c
end

local function uiButton(parent, text, bg, textSize)
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = bg or UI_CARD
    b.Text = text
    b.TextColor3 = UI_TEXT
    b.Font = MC_FONT
    b.TextSize = textSize or 12
    b.AutoButtonColor = false
    b.BorderSizePixel = 0
    b.Parent = parent
    uiCorner(b, 6)
    uiStroke(b, Color3.fromRGB(230,230,230))
    return b
end

local function createUI()
    local old = PlayerGui:FindFirstChild("RollAPackUI")
    if old then old:Destroy() end
    local guiParent = PlayerGui
    pcall(function()
        if gethui then
            guiParent = gethui()
        elseif get_hidden_gui then
            guiParent = get_hidden_gui()
        end
    end)
    local dup = guiParent:FindFirstChild("RollAPackUI")
    if dup then dup:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "RollAPackUI"
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.DisplayOrder = 999
    sg.IgnoreGuiInset = true
    sg.Parent = guiParent
    log("GUI parented to:", guiParent:GetFullName())

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 400, 0, 340)
    frame.Position = UDim2.new(0.5, -200, 0.5, -170)
    frame.BackgroundColor3 = UI_BG
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = sg
    uiStroke(frame, Color3.fromRGB(220, 220, 220))
    uiCorner(frame, 10)
    frame.ClipsDescendants = false

    -- TOP BAR — clean white/grey
    local top = Instance.new("Frame")
    top.Name = "TopBar"
    top.Size = UDim2.new(1, 0, 0, 44)
    top.BackgroundColor3 = UI_CARD
    top.BorderSizePixel = 0
    top.Parent = frame
    uiCorner(top, 10)
    -- fix corners clipping: bottom corners square so top rounding only
    local topFix = Instance.new("Frame")
    topFix.Size = UDim2.new(1, 0, 0, 10)
    topFix.Position = UDim2.new(0, 0, 1, -10)
    topFix.BackgroundColor3 = UI_CARD
    topFix.BorderSizePixel = 0
    topFix.Parent = top
    local topLine = Instance.new("Frame")
    topLine.Size = UDim2.new(1, 0, 0, 2)
    topLine.Position = UDim2.new(0, 0, 1, -2)
    topLine.BackgroundColor3 = Color3.fromRGB(220,220,220)
    topLine.BorderSizePixel = 0
    topLine.Parent = top

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 12, 0, 6)
    title.Size = UDim2.new(0, 220, 0, 20)
    title.Font = MC_FONT
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = UI_TEXT
    title.Text = "ROLL-A-PACK"
    title.Parent = top

    local credit = Instance.new("TextLabel")
    credit.BackgroundTransparency = 1
    credit.Position = UDim2.new(0, 12, 0, 26)
    credit.Size = UDim2.new(0, 220, 0, 12)
    credit.Font = Enum.Font.Gotham
    credit.TextSize = 10
    credit.TextXAlignment = Enum.TextXAlignment.Left
    credit.TextColor3 = UI_DIM
    credit.Text = "made by 4lxamm (beginner scripter)"
    credit.Parent = top

    local minBtn = uiButton(top, "_", Color3.fromRGB(235,235,235), 16)
    minBtn.AnchorPoint = Vector2.new(1, 0.5)
    minBtn.Position = UDim2.new(1, -8, 0.5, 0)
    minBtn.Size = UDim2.new(0, 32, 0, 28)

    -- scrollable content for future additions
    local content = Instance.new("ScrollingFrame")
    content.Name = "Content"
    content.Position = UDim2.new(0, 0, 0, 44)
    content.Size = UDim2.new(1, 0, 1, -44)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 4
    content.ScrollBarImageTransparency = 0.3
    content.CanvasSize = UDim2.new(0, 0, 0, 0)
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    content.ScrollingDirection = Enum.ScrollingDirection.Y
    content.Parent = frame
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = content
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 6)
    pad.PaddingRight = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.Parent = content

    local function makeSection(titleText)
        local s = Instance.new("TextLabel")
        s.BackgroundColor3 = Color3.fromRGB(235,235,235)
        s.Size = UDim2.new(1, 0, 0, 22)
        s.Font = MC_FONT
        s.TextSize = 11
        s.TextXAlignment = Enum.TextXAlignment.Left
        s.TextColor3 = UI_DIM
        s.Text = "  " .. titleText
        s.Parent = content
        uiCorner(s, 6)
        return s
    end

    local function makeRow(name, subText)
        local row = Instance.new("Frame")
        row.BackgroundColor3 = UI_CARD
        row.Size = UDim2.new(1, 0, 0, 46)
        row.Parent = content
        uiStroke(row, Color3.fromRGB(228, 228, 228))
        uiCorner(row, 8)
        local nameL = Instance.new("TextLabel")
        nameL.BackgroundTransparency = 1
        nameL.Position = UDim2.new(0, 10, 0, 4)
        nameL.Size = UDim2.new(1, -84, 0, 18)
        nameL.Font = MC_FONT
        nameL.TextSize = 12
        nameL.TextXAlignment = Enum.TextXAlignment.Left
        nameL.TextColor3 = UI_TEXT
        nameL.Text = name
        nameL.Parent = row
        local subL = Instance.new("TextLabel")
        subL.BackgroundTransparency = 1
        subL.Position = UDim2.new(0, 10, 0, 22)
        subL.Size = UDim2.new(1, -84, 0, 16)
        subL.Font = MC_FONT
        subL.TextSize = 10
        subL.TextXAlignment = Enum.TextXAlignment.Left
        subL.TextColor3 = UI_DIM
        subL.Text = subText
        subL.Parent = row
        return row
    end

    local function makeToggle(name, subText, default, callback)
        local row = makeRow(name, subText)
        -- clean white/grey on/off: ON = dark grey, OFF = light grey
        local pill = uiButton(row, default and "ON" or "OFF", default and Color3.fromRGB(45,45,45) or Color3.fromRGB(210,210,210), 11)
        pill.AnchorPoint = Vector2.new(1, 0.5)
        pill.Position = UDim2.new(1, -10, 0.5, 0)
        pill.Size = UDim2.new(0, 60, 0, 28)
        pill.TextColor3 = default and Color3.fromRGB(255,255,255) or UI_TEXT
        local state = default
        addConnection(pill.Activated, function()
            state = not state
            pill.Text = state and "ON" or "OFF"
            pill.BackgroundColor3 = state and Color3.fromRGB(45,45,45) or Color3.fromRGB(210,210,210)
            pill.TextColor3 = state and Color3.fromRGB(255,255,255) or UI_TEXT
            callback(state)
        end)
        return row
    end

    local function makeActionBtn(text, bg, height)
        local b = uiButton(content, text, bg or Color3.fromRGB(24, 24, 32), 13)
        b.Size = UDim2.new(1, 0, 0, height or 32)
        return b
    end

    -- AUTOMATION
    makeSection("AUTO REBIRTH")
    makeToggle("Auto Rebirth", "every 5 seconds", CONFIG.AUTO_REBIRTH, function(v)
        CONFIG.AUTO_REBIRTH = v
        if v then doRebirth() end
    end)
    local rebirthNowBtn = makeActionBtn("Rebirth Now", UI_GOLD, 32)
    addConnection(rebirthNowBtn.Activated, function()
        cmdrExec("rebirth")
        pressRebirthButton()
        fireRebirth(rebirthRemote, "Rebirth(manual)")
    end)

    makeSection("LUCKY AREA")
    makeToggle("Lucky TP", "always TP to Lucky Circle when ON", CONFIG.AUTO_LUCKY, function(v)
        CONFIG.AUTO_LUCKY = v
        if v then doLucky() end
    end)

    makeSection("PACK SHOP")
    local openShopBtn = makeActionBtn("Open Pack Shop", UI_GOLD, 32)
    addConnection(openShopBtn.Activated, function()
        openPackShop()
    end)
    makeToggle("Auto Buy Pack Shop", "buys pack via remote everywhere", CONFIG.AUTO_BUY_SHOP, function(v)
        CONFIG.AUTO_BUY_SHOP = v
        if v then doAutoBuyShop() end
    end)
    -- pack selector foldout — jungle pack / volcanic pack
    local PACK_LIST = {"Jungle Pack", "Volcanic Pack"}
    CONFIG.SELECTED_PACK = PACK_LIST[1]
    local packHeader = makeActionBtn("Selected Pack: " .. CONFIG.SELECTED_PACK .. "  ▼", nil, 34)
    uiCorner(packHeader, 10)
    local packFold = Instance.new("Frame")
    packFold.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
    packFold.Size = UDim2.new(1, 0, 0, 0)
    packFold.Visible = false
    packFold.ClipsDescendants = true
    packFold.Parent = content
    uiCorner(packFold, 10)
    uiStroke(packFold, Color3.fromRGB(40, 40, 50))
    local foldLayout = Instance.new("UIListLayout")
    foldLayout.Padding = UDim.new(0, 4)
    foldLayout.SortOrder = Enum.SortOrder.LayoutOrder
    foldLayout.Parent = packFold
    local foldPad = Instance.new("UIPadding")
    foldPad.PaddingTop = UDim.new(0, 4)
    foldPad.PaddingBottom = UDim.new(0, 4)
    foldPad.PaddingLeft = UDim.new(0, 4)
    foldPad.PaddingRight = UDim.new(0, 4)
    foldPad.Parent = packFold
    local function refreshPackHeader()
        packHeader.Text = "Selected Pack: " .. (CONFIG.SELECTED_PACK or "none") .. "  " .. (packFold.Visible and "▲" or "▼")
    end
    local function closeFold()
        packFold.Visible = false
        packFold.Size = UDim2.new(1, 0, 0, 0)
        refreshPackHeader()
    end
    local function openFold()
        packFold.Visible = true
        packFold.Size = UDim2.new(1, 0, 0, #PACK_LIST * 34 + 8)
        refreshPackHeader()
    end
    addConnection(packHeader.Activated, function()
        if packFold.Visible then closeFold() else openFold() end
    end)
    for _, packName in ipairs(PACK_LIST) do
        local btn = uiButton(packFold, packName, CONFIG.SELECTED_PACK == packName and Color3.fromRGB(45,45,45) or Color3.fromRGB(245,245,245), 11)
        btn.Size = UDim2.new(1, 0, 0, 30)
        btn.Font = MC_FONT
        btn.TextColor3 = CONFIG.SELECTED_PACK == packName and Color3.fromRGB(255,255,255) or UI_TEXT
        addConnection(btn.Activated, function()
            CONFIG.SELECTED_PACK = packName
            -- update all buttons highlight
            for _, child in ipairs(packFold:GetChildren()) do
                if child:IsA("TextButton") then
                    local isSel = child.Text == packName
                    child.BackgroundColor3 = isSel and Color3.fromRGB(45,45,45) or Color3.fromRGB(245,245,245)
                    child.TextColor3 = isSel and Color3.fromRGB(255,255,255) or UI_TEXT
                end
            end
            refreshPackHeader()
            closeFold()
            log("Selected pack:", packName)
        end)
    end
    -- Hotkey chooser row
    local hotkeyRow = makeRow("Shop Hotkey", "press Set then a key")
    local hotkeyLabel = Instance.new("TextLabel")
    hotkeyLabel.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
    hotkeyLabel.AnchorPoint = Vector2.new(1, 0.5)
    hotkeyLabel.Position = UDim2.new(1, -84, 0.5, 0)
    hotkeyLabel.Size = UDim2.new(0, 70, 0, 28)
    hotkeyLabel.Font = MC_FONT
    hotkeyLabel.TextSize = 11
    hotkeyLabel.TextColor3 = UI_TEXT
    hotkeyLabel.Text = CONFIG.SHOP_HOTKEY.Name
    hotkeyLabel.Parent = hotkeyRow
    uiCorner(hotkeyLabel, 6)
    uiStroke(hotkeyLabel, Color3.fromRGB(220,220,220))
    local setHotkeyBtn = uiButton(hotkeyRow, "Set", Color3.fromRGB(240,240,240), 11)
    setHotkeyBtn.AnchorPoint = Vector2.new(1, 0.5)
    setHotkeyBtn.Position = UDim2.new(1, -10, 0.5, 0)
    setHotkeyBtn.Size = UDim2.new(0, 60, 0, 28)
    local waitingForKey = false
    addConnection(setHotkeyBtn.Activated, function()
        if waitingForKey then return end
        waitingForKey = true
        setHotkeyBtn.Text = "..."
        hotkeyLabel.Text = "Press key..."
        log("Press any key to set Shop hotkey...")
    end)
    addConnection(UserInputService.InputBegan, function(input, gp)
        if waitingForKey then
            if input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode ~= Enum.KeyCode.LeftControl then
                CONFIG.SHOP_HOTKEY = input.KeyCode
                hotkeyLabel.Text = input.KeyCode.Name
                setHotkeyBtn.Text = "Set"
                waitingForKey = false
                log("Shop hotkey set to:", input.KeyCode.Name)
            end
            return
        end
        if gp then return end
        if input.KeyCode == CONFIG.SHOP_HOTKEY then
            openPackShop()
        end
    end)

    -- DEBUG / ANTI-AFK / EJECT
    makeSection("DEBUG")
    makeToggle("Anti-AFK", "prevents idle kick", CONFIG.ANTI_AFK, function(v)
        CONFIG.ANTI_AFK = v
        if v then
            addConnection(LocalPlayer.Idled, function()
                VirtualUser:Button2Down(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
                task.wait(0.1)
                VirtualUser:Button2Up(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
                log("Anti-AFK triggered")
            end)
            log("Anti-AFK enabled")
        else
            log("Anti-AFK disabled — re-execute to fully disconnect")
        end
    end)
    local ejectBtn = makeActionBtn("EJECT  —  STOP EVERYTHING", UI_RED, 34)
    addConnection(ejectBtn.Activated, ejectScript)

    -- Minimize + LeftControl toggle
    local minimized = false
    local fullSize = UDim2.new(0, 400, 0, 320)
    local miniSize = UDim2.new(0, 400, 0, 44)
    addConnection(minBtn.Activated, function()
        minimized = not minimized
        minBtn.Text = minimized and "+" or "_"
        content.Visible = not minimized
        frame.Size = minimized and miniSize or fullSize
    end)
    addConnection(UserInputService.InputBegan, function(input, gp)
        if gp then return end
        if input.KeyCode == Enum.KeyCode.LeftControl then
            sg.Enabled = not sg.Enabled
            log("GUI toggled:", sg.Enabled and "ON" or "OFF", "(LeftControl)")
        end
    end)

    return sg
end

-- START
local uiOk, uiErr = pcall(createUI)
if not uiOk then
    warn("[RollAPack] GUI failed to build: " .. tostring(uiErr))
end
if CONFIG.AUTO_REBIRTH then doRebirth() end
if CONFIG.AUTO_LUCKY then doLucky() end
if CONFIG.AUTO_BUY_SHOP then doAutoBuyShop() end

log("══════════════════════════════════════")
log("  Roll-A-Pack loaded! Rebirth 5s + Lucky spoof")
log("  Enable toggles in GUI — LeftControl to toggle")
log("══════════════════════════════════════")

if not rebirthRemote and not CmdrClient then
    warn("[RollAPack] No rebirth remote detected!")
end
