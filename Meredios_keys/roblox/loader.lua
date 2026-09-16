--[[
    MEREDIOS key loader
    1. Замени API_URL на URL от Bothost
    2. Замени API_SECRET на тот же секрет
    3. Замени MAIN_SCRIPT_URL на raw-url самого HUD-скрипта
]]

local API_URL         = "https://ТВОЙ-БОТ.bothost.tech/validate"
local API_SECRET      = "ВСТАВЬ_СЮДА_API_SECRET"
local MAIN_SCRIPT_URL = "https://raw.githubusercontent.com/ТВОЙ_ЮЗЕР/ТВОЙ_РЕПО/main/meredios.lua"

local Players   = game:GetService("Players")
local HttpSvc   = game:GetService("HttpService")
local LP        = Players.LocalPlayer

local function getHWID()
    local ok, id = pcall(function()
        return game:GetService("RbxAnalyticsService"):GetClientId()
    end)
    if ok and id then return id end
    return tostring(LP.UserId) .. ":" .. tostring(game.PlaceId)
end

local function readSaved()
    if type(readfile) ~= "function" then return nil end
    local ok, data = pcall(readfile, "meredios_key.txt")
    if ok and data and #data > 8 then return data end
    return nil
end

local function saveKey(k)
    if type(writefile) ~= "function" then return end
    pcall(writefile, "meredios_key.txt", k)
end

local HWID = getHWID()

local function requestValidate(key)
    local ok, resp = pcall(function()
        return HttpSvc:PostAsync(
            API_URL,
            HttpSvc:JSONEncode({ key = key, hwid = HWID }),
            Enum.HttpContentType.ApplicationJson,
            false,
            { ["X-Api-Secret"] = API_SECRET }
        )
    end)
    if not ok or not resp then return nil end
    local okd, data = pcall(function() return HttpSvc:JSONDecode(resp) end)
    if not okd then return nil end
    return data
end

local function makeKeyUI(onSubmit)
    local gui = Instance.new("ScreenGui")
    gui.Name = "MerediosKeyPrompt"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    local okH, hui = pcall(function() return gethui() end)
    gui.Parent = (okH and hui) or LP:WaitForChild("PlayerGui")

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0, 340, 0, 190)
    panel.Position = UDim2.new(0.5, 0, 0.5, 0)
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.BackgroundColor3 = Color3.fromRGB(31, 37, 52)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)

    local stroke = Instance.new("UIStroke", panel)
    stroke.Thickness = 2
    stroke.Color = Color3.fromRGB(90, 130, 240)
    local grad = Instance.new("UIGradient", stroke)
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 64, 175)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 95, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 95, 175)),
    })

    local title = Instance.new("TextLabel", panel)
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 18, 0, 14)
    title.Size = UDim2.new(1, -36, 0, 22)
    title.Text = "MEREDIOS · KEY"
    title.TextColor3 = Color3.fromRGB(235, 240, 250)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left

    local sub = Instance.new("TextLabel", panel)
    sub.BackgroundTransparency = 1
    sub.Position = UDim2.new(0, 18, 0, 38)
    sub.Size = UDim2.new(1, -36, 0, 16)
    sub.Text = "ключ выдаётся в t.me//meredioshub"
    sub.TextColor3 = Color3.fromRGB(145, 158, 182)
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 10
    sub.TextXAlignment = Enum.TextXAlignment.Left

    local box = Instance.new("TextBox", panel)
    box.Position = UDim2.new(0, 18, 0, 66)
    box.Size = UDim2.new(1, -36, 0, 34)
    box.BackgroundColor3 = Color3.fromRGB(24, 29, 41)
    box.BorderSizePixel = 0
    box.Text = ""
    box.PlaceholderText = "XXXX-XXXX-XXXX-XXXX"
    box.TextColor3 = Color3.fromRGB(235, 240, 250)
    box.PlaceholderColor3 = Color3.fromRGB(90, 100, 122)
    box.Font = Enum.Font.Code
    box.TextSize = 13
    box.ClearTextOnFocus = false
    box.Parent = panel
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)

    local btn = Instance.new("TextButton", panel)
    btn.Position = UDim2.new(0, 18, 0, 112)
    btn.Size = UDim2.new(1, -36, 0, 34)
    btn.BackgroundColor3 = Color3.fromRGB(30, 64, 175)
    btn.Text = "ПОДТВЕРДИТЬ"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.AutoButtonColor = false
    btn.BorderSizePixel = 0
    btn.Parent = panel
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local status = Instance.new("TextLabel", panel)
    status.BackgroundTransparency = 1
    status.Position = UDim2.new(0, 18, 0, 152)
    status.Size = UDim2.new(1, -36, 0, 22)
    status.Text = ""
    status.TextColor3 = Color3.fromRGB(255, 90, 90)
    status.Font = Enum.Font.Gotham
    status.TextSize = 10
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextWrapped = true

    local busy = false
    btn.MouseButton1Click:Connect(function()
        if busy then return end
        local key = box.Text:gsub("%s", ""):upper()
        if #key < 8 then
            status.Text = "❌ слишком короткий ключ"
            return
        end
        busy = true
        btn.Text = "..."
        status.Text = ""
        task.spawn(function()
            local resp = requestValidate(key)
            busy = false
            btn.Text = "ПОДТВЕРДИТЬ"
            if not resp then
                status.Text = "❌ сервер недоступен"
                return
            end
            if resp.ok then
                saveKey(key)
                status.TextColor3 = Color3.fromRGB(80, 220, 100)
                status.Text = "✅ принято · " .. tostring(resp.days_left or 0) .. " дн."
                task.wait(0.6)
                gui:Destroy()
                onSubmit(key, resp)
            else
                local map = {
                    not_found      = "❌ ключ не найден",
                    revoked        = "❌ ключ отозван",
                    expired        = "❌ ключ истёк",
                    hwid_mismatch  = "❌ HWID занят · /rebind в боте",
                    unauthorized   = "❌ API-секрет неверный",
                    bad_json       = "❌ ошибка формата",
                    missing_fields = "❌ пустой ключ",
                }
                status.Text = map[resp.status] or ("❌ " .. tostring(resp.status))
            end
        end)
    end)
    box.FocusLost:Connect(function(enter)
        if enter then btn.MouseButton1Click:Fire() end
    end)
end

local function launch()
    local ok, src = pcall(function() return game:HttpGet(MAIN_SCRIPT_URL) end)
    if not ok or not src then
        warn("[MEREDIOS] main script fetch failed")
        return
    end
    local fn = loadstring(src)
    if not fn then
        warn("[MEREDIOS] loadstring failed")
        return
    end
    local okr, err = pcall(fn)
    if not okr then
        warn("[MEREDIOS] main script error: " .. tostring(err))
    end
end

-- ---------- main ----------
local saved = readSaved()
if saved then
    local resp = requestValidate(saved)
    if resp and resp.ok then
        launch()
    else
        makeKeyUI(function() launch() end)
    end
else
    makeKeyUI(function() launch() end)
end
