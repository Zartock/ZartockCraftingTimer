-- Zartock Crafting Timer
--
-- While a queue of several crafts is running ("Create All", or a count above
-- one), shows how long it takes until the whole queue is done.
--
-- The game only tells addons about the craft that is being cast right now
-- (UnitCastingInfo) and how many more will follow it
-- (C_TradeSkillUI.GetRemainingRecasts). The total is therefore
--
--     time left on the current cast + crafts still to come * time per craft
--
-- Time per craft starts out as the cast time and is replaced by the measured
-- time between two cast starts as soon as there is one, because that includes
-- the short pause the server adds between crafts.

local ADDON_NAME = ...

local DEFAULT_POSITION = { point = "CENTER", x = 0, y = -180 };

-- Between two crafts nothing is being cast for a moment. The timer stays up
-- for this long waiting for the next cast before it assumes the queue ended.
local GAP_GRACE = 1.5;

local UPDATE_INTERVAL = 0.1;

local db;

local state = {
    casting = false,    -- a craft is being cast right now
    multi = false,      -- this queue had more than one craft, so it is worth showing
    preview = false,    -- /zct: shown with sample numbers so it can be moved
    endTime = 0,        -- GetTime() at which the current cast ends
    perCraft = 0,       -- seconds from one cast start to the next
    lastStart = nil,    -- GetTime() at which the previous cast started
    recasts = 0,        -- crafts still to come after the current one
    gapDeadline = 0,    -- GetTime() at which a pause between crafts is given up on
};

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value);
end

local function FormatTime(seconds)
    seconds = math.ceil(seconds);
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60);
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60);
end

----------------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ZartockCraftingTimerFrame", UIParent, "BackdropTemplate");
frame:SetSize(150, 46);
frame:SetFrameStrata("HIGH");
frame:SetClampedToScreen(true);
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
});
frame:SetBackdropColor(0, 0, 0, 0.8);
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1);
frame:Hide();

local timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge");
timeText:SetPoint("TOP", 0, -8);

local countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
countText:SetPoint("BOTTOM", 0, 8);

local function ApplyPosition()
    local pos = db.position or DEFAULT_POSITION;
    frame:ClearAllPoints();
    frame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y);
end

frame:SetMovable(true);
frame:EnableMouse(true);
frame:RegisterForDrag("LeftButton");
frame:SetScript("OnDragStart", frame.StartMoving);
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing();
    local point, _, _, x, y = self:GetPoint(1);
    db.position = { point = point, x = x, y = y };
    ApplyPosition();
end);

local function SetDisplay(seconds, crafts)
    timeText:SetText(FormatTime(seconds));
    countText:SetText(crafts == 1 and "last craft" or (crafts .. " crafts left"));
end

----------------------------------------------------------------------------
-- Queue tracking
----------------------------------------------------------------------------

local function EndQueue()
    state.casting = false;
    state.multi = false;
    state.lastStart = nil;
    state.recasts = 0;
    if not state.preview then
        frame:Hide();
    end
end

local function Refresh()
    if state.preview then
        SetDisplay(754, 12);
        return;
    end

    local now = GetTime();
    if not state.casting then
        -- Pause between two crafts: keep the last numbers until the next
        -- cast starts, or give up when it does not.
        if now > state.gapDeadline then
            EndQueue();
        end
        return;
    end

    state.recasts = C_TradeSkillUI.GetRemainingRecasts() or 0;
    if state.recasts > 0 then
        state.multi = true;
    end
    if not state.multi then
        return;     -- a single craft; the cast bar already covers that
    end

    local remaining = math.max(0, state.endTime - now) + state.recasts * state.perCraft;
    SetDisplay(remaining, state.recasts + 1);
    frame:Show();
end

local function OnCastStart()
    local name, _, _, startMs, endMs, isTradeSkill = UnitCastingInfo("player");
    if not name or not isTradeSkill or IsSecret(startMs) or IsSecret(endMs) then
        -- Casting anything else cancels a craft queue.
        EndQueue();
        return;
    end

    local start = startMs / 1000;
    local duration = (endMs - startMs) / 1000;

    local sinceLast = state.lastStart and (start - state.lastStart);
    if sinceLast and sinceLast >= duration and sinceLast <= duration + 2 then
        state.perCraft = sinceLast;
    elseif not state.lastStart or state.perCraft < duration then
        state.perCraft = duration;
    end

    state.casting = true;
    state.endTime = endMs / 1000;
    state.lastStart = start;
    Refresh();
end

local function OnCastEnd()
    if not state.casting then
        return;
    end
    state.casting = false;
    if state.recasts > 0 then
        state.gapDeadline = GetTime() + GAP_GRACE;
    else
        EndQueue();
    end
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

local elapsedSinceUpdate = 0;
frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed;
    if elapsedSinceUpdate >= UPDATE_INTERVAL then
        elapsedSinceUpdate = 0;
        Refresh();
    end
end);

-- A separate frame for events, so they keep arriving while the display is hidden.
local events = CreateFrame("Frame");
events:RegisterEvent("ADDON_LOADED");
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return;
        end
        ZartockCraftingTimerDB = ZartockCraftingTimerDB or {};
        db = ZartockCraftingTimerDB;
        ApplyPosition();

        self:UnregisterEvent("ADDON_LOADED");
        self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player");
        self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player");
        self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player");
        self:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED");
    elseif event == "UNIT_SPELLCAST_START" then
        OnCastStart();
    elseif event == "UNIT_SPELLCAST_STOP" then
        OnCastEnd();
    else
        -- Interrupted (moved, cancelled, out of materials): the queue is gone.
        EndQueue();
    end
end);

----------------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------------

SLASH_ZARTOCKCRAFTINGTIMER1 = "/zct";
SlashCmdList.ZARTOCKCRAFTINGTIMER = function(msg)
    msg = strlower(strtrim(msg or ""));
    if msg == "reset" then
        db.position = nil;
        ApplyPosition();
        print("|cff33ff99Crafting Timer|r: position reset.");
        return;
    end

    state.preview = not state.preview;
    if state.preview then
        Refresh();
        frame:Show();
        print("|cff33ff99Crafting Timer|r: drag the timer where you want it, then type /zct again. /zct reset puts it back.");
    elseif not state.multi then
        frame:Hide();
    end
end;
